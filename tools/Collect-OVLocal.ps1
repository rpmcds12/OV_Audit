#requires -Version 5.1
<#
.SYNOPSIS
    Read-only LOCAL inventory collector for OV-Audit. Runs ON a Windows Server,
    gathers OS / cores / SQL / roles via local CIM (no remoting), and writes one
    <hostname>.json to -OutputPath. For estates where WinRM/DCOM is blocked.

.DESCRIPTION
    Designed to be deployed once and run on every server through a channel you
    already have (NinjaOne job, GPO startup script / scheduled task, Intune
    script). Each server writes its own JSON to a shared folder; point the audit
    at that folder (config LocalDrop) to fold the data in. Nothing is changed on
    the server; it only reads.

    No module dependencies, so it deploys as a single file. Safe to run as SYSTEM
    (GPO/scheduled task) provided the computer account can write to -OutputPath.

.EXAMPLE
    # one server, to a share
    powershell -ExecutionPolicy Bypass -File Collect-OVLocal.ps1 -OutputPath \\fs01\ov$

.EXAMPLE
    # NinjaOne / GPO scheduled task command line
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OV\Collect-OVLocal.ps1 -OutputPath \\fs01\ov$
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputPath,
    [bool] $CollectSql = $true,
    [bool] $CollectRoles = $true
)

$ErrorActionPreference = 'Stop'

function Resolve-Edition {
    param([string] $Caption, $Sku)
    switch -Regex ($Caption) {
        'Datacenter' { return 'Datacenter' }
        'Standard'   { return 'Standard' }
        'Essentials' { return 'Essentials' }
        'Enterprise' { return 'Enterprise' }
        'Web'        { return 'Web' }
    }
    switch ([string]$Sku) { '7' { 'Standard' } '8' { 'Datacenter' } '12' { 'Datacenter' } '13' { 'Standard' } default { 'Unknown' } }
}

$rec = [ordered]@{
    ComputerName = $env:COMPUTERNAME; Reachable = $true; DataSource = 'Local collector'; Error = $null
    FQDN = $null; Domain = $null; IPAddresses = $null
    OSCaption = $null; OSVersion = $null; OSBuild = $null; OSArchitecture = $null; Edition = $null
    InstallDate = $null; LastBootUpTime = $null
    Sockets = $null; CoresPerSocket = $null; PhysicalCores = $null; LogicalProcs = $null; ProcessorName = $null
    IsVirtual = $null; Hypervisor = $null; IsHyperVHost = $null; Manufacturer = $null; Model = $null
    SqlInstances = @(); InstalledRoles = @(); CollectedAt = (Get-Date).ToString('s')
}

try {
    $os   = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $cpus = @(Get-CimInstance -ClassName Win32_Processor)

    $rec.OSCaption = $os.Caption; $rec.OSVersion = $os.Version; $rec.OSBuild = $os.BuildNumber
    $rec.OSArchitecture = $os.OSArchitecture; $rec.InstallDate = $os.InstallDate; $rec.LastBootUpTime = $os.LastBootUpTime
    $rec.Edition = Resolve-Edition -Caption $os.Caption -Sku $os.OperatingSystemSKU

    $rec.Domain = $cs.Domain
    $rec.FQDN   = if ($cs.PartOfDomain) { "$($cs.Name).$($cs.Domain)" } else { $cs.Name }
    $rec.Manufacturer = "$($cs.Manufacturer)"; $rec.Model = "$($cs.Model)"

    $rec.Sockets       = $cpus.Count
    $rec.PhysicalCores = ($cpus | Measure-Object NumberOfCores -Sum).Sum
    $rec.LogicalProcs  = ($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    $rec.CoresPerSocket = if ($cpus.Count) { [math]::Round($rec.PhysicalCores / $cpus.Count, 1) } else { $null }
    $rec.ProcessorName  = ($cpus | Select-Object -First 1).Name

    $hint = "$($cs.Manufacturer) $($cs.Model) $($bios.SerialNumber)"
    $rec.IsVirtual = [bool]($hint -match 'VMware|Virtual Machine|KVM|QEMU|Xen|VirtualBox|innotek|Nutanix|AHV|Google|OpenStack|Amazon EC2|Parallels|Bochs')
    $rec.Hypervisor = if ($rec.IsVirtual) {
        switch -Regex ($hint) { 'VMware' { 'VMware' } 'Nutanix|AHV' { 'Nutanix AHV' } 'Virtual Machine|Microsoft' { 'Microsoft Hyper-V' } 'KVM|QEMU' { 'KVM/QEMU' } 'Xen' { 'Xen' } default { 'Virtual' } }
    } else { 'Physical' }
    $rec.IsHyperVHost = [bool]($cs.HypervisorPresent -and -not $rec.IsVirtual)

    try {
        $nics = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction SilentlyContinue
        $rec.IPAddresses = (@($nics.IPAddress) | Where-Object { $_ -and $_ -notmatch ':' }) -join ';'
    } catch { }
}
catch { $rec.Error = $_.Exception.Message }

# SQL (local registry; covers 64-bit and 32-bit WOW paths)
if ($CollectSql) {
    $sql = @()
    foreach ($wow in @('', 'Wow6432Node\')) {
        $root = "HKLM:\SOFTWARE\${wow}Microsoft\Microsoft SQL Server"
        $names = "$root\Instance Names\SQL"
        if (Test-Path $names) {
            $props = (Get-ItemProperty $names).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Provider|Drive)$' }
            foreach ($p in $props) {
                $setup = "$root\$($p.Value)\Setup"
                $sql += [pscustomobject]@{
                    Instance   = $p.Name
                    Edition    = (Get-ItemProperty $setup -Name Edition -ErrorAction SilentlyContinue).Edition
                    Version    = (Get-ItemProperty $setup -Name Version -ErrorAction SilentlyContinue).Version
                    PatchLevel = (Get-ItemProperty $setup -Name PatchLevel -ErrorAction SilentlyContinue).PatchLevel
                    InstanceId = $p.Value
                }
            }
        }
    }
    $rec.SqlInstances = $sql
}

# Installed roles (server-only cmdlet)
if ($CollectRoles -and (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    try { $rec.InstalledRoles = @(Get-WindowsFeature | Where-Object Installed | Select-Object -ExpandProperty Name) } catch { }
}

# Write one file per host
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$file = Join-Path $OutputPath ("{0}.json" -f $env:COMPUTERNAME)
([pscustomobject]$rec) | ConvertTo-Json -Depth 6 | Out-File -FilePath $file -Encoding UTF8
Write-Host "OV-Audit local collector wrote $file"
