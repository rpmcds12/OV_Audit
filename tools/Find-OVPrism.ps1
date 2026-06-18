#requires -Version 5.1
<#
.SYNOPSIS
    Discover Nutanix Prism endpoints on a subnet and identify each cluster's VIP.

.DESCRIPTION
    Read-only pre-flight helper. Scans a /24 for TCP 9440, then queries each
    responder's Prism Element /cluster endpoint to report the cluster name, node
    count, UUID, and the cluster Virtual IP (VIP) to put in config.psd1 under
    Nutanix.Prisms. Uses the same REST/auth path as the audit collector.

    Prism runs on the CVM IPs and the cluster VIP (not the AHV host IP), so a
    plain ping of a host tells you nothing about Prism. This finds the real ones.

    Run from PowerShell 7 (pwsh). On Windows PowerShell 5.1 the HTTPS call may
    fail the TLS handshake against recent AOS; PS7's modern stack avoids that.

.EXAMPLE
    pwsh ./tools/Find-OVPrism.ps1 -Subnet 198.18.244

.EXAMPLE
    # Reuse one credential set across the scan (e.g. an AD-integrated Prism login)
    pwsh ./tools/Find-OVPrism.ps1 -Subnet 10.20.30 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Subnet,         # first three octets, e.g. 198.18.244
    [int[]] $Range = (1..254),
    [int] $Port = 9440,
    [int] $ConnectTimeoutMs = 300,
    [pscredential] $Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reuse the collector's Prism REST + safe-property helpers for a consistent path.
$srcModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/OVAudit.Sources.psm1'
Import-Module $srcModule -Force

if (-not $Credential) { $Credential = Get-Credential -Message 'Prism login (a read-only Viewer account is fine)' }

# ── 1. Scan the subnet for anything answering on the Prism port ────────────
Write-Host "Scanning $Subnet.0/24 for Prism on TCP $Port ..." -ForegroundColor Cyan
$responders = foreach ($n in $Range) {
    $ip = "$Subnet.$n"
    $c = New-Object Net.Sockets.TcpClient
    try { if ($c.ConnectAsync($ip, $Port).Wait($ConnectTimeoutMs)) { $ip } } catch {} finally { $c.Dispose() }
}
$responders = @($responders)
Write-Host "  $($responders.Count) host(s) answering on $Port." -ForegroundColor Cyan
if (-not $responders.Count) { Write-Warning "Nothing on $Port. Check the subnet and that you can reach the CVM/VIP network."; return }

# ── 2. Ask each responder which cluster it is ──────────────────────────────
# PS5.1 needs cert validation relaxed before the HTTPS call; scope it to the
# responders we actually probe rather than trusting every HTTPS cert process-wide.
$restoreCb = $null
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $script:OVPrismAllowed = @{}
    foreach ($ip in $responders) { $script:OVPrismAllowed["$ip".ToLower()] = $true }
    $restoreCb = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($snd, $cert, $chain, $errs)
        if ($errs -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
        $h = $null
        try { if ($snd -is [System.Net.HttpWebRequest]) { $h = $snd.Address.Host } } catch {}
        return [bool]($h -and $script:OVPrismAllowed.ContainsKey($h.ToLower()))
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
try {
    $results = foreach ($ip in $responders) {
        try {
            $c = Invoke-OVPrismRest -Url "https://$($ip):$Port/PrismGateway/services/rest/v2.0/cluster" -Credential $Credential -TimeoutSec 15
            [pscustomobject]@{
                IP      = $ip
                Cluster = (Get-OVProp $c 'name')
                Nodes   = (Get-OVProp $c 'num_nodes')
                VIP     = (Get-OVProp $c 'cluster_external_ipaddress')
                UUID    = (Get-OVProp $c 'cluster_uuid')
            }
        }
        catch {
            [pscustomobject]@{ IP = $ip; Cluster = "ERR: $($_.Exception.Message)"; Nodes = $null; VIP = $null; UUID = $null }
        }
    }
}
finally {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $restoreCb
        Remove-Variable -Name OVPrismAllowed -Scope Script -ErrorAction SilentlyContinue
    }
}
$results = @($results)

# ── 3. Report ──────────────────────────────────────────────────────────────
Write-Host "`nAll responders:" -ForegroundColor Cyan
$results | Sort-Object UUID | Format-Table -AutoSize

$clusters = @($results | Where-Object UUID | Sort-Object UUID -Unique)
Write-Host "Distinct clusters found:" -ForegroundColor Green
$clusters | Select-Object Cluster, Nodes, VIP, UUID | Format-Table -AutoSize

$errs = @($results | Where-Object { -not $_.UUID })
if ($errs.Count) {
    Write-Host "Responded on $Port but did not authenticate (likely other clusters needing different credentials, or a non-Prism device):" -ForegroundColor Yellow
    $errs | Select-Object IP, Cluster | Format-Table -AutoSize
}

if ($clusters.Count) {
    # Prefer the VIP; fall back to the responding IP if a cluster has no VIP set.
    $targets = $clusters | ForEach-Object { if ($_.VIP) { $_.VIP } else { $_.IP } }
    $arr = ($targets | ForEach-Object { "'$_'" }) -join ', '
    Write-Host "`nPaste into config.psd1 under Nutanix:" -ForegroundColor Green
    Write-Host "    Prisms = @($arr)"
}
