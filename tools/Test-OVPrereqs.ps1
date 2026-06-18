#requires -Version 5.1
<#
.SYNOPSIS
    Read-only pre-flight check for OV-Audit. Verifies prerequisites and
    connectivity for the sources your config enables, and reports PASS / WARN /
    FAIL per item so you can fix problems before running the full audit.

.DESCRIPTION
    Checks (scoped to enabled sources): PowerShell version, execution policy,
    Mark-of-the-Web on downloaded files, config sanity, the required modules,
    TCP reachability to each source, and a SAMPLE of AD servers for WinRM/DCOM
    (the single best predictor of whether the per-server sweep will reach anything).
    Nothing is changed; it only reads and tests connections.

.EXAMPLE
    pwsh ./tools/Test-OVPrereqs.ps1 -ConfigPath .\config.psd1

.NOTES
    Exit code 0 = no failures, 1 = at least one FAIL. SampleServers controls how
    many AD servers are probed for reachability (default 5).
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = '.\config.psd1',
    [int] $SampleServers = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$results = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string] $Area, [string] $Check, [ValidateSet('PASS','WARN','FAIL','SKIP')] [string] $Result, [string] $Detail)
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Result = $Result; Detail = $Detail })
}
function Test-OVPort {
    param([string] $ComputerName, [int] $Port, [int] $TimeoutMs = 800)
    $c = [Net.Sockets.TcpClient]::new()
    try { if ($c.ConnectAsync($ComputerName, $Port).Wait($TimeoutMs)) { return $true } } catch {} finally { $c.Dispose() }
    return $false
}
function Test-OVModule { param([string] $Name) [bool](Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue) }
function Get-OVSafe { param($Object, [string] $Path, $Default = $null)
    # dotted safe getter for nested config (e.g. 'VMware.Enabled')
    $cur = $Object
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) { if ($cur.Contains($p)) { $cur = $cur[$p] } else { return $Default } }
        elseif ($cur.PSObject.Properties[$p]) { $cur = $cur.$p } else { return $Default }
    }
    return $cur
}

# ── Config ─────────────────────────────────────────────────────────────────
$cfg = $null
if (Test-Path $ConfigPath) {
    try { $cfg = Import-PowerShellDataFile -Path $ConfigPath; Add-Check 'Config' 'config.psd1 loads' 'PASS' $ConfigPath }
    catch { Add-Check 'Config' 'config.psd1 loads' 'FAIL' "Parse error: $($_.Exception.Message)" }
} else {
    Add-Check 'Config' 'config.psd1 exists' 'FAIL' "Not found. Copy config.example.psd1 to config.psd1 and edit it."
    $example = Join-Path $root 'config.example.psd1'
    if (Test-Path $example) { $cfg = Import-PowerShellDataFile -Path $example }   # fall back to learn structure
}

$en = @{
    AD      = [bool](Get-OVSafe $cfg 'ActiveDirectory.Enabled' $false)
    VMware  = [bool](Get-OVSafe $cfg 'VMware.Enabled' $false)
    HyperV  = [bool](Get-OVSafe $cfg 'HyperV.Enabled' $false)
    Nutanix = [bool](Get-OVSafe $cfg 'Nutanix.Enabled' $false)
    Azure   = [bool](Get-OVSafe $cfg 'Azure.Enabled' $false)
    SCCM    = [bool](Get-OVSafe $cfg 'ConfigMgr.Enabled' $false)
}
if ($cfg) {
    $anyHv = $en.VMware -or $en.HyperV -or $en.Nutanix
    Add-Check 'Config' 'At least one source enabled' ($(if ($en.AD -or $anyHv -or $en.Azure -or $en.SCCM) { 'PASS' } else { 'FAIL' })) ("Enabled: " + (($en.GetEnumerator() | Where-Object Value | ForEach-Object Key) -join ', '))
    Add-Check 'Config' 'At least one hypervisor enabled' ($(if ($anyHv) { 'PASS' } else { 'WARN' })) 'Without a hypervisor, physical host core counts are not collected.'
    if ((Get-OVSafe $cfg 'Report.CustomerName' '') -in @('', 'Contoso Ltd', 'Acme Corporation')) { Add-Check 'Config' 'CustomerName set' 'WARN' 'Still the placeholder; set Report.CustomerName.' } else { Add-Check 'Config' 'CustomerName set' 'PASS' (Get-OVSafe $cfg 'Report.CustomerName' '') }
    if ((Get-OVSafe $cfg 'Licensing.StandardPerCore' 0) -eq 73.50 -and (Get-OVSafe $cfg 'Licensing.DatacenterPerCore' 0) -eq 423.19) { Add-Check 'Config' 'Pricing customised' 'WARN' 'Using Microsoft suggested-list pricing; replace with the customer Open Value price for a real number.' } else { Add-Check 'Config' 'Pricing customised' 'PASS' 'Custom pricing set.' }
}

