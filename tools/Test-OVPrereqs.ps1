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

.EXAMPLE
    # Check, then remediate the LOCAL jump-box prerequisites that failed
    pwsh ./tools/Test-OVPrereqs.ps1 -ConfigPath .\config.psd1 -Fix

.EXAMPLE
    # Preview what -Fix would change without doing it
    pwsh ./tools/Test-OVPrereqs.ps1 -Fix -WhatIf

.NOTES
    Exit code 0 = no failures, 1 = at least one FAIL. SampleServers controls how
    many AD servers are probed for reachability (default 5).

    -Fix remediates ONLY local jump-box prerequisites: install missing modules
    (current-user), Unblock-File, set the process execution policy, and Azure
    sign-in. It NEVER changes the customer environment (WinRM on target servers,
    firewall, account rights) -- those are printed as guidance for the customer's
    admin to apply under change control. Module/feature installs may need an
    elevated session; re-run the check afterward to confirm.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = '.\config.psd1',
    [int] $SampleServers = 5,
    [switch] $Fix
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
    if ((Get-OVSafe $cfg 'Report.CustomerName' '') -in @('', '<CUSTOMER NAME>', 'Contoso Ltd', 'Acme Corporation')) { Add-Check 'Config' 'CustomerName set' 'WARN' 'Still the placeholder; set Report.CustomerName (the audit run will refuse to build the customer summary until you do).' } else { Add-Check 'Config' 'CustomerName set' 'PASS' (Get-OVSafe $cfg 'Report.CustomerName' '') }
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
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
Add-Check 'Modules' 'Git (optional, for clone/pull)' ($(if ($gitCmd) { 'PASS' } else { 'WARN' })) ($(if ($gitCmd) { (& git --version) } else { 'Not found. Only needed to clone/update the tool from GitHub (you can run from a ZIP instead). -Fix installs it via winget; or get it from https://git-scm.com/download/win' }))

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

# ── Report helpers ───────────────────────────────────────────────────────────
$color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray'; FIXED = 'Green' }
function Get-Res     { param([string] $Check)
    $e = $results | Where-Object Check -eq $Check | Select-Object -First 1
    if ($e) { $e.Result } else { $null } }
function Set-Res     { param([string] $Check, [string] $Result, [string] $Detail)
    $e = $results | Where-Object Check -eq $Check | Select-Object -First 1
    if ($e) { $e.Result = $Result; if ($Detail) { $e.Detail = $Detail } } }
function Show-OVReport {
    foreach ($area in ($results | Select-Object -ExpandProperty Area -Unique)) {
        Write-Host "`n$area" -ForegroundColor Cyan
        foreach ($r in ($results | Where-Object Area -eq $area)) {
            $c = if ($color.ContainsKey($r.Result)) { $color[$r.Result] } else { 'Gray' }
            Write-Host ("  [{0,-5}] " -f $r.Result) -ForegroundColor $c -NoNewline
            Write-Host ("{0,-34} {1}" -f $r.Check, $r.Detail)
        }
    }
}

Write-Host "`nOV-Audit pre-flight" -ForegroundColor Cyan
Write-Host ("=" * 64)
Show-OVReport

