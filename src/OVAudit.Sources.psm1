#requires -Version 5.1
<#
    OVAudit.Sources.psm1
    Read-only collectors for the authoritative "source" systems:
      - Active Directory (server list + CAL footprint)
      - VMware vCenter/ESXi (physical host cores + VM↔host mapping) via PowerCLI
      - Microsoft Hyper-V (hosts/clusters + VM↔host mapping)

    Why these are the source of truth for cores: a guest VM cannot see the
    physical host's core count, but Windows Server is licensed on physical
    host cores. So host core/socket data comes from the hypervisor, not the guest.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ──────────────────────────────────────────────────────────────────────────
#  Active Directory: enumerate Windows Server computer accounts
# ──────────────────────────────────────────────────────────────────────────

function Get-OVADServers {
    [CmdletBinding()]
    param(
        [string] $Server,
        [string] $SearchBase,
        [string] $ServerOsFilter = '*Server*'
    )

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "ActiveDirectory module not found. Install RSAT (Get-WindowsCapability / Install-WindowsFeature RSAT-AD-PowerShell)."
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    $filter = "Enabled -eq 'True' -and OperatingSystem -like '$ServerOsFilter'"
    $props  = 'OperatingSystem','OperatingSystemVersion','DNSHostName','LastLogonDate','IPv4Address','CanonicalName'
    $params = @{ Filter = $filter; Properties = $props; ErrorAction = 'Stop' }
    if ($Server)     { $params['Server'] = $Server }
    if ($SearchBase) { $params['SearchBase'] = $SearchBase }

    Get-ADComputer @params | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            DNSHostName = $_.DNSHostName
            OS          = $_.OperatingSystem
            OSVersion   = $_.OperatingSystemVersion
            IPv4        = $_.IPv4Address
            LastLogon   = $_.LastLogonDate
            OU          = $_.CanonicalName
            Stale       = ($_.LastLogonDate -and $_.LastLogonDate -lt (Get-Date).AddDays(-60))
        }
    }
}

# ──────────────────────────────────────────────────────────────────────────
#  CAL footprint: enabled user / device counts to size Server + RDS CALs
# ──────────────────────────────────────────────────────────────────────────

function Get-OVCalFootprint {
    [CmdletBinding()]
    param([string] $Server, [string] $SearchBase)

    Import-Module ActiveDirectory -ErrorAction Stop
    $common = @{ ErrorAction = 'Stop' }
    if ($Server)     { $common['Server'] = $Server }
    if ($SearchBase) { $common['SearchBase'] = $SearchBase }

    $enabledUsers = @(Get-ADUser -Filter "Enabled -eq 'True'" @common).Count
    # Device CAL proxy: enabled, non-server computer accounts (workstations).
    $workstations = @(Get-ADComputer -Filter "Enabled -eq 'True' -and OperatingSystem -notlike '*Server*'" `
        -Properties OperatingSystem @common).Count
    $servers      = @(Get-ADComputer -Filter "Enabled -eq 'True' -and OperatingSystem -like '*Server*'" `
        -Properties OperatingSystem @common).Count

    [pscustomobject]@{
        EnabledUsers        = $enabledUsers
        EnabledWorkstations = $workstations
        EnabledServers      = $servers
        # CALs are required per user OR per device — buy whichever is fewer.
        CalRecommendation   = if ($enabledUsers -le $workstations) { 'User CALs likely cheaper' } else { 'Device CALs likely cheaper' }
        Note = 'CALs cover Windows Server access; RDS CALs are separate and needed only where Remote Desktop Session Host is used.'
    }
}

# ──────────────────────────────────────────────────────────────────────────
#  VMware vCenter / ESXi via PowerCLI
# ──────────────────────────────────────────────────────────────────────────