# ── Environment ──────────────────────────────────────────────────────────────
$ps = $PSVersionTable.PSVersion
if ($ps.Major -ge 7) { Add-Check 'Environment' 'PowerShell version' 'PASS' "$ps (7+ recommended)" }
elseif ($en.Nutanix -or $en.Azure) { Add-Check 'Environment' 'PowerShell version' 'WARN' "$ps - Nutanix/Azure are enabled; run from PowerShell 7 (pwsh) to avoid TLS/module issues." }
else { Add-Check 'Environment' 'PowerShell version' 'PASS' "$ps" }

try {
    $ep = Get-ExecutionPolicy
    if ($ep -in @('Restricted','AllSigned')) { Add-Check 'Environment' 'Execution policy' 'WARN' "$ep - run with: Set-ExecutionPolicy -Scope Process Bypass -Force" }
    else { Add-Check 'Environment' 'Execution policy' 'PASS' "$ep" }
} catch {}

try {
    $blocked = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { Get-Item $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue }).Count
    if ($blocked -gt 0) { Add-Check 'Environment' 'Files unblocked (Mark-of-the-Web)' 'FAIL' "$blocked file(s) carry the internet block. Run: Get-ChildItem -Recurse -File | Unblock-File" }
    else { Add-Check 'Environment' 'Files unblocked (Mark-of-the-Web)' 'PASS' 'No blocked files.' }
} catch { Add-Check 'Environment' 'Files unblocked (Mark-of-the-Web)' 'SKIP' 'Could not check (non-Windows filesystem?).' }

# ── Modules (scoped to enabled sources) ─────────────────────────────────────
if ($en.AD) {
    if (Test-OVModule 'ActiveDirectory') { Add-Check 'Modules' 'RSAT ActiveDirectory' 'PASS' '' }
    else {
        $pt = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType } catch { 0 }
        $how = if ($pt -eq 1) { 'Windows 10/11: run in Windows PowerShell 5.1 -> Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' }
               else { 'Windows Server: Install-WindowsFeature RSAT-AD-PowerShell' }
        Add-Check 'Modules' 'RSAT ActiveDirectory' 'FAIL' $how
    }
}
if ($en.VMware) { $haveVmw = (Test-OVModule 'VMware.VimAutomation.Core') -or (Test-OVModule 'VMware.PowerCLI'); Add-Check 'Modules' 'VMware PowerCLI' ($(if ($haveVmw) { 'PASS' } else { 'FAIL' })) 'Install-Module VMware.PowerCLI -Scope CurrentUser' }
if ($en.HyperV) { Add-Check 'Modules' 'Hyper-V module' ($(if (Test-OVModule 'Hyper-V') { 'PASS' } else { 'FAIL' })) 'Add via RSAT / Install-WindowsFeature' }
if ($en.Azure) {
    $haveAz = (Test-OVModule 'Az.Accounts') -and (Test-OVModule 'Az.ResourceGraph')
    Add-Check 'Modules' 'Az.Accounts + Az.ResourceGraph' ($(if ($haveAz) { 'PASS' } else { 'FAIL' })) 'Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser'
}
Add-Check 'Modules' 'ImportExcel (optional)' ($(if (Test-OVModule 'ImportExcel') { 'PASS' } else { 'WARN' })) 'Without it the report falls back to HTML. Install-Module ImportExcel -Scope CurrentUser'
$browser = @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
Add-Check 'Modules' 'Edge/Chrome for PDF (optional)' ($(if ($browser) { 'PASS' } else { 'WARN' })) ($(if ($browser) { $browser } else { 'No browser found; HTML/.doc still produced, export to PDF manually.' }))

