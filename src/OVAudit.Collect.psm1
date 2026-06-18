#requires -Version 5.1
<#
    OVAudit.Collect.psm1
    Read-only per-server inventory collection for OV-Audit.

    Core counting note: Windows Server is licensed on PHYSICAL CORES of the
    machine the OS runs on. Win32_Processor returns one instance per populated
    socket; .NumberOfCores is physical cores in that socket. We sum across
    instances. Inside a guest VM these numbers reflect the *guest* config, not
    the physical host — host physical cores come from the hypervisor collectors.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# HKEY_LOCAL_MACHINE for StdRegProv (works over both WSMan and DCOM CIM sessions)
$script:HKLM = [uint32]2147483650

# ──────────────────────────────────────────────────────────────────────────
#  CIM session helpers
# ──────────────────────────────────────────────────────────────────────────

function New-OVCimSession {
    <#
        Create a CIM session to a target, preferring WSMan (WinRM) and optionally
        falling back to DCOM for older / unmanaged hosts. Returns $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [pscredential] $Credential,
        [bool] $PreferWinRM = $true,
        [bool] $AllowDcomFallback = $true,
        [int]  $TimeoutSec = 30
    )

    $opTimeout = New-TimeSpan -Seconds $TimeoutSec
    $order = if ($PreferWinRM) { @('Wsman', 'Dcom') } else { @('Dcom', 'Wsman') }
    if (-not $AllowDcomFallback) { $order = $order | Where-Object { $_ -ne 'Dcom' } }

    foreach ($proto in $order) {
        try {
            $opt = New-CimSessionOption -Protocol $proto
            $params = @{
                ComputerName  = $ComputerName
                SessionOption = $opt
                OperationTimeoutSec = $TimeoutSec
                ErrorAction   = 'Stop'
            }
            if ($Credential) { $params['Credential'] = $Credential }
            $session = New-CimSession @params
            # Tag the protocol we actually connected with.
            Add-Member -InputObject $session -NotePropertyName OVProtocol -NotePropertyValue $proto -Force
            return $session
        }
        catch {
            Write-Verbose "[$ComputerName] $proto connect failed: $($_.Exception.Message)"
        }
    }
    return $null
}

# ──────────────────────────────────────────────────────────────────────────
#  Remote-registry helpers (StdRegProv) — transport-agnostic
# ──────────────────────────────────────────────────────────────────────────

function Get-OVRegSubKeys {
    param([Microsoft.Management.Infrastructure.CimSession] $Session, [string] $Path)
    try {
        $r = Invoke-CimMethod -CimSession $Session -Namespace 'root\cimv2' -ClassName 'StdRegProv' `
            -MethodName 'EnumKey' -Arguments @{ hDefKey = $script:HKLM; sSubKeyName = $Path } -ErrorAction Stop
        if ($r.ReturnValue -eq 0 -and $r.sNames) { return $r.sNames }
    } catch { Write-Verbose "EnumKey '$Path' failed: $($_.Exception.Message)" }
    return @()
}

function Get-OVRegString {
    param([Microsoft.Management.Infrastructure.CimSession] $Session, [string] $Path, [string] $Name)
    try {
        $r = Invoke-CimMethod -CimSession $Session -Namespace 'root\cimv2' -ClassName 'StdRegProv' `
            -MethodName 'GetStringValue' -Arguments @{ hDefKey = $script:HKLM; sSubKeyName = $Path; sValueName = $Name } -ErrorAction Stop
        if ($r.ReturnValue -eq 0) { return $r.sValue }
    } catch { Write-Verbose "GetStringValue '$Path\$Name' failed: $($_.Exception.Message)" }
    return $null
}

# ──────────────────────────────────────────────────────────────────────────
#  Virtualization detection
# ──────────────────────────────────────────────────────────────────────────