function Get-OVVMwareInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $VIServers,
        [pscredential] $Credential
    )

    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI -ErrorAction SilentlyContinue) -and
        -not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) {
        throw "VMware PowerCLI not found. Install-Module VMware.PowerCLI -Scope CurrentUser"
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    # Don't trip on self-signed vCenter certs; never participate in CEIP for an audit.
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null

    $hosts = @()
    $vms   = @()
    $connectParams = @{ Server = $VIServers; ErrorAction = 'Stop' }
    if ($Credential) { $connectParams['Credential'] = $Credential }
    $conn = Connect-VIServer @connectParams
    try {
        foreach ($h in Get-VMHost) {
            $cpu = $h.ExtensionData.Hardware.CpuInfo
            $hosts += [pscustomobject]@{
                Hypervisor    = 'VMware'
                HostName      = $h.Name
                Cluster       = (Get-Cluster -VMHost $h -ErrorAction SilentlyContinue).Name
                Sockets       = $cpu.NumCpuPackages
                PhysicalCores = $cpu.NumCpuCores
                LogicalProcs  = $cpu.NumCpuThreads
                CpuModel      = $h.ProcessorType
                Model         = "$($h.Manufacturer) $($h.Model)"
                Version       = "$($h.Version) build $($h.Build)"
                ConnectionState = $h.ConnectionState.ToString()
            }
            foreach ($vm in (Get-VM -Location $h)) {
                $vms += [pscustomobject]@{
                    Hypervisor = 'VMware'
                    VMName     = $vm.Name
                    HostName   = $h.Name
                    GuestOS    = $vm.ExtensionData.Guest.GuestFullName
                    GuestHostName = $vm.Guest.HostName
                    PowerState = $vm.PowerState.ToString()
                    vCPU       = $vm.NumCpu
                    IsWindowsServer = ($vm.ExtensionData.Guest.GuestFullName -match 'Windows.*Server' -or $vm.ExtensionData.Config.GuestFullName -match 'Windows.*Server')
                }
            }
        }
    }
    finally {
        Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue
    }
    return @{ Hosts = $hosts; VMs = $vms }
}

# ──────────────────────────────────────────────────────────────────────────
#  Microsoft Hyper-V (standalone hosts and/or failover clusters)
# ──────────────────────────────────────────────────────────────────────────

function Get-OVHyperVInventory {
    [CmdletBinding()]
    param(
        [string[]] $Hosts = @(),
        [string[]] $Clusters = @(),
        [pscredential] $Credential
    )

    Import-Module Hyper-V -ErrorAction Stop

    # Expand cluster names into member nodes.
    $allHosts = [System.Collections.Generic.List[string]]::new()
    $Hosts | Where-Object { $_ } | ForEach-Object { $allHosts.Add($_) }
    if ($Clusters.Count -gt 0) {
        Import-Module FailoverClusters -ErrorAction Stop
        foreach ($c in $Clusters) {
            (Get-ClusterNode -Cluster $c -ErrorAction Stop).Name | ForEach-Object { $allHosts.Add($_) }
        }
    }
    $allHosts = $allHosts | Select-Object -Unique

    $hostList = @()
    $vms      = @()
    foreach ($hv in $allHosts) {
        $sess = $null   # initialize for StrictMode-safe cleanup below
        try {
            # Physical cores come from CIM on the host (Get-VMHost gives logical only).
            $cimArgs = @{ ComputerName = $hv; ClassName = 'Win32_Processor'; ErrorAction = 'Stop' }
            if ($Credential) {
                $sess = New-CimSession -ComputerName $hv -Credential $Credential -ErrorAction Stop
                $cpus = @(Get-CimInstance -CimSession $sess -ClassName Win32_Processor)
            } else {
                $cpus = @(Get-CimInstance @cimArgs)
            }
            $hostList += [pscustomobject]@{
                Hypervisor    = 'Hyper-V'
                HostName      = $hv
                Sockets       = $cpus.Count
                PhysicalCores = ($cpus | Measure-Object NumberOfCores -Sum).Sum
                LogicalProcs  = ($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum
                CpuModel      = ($cpus | Select-Object -First 1).Name
            }
            if ($sess) { Remove-CimSession $sess -ErrorAction SilentlyContinue; $sess = $null }

            $vmParams = @{ ComputerName = $hv; ErrorAction = 'Stop' }
            foreach ($vm in (Get-VM @vmParams)) {
                $vms += [pscustomobject]@{
                    Hypervisor = 'Hyper-V'
                    VMName     = $vm.Name
                    HostName   = $hv
                    GuestOS    = $vm.OperatingSystem  # may be blank without integration services
                    PowerState = $vm.State.ToString()
                    vCPU       = $vm.ProcessorCount
                    IsWindowsServer = $null  # resolved later by joining to per-guest CIM detail
                }
            }
        }
        catch {
            Write-Warning "[$hv] Hyper-V collection failed: $($_.Exception.Message)"
        }
    }
    return @{ Hosts = $hostList; VMs = $vms }
}

# ──────────────────────────────────────────────────────────────────────────
#  Nutanix AHV via Prism Element REST API v2.0
# ──────────────────────────────────────────────────────────────────────────
#  AHV is KVM-based, so there is no Windows host OS to query for physical cores.
#  Host sockets/cores and VM->host placement come from Prism. Verified fields:
#    /hosts : num_cpu_sockets, num_cpu_cores (physical), num_cpu_threads, uuid, name
#    /vms   : num_vcpus (= sockets), num_cores_per_vcpu, host_uuid, power_state, name
#  A VM's true virtual-core count (what per-VM licensing charges on) is
#  num_vcpus * num_cores_per_vcpu, NOT num_vcpus alone.

function Invoke-OVPrismRest {
    param([string] $Url, [pscredential] $Credential, [int] $TimeoutSec = 60)
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        Accept        = 'application/json'
    }
    $a = @{ Uri = $Url; Headers = $headers; Method = 'Get'; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $a['SkipCertificateCheck'] = $true }  # PS7 self-signed
    return Invoke-RestMethod @a
}