# ── Remediation (LOCAL jump box only; opt-in via -Fix) ──────────────────────
if ($Fix) {
    Write-Host "`n$("=" * 64)"
    Write-Host "Remediation (LOCAL jump-box prerequisites only; the customer environment is never modified)" -ForegroundColor Cyan
    $isAdmin = try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false }

    function Install-OVModule {
        param([string] $Name)
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    function Invoke-OVFix {
        param([string] $Check, [string] $What, [scriptblock] $Action, [scriptblock] $Verify, [switch] $NeedsAdmin)
        if ((Get-Res $Check) -notin @('FAIL', 'WARN')) { return }
        if ($NeedsAdmin -and -not $isAdmin) { Write-Host "  [SKIP ] $What -> needs an elevated (Run as administrator) session" -ForegroundColor DarkGray; return }
        if ($WhatIfPreference) { Write-Host "  [WHATIF] would: $What" -ForegroundColor DarkGray; return }
        try {
            & $Action
            if (& $Verify) { Set-Res $Check 'FIXED' 'Remediated this session.'; Write-Host "  [FIXED] $What" -ForegroundColor Green }
            else { Write-Host "  [FAIL ] $What -> attempted; may need a NEW PowerShell session to take effect" -ForegroundColor Red }
        } catch { Write-Host "  [FAIL ] $What -> $($_.Exception.Message)" -ForegroundColor Red }
    }

    Invoke-OVFix 'Files unblocked (Mark-of-the-Web)' 'Unblock downloaded files' `
        { Get-ChildItem $root -Recurse -File | Unblock-File -ErrorAction SilentlyContinue } `
        { @(Get-ChildItem $root -Recurse -File | Where-Object { Get-Item $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue }).Count -eq 0 }

    Invoke-OVFix 'Execution policy' 'Set process execution policy to Bypass' `
        { Set-ExecutionPolicy -Scope Process Bypass -Force } `
        { (Get-ExecutionPolicy -Scope Process) -in @('Bypass', 'Unrestricted', 'RemoteSigned') }

    Invoke-OVFix 'ImportExcel (optional)' 'Install ImportExcel (CurrentUser)' { Install-OVModule 'ImportExcel' } { Test-OVModule 'ImportExcel' }

    # Git (for the clone/pull workflow): install via winget if present, else advise.
    Invoke-OVFix 'Git (optional, for clone/pull)' 'Install Git (winget)' `
        {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget not available on this host; install Git manually from https://git-scm.com/download/win' }
            winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
        } `
        { [bool](Get-Command git -ErrorAction SilentlyContinue) } -NeedsAdmin
    if ($en.Azure)  { Invoke-OVFix 'Az.Accounts + Az.ResourceGraph' 'Install Az.Accounts + Az.ResourceGraph (CurrentUser)' { Install-OVModule 'Az.Accounts'; Install-OVModule 'Az.ResourceGraph' } { (Test-OVModule 'Az.Accounts') -and (Test-OVModule 'Az.ResourceGraph') } }
    if ($en.VMware) { Invoke-OVFix 'VMware PowerCLI' 'Install VMware.PowerCLI (CurrentUser)' { Install-OVModule 'VMware.PowerCLI' } { (Test-OVModule 'VMware.VimAutomation.Core') -or (Test-OVModule 'VMware.PowerCLI') } }

    # RSAT AD: system feature, needs admin, OS-aware. On a client under PS7 the
    # DISM cmdlet throws "Class not registered", so run it via Windows PowerShell 5.1.
    Invoke-OVFix 'RSAT ActiveDirectory' 'Install RSAT ActiveDirectory' `
        {
            $pt = (Get-CimInstance Win32_OperatingSystem).ProductType
            if ($pt -eq 1) {
                $c = 'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
                if ($PSVersionTable.PSVersion.Major -ge 7) { powershell.exe -NoProfile -Command $c | Out-Null } else { Invoke-Expression $c | Out-Null }
            } else { Import-Module ServerManager -ErrorAction SilentlyContinue; Install-WindowsFeature -Name RSAT-AD-PowerShell | Out-Null }
        } `
        { Test-OVModule 'ActiveDirectory' } -NeedsAdmin

    if ($en.HyperV) {
        Invoke-OVFix 'Hyper-V module' 'Install Hyper-V management module' `
            {
                if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart | Out-Null }
                else { Install-WindowsFeature -Name RSAT-Hyper-V-Tools | Out-Null }
            } `
            { Test-OVModule 'Hyper-V' } -NeedsAdmin
    }
    if ($en.Azure) {
        Invoke-OVFix 'Azure signed in' 'Sign in to Azure (Connect-AzAccount)' `
            { Import-Module Az.Accounts -ErrorAction SilentlyContinue; Connect-AzAccount -ErrorAction Stop | Out-Null } `
            { [bool](Get-AzContext -ErrorAction SilentlyContinue) }
    }
    Write-Host "`nNote: module/feature installs can require a NEW PowerShell session to load. Re-run the pre-flight to confirm." -ForegroundColor DarkGray
}

# ── Customer-environment items: guidance only, never changed by this tool ───
$envGuide = [System.Collections.Generic.List[string]]::new()
if ((Get-Res 'Servers reachable (CIM)') -eq 'FAIL') {
    $envGuide.Add("Target servers unreachable: enable WinRM fleet-wide via GPO (set the 'Windows Remote Management' service to Automatic, enable 'Allow remote server management through WinRM', and the WinRM firewall rule) OR run 'Enable-PSRemoting -Force' on the servers; open TCP 5985 / 135 + dynamic RPC; ensure the audit account has local admin. This is a CUSTOMER change under their change control -- the audit tool will not do it.")
}
foreach ($r in ($results | Where-Object { $_.Area -eq 'Connectivity' -and $_.Result -eq 'FAIL' })) {
    $envGuide.Add("$($r.Check) failed: open the port / verify the address / DNS path (network change). $($r.Detail)")
}
if ($envGuide.Count) {
    Write-Host "`n$("=" * 64)"
    Write-Host "Customer-environment items (guidance only -- NOT changed by this tool):" -ForegroundColor Yellow
    $envGuide | ForEach-Object { Write-Host "  - $_" }
}

# ── Final summary ────────────────────────────────────────────────────────────
$pass  = @($results | Where-Object Result -in @('PASS', 'FIXED')).Count
$warn  = @($results | Where-Object Result -eq 'WARN').Count
$failC = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host ("`n" + ("=" * 64))
Write-Host ("Summary: {0} PASS/FIXED, {1} WARN, {2} FAIL" -f $pass, $warn, $failC) -ForegroundColor $(if ($failC) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })
if ($failC)    { Write-Host "Resolve the FAIL items before running the audit$(if (-not $Fix) { ' (try -Fix for the local ones)' })." -ForegroundColor Red }
elseif ($warn) { Write-Host "OK to run; review the WARN items (they reduce coverage, not correctness)." -ForegroundColor Yellow }
else           { Write-Host "Ready to run." -ForegroundColor Green }

if ($failC) { exit 1 } else { exit 0 }