function Resolve-OVVirtualization {
    <#
        Classify a machine as physical or virtual and identify the hypervisor
        from Win32_ComputerSystem + Win32_BIOS strings. Returns a hashtable.
    #>
    param($ComputerSystem, $Bios)

    $mfg   = "$($ComputerSystem.Manufacturer)"
    $model = "$($ComputerSystem.Model)"
    $biosSerial  = "$($Bios.SerialNumber)"
    $biosVersion = ($Bios.BIOSVersion -join ' ')
    $hyperPresent = [bool]$ComputerSystem.HypervisorPresent

    $hint = "$mfg $model $biosSerial $biosVersion"

    $map = [ordered]@{
        'VMware'                 = 'VMware'
        'VMware, Inc.'           = 'VMware'
        'Virtual Machine'        = 'Microsoft Hyper-V'   # Microsoft Corporation / Virtual Machine
        'Microsoft Corporation'  = 'Microsoft Hyper-V'
        'VirtualBox'             = 'Oracle VirtualBox'
        'innotek'                = 'Oracle VirtualBox'
        'Nutanix'                = 'Nutanix AHV'
        'AHV'                    = 'Nutanix AHV'
        'KVM'                    = 'KVM'
        'QEMU'                   = 'KVM/QEMU'
        'Red Hat'                = 'KVM (RHV)'
        'Xen'                    = 'Xen'
        'Google'                 = 'Google Compute Engine'
        'OpenStack'              = 'OpenStack'
        'Amazon EC2'             = 'AWS EC2'
        'Bochs'                  = 'Bochs'
        'Parallels'             = 'Parallels'
    }

    $hypervisor = $null
    foreach ($key in $map.Keys) {
        if ($hint -match [regex]::Escape($key)) { $hypervisor = $map[$key]; break }
    }

    # Microsoft Corporation alone is ambiguous (Surface etc.); require "Virtual Machine".
    if ($hypervisor -eq 'Microsoft Hyper-V' -and $model -notmatch 'Virtual') {
        $hypervisor = $null
    }

    $isVirtual = [bool]$hypervisor
    # HypervisorPresent is true on physical hosts running the Hyper-V role too,
    # so it is only a weak signal — used to flag "possible host" not "is a VM".
    $isHyperVHost = ($hyperPresent -and -not $isVirtual)

    return @{
        IsVirtual      = $isVirtual
        Hypervisor     = if ($isVirtual) { $hypervisor } else { 'Physical' }
        IsHyperVHost   = $isHyperVHost
        Manufacturer   = $mfg
        Model          = $model
        HypervisorPresent = $hyperPresent
    }
}

# ──────────────────────────────────────────────────────────────────────────
#  OS edition parsing (Standard vs Datacenter drives the licensing decision)
# ──────────────────────────────────────────────────────────────────────────

function Resolve-OVEdition {
    param([string] $Caption, $OperatingSystemSKU)

    $edition = 'Unknown'
    switch -Regex ($Caption) {
        'Datacenter'  { $edition = 'Datacenter'; break }
        'Standard'    { $edition = 'Standard';   break }
        'Essentials'  { $edition = 'Essentials'; break }
        'Enterprise'  { $edition = 'Enterprise'; break }
        'Web'         { $edition = 'Web';        break }
    }
    # SKU backstop (subset of common server SKUs).
    if ($edition -eq 'Unknown' -and $null -ne $OperatingSystemSKU) {
        switch ([int]$OperatingSystemSKU) {
            7  { $edition = 'Standard' }    # PRODUCT_STANDARD_SERVER
            8  { $edition = 'Datacenter' }  # PRODUCT_DATACENTER_SERVER
            10 { $edition = 'Enterprise' }
            12 { $edition = 'Datacenter' }  # core
            13 { $edition = 'Standard' }    # core
            14 { $edition = 'Enterprise' }  # core
            default { }
        }
    }
    return $edition
}

# ──────────────────────────────────────────────────────────────────────────
#  SQL Server detection (via StdRegProv — works over WinRM or DCOM)
# ──────────────────────────────────────────────────────────────────────────

