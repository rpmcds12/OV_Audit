#requires -Version 5.1
<#
    OVAudit.License.psm1
    Computes the cheapest-COMPLIANT Windows Server license position from the
    collected inventory. All rules verified against Microsoft Product Terms /
    Windows Server 2025 Licensing Guidance (see README references).

    Core rules encoded:
      • License all PHYSICAL cores of the host the OS runs on (never logical/HT,
        never guest vCPUs). Minimum 8 core licenses per processor, 16 per server.
        LicensableCores = MAX(16, Σ over sockets of MAX(8, coresPerSocket)),
        rounded up to an even number (2-core packs).
      • Standard = 2 OSEs (VMs) per full set of all-core licenses; "stack" full
        sets for +2 VMs each. Datacenter = unlimited VMs on a fully-licensed host.
      • Per-VM (vCore) option = Σ MAX(8, vCPUs); requires active SA/subscription.
      • Datacenter is forced where a host/cluster-level Datacenter-only feature
        is detected. Only Storage Spaces Direct (S2D) is auto-detected today
        (stamped by the Hyper-V collector); other Datacenter-only features
        (SDN/Network Controller, guarded host, Storage Replica beyond Standard's
        single 2 TB volume) must be flagged manually via the host ForceReason.
#>

Set-StrictMode -Version Latest

# Default Microsoft suggested-list per-core pricing (override via config).
$script:DefaultPricing = @{
    StandardPerCore   = 73.50    # $1,176 / 16
    DatacenterPerCore = 423.19   # $6,771 / 16
}

# Sum a property safely. Under StrictMode, (@() | Measure-Object -Sum).Sum throws
# ("property 'Sum' cannot be found"), which happens when nothing is collected
# (0 hosts, 0 servers reached). Return 0 for an empty set instead of crashing.
function Get-OVSum {
    param([object[]] $Items, [string] $Property)
    $a = @($Items)
    if ($a.Count -eq 0) { return 0 }
    $s = ($a | Measure-Object -Property $Property -Sum).Sum
    if ($null -eq $s) { return 0 }
    return $s
}

# StrictMode-safe property read. The engine does not import Sources, so it cannot
# use Get-OVProp; this is the local equivalent. Collectors emit different field
# sets (e.g. Hyper-V VM records have no GuestHostName), so every cross-source
# property read must go through this or StrictMode aborts the whole run.
function Get-OVMember {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $Default }
}

# Classify a VM hostname key safely across collectors (GuestHostName or VMName).
function Get-OVVmKey {
    param($Vm)
    $gh = Get-OVMember $Vm 'GuestHostName'
    $vn = Get-OVMember $Vm 'VMName'
    $key = @($gh, $vn | Where-Object { $_ })
    if ($key.Count) { $key[0] } else { $null }
}

# Datacenter-only features (S2D, Storage Replica, SDN, guarded host) are
# HOST/CLUSTER-level, so they are detected by the collectors and stamped onto the
# host record (ForceReason), not inferred from guest roles (which would wrongly
# force a host to Datacenter because a guest happened to run a feature).

function Get-OVLicensableCores {
    <#
        Apply the 8-core/processor and 16-core/server minimums to physical cores,
        rounded up to an even number (2-core packs).
    #>
    param([int] $PhysicalCores, [int] $Sockets)

    if ($Sockets -lt 1) { $Sockets = 1 }
    $coresPerSocket = [math]::Ceiling($PhysicalCores / $Sockets)
    $perSocket = [math]::Max(8, $coresPerSocket)
    $licensable = [math]::Max(16, $perSocket * $Sockets)
    if ($licensable % 2 -ne 0) { $licensable++ }   # 2-core pack granularity
    return [int]$licensable
}

function Get-OVCorePacks {
    <# Express a core count as 16-core packs + 2-core packs (equivalent pricing). #>
    param([int] $Cores)
    $sixteens = [math]::Floor($Cores / 16)
    $twos     = [math]::Ceiling(($Cores - ($sixteens * 16)) / 2)
    return "$sixteens x 16-core + $twos x 2-core"
}

