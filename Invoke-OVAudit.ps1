#requires -Version 5.1
<#
.SYNOPSIS
    OV-Audit — read-only Windows Server inventory for a licensing renewal.

.DESCRIPTION
    Pulls the server list from Active Directory, physical-host core counts and
    VM↔host mapping from the hypervisors (VMware / Hyper-V), and per-guest
    detail (OS edition, cores, SQL, roles) via CIM. Joins it all and writes
    raw inventory + a host summary, then (if the licensing engine is present)
    a recommended license position.

    Everything is READ-ONLY.

.EXAMPLE
    .\Invoke-OVAudit.ps1 -ConfigPath .\config.psd1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = '.\config.psd1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Load config & modules ──────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath (copy config.example.psd1)" }
$cfg = Import-PowerShellDataFile -Path $ConfigPath

Import-Module (Join-Path $scriptRoot 'src\OVAudit.Collect.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\OVAudit.Sources.psm1') -Force
$licenseModule = Join-Path $scriptRoot 'src\OVAudit.License.psm1'
$reportModule  = Join-Path $scriptRoot 'src\OVAudit.Report.psm1'
$execModule    = Join-Path $scriptRoot 'src\OVAudit.ExecSummary.psm1'
if (Test-Path $licenseModule) { Import-Module $licenseModule -Force }
if (Test-Path $reportModule)  { Import-Module $reportModule  -Force }
if (Test-Path $execModule)    { Import-Module $execModule    -Force }

$outDir = $cfg.OutputPath
if (-not [IO.Path]::IsPathRooted($outDir)) { $outDir = Join-Path $scriptRoot $outDir }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Step { param($m) Write-Host "[OV-Audit] $m" -ForegroundColor Cyan }

# ── Credentials (prompt once per realm; never store) ───────────────────────
$creds = @{}
function Get-OVCred {
    param([string] $Realm, [string] $Prompt)
    if (-not $creds.ContainsKey($Realm)) {
        $creds[$Realm] = Get-Credential -Message $Prompt
    }
    return $creds[$Realm]
}

# ── 1. Server list from AD ─────────────────────────────────────────────────
$adServers = @()
if ($cfg.ActiveDirectory.Enabled) {
    Write-Step "Enumerating Windows Server accounts from Active Directory..."
    $adServers = @(Get-OVADServers -Server $cfg.ActiveDirectory.Server `
        -SearchBase $cfg.ActiveDirectory.SearchBase `
        -ServerOsFilter $cfg.ActiveDirectory.ServerOsFilter)
    Write-Step "  $($adServers.Count) server accounts found ($([int](@($adServers | Where-Object Stale).Count)) stale > 60d)."
}

# ── 1b. SCCM/MECM supplement (breadth + offline backfill) ──────────────────
$sccm = @{}
if ($cfg.ContainsKey('ConfigMgr') -and $cfg.ConfigMgr.Enabled) {
    Write-Step "Pulling SCCM/MECM hardware inventory..."
    $cmCred = Get-OVCred -Realm 'sccm' -Prompt 'SCCM SMS Provider credentials'
    try {
        $rows = @(Get-OVConfigMgrInventory -SiteServer $cfg.ConfigMgr.SiteServer -SiteCode $cfg.ConfigMgr.SiteCode -Credential $cmCred)
        foreach ($r in $rows) { if ($r.ComputerName) { $sccm[($r.ComputerName -split '\.')[0].ToLower()] = $r } }
        Write-Step "  $($sccm.Count) server records from SCCM."
    } catch { Write-Warning "SCCM collection failed: $($_.Exception.Message)" }
}

# ── 2. Hypervisor inventory (hosts + VM↔host mapping) ──────────────────────
$hosts = @()
$vmMap = @()
if ($cfg.VMware.Enabled) {
    Write-Step "Collecting VMware inventory via PowerCLI..."
    $vmwCred = Get-OVCred -Realm 'vmware' -Prompt 'vCenter / ESXi credentials'
    $vmw = Get-OVVMwareInventory -VIServers $cfg.VMware.vCenters -Credential $vmwCred
    $hosts += $vmw.Hosts
    $vmMap += $vmw.VMs
    Write-Step "  $($vmw.Hosts.Count) ESXi hosts, $($vmw.VMs.Count) VMs."
}
if ($cfg.HyperV.Enabled) {
    Write-Step "Collecting Hyper-V inventory..."
    $hvCred = if ($cfg.HyperV.Hosts -or $cfg.HyperV.Clusters) { Get-OVCred -Realm 'hyperv' -Prompt 'Hyper-V host credentials' } else { $null }
    $hv = Get-OVHyperVInventory -Hosts $cfg.HyperV.Hosts -Clusters $cfg.HyperV.Clusters -Credential $hvCred
    $hosts += $hv.Hosts
    $vmMap += $hv.VMs
    Write-Step "  $($hv.Hosts.Count) Hyper-V hosts, $($hv.VMs.Count) VMs."
}
if ($cfg.ContainsKey('Nutanix') -and $cfg.Nutanix.Enabled) {
    Write-Step "Collecting Nutanix AHV inventory via Prism REST..."
    $ntxCred = Get-OVCred -Realm 'nutanix' -Prompt 'Nutanix Prism credentials'
    $ntx = Get-OVNutanixInventory -Prisms $cfg.Nutanix.Prisms -Port $cfg.Nutanix.Port -Credential $ntxCred
    $hosts += $ntx.Hosts
    $vmMap += $ntx.VMs
    Write-Step "  $($ntx.Hosts.Count) AHV hosts, $($ntx.VMs.Count) VMs."
}