function Get-OVProp {
    # Safe property read for parsed JSON objects (Prism omits fields like
    # guest_os without NGT, or host_uuid when a VM is powered off). StrictMode
    # would otherwise throw on a missing property.
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $Default }
}

function ConvertFrom-OVPrismData {
    <#
        Pure shaping of Prism v2.0 host/VM entities into the common collector
        format (same shape as the VMware/Hyper-V collectors). Separated from the
        HTTP call so the core mapping/vCPU math is unit-testable. Every Prism
        field is read defensively because the API omits absent fields.
    #>
    [CmdletBinding()]
    param([object[]] $HostEntities = @(), [object[]] $VmEntities = @(), [string] $ClusterName)

    $uuidToName = @{}
    foreach ($h in $HostEntities) {
        $u = Get-OVProp $h 'uuid'
        if ($u) { $uuidToName[$u] = (Get-OVProp $h 'name') }
    }

    $hostList = foreach ($h in $HostEntities) {
        [pscustomobject]@{
            Hypervisor    = 'Nutanix AHV'
            HostName      = (Get-OVProp $h 'name')
            Cluster       = $ClusterName
            Sockets       = (Get-OVProp $h 'num_cpu_sockets')
            PhysicalCores = (Get-OVProp $h 'num_cpu_cores')   # physical cores (license on this)
            LogicalProcs  = (Get-OVProp $h 'num_cpu_threads')
            CpuModel      = (Get-OVProp $h 'cpu_model')
            Model         = (Get-OVProp $h 'block_model_name')
        }
    }

    $vmList = foreach ($v in $VmEntities) {
        $nv = Get-OVProp $v 'num_vcpus'
        $nc = Get-OVProp $v 'num_cores_per_vcpu'
        $sockets  = if ($nv) { [int]$nv } else { 0 }
        $coresPer = if ($nc) { [int]$nc } else { 1 }
        $hu = Get-OVProp $v 'host_uuid'
        $hostName = if ($hu -and $uuidToName.ContainsKey($hu)) { $uuidToName[$hu] } else { $null }

        # Guest OS from Nutanix Guest Tools (NGT), when installed and reachable.
        # Defensive: it nests under nutanix_guest_tools.guest_os_version and may be
        # absent/null. When present it classifies the VM (and excludes Windows
        # client / VDI); when absent we leave IsWindowsServer = $null so the engine
        # falls back to the AD-based classification.
        $ngt = Get-OVProp $v 'nutanix_guest_tools'
        $guestOs = Get-OVProp $ngt 'guest_os_version'
        if (-not $guestOs) { $guestOs = Get-OVProp $v 'guest_os' }
        if (-not $guestOs) { $guestOs = Get-OVProp $v 'os_type' }

        $isWin = $null
        if ($guestOs) {
            if ($guestOs -match 'Windows.*Server') { $isWin = $true }    # Windows Server
            else { $isWin = $false }                                      # Windows client / Linux / other
        }

        [pscustomobject]@{
            Hypervisor      = 'Nutanix AHV'
            VMName          = (Get-OVProp $v 'name')
            HostName        = $hostName                  # null when powered off (no host_uuid)
            GuestOS         = $guestOs                    # NGT-reported OS, when available
            GuestHostName   = (Get-OVProp $v 'name')
            PowerState      = (Get-OVProp $v 'power_state')
            vCPU            = ($sockets * $coresPer)      # total virtual cores
            IsWindowsServer = $isWin                      # $true/$false from NGT, else $null (AD classifies)
        }
    }

    return @{ Hosts = @($hostList); VMs = @($vmList) }
}