function Get-OVHostLicensePosition {
    <#
        Compute the per-host cheapest-compliant position.
        $WindowsVMs = collection with a .vCPU property (Windows Server guests only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $HostInfo,
        [object[]] $WindowsVMs = @(),
        [hashtable] $Pricing,
        [bool] $HasSA = $true,
        [bool] $ForceDatacenter = $false,
        [string[]] $ForceReasons = @(),
        [int] $PreferDatacenterAtVMs = 0
    )
    if (-not $Pricing) { $Pricing = $script:DefaultPricing }

    $cores   = [int]$HostInfo.PhysicalCores
    $sockets = [int]$HostInfo.Sockets
    $licensableCores = Get-OVLicensableCores -PhysicalCores $cores -Sockets $sockets
    $vmCount = @($WindowsVMs).Count

    # A hypervisor host with no Windows VMs needs no Windows Server licensing — do
    # not charge a phantom Standard set. Standalone physical servers still run
    # their own OSE, so this applies only to hypervisor hosts and only when not
    # forced to Datacenter.
    if ($vmCount -eq 0 -and ("$(Get-OVMember $HostInfo 'Hypervisor')" -ne 'Physical') -and -not $ForceDatacenter) {
        return [pscustomobject]@{
            HostName = (Get-OVMember $HostInfo 'HostName'); Hypervisor = (Get-OVMember $HostInfo 'Hypervisor'); Cluster = (Get-OVMember $HostInfo 'Cluster')
            Sockets = $sockets; PhysicalCores = $cores; LicensableCores = $licensableCores; WindowsVMCount = 0
            ForceDatacenter = $false; ForceReasons = ''; BreakEvenVMs = 0
            RecommendedModel = 'None (no Windows VMs)'; RecommendedCores = 0; RecommendedPacks = '-'; EstimatedCost = 0
            CheapestModel = 'None (no Windows VMs)'; CheapestCost = 0; PreferenceApplied = $false; OperationalPremium = 0
            Options = @()
        }
    }

    # ── Option A: Datacenter (covers all VMs on the host) ──────────────────
    $dcCost = $licensableCores * $Pricing.DatacenterPerCore

    # ── Option B: Stacked Standard (2 VMs per full all-core set) ───────────
    $stdSets  = [math]::Max(1, [math]::Ceiling($vmCount / 2))
    $stdCores = $stdSets * $licensableCores
    $stdCost  = $stdCores * $Pricing.StandardPerCore

    # ── Option C: Per-VM (vCore), SA/subscription only ─────────────────────
    $perVmCores = 0
    foreach ($vm in $WindowsVMs) {
        $raw = Get-OVMember $vm 'vCPU' 0
        $v = if ($raw) { [int]$raw } else { 8 }
        $perVmCores += [math]::Max(8, $v)
    }
    $perVmCost = if ($HasSA -and $vmCount -gt 0) { $perVmCores * $Pricing.StandardPerCore } else { $null }

    # ── Choose cheapest compliant ──────────────────────────────────────────
    $options = [System.Collections.Generic.List[object]]::new()
    $options.Add([pscustomobject]@{ Model = 'Datacenter (all cores)'; Cores = $licensableCores; Cost = [math]::Round($dcCost, 2); Compliant = $true; Note = "Unlimited Windows VMs" })
    if (-not $ForceDatacenter) {
        $options.Add([pscustomobject]@{ Model = 'Standard (stacked)'; Cores = $stdCores; Cost = [math]::Round($stdCost, 2); Compliant = $true; Note = "$stdSets set(s) x $licensableCores cores -> covers $($stdSets*2) VMs" })
        if ($null -ne $perVmCost) {
            $options.Add([pscustomobject]@{ Model = 'Per-VM (vCore, SA)'; Cores = $perVmCores; Cost = [math]::Round($perVmCost, 2); Compliant = $true; Note = "Sum of MAX(8, vCPU) across $vmCount VM(s); enables Flexible Virtualization" })
        }
    }

    $cheapest = $options | Sort-Object Cost | Select-Object -First 1
    $best = $cheapest

    # Operational-simplicity override: flip dense hosts to Datacenter even if a
    # cheaper option exists. Compliance forcing already lands on Datacenter, so
    # only apply the preference when not already forced.
    $preferenceApplied = $false
    if ($PreferDatacenterAtVMs -gt 0 -and $vmCount -ge $PreferDatacenterAtVMs -and -not $ForceDatacenter) {
        $dcOption = $options | Where-Object { $_.Model -like 'Datacenter*' } | Select-Object -First 1
        if ($dcOption -and $best.Model -notlike 'Datacenter*') {
            $best = $dcOption
            $preferenceApplied = $true
        }
    }
    $operationalPremium = [math]::Round([double]$best.Cost - [double]$cheapest.Cost, 2)

    # Break-even transparency: how many VMs before Datacenter wins on this host.
    $stdSetCost = $licensableCores * $Pricing.StandardPerCore
    $breakEvenVMs = if ($stdSetCost -gt 0) { [math]::Floor($dcCost / $stdSetCost) * 2 } else { 0 }

    return [pscustomobject]@{
        HostName          = $HostInfo.HostName
        Hypervisor        = $HostInfo.Hypervisor
        Cluster           = $HostInfo.Cluster
        Sockets           = $sockets
        PhysicalCores     = $cores
        LicensableCores   = $licensableCores
        WindowsVMCount    = $vmCount
        ForceDatacenter   = $ForceDatacenter
        ForceReasons      = ($ForceReasons -join '; ')
        BreakEvenVMs      = $breakEvenVMs
        RecommendedModel  = $best.Model
        RecommendedCores  = $best.Cores
        RecommendedPacks  = (Get-OVCorePacks -Cores $best.Cores)
        EstimatedCost     = $best.Cost
        CheapestModel     = $cheapest.Model
        CheapestCost      = $cheapest.Cost
        PreferenceApplied = $preferenceApplied
        OperationalPremium= $operationalPremium
        Options           = $options
    }
}