# ── 2c. Azure / Arc discovery (servers that left on-prem AD for the cloud) ─
$azureServers = @()
if ($cfg.ContainsKey('Azure') -and $cfg.Azure.Enabled) {
    Write-Step "Discovering Azure / Arc-enabled Windows Servers via Resource Graph..."
    try {
        $azureServers = @(Get-OVAzureInventory -TenantId $cfg.Azure.TenantId `
            -SubscriptionIds $cfg.Azure.SubscriptionIds -TenantScope $cfg.Azure.TenantScope)
        $arcN = @($azureServers | Where-Object { $_.Source -eq 'Azure Arc' }).Count
        $vmN  = @($azureServers | Where-Object { $_.Source -eq 'Azure VM' }).Count
        Write-Step "  $($azureServers.Count) Windows server(s) from Azure ($arcN Arc, $vmN Azure VM)."
    } catch { Write-Warning "Azure discovery failed: $($_.Exception.Message)" }
}

# ── 2d. Local-collector drop (servers that self-reported via Collect-OVLocal) ─
$localDrop = @{}
if ($cfg.ContainsKey('LocalDrop') -and $cfg.LocalDrop.Enabled) {
    Write-Step "Loading local-collector drop from $($cfg.LocalDrop.Path)..."
    foreach ($r in @(Import-OVLocalDrop -Path $cfg.LocalDrop.Path)) {
        if ($r.ComputerName) { $localDrop[($r.ComputerName -split '\.')[0].ToLower()] = $r }
    }
    Write-Step "  $($localDrop.Count) local-collector record(s)."
}

# ── 3. Per-server detail via CIM ───────────────────────────────────────────
Write-Step "Collecting per-server detail (OS / cores / SQL / roles)..."
# Reconcile every discovery source (AD + hypervisor VMs + SCCM) into one
# de-duplicated target list. Including hypervisor VMs catches servers that are
# on a host but NOT in AD (the Entra-only / workgroup case).
$discovery = Merge-OVDiscoveryTargets -AdServers $adServers -HypervisorVMs $vmMap -SccmServers @($sccm.Values)
$discByShort = @{}; foreach ($d in $discovery) { $discByShort[$d.Short] = $d }
$targets = @($discovery | ForEach-Object { $_.Name }) | Select-Object -Unique
$outsideAd = @($discovery | Where-Object { -not $_.InAD }).Count
Write-Step "  $($targets.Count) targets ($outsideAd not found in AD)."
$svrCred = Get-OVCred -Realm 'servers' -Prompt 'Credentials for target servers (CIM/WinRM)'
$sd = $cfg.ServerDetail

$detail =
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $targets | ForEach-Object -ThrottleLimit $sd.ThrottleLimit -Parallel {
            Import-Module "$using:scriptRoot\src\OVAudit.Collect.psm1" -Force
            $c = $using:sd
            Get-OVServerDetail -ComputerName $_ -Credential $using:svrCred `
                -PreferWinRM $c.PreferWinRM -AllowDcomFallback $c.AllowDcomFallback `
                -CollectSql $c.CollectSql -CollectRoles $c.CollectRoles -TimeoutSec $c.TimeoutSec
        }
    } else {
        $targets | ForEach-Object {
            Get-OVServerDetail -ComputerName $_ -Credential $svrCred `
                -PreferWinRM $sd.PreferWinRM -AllowDcomFallback $sd.AllowDcomFallback `
                -CollectSql $sd.CollectSql -CollectRoles $sd.CollectRoles -TimeoutSec $sd.TimeoutSec
        }
    }
$detail = @($detail)
$reached = @($detail | Where-Object Reachable).Count
Write-Step "  $reached/$($targets.Count) servers reached."

# ── 4. Join guest detail to host mapping ───────────────────────────────────
# Match VM records to collected detail by hostname (case-insensitive, short name).
foreach ($vm in $vmMap) {
    # Hyper-V VM records have no GuestHostName property; read safely or StrictMode aborts the run.
    $key = @((Get-OVProp $vm 'GuestHostName'), (Get-OVProp $vm 'VMName') | Where-Object { $_ })[0]
    if ($key) {
        $short = ($key -split '\.')[0]
        $match = $detail | Where-Object { $_.ComputerName -and ($_.ComputerName -split '\.')[0] -ieq $short } | Select-Object -First 1
        if ($match) {
            Add-Member -InputObject $match -NotePropertyName PhysicalHost -NotePropertyValue $vm.HostName -Force
            Add-Member -InputObject $match -NotePropertyName HypervisorSource -NotePropertyValue $vm.Hypervisor -Force
        }
    }
}

# ── 4b. Backfill unreachable servers from SCCM last-known inventory ────────
if ($sccm.Count -gt 0) {
    foreach ($d in $detail) {
        if ($d.Reachable) { continue }
        $short = ($d.ComputerName -split '\.')[0].ToLower()
        if ($sccm.ContainsKey($short)) {
            $r = $sccm[$short]
            $d.DataSource    = $r.DataSource
            $d.OSCaption     = $r.OSCaption
            $d.OSVersion     = $r.OSVersion
            $d.OSBuild       = $r.OSBuild
            $d.Sockets       = $r.Sockets
            $d.PhysicalCores = $r.PhysicalCores
            $d.LogicalProcs  = $r.LogicalProcs
            $d.Manufacturer  = $r.Manufacturer
            $d.Model         = $r.Model
            $d.IsVirtual     = $r.IsVirtual
            $d.Edition       = Resolve-OVEdition -Caption $r.OSCaption -OperatingSystemSKU $null
        }
    }
    $backfilled = @($detail | Where-Object { $_.DataSource -eq 'SCCM (last inventory)' }).Count
    Write-Step "  Backfilled $backfilled unreachable server(s) from SCCM."
}

# ── 4c. Tag each server with how it was discovered (AD vs elsewhere) ───────
foreach ($d in $detail) {
    $short = ($d.ComputerName -split '\.')[0].ToLower()
    $disc  = $discByShort[$short]
    $via   = if ($disc) { ($disc.Sources -join ';') } else { 'Unknown' }
    $inAd  = if ($disc) { [bool]$disc.InAD } else { $false }
    Add-Member -InputObject $d -NotePropertyName DiscoveredVia -NotePropertyValue $via  -Force
    Add-Member -InputObject $d -NotePropertyName InAD          -NotePropertyValue $inAd -Force
}

# ── 4d. Fold in local-collector data (backfill unreachable; append local-only) ─
if ($localDrop.Count -gt 0) {
    $adShortSet = @{}; foreach ($a in $adServers) { $nm = if ($a.DNSHostName) { $a.DNSHostName } else { $a.Name }; if ($nm) { $adShortSet[($nm -split '\.')[0].ToLower()] = $true } }
    $detailShortSet = @{}; foreach ($d in $detail) { $detailShortSet[($d.ComputerName -split '\.')[0].ToLower()] = $true }

    foreach ($d in $detail) {
        if ($d.Reachable) { continue }   # live CIM wins; only enrich the ones we missed
        $short = ($d.ComputerName -split '\.')[0].ToLower()
        if (-not $localDrop.ContainsKey($short)) { continue }
        $r = $localDrop[$short]
        $d.DataSource    = 'Local collector'
        $d.OSCaption     = Get-OVProp $r 'OSCaption'
        $d.OSVersion     = Get-OVProp $r 'OSVersion'
        $d.OSBuild       = Get-OVProp $r 'OSBuild'
        $d.Edition       = Get-OVProp $r 'Edition'
        $d.Sockets       = Get-OVProp $r 'Sockets'
        $d.PhysicalCores = Get-OVProp $r 'PhysicalCores'
        $d.LogicalProcs  = Get-OVProp $r 'LogicalProcs'
        $d.IsVirtual     = Get-OVProp $r 'IsVirtual'
        $d.Manufacturer  = Get-OVProp $r 'Manufacturer'
        $d.Model         = Get-OVProp $r 'Model'
        $d.SqlInstances  = @(Get-OVProp $r 'SqlInstances')
        $d.InstalledRoles= @(Get-OVProp $r 'InstalledRoles')
    }

    $appended = 0
    foreach ($k in $localDrop.Keys) {
        if ($detailShortSet.ContainsKey($k)) { continue }   # already represented
        $r = $localDrop[$k]
        Add-Member -InputObject $r -NotePropertyName DiscoveredVia -NotePropertyValue 'Local collector' -Force
        Add-Member -InputObject $r -NotePropertyName InAD -NotePropertyValue ([bool]$adShortSet.ContainsKey($k)) -Force
        $detail += $r
        $appended++
    }
    Write-Step "  Local-collector: enriched unreachable hosts; appended $appended local-only server(s)."
}

# ── 5. CAL footprint ───────────────────────────────────────────────────────
$cals = $null
if ($cfg.ActiveDirectory.Enabled -and $cfg.ActiveDirectory.CountCals) {
    Write-Step "Estimating CAL footprint..."
    $cals = Get-OVCalFootprint -Server $cfg.ActiveDirectory.Server -SearchBase $cfg.ActiveDirectory.SearchBase
}

# ── 6. Assemble dataset ────────────────────────────────────────────────────
$dataset = [ordered]@{
    GeneratedAt = (Get-Date).ToString('s')
    Servers     = $detail
    Hosts       = $hosts
    VMMap       = $vmMap
    CalFootprint= $cals
    AdServers   = $adServers
    AzureServers= $azureServers
}

# ── 7. License position (engine added once research lands) ─────────────────
if (Get-Command Get-OVLicensePosition -ErrorAction SilentlyContinue) {
    Write-Step "Computing cheapest-compliant license position..."
    $licCfg = if ($cfg.ContainsKey('Licensing')) { $cfg.Licensing } else { $null }
    $dataset.LicensePosition = Get-OVLicensePosition -Dataset $dataset -Licensing $licCfg
} else {
    Write-Warning "License engine (OVAudit.License.psm1) not present yet — exporting raw inventory only."
}

# ── 8. Export ──────────────────────────────────────────────────────────────
Write-Step "Writing output to $outDir ..."
$detail | Export-Csv -Path (Join-Path $outDir 'inventory.csv') -NoTypeInformation -Encoding UTF8
$hosts  | Export-Csv -Path (Join-Path $outDir 'host-summary.csv') -NoTypeInformation -Encoding UTF8
# Discovery coverage: every server, how it was found, and crucially what is NOT
# in AD. Combines CIM-scanned servers (AD/hypervisor/SCCM) with Azure/Arc finds.
$cimCoverage = $detail | Select-Object ComputerName, InAD, DiscoveredVia, Reachable, DataSource,
    OSCaption, Edition, IsVirtual, PhysicalHost, PhysicalCores
$detailShort = @{}; foreach ($d in $detail) { $detailShort[($d.ComputerName -split '\.')[0].ToLower()] = $true }
$azCoverage = foreach ($z in $azureServers) {
    $short = ($z.ComputerName -split '\.')[0].ToLower()
    if ($detailShort.ContainsKey($short)) { continue }   # already represented by a CIM-scanned record
    [pscustomobject]@{
        ComputerName  = $z.ComputerName
        InAD          = ($discByShort.ContainsKey($short) -and [bool]$discByShort[$short].InAD)
        DiscoveredVia = $z.Source
        Reachable     = $false
        DataSource    = 'Azure Resource Graph'
        OSCaption     = $z.OSName
        Edition       = (Resolve-OVEdition -Caption ([string]$z.OSName) -OperatingSystemSKU $null)
        IsVirtual     = $true
        PhysicalHost  = $z.Cloud
        PhysicalCores = $(if ($z.PhysicalCores) { $z.PhysicalCores } else { $z.vCPU })
    }
}
$coverage = @($cimCoverage) + @($azCoverage)
$coverage | Sort-Object InAD, ComputerName |
    Export-Csv -Path (Join-Path $outDir 'discovery-coverage.csv') -NoTypeInformation -Encoding UTF8
$serversNotInAd = @($coverage | Where-Object { -not $_.InAD -and $_.OSCaption -match 'Windows.*Server' }).Count
Write-Step "  Discovery: $serversNotInAd Windows Server(s) found OUTSIDE Active Directory (see discovery-coverage.csv)."
$dataset | ConvertTo-Json -Depth 8 | Out-File (Join-Path $outDir 'inventory.json') -Encoding UTF8
if (Get-Command Export-OVReport -ErrorAction SilentlyContinue) {
    Export-OVReport -Dataset $dataset -OutputPath $outDir
}
if ((Get-Command Export-OVExecutiveSummary -ErrorAction SilentlyContinue) -and
    $cfg.ContainsKey('Report') -and $cfg.Report.ExecutiveSummary) {
    Write-Step "Building customer-facing executive summary..."
    Export-OVExecutiveSummary -Dataset $dataset -OutputPath $outDir `
        -CustomerName $cfg.Report.CustomerName -PreparedBy $cfg.Report.PreparedBy | Out-Null
}

Write-Step "Done."