# ── Connectivity (scoped to enabled sources) ────────────────────────────────
if ($en.AD) {
    if (Test-OVModule 'ActiveDirectory') {
        try { Import-Module ActiveDirectory -ErrorAction Stop; $d = Get-ADDomain -ErrorAction Stop; Add-Check 'Connectivity' 'Active Directory (ADWS 9389)' 'PASS' "Domain: $($d.DNSRoot)" }
        catch { Add-Check 'Connectivity' 'Active Directory (ADWS 9389)' 'FAIL' "Get-ADDomain failed: $($_.Exception.Message). Confirm TCP 9389 to a DC." }
    } else { Add-Check 'Connectivity' 'Active Directory' 'SKIP' 'RSAT module missing (see Modules).' }
}
if ($en.VMware) { foreach ($v in @(Get-OVSafe $cfg 'VMware.vCenters' @())) { Add-Check 'Connectivity' "VMware $v (443)" ($(if (Test-OVPort $v 443) { 'PASS' } else { 'FAIL' })) '' } }
if ($en.Nutanix) { foreach ($p in @(Get-OVSafe $cfg 'Nutanix.Prisms' @())) { $port = [int](Get-OVSafe $cfg 'Nutanix.Port' 9440); Add-Check 'Connectivity' "Nutanix Prism $p ($port)" ($(if (Test-OVPort $p $port) { 'PASS' } else { 'FAIL' })) 'Must be the Prism Element cluster VIP, not the AHV host IP or Prism Central.' } }
if ($en.SCCM) { $ss = Get-OVSafe $cfg 'ConfigMgr.SiteServer' $null; if ($ss) { Add-Check 'Connectivity' "SCCM $ss (135)" ($(if (Test-OVPort $ss 135) { 'PASS' } else { 'FAIL' })) '' } }
if ($en.Azure) {
    Add-Check 'Connectivity' 'Azure ARM (443)' ($(if (Test-OVPort 'management.azure.com' 443) { 'PASS' } else { 'FAIL' })) ''
    $ctx = if (Test-OVModule 'Az.Accounts') { try { Import-Module Az.Accounts -ErrorAction Stop; Get-AzContext -ErrorAction SilentlyContinue } catch { $null } } else { $null }
    Add-Check 'Connectivity' 'Azure signed in' ($(if ($ctx) { 'PASS' } else { 'WARN' })) ($(if ($ctx) { "Account: $($ctx.Account.Id)" } else { 'Run Connect-AzAccount (a Reader role is enough).' }))
}

# ── Target reachability sample (the best predictor of the per-server sweep) ──
if ($en.AD -and (Test-OVModule 'ActiveDirectory')) {
    try {
        Import-Module (Join-Path $root 'src/OVAudit.Sources.psm1') -Force -ErrorAction Stop
        $servers = @(Get-OVADServers -Server (Get-OVSafe $cfg 'ActiveDirectory.Server' $null) -SearchBase (Get-OVSafe $cfg 'ActiveDirectory.SearchBase' $null) -ServerOsFilter (Get-OVSafe $cfg 'ActiveDirectory.ServerOsFilter' '*Server*'))
        if ($servers.Count -eq 0) { Add-Check 'Targets' 'AD server sample' 'WARN' 'AD returned 0 server accounts to probe.' }
        else {
            $sample = $servers | Get-Random -Count ([math]::Min($SampleServers, $servers.Count))
            $winrm = 0; $dcom = 0
            foreach ($s in $sample) {
                $name = if ($s.DNSHostName) { $s.DNSHostName } else { $s.Name }
                if (Test-OVPort $name 5985) { $winrm++ }
                if (Test-OVPort $name 135)  { $dcom++ }
            }
            $n = $sample.Count
            $detail = "Of $n sampled: WinRM(5985) $winrm/$n, DCOM(135) $dcom/$n. The full sweep needs one of these per server."
            if ($winrm -eq 0 -and $dcom -eq 0) { Add-Check 'Targets' 'Servers reachable (CIM)' 'FAIL' "$detail Likely WinRM disabled, firewall, or wrong network. Per-server detail (OS edition/SQL) will be empty." }
            elseif ($winrm -lt $n -and $dcom -lt $n) { Add-Check 'Targets' 'Servers reachable (CIM)' 'WARN' $detail }
            else { Add-Check 'Targets' 'Servers reachable (CIM)' 'PASS' $detail }
        }
    } catch { Add-Check 'Targets' 'AD server sample' 'SKIP' "Could not enumerate/probe: $($_.Exception.Message)" }
}

# ── Report ───────────────────────────────────────────────────────────────────
$color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray' }
Write-Host ""
Write-Host "OV-Audit pre-flight" -ForegroundColor Cyan
Write-Host ("=" * 60)
foreach ($area in ($results | Select-Object -ExpandProperty Area -Unique)) {
    Write-Host "`n$area" -ForegroundColor Cyan
    foreach ($r in ($results | Where-Object Area -eq $area)) {
        Write-Host ("  [{0,-4}] " -f $r.Result) -ForegroundColor $color[$r.Result] -NoNewline
        Write-Host ("{0,-34} {1}" -f $r.Check, $r.Detail)
    }
}
$pass = @($results | Where-Object Result -eq 'PASS').Count
$warn = @($results | Where-Object Result -eq 'WARN').Count
$failC= @($results | Where-Object Result -eq 'FAIL').Count
Write-Host ("`n" + ("=" * 60))
Write-Host ("Summary: {0} PASS, {1} WARN, {2} FAIL" -f $pass, $warn, $failC) -ForegroundColor $(if ($failC) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })
if ($failC)    { Write-Host "Resolve the FAIL items before running the audit." -ForegroundColor Red }
elseif ($warn) { Write-Host "OK to run; review the WARN items (they reduce coverage, not correctness)." -ForegroundColor Yellow }
else           { Write-Host "Ready to run." -ForegroundColor Green }

if ($failC) { exit 1 } else { exit 0 }