function Get-OVLicensePosition {
    <#
        Top-level: walk every physical host (hypervisor hosts + standalone
        physical Windows servers), compute the cheapest-compliant position,
        and roll up an estate summary with warnings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Dataset,
        [hashtable] $Licensing
    )

    $pricing = $script:DefaultPricing.Clone()
    $hasSA = $true
    $clusterForcesDC = $true
    $preferDcAtVms = 0
    $unknownTreatment = 'Warn'   # 'Warn' (exclude + flag) or 'AssumeWindows' (count, conservative)
    # VMs whose NAME marks them as Windows client / VDI (e.g. WIN11-*, CTX-H-WIN11-*)
    # are not Windows Server: excluded from the Server count (never flagged 'Unknown')
    # and tallied separately for the client-licensing advisory. Override via config.
    $clientNameRegex = '(?i)win(10|11|7|8)'
    if ($Licensing) {
        if ($Licensing.ContainsKey('StandardPerCore'))   { $pricing.StandardPerCore   = $Licensing.StandardPerCore }
        if ($Licensing.ContainsKey('DatacenterPerCore')) { $pricing.DatacenterPerCore = $Licensing.DatacenterPerCore }
        if ($Licensing.ContainsKey('HasSoftwareAssurance')) { $hasSA = [bool]$Licensing.HasSoftwareAssurance }
        if ($Licensing.ContainsKey('ClusterForcesDatacenterWithoutSA')) { $clusterForcesDC = [bool]$Licensing.ClusterForcesDatacenterWithoutSA }
        if ($Licensing.ContainsKey('Currency')) { $pricing['Currency'] = $Licensing.Currency }
        if ($Licensing.ContainsKey('PreferDatacenterAtVMCount')) { $preferDcAtVms = [int]$Licensing.PreferDatacenterAtVMCount }
        if ($Licensing.ContainsKey('UnknownVmTreatment')) { $unknownTreatment = [string]$Licensing.UnknownVmTreatment }
        if ($Licensing.ContainsKey('ClientVmNamePattern') -and $Licensing.ClientVmNamePattern) { $clientNameRegex = [string]$Licensing.ClientVmNamePattern }
    }

    $servers = @($Dataset.Servers)
    $hosts   = @($Dataset.Hosts)
    $vmMap   = @($Dataset.VMMap)
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Index collected per-guest detail by short name for joins.
    $detailByShort = @{}
    foreach ($s in $servers) {
        if ($s.ComputerName) {
            $short = ($s.ComputerName -split '\.')[0].ToLower()
            $detailByShort[$short] = $s
        }
    }

    # Short names of AD computers whose OS is Windows Server. This lets us
    # classify a VM as Windows Server from AD alone when CIM can't reach it
    # (locked-down estates), and correctly EXCLUDES Windows client / VDI VMs.
    $adWinServer = @{}
    $adServerList = if ($Dataset -is [System.Collections.IDictionary]) {
        if ($Dataset.Contains('AdServers')) { $Dataset['AdServers'] } else { @() }
    } elseif ($Dataset.PSObject.Properties['AdServers']) { $Dataset.AdServers } else { @() }
    foreach ($a in @($adServerList)) {
        $nm = if ($a.PSObject.Properties['Name']) { $a.Name } else { $null }
        $os = if ($a.PSObject.Properties['OS'])   { $a.OS }   else { $null }
        if ($nm -and ($os -match 'Windows.*Server')) { $adWinServer[($nm -split '\.')[0].ToLower()] = $true }
    }

    # Classify a VM as a Windows Server. Returns 'Yes' / 'No' / 'Unknown'.
    # 'Unknown' (no signal at all) must NEVER be silently treated as 'No' — that
    # under-counts whole hosts in locked-down estates with no warning.
    function Test-WindowsServerVM {
        param($vm)
        $key = Get-OVVmKey $vm
        $short = if ($key) { ($key -split '\.')[0].ToLower() } else { $null }
        # 1. Live CIM detail, decide only if we actually captured an OS caption.
        if ($short -and $detailByShort.ContainsKey($short)) {
            $cap = $detailByShort[$short].OSCaption
            if ($cap) { return $(if ($cap -match 'Windows.*Server') { 'Yes' } else { 'No' }) }
        }
        # 2. AD's recorded OS (works with no CIM access).
        if ($short -and $adWinServer.ContainsKey($short)) { return 'Yes' }
        # 3. Hypervisor flag (e.g. Nutanix NGT), then guest OS string.
        $flag = Get-OVMember $vm 'IsWindowsServer'
        if ($null -ne $flag) { return $(if ([bool]$flag) { 'Yes' } else { 'No' }) }
        $gos = Get-OVMember $vm 'GuestOS'
        if ($gos) { return $(if ($gos -match 'Windows.*Server') { 'Yes' } else { 'No' }) }
        # 3b. Windows client / VDI by naming convention (no OS signal, but the name
        # marks it a desktop, e.g. WIN11-*) -> definite non-Server, not 'Unknown'.
        if ($key -and ($key -match $clientNameRegex)) { return 'No' }
        # 4. No signal -> Unknown (surfaced as a warning, never a silent 'No').
        return 'Unknown'
    }

    # ── Per-host positions ─────────────────────────────────────────────────
    $hostPositions = [System.Collections.Generic.List[object]]::new()
    foreach ($h in $hosts) {
        if (-not $h.PhysicalCores) {
            $warnings.Add("Host '$($h.HostName)' has no physical-core data — skipped from license math (verify hypervisor collection).")
            continue
        }
        $hostVMs = @($vmMap | Where-Object { $_.HostName -eq $h.HostName })
        $classified = foreach ($vm in $hostVMs) { [pscustomobject]@{ VM = $vm; Class = (Test-WindowsServerVM $vm) } }
        $winVMs     = @($classified | Where-Object { $_.Class -eq 'Yes' } | ForEach-Object { $_.VM })
        $unknownVMs = @($classified | Where-Object { $_.Class -eq 'Unknown' } | ForEach-Object { $_.VM })

        # Undetermined-OS VMs are never silently dropped. Default: warn + exclude
        # (the host position may be understated). UnknownVmTreatment='AssumeWindows'
        # counts them for a conservative high estimate.
        if ($unknownVMs.Count -gt 0) {
            $names = (@($unknownVMs | ForEach-Object { Get-OVVmKey $_ }) -join ', ')
            if ($unknownTreatment -eq 'AssumeWindows') {
                $winVMs += $unknownVMs
                $warnings.Add("Host '$($h.HostName)': $($unknownVMs.Count) VM(s) of undetermined OS counted AS Windows Server (UnknownVmTreatment=AssumeWindows). Confirm via NGT / CIM / AD. [$names]")
            } else {
                $warnings.Add("Host '$($h.HostName)': $($unknownVMs.Count) VM(s) could not be classified (no CIM, not in AD, no NGT/guest OS) and are EXCLUDED from the Windows count — this host's position may be understated. [$names]")
            }
        }

        # Force Datacenter on a host/cluster-level Datacenter-only feature (stamped
        # by the collector, e.g. S2D) or on a no-SA clustered host.
        $forceReasons = @()
        $hostForce = Get-OVMember $h 'ForceReason'
        if ($hostForce) { $forceReasons += "host requires Datacenter: $hostForce" }
        $isClustered = [bool](Get-OVMember $h 'Cluster')
        if ($isClustered -and -not $hasSA -and $clusterForcesDC) {
            $forceReasons += "clustered host without SA (90-day reassignment rule forces licensing every node as Datacenter)"
        }
        $force = $forceReasons.Count -gt 0

        $pos = Get-OVHostLicensePosition -HostInfo $h -WindowsVMs $winVMs -Pricing $pricing `
            -HasSA $hasSA -ForceDatacenter:$force -ForceReasons $forceReasons -PreferDatacenterAtVMs $preferDcAtVms
        # Transparency columns next to WindowsVMCount.
        Add-Member -InputObject $pos -NotePropertyName TotalVMCount   -NotePropertyValue $hostVMs.Count    -Force
        Add-Member -InputObject $pos -NotePropertyName UnknownVMCount -NotePropertyValue $unknownVMs.Count -Force
        $hostPositions.Add($pos)
    }

    # ── Standalone PHYSICAL Windows servers (not a hypervisor host, not a VM) ─
    $hostNames = @($hosts | ForEach-Object { ($_.HostName -split '\.')[0].ToLower() })
    # Collapse per-server "no core data" notes into ONE grouped warning instead of
    # one row per unreachable target (which otherwise floods the report).
    $noCoreServers = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $servers) {
        # Usable if we have physical-core data from any source (live CIM or SCCM
        # backfill). Never assume zero cores for a server we could not measure.
        $hasCores = [bool]($s.PSObject.Properties.Match('PhysicalCores').Count -and $s.PhysicalCores)
        if (-not $hasCores) {
            $noCoreServers.Add([string]$s.ComputerName) | Out-Null
            continue
        }
        $short = ($s.ComputerName -split '\.')[0].ToLower()
        $isHypervisorHost = $hostNames -contains $short
        # Optional fields read StrictMode-safely (local-drop / partial records).
        if ((Get-OVMember $s 'IsVirtual') -or $isHypervisorHost) { continue }   # VMs covered by host; hosts already done
        if ((Get-OVMember $s 'OSCaption') -notmatch 'Windows.*Server') { continue }

        $synthHost = [pscustomobject]@{
            HostName = $s.ComputerName; Hypervisor = 'Physical'; Cluster = $null
            Sockets = (Get-OVMember $s 'Sockets'); PhysicalCores = (Get-OVMember $s 'PhysicalCores')
        }
        # A standalone physical server runs its own OS; Standard's 2-OSE right
        # is moot here (1 physical OSE), so it's the simplest comparison.
        $pos = Get-OVHostLicensePosition -HostInfo $synthHost -WindowsVMs @() -Pricing $pricing -HasSA $hasSA
        Add-Member -InputObject $pos -NotePropertyName TotalVMCount   -NotePropertyValue 0 -Force
        Add-Member -InputObject $pos -NotePropertyName UnknownVMCount -NotePropertyValue 0 -Force
        $hostPositions.Add($pos)
    }
    if ($noCoreServers.Count -gt 0) {
        $shown = if ($noCoreServers.Count -gt 40) { (@($noCoreServers | Select-Object -First 40) -join ', ') + ", and $($noCoreServers.Count - 40) more" } else { $noCoreServers -join ', ' }
        $warnings.Add("$($noCoreServers.Count) server(s) had no core data (unreachable, and no SCCM/local-collector backfill). Excluded from license math; NOT assumed zero-core. [$shown]")
    }

    # ── Windows VMs not mapped to any assessed host (never silently dropped) ──
    # e.g. powered-off Nutanix VMs (HostName=$null) or VMs on a host we couldn't
    # price. They still consume licensing, so surface them loudly.
    $assessedHostNames = @{}
    foreach ($h in $hosts) { if ($h.PhysicalCores -and $h.HostName) { $assessedHostNames[$h.HostName] = $true } }
    $unmappedWin = @()
    foreach ($vm in $vmMap) {
        $hn = Get-OVMember $vm 'HostName'
        if ($hn -and $assessedHostNames.ContainsKey($hn)) { continue }
        if ((Test-WindowsServerVM $vm) -eq 'Yes') { $unmappedWin += (Get-OVVmKey $vm) }
    }
    if ($unmappedWin.Count -gt 0) {
        $warnings.Add("$($unmappedWin.Count) Windows Server VM(s) are not mapped to an assessed host (powered off / unresolved placement) and are NOT counted, but still consume licensing. [$($unmappedWin -join ', ')]")
    }

    # ── SQL roll-up (secondary cost driver) ────────────────────────────────
    $sqlInstances = foreach ($s in $servers) {
        foreach ($i in @(Get-OVMember $s 'SqlInstances')) {
            [pscustomobject]@{ Server = $s.ComputerName; Instance = (Get-OVMember $i 'Instance'); Edition = (Get-OVMember $i 'Edition'); Version = (Get-OVMember $i 'Version') }
        }
    }

    # No hosts assessed at all (no hypervisor data and nothing reachable) — make
    # this loud rather than emitting a silent $0 position.
    if (@($hostPositions).Count -eq 0) {
        $warnings.Add("No hosts could be assessed: no hypervisor host data was collected and no servers were reachable for live core counts. Check WinRM / firewall / credentials to the targets and the hypervisor connections.")
    }

    # ── Estate summary ─────────────────────────────────────────────────────
    $byModel = $hostPositions | Group-Object RecommendedModel | ForEach-Object {
        [pscustomobject]@{
            Model = $_.Name
            Hosts = $_.Count
            Cores = (Get-OVSum -Items $_.Group -Property 'RecommendedCores')
            Cost  = [math]::Round((Get-OVSum -Items $_.Group -Property 'EstimatedCost'), 2)
        }
    }
    $totalCost = [math]::Round((Get-OVSum -Items $hostPositions -Property 'EstimatedCost'), 2)

    foreach ($p in ($hostPositions | Where-Object ForceDatacenter)) {
        $warnings.Add("Host '$($p.HostName)' forced to Datacenter: $($p.ForceReasons)")
    }

    # Operational-simplicity preference rollup.
    $premiumHosts = @($hostPositions | Where-Object PreferenceApplied)
    $premiumTotal = 0.0
    if ($premiumHosts.Count) {
        $sum = ($premiumHosts | Measure-Object OperationalPremium -Sum).Sum
        if ($sum) { $premiumTotal = [math]::Round($sum, 2) }
        $warnings.Add("$($premiumHosts.Count) host(s) set to Datacenter for operational simplicity (PreferDatacenterAtVMCount). Premium over the lowest-cost option: $premiumTotal.")
    }

    $totalUnknown = 0
    foreach ($p in $hostPositions) { $u = Get-OVMember $p 'UnknownVMCount' 0; if ($u) { $totalUnknown += [int]$u } }

    # Windows client / VDI tally (separate license family; informational, not priced).
    $clientVdiCount = @($vmMap | Where-Object {
        $gos = Get-OVMember $_ 'GuestOS'
        $nm  = Get-OVVmKey $_
        $iws = Get-OVMember $_ 'IsWindowsServer'
        (($iws -eq $false) -and $gos -and ($gos -match 'Windows') -and ($gos -notmatch 'Server')) -or
        ($gos -and ($gos -match 'Windows (1[01]|7|8|XP|Vista)') -and ($gos -notmatch 'Server')) -or
        ($nm -and ($nm -match $clientNameRegex))
    }).Count

    return [pscustomobject]@{
        GeneratedAt             = $Dataset.GeneratedAt
        SoftwareAssurance       = $hasSA
        Pricing                 = $pricing
        HostPositions           = $hostPositions
        SummaryByModel          = $byModel
        EstimatedTotalCost      = $totalCost
        PreferenceHostCount     = $premiumHosts.Count
        OperationalPremiumTotal = $premiumTotal
        UnknownVMCount          = $totalUnknown
        UnmappedWindowsVMCount  = $unmappedWin.Count
        ClientVdiVMCount        = $clientVdiCount
        SqlInstances            = @($sqlInstances)
        CalFootprint            = $Dataset.CalFootprint
        Warnings                = @($warnings)
    }
}

Export-ModuleMember -Function Get-OVLicensePosition, Get-OVHostLicensePosition,
    Get-OVLicensableCores, Get-OVCorePacks
