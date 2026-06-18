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

# Scan + identify (shared with the audit's auto-discovery).
Write-Host "Scanning $Subnet.0/24 for Prism on TCP $Port ..." -ForegroundColor Cyan
$disc = Find-OVPrismEndpoints -Subnet $Subnet -Range $Range -Port $Port -ConnectTimeoutMs $ConnectTimeoutMs -Credential $Credential
$responders = @($disc.Responders)
Write-Host "  $($responders.Count) host(s) answering on $Port." -ForegroundColor Cyan
if (-not $responders.Count) { Write-Warning "Nothing on $Port. Check the subnet and that you can reach the CVM/VIP network."; return }

$clusters = @($disc.Clusters)
Write-Host "`nDistinct clusters found ('Queryable' = a Prism Element cluster you can audit; non-queryable is usually Prism Central):" -ForegroundColor Green
$clusters | Select-Object Cluster, Nodes, VIP, Queryable, HostCount, UUID | Format-Table -AutoSize

$errs = @($disc.Errors)
if ($errs.Count) {
    Write-Host "Responded on $Port but did not authenticate (other-credential clusters or non-Prism devices):" -ForegroundColor Yellow
    $errs | Select-Object IP, Error | Format-Table -AutoSize
}

$pe = @($clusters | Where-Object Queryable)
if ($pe.Count) {
    $targets = $pe | ForEach-Object { if ($_.VIP) { $_.VIP } else { $_.IP } }
    $arr = ($targets | ForEach-Object { "'$_'" }) -join ', '
    Write-Host "`nQueryable Prism Element cluster(s). Paste into config.psd1 under Nutanix:" -ForegroundColor Green
    Write-Host "    Prisms = @($arr)"
} else {
    Write-Host "`nNo queryable Prism Element clusters found (only Prism Central / non-Prism, or wrong credentials)." -ForegroundColor Yellow
}