function Get-OVNutanixInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Prisms,   # Prism Element cluster VIP(s) / CVM IP(s)
        [int] $Port = 9440,
        [pscredential] $Credential,
        [int] $TimeoutSec = 60
    )

    $allHosts = @(); $allVMs = @()

    # PS5.1 has no -SkipCertificateCheck; relax cert validation for the call and restore after.
    $restoreCb = $null
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $restoreCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
    try {
        foreach ($p in $Prisms) {
            $base = "https://$($p):$Port/PrismGateway/services/rest/v2.0"
            try {
                $cluster   = Invoke-OVPrismRest -Url "$base/cluster"  -Credential $Credential -TimeoutSec $TimeoutSec
                $hostsResp = Invoke-OVPrismRest -Url "$base/hosts/"   -Credential $Credential -TimeoutSec $TimeoutSec
                $vmsResp   = Invoke-OVPrismRest -Url "$base/vms/"     -Credential $Credential -TimeoutSec $TimeoutSec

                # Surface (don't hide) truncation if the cluster paginates VMs.
                $got = @($vmsResp.entities).Count
                if ($vmsResp.metadata -and $vmsResp.metadata.grand_total_entities -gt $got) {
                    Write-Warning "[$p] Prism returned $got of $($vmsResp.metadata.grand_total_entities) VMs; some VMs were not retrieved."
                }

                $shaped = ConvertFrom-OVPrismData -HostEntities @($hostsResp.entities) `
                    -VmEntities @($vmsResp.entities) -ClusterName $cluster.name
                $allHosts += $shaped.Hosts
                $allVMs   += $shaped.VMs
            }
            catch { Write-Warning "[$p] Nutanix Prism collection failed: $($_.Exception.Message)" }
        }
    }
    finally {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $restoreCb
        }
    }
    return @{ Hosts = $allHosts; VMs = $allVMs }
}

# ──────────────────────────────────────────────────────────────────────────
#  SCCM / MECM hardware inventory (SMS Provider WMI namespace)
# ──────────────────────────────────────────────────────────────────────────

function Get-OVConfigMgrInventory {
    <#
        Pull last-known hardware inventory for Windows Server systems from the
        SCCM SMS Provider (root\sms\site_<code>). Merges OS / computer-system /
        processor classes by ResourceID into one record per system.

        CAVEAT: SCCM's agent reports what the OS sees. On a VM that is GUEST
        vCPU, not the physical host's cores — so this data is used for breadth
        and to backfill UNREACHABLE PHYSICAL servers only. Hypervisor collectors
        remain the source of truth for host cores and VM mapping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SiteServer,
        [Parameter(Mandatory)] [string] $SiteCode,
        [pscredential] $Credential
    )

    $ns = "root\sms\site_$SiteCode"
    $session = $null
    if ($Credential) { $session = New-CimSession -ComputerName $SiteServer -Credential $Credential -ErrorAction Stop }

    function _Query {
        param([string] $Class, [string] $Filter)
        $p = @{ Namespace = $ns; ClassName = $Class; ErrorAction = 'Stop' }
        if ($Filter) { $p['Filter'] = $Filter }
        if ($session) { Get-CimInstance -CimSession $session @p }
        else          { Get-CimInstance -ComputerName $SiteServer @p }
    }

    try {
        # Only server OSes (cuts volume dramatically on large sites).
        $os  = @(_Query 'SMS_G_System_OPERATING_SYSTEM' "Caption LIKE '%Server%'")
        $cs  = @(_Query 'SMS_G_System_COMPUTER_SYSTEM' $null)
        $cpu = @(_Query 'SMS_G_System_PROCESSOR' $null)

        $csById  = @{}; foreach ($c in $cs)  { $csById[[int]$c.ResourceID]  = $c }
        $cpuById = @{}
        foreach ($p in $cpu) {
            $id = [int]$p.ResourceID
            if (-not $cpuById.ContainsKey($id)) { $cpuById[$id] = [System.Collections.Generic.List[object]]::new() }
            $cpuById[$id].Add($p)
        }

        $vendorRx = 'VMware|Virtual|KVM|QEMU|Xen|VirtualBox|innotek|Nutanix|Google|OpenStack|Amazon|Parallels'
        foreach ($o in $os) {
            $id = [int]$o.ResourceID
            $c  = $csById[$id]
            $procs = if ($cpuById.ContainsKey($id)) { $cpuById[$id] } else { @() }
            $physCores = ($procs | Measure-Object -Property NumberOfCores -Sum).Sum
            $logProcs  = ($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            $modelStr  = "$($c.Manufacturer) $($c.Model)"

            [pscustomobject]@{
                ComputerName  = if ($c) { $c.Name } else { $o.CSName }
                OSCaption     = $o.Caption
                OSVersion     = $o.Version
                OSBuild       = $o.BuildNumber
                Manufacturer  = if ($c) { $c.Manufacturer } else { $null }
                Model         = if ($c) { $c.Model } else { $null }
                Sockets       = if ($procs.Count) { $procs.Count } else { $null }
                PhysicalCores = $physCores
                LogicalProcs  = $logProcs
                IsVirtual     = [bool]($modelStr -match $vendorRx)
                DataSource    = 'SCCM (last inventory)'
            }
        }
    }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
}

# ──────────────────────────────────────────────────────────────────────────
#  Azure Resource Graph: Arc-enabled servers + native Azure VMs
# ──────────────────────────────────────────────────────────────────────────
#  Catches Windows Servers that left on-prem AD for the cloud. Arc projects
#  on-prem / other-cloud machines into Azure (and reports detected physical
#  cores); native Azure VMs are vCPU-based under Azure Hybrid Benefit. This is a
#  DISCOVER-AND-REPORT source: it populates the coverage report; it does not
#  feed the cost engine (cloud licensing needs separate AHB-vs-physical handling).

function ConvertFrom-OVAzureGraph {
    <#
        Pure shaping of Azure Resource Graph rows (Arc machines + Azure VMs) into
        a uniform server record. Separated from the query call so it is testable
        without an Azure connection. Every field is read defensively.
    #>
    [CmdletBinding()]
    param([object[]] $ArcRows = @(), [object[]] $VmRows = @())

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $ArcRows) {
        $cn = Get-OVProp $r 'computerName'; if (-not $cn) { $cn = Get-OVProp $r 'name' }
        $os = Get-OVProp $r 'osSku';        if (-not $os) { $os = Get-OVProp $r 'osName' }
        $rows.Add([pscustomobject]@{
            Source = 'Azure Arc'; Name = (Get-OVProp $r 'name'); ComputerName = $cn; OSName = $os
            PhysicalCores = (Get-OVProp $r 'coreCount')      # HT-exclusive where present
            LogicalCores  = (Get-OVProp $r 'logicalCores')   # HT-inclusive
            vCPU = $null; VmSize = $null
            Domain = (Get-OVProp $r 'domain'); Cloud = (Get-OVProp $r 'cloud')
            Location = (Get-OVProp $r 'location'); ResourceGroup = (Get-OVProp $r 'resourceGroup')
            SubscriptionId = (Get-OVProp $r 'subscriptionId'); LicenseType = $null
            Status = (Get-OVProp $r 'status')
        })
    }
    foreach ($r in $VmRows) {
        $rows.Add([pscustomobject]@{
            Source = 'Azure VM'; Name = (Get-OVProp $r 'name'); ComputerName = (Get-OVProp $r 'name')
            OSName = (Get-OVProp $r 'osType')
            PhysicalCores = $null; LogicalCores = $null; vCPU = $null   # vCPU-based under AHB
            VmSize = (Get-OVProp $r 'vmSize')
            Domain = $null; Cloud = 'Azure'
            Location = (Get-OVProp $r 'location'); ResourceGroup = (Get-OVProp $r 'resourceGroup')
            SubscriptionId = (Get-OVProp $r 'subscriptionId')
            LicenseType = (Get-OVProp $r 'licenseType')   # 'Windows_Server' => AHB already applied
            Status = $null
        })
    }
    return @($rows)
}

function Invoke-OVGraphQuery {
    # Run an Azure Resource Graph query with SkipToken paging (1000 rows/page).
    param([string] $Query, [bool] $TenantScope = $true, [string[]] $SubscriptionIds = @())
    $all = [System.Collections.Generic.List[object]]::new()
    $common = @{ Query = $Query; First = 1000; ErrorAction = 'Stop' }
    if ($TenantScope) { $common['UseTenantScope'] = $true }
    elseif ($SubscriptionIds.Count) { $common['Subscription'] = $SubscriptionIds }
    $batch = Search-AzGraph @common
    foreach ($x in $batch) { $all.Add($x) }
    while ($batch -and $batch.SkipToken) {
        $batch = Search-AzGraph @common -SkipToken $batch.SkipToken
        foreach ($x in $batch) { $all.Add($x) }
    }
    return @($all)
}

function Get-OVAzureInventory {
    <#
        Discover Windows Servers in Azure via Resource Graph: Arc-enabled machines
        (on-prem / other-cloud, status Connected) and native Azure VMs. Read-only
        (built-in Reader role is sufficient).
    #>
    [CmdletBinding()]
    param([string] $TenantId, [string[]] $SubscriptionIds = @(), [bool] $TenantScope = $true)

    foreach ($m in 'Az.Accounts', 'Az.ResourceGraph') {
        if (-not (Get-Module -ListAvailable -Name $m)) { throw "$m not found. Install-Module $m -Scope CurrentUser" }
    }
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.ResourceGraph -ErrorAction Stop
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        if ($TenantId) { Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null }
        else { Connect-AzAccount -ErrorAction Stop | Out-Null }
    }

    $arcQuery = @'
Resources
| where type =~ 'microsoft.hybridcompute/machines'
| where properties.status =~ 'Connected'
| where (tolower(tostring(properties.osName)) has 'windows') or (tostring(properties.osSku) has 'Windows Server')
| extend dp = properties.detectedProperties
| project name,
  computerName = tostring(properties.osProfile.computerName),
  osSku = tostring(properties.osSku), osName = tostring(properties.osName),
  domain = tostring(properties.domainName),
  logicalCores = toint(dp.logicalCoreCount), coreCount = toint(dp.coreCount),
  memGB = todouble(dp.totalPhysicalMemoryInGigabytes), cloud = tostring(dp.cloudprovider),
  location, resourceGroup, subscriptionId, status = tostring(properties.status)
'@

    $vmQuery = @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| where tostring(properties.storageProfile.osDisk.osType) =~ 'Windows'
| project name, vmSize = tostring(properties.hardwareProfile.vmSize),
  osType = tostring(properties.storageProfile.osDisk.osType),
  licenseType = tostring(properties.licenseType), location, resourceGroup, subscriptionId
'@

    $arcRows = Invoke-OVGraphQuery -Query $arcQuery -TenantScope $TenantScope -SubscriptionIds $SubscriptionIds
    $vmRows  = Invoke-OVGraphQuery -Query $vmQuery  -TenantScope $TenantScope -SubscriptionIds $SubscriptionIds
    return ConvertFrom-OVAzureGraph -ArcRows $arcRows -VmRows $vmRows
}

# ──────────────────────────────────────────────────────────────────────────
#  Discovery reconciliation: merge every source into one de-duplicated target
#  list so a server found anywhere gets scanned, and AD gaps become visible.
# ──────────────────────────────────────────────────────────────────────────

function Merge-OVDiscoveryTargets {
    <#
        Build one de-duplicated target list keyed by short hostname, tagging each
        host with the source(s) that found it. Lets the per-server scan reach
        servers that aren't in AD (e.g. VMs on a hypervisor but not domain-joined),
        and lets the report show "found outside AD".

        Match key is the short hostname (lowercased); an FQDN is preferred over a
        bare name when both are seen. Returns objects: Short, Name, Sources[], InAD.
    #>
    [CmdletBinding()]
    param(
        [object[]] $AdServers = @(),
        [object[]] $HypervisorVMs = @(),
        [object[]] $SccmServers = @()
    )

    $map = [ordered]@{}
    function Add-OVTarget {
        param([string] $Name, [string] $Source)
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        $short = ($Name -split '\.')[0].ToLower()
        if (-not $map.Contains($short)) {
            $map[$short] = [pscustomobject]@{
                Short = $short; Name = $Name
                Sources = [System.Collections.Generic.List[string]]::new()
            }
        } elseif (($Name -match '\.') -and ($map[$short].Name -notmatch '\.')) {
            $map[$short].Name = $Name   # prefer an FQDN over a short name
        }
        if (-not $map[$short].Sources.Contains($Source)) { $map[$short].Sources.Add($Source) }
    }

    foreach ($a in $AdServers) {
        $n = Get-OVProp $a 'DNSHostName'; if (-not $n) { $n = Get-OVProp $a 'Name' }
        Add-OVTarget -Name $n -Source 'AD'
    }
    foreach ($v in $HypervisorVMs) {
        $n = Get-OVProp $v 'GuestHostName'; if (-not $n) { $n = Get-OVProp $v 'VMName' }
        Add-OVTarget -Name $n -Source ('Hypervisor:' + (Get-OVProp $v 'Hypervisor'))
    }
    foreach ($s in $SccmServers) {
        Add-OVTarget -Name (Get-OVProp $s 'ComputerName') -Source 'SCCM'
    }

    foreach ($t in $map.Values) {
        Add-Member -InputObject $t -NotePropertyName InAD -NotePropertyValue ($t.Sources.Contains('AD')) -Force
    }
    return @($map.Values)
}

# ──────────────────────────────────────────────────────────────────────────
#  Local-collector drop: ingest the JSON files written by tools/Collect-OVLocal.ps1
#  (for estates where WinRM/DCOM is blocked and servers self-report locally).
# ──────────────────────────────────────────────────────────────────────────

function Import-OVLocalDrop {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path $Path)) { Write-Warning "Local-drop path not found: $Path"; return @() }
    $out = foreach ($f in (Get-ChildItem -Path $Path -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { Get-Content -Path $f.FullName -Raw | ConvertFrom-Json }
        catch { Write-Warning "Skipping unreadable local-drop file $($f.Name): $($_.Exception.Message)" }
    }
    return @($out)
}

Export-ModuleMember -Function Get-OVADServers, Get-OVCalFootprint,
    Get-OVVMwareInventory, Get-OVHyperVInventory, Get-OVConfigMgrInventory,
    Get-OVNutanixInventory, ConvertFrom-OVPrismData, Invoke-OVPrismRest, Get-OVProp,
    Merge-OVDiscoveryTargets, Get-OVAzureInventory, ConvertFrom-OVAzureGraph, Invoke-OVGraphQuery,
    Import-OVLocalDrop
