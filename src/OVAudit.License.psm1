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
      • Datacenter is forced where Datacenter-only features are in use
        (S2D, SDN/Network Controller, guarded Hyper-V host, unplanned-failover
        clustering, Storage Replica beyond Standard's single 2 TB volume).
#>

Set-StrictMode -Version Latest

# Default Microsoft suggested-list per-core pricing (override via config).
$script:DefaultPricing = @{
    StandardPerCore   = 73.50    # $1,176 / 16
    DatacenterPerCore = 423.19   # $6,771 / 16
}

# Datacenter-only role/feature signatures (matched against InstalledRoles).
$script:DatacenterFeatures = @(
    'Storage-Replica'           # Storage Replica (Standard caps at one 2TB volume)
    'FS-SMBBW'
    'NetworkController'         # SDN / Network Controller
    'HostGuardian'             # guarded Hyper-V host (Host Guardian Hyper-V Support)
)

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

    # ── Option A: Datacenter (covers all VMs on the host) ──────────────────
    $dcCost = $licensableCores * $Pricing.DatacenterPerCore

    # ── Option B: Stacked Standard (2 VMs per full all-core set) ───────────
    $stdSets  = [math]::Max(1, [math]::Ceiling($vmCount / 2))
    $stdCores = $stdSets * $licensableCores
    $stdCost  = $stdCores * $Pricing.StandardPerCore

    # ── Option C: Per-VM (vCore), SA/subscription only ─────────────────────
    $perVmCores = 0
    foreach ($vm in $WindowsVMs) {
        $v = if ($vm.vCPU) { [int]$vm.vCPU } else { 8 }
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
    if ($Licensing) {
        if ($Licensing.ContainsKey('StandardPerCore'))   { $pricing.StandardPerCore   = $Licensing.StandardPerCore }
        if ($Licensing.ContainsKey('DatacenterPerCore')) { $pricing.DatacenterPerCore = $Licensing.DatacenterPerCore }
        if ($Licensing.ContainsKey('HasSoftwareAssurance')) { $hasSA = [bool]$Licensing.HasSoftwareAssurance }
        if ($Licensing.ContainsKey('ClusterForcesDatacenterWithoutSA')) { $clusterForcesDC = [bool]$Licensing.ClusterForcesDatacenterWithoutSA }
        if ($Licensing.ContainsKey('Currency')) { $pricing['Currency'] = $Licensing.Currency }
        if ($Licensing.ContainsKey('PreferDatacenterAtVMCount')) { $preferDcAtVms = [int]$Licensing.PreferDatacenterAtVMCount }
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

    # Which VMs are Windows Server? Prefer collected detail; fall back to the
    # hypervisor's IsWindowsServer flag / guest OS string.
    function Test-WindowsServerVM {
        param($vm)
        $key = @($vm.GuestHostName, $vm.VMName | Where-Object { $_ })[0]
        if ($key) {
            $short = ($key -split '\.')[0].ToLower()
            if ($detailByShort.ContainsKey($short)) {
                return ($detailByShort[$short].OSCaption -match 'Windows.*Server')
            }
        }
        if ($null -ne $vm.IsWindowsServer) { return [bool]$vm.IsWindowsServer }
        return ($vm.GuestOS -match 'Windows.*Server')
    }

    function Get-VMEditionFeatures {
        # Did any guest on this host use Datacenter-only roles? (best-effort)
        param($winVms)
        $reasons = @()
        foreach ($vm in $winVms) {
            $key = @($vm.GuestHostName, $vm.VMName | Where-Object { $_ })[0]
            if ($key) {
                $short = ($key -split '\.')[0].ToLower()
                if ($detailByShort.ContainsKey($short)) {
                    $roles = @($detailByShort[$short].InstalledRoles)
                    foreach ($f in $script:DatacenterFeatures) {
                        if ($roles -contains $f) { $reasons += "guest '$short' uses $f" }
                    }
                }
            }
        }
        return $reasons
    }

    # ── Per-host positions ─────────────────────────────────────────────────
    $hostPositions = [System.Collections.Generic.List[object]]::new()
    foreach ($h in $hosts) {
        if (-not $h.PhysicalCores) {
            $warnings.Add("Host '$($h.HostName)' has no physical-core data — skipped from license math (verify hypervisor collection).")
            continue
        }
        $hostVMs = @($vmMap | Where-Object { $_.HostName -eq $h.HostName })
        $winVMs  = @($hostVMs | Where-Object { Test-WindowsServerVM $_ })

        # Force Datacenter on Datacenter-only features or (no SA + clustered).
        $forceReasons = @()
        $forceReasons += Get-VMEditionFeatures -winVms $winVMs
        $isClustered = [bool]$h.Cluster
        if ($isClustered -and -not $hasSA -and $clusterForcesDC) {
            $forceReasons += "clustered host without SA (90-day reassignment rule forces licensing every node as Datacenter)"
        }
        $force = $forceReasons.Count -gt 0

        $pos = Get-OVHostLicensePosition -HostInfo $h -WindowsVMs $winVMs -Pricing $pricing `
            -HasSA $hasSA -ForceDatacenter:$force -ForceReasons $forceReasons -PreferDatacenterAtVMs $preferDcAtVms
        $hostPositions.Add($pos)
    }

    # ── Standalone PHYSICAL Windows servers (not a hypervisor host, not a VM) ─
    $hostNames = @($hosts | ForEach-Object { ($_.HostName -split '\.')[0].ToLower() })
    foreach ($s in $servers) {
        # Usable if we have physical-core data from any source (live CIM or SCCM
        # backfill). Never assume zero cores for a server we could not measure.
        $hasCores = [bool]($s.PSObject.Properties.Match('PhysicalCores').Count -and $s.PhysicalCores)
        if (-not $hasCores) {
            $src = if ($s.PSObject.Properties.Match('DataSource').Count) { $s.DataSource } else { 'none' }
            $warnings.Add("Server '$($s.ComputerName)' has no core data (reachable=$($s.Reachable); source=$src). Excluded from license math; NOT assumed zero-core.")
            continue
        }
        $short = ($s.ComputerName -split '\.')[0].ToLower()
        $isHypervisorHost = $hostNames -contains $short
        if ($s.IsVirtual -or $isHypervisorHost) { continue }   # VMs covered by host; hosts already done
        if ($s.OSCaption -notmatch 'Windows.*Server') { continue }

        $synthHost = [pscustomobject]@{
            HostName = $s.ComputerName; Hypervisor = 'Physical'; Cluster = $null
            Sockets = $s.Sockets; PhysicalCores = $s.PhysicalCores
        }
        # A standalone physical server runs its own OS; Standard's 2-OSE right
        # is moot here (1 physical OSE), so it's the simplest comparison.
        $pos = Get-OVHostLicensePosition -HostInfo $synthHost -WindowsVMs @() -Pricing $pricing -HasSA $hasSA
        $hostPositions.Add($pos)
    }

    # ── SQL roll-up (secondary cost driver) ────────────────────────────────
    $sqlInstances = foreach ($s in $servers) {
        foreach ($i in @($s.SqlInstances)) {
            [pscustomobject]@{ Server = $s.ComputerName; Instance = $i.Instance; Edition = $i.Edition; Version = $i.Version }
        }
    }

    # ── Estate summary ─────────────────────────────────────────────────────
    $byModel = $hostPositions | Group-Object RecommendedModel | ForEach-Object {
        [pscustomobject]@{
            Model = $_.Name
            Hosts = $_.Count
            Cores = ($_.Group | Measure-Object RecommendedCores -Sum).Sum
            Cost  = [math]::Round((($_.Group | Measure-Object EstimatedCost -Sum).Sum), 2)
        }
    }
    $totalCost = [math]::Round((($hostPositions | Measure-Object EstimatedCost -Sum).Sum), 2)

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

    return [pscustomobject]@{
        GeneratedAt             = $Dataset.GeneratedAt
        SoftwareAssurance       = $hasSA
        Pricing                 = $pricing
        HostPositions           = $hostPositions
        SummaryByModel          = $byModel
        EstimatedTotalCost      = $totalCost
        PreferenceHostCount     = $premiumHosts.Count
        OperationalPremiumTotal = $premiumTotal
        SqlInstances            = @($sqlInstances)
        CalFootprint            = $Dataset.CalFootprint
        Warnings                = @($warnings)
    }
}

Export-ModuleMember -Function Get-OVLicensePosition, Get-OVHostLicensePosition,
    Get-OVLicensableCores, Get-OVCorePacks