function Get-OVSqlInventory {
    param([Microsoft.Management.Infrastructure.CimSession] $Session)

    $instances = @()
    $base = 'SOFTWARE\Microsoft\Microsoft SQL Server'
    # Instance Names\SQL maps instance name -> internal instance id (e.g. MSSQL16.MSSQLSERVER)
    try {
        $names = Invoke-CimMethod -CimSession $Session -Namespace 'root\cimv2' -ClassName 'StdRegProv' `
            -MethodName 'EnumValues' -Arguments @{ hDefKey = $script:HKLM; sSubKeyName = "$base\Instance Names\SQL" } -ErrorAction Stop
        if ($names.ReturnValue -eq 0 -and $names.sNames) {
            foreach ($inst in $names.sNames) {
                $instId = Get-OVRegString -Session $Session -Path "$base\Instance Names\SQL" -Name $inst
                $setupPath = "$base\$instId\Setup"
                $instances += [pscustomobject]@{
                    Instance    = $inst
                    Edition     = Get-OVRegString -Session $Session -Path $setupPath -Name 'Edition'
                    Version     = Get-OVRegString -Session $Session -Path $setupPath -Name 'Version'
                    PatchLevel  = Get-OVRegString -Session $Session -Path $setupPath -Name 'PatchLevel'
                    InstanceId  = $instId
                }
            }
        }
    } catch { Write-Verbose "SQL detection failed: $($_.Exception.Message)" }
    return $instances
}

# ──────────────────────────────────────────────────────────────────────────
#  Installed roles (RDS etc.) — best over WinRM; degraded over DCOM
# ──────────────────────────────────────────────────────────────────────────

function Get-OVServerRoles {
    param([string] $ComputerName, [pscredential] $Credential, [string] $Protocol)

    # Get-WindowsFeature needs the ServerManager module on the target → use WinRM.
    if ($Protocol -ne 'Wsman') {
        return @{ Method = 'unavailable-over-dcom'; Roles = @() }
    }
    try {
        $icmArgs = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        if ($Credential) { $icmArgs['Credential'] = $Credential }
        $roles = Invoke-Command @icmArgs -ScriptBlock {
            if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                Get-WindowsFeature | Where-Object Installed |
                    Select-Object -ExpandProperty Name
            }
        }
        return @{ Method = 'Get-WindowsFeature'; Roles = @($roles) }
    } catch {
        Write-Verbose "[$ComputerName] role collection failed: $($_.Exception.Message)"
        return @{ Method = 'error'; Roles = @() }
    }
}

# ──────────────────────────────────────────────────────────────────────────
#  Main per-server collector
# ──────────────────────────────────────────────────────────────────────────

function Get-OVServerDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [pscredential] $Credential,
        [bool] $PreferWinRM = $true,
        [bool] $AllowDcomFallback = $true,
        [bool] $CollectSql = $true,
        [bool] $CollectRoles = $true,
        [int]  $TimeoutSec = 30
    )

    $result = [ordered]@{
        ComputerName   = $ComputerName
        Reachable      = $false
        DataSource     = $null
        Protocol       = $null
        Error          = $null
        FQDN           = $null
        Domain         = $null
        IPAddresses    = $null
        OSCaption      = $null
        OSVersion      = $null
        OSBuild        = $null
        OSArchitecture = $null
        Edition        = $null
        InstallDate    = $null
        LastBootUpTime = $null
        Sockets        = $null
        CoresPerSocket = $null
        PhysicalCores  = $null
        LogicalProcs   = $null
        ProcessorName  = $null
        IsVirtual      = $null
        Hypervisor     = $null
        IsHyperVHost   = $null
        Manufacturer   = $null
        Model          = $null
        SqlInstances   = @()
        InstalledRoles = @()
        CollectedAt    = (Get-Date).ToString('s')
    }

    $session = New-OVCimSession -ComputerName $ComputerName -Credential $Credential `
        -PreferWinRM $PreferWinRM -AllowDcomFallback $AllowDcomFallback -TimeoutSec $TimeoutSec
    if (-not $session) {
        $result.Error = 'unreachable (WinRM/DCOM both failed)'
        return [pscustomobject]$result
    }

    try {
        $result.Reachable  = $true
        $result.DataSource = 'Live CIM'
        $result.Protocol   = $session.OVProtocol

        $os  = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs  = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios= Get-CimInstance -CimSession $session -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $cpus= @(Get-CimInstance -CimSession $session -ClassName Win32_Processor -ErrorAction Stop)

        # OS
        $result.OSCaption      = $os.Caption
        $result.OSVersion      = $os.Version
        $result.OSBuild        = $os.BuildNumber
        $result.OSArchitecture = $os.OSArchitecture
        $result.InstallDate    = $os.InstallDate
        $result.LastBootUpTime = $os.LastBootUpTime
        $result.Edition        = Resolve-OVEdition -Caption $os.Caption -OperatingSystemSKU $os.OperatingSystemSKU

        # Identity
        $result.Domain = $cs.Domain
        $result.FQDN   = if ($cs.Domain -and $cs.Name) { "$($cs.Name).$($cs.Domain)" } else { $cs.Name }
        try {
            $nics = Get-CimInstance -CimSession $session -ClassName Win32_NetworkAdapterConfiguration `
                -Filter 'IPEnabled = TRUE' -ErrorAction SilentlyContinue
            $result.IPAddresses = (@($nics.IPAddress) | Where-Object { $_ -and $_ -notmatch ':' }) -join ';'
        } catch { }

        # CPU / cores — sum physical cores across populated sockets
        $result.Sockets        = $cpus.Count
        $result.PhysicalCores  = if (@($cpus).Count) { ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum } else { 0 }
        $result.LogicalProcs   = if (@($cpus).Count) { ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum } else { 0 }
        $result.CoresPerSocket = if ($cpus.Count -gt 0) { [math]::Round($result.PhysicalCores / $cpus.Count, 1) } else { $null }
        $result.ProcessorName  = ($cpus | Select-Object -First 1).Name

        # Virtualization
        $virt = Resolve-OVVirtualization -ComputerSystem $cs -Bios $bios
        $result.IsVirtual    = $virt.IsVirtual
        $result.Hypervisor   = $virt.Hypervisor
        $result.IsHyperVHost = $virt.IsHyperVHost
        $result.Manufacturer = $virt.Manufacturer
        $result.Model        = $virt.Model

        # SQL
        if ($CollectSql) {
            $result.SqlInstances = @(Get-OVSqlInventory -Session $session)
        }

        # Roles (WinRM only)
        if ($CollectRoles) {
            $roleInfo = Get-OVServerRoles -ComputerName $ComputerName -Credential $Credential -Protocol $session.OVProtocol
            $result.InstalledRoles = $roleInfo.Roles
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]$result
}

Export-ModuleMember -Function New-OVCimSession, Get-OVServerDetail, Get-OVSqlInventory,
    Get-OVServerRoles, Resolve-OVVirtualization, Resolve-OVEdition,
    Get-OVRegString, Get-OVRegSubKeys
