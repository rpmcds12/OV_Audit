#requires -Version 5.1
<#
    Validates the OV-Audit licensing math against hand-computed cases.
    Run: pwsh ./tests/Test-OVLicense.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'src/OVAudit.License.psm1') -Force

$fail = 0
function Assert-Eq {
    param($Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Name  (expected $Expected, got $Actual)" -ForegroundColor Red
        $script:fail++
    }
}
function Assert-Near {
    # Currency: compare within a tolerance (rounded per-core rates drift by cents).
    param($Name, [double]$Expected, [double]$Actual, [double]$Tolerance = 0.10)
    if ([math]::Abs($Expected - $Actual) -le $Tolerance) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Name  (expected ~$Expected, got $Actual)" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "`n== Get-OVLicensableCores (8/proc, 16/server minimums, 2-core rounding) ==" -ForegroundColor Cyan
Assert-Eq "1x4-core -> 16 (server min)"        16  (Get-OVLicensableCores -PhysicalCores 4  -Sockets 1)
Assert-Eq "2x4-core (8 cores) -> 16 (server min)" 16 (Get-OVLicensableCores -PhysicalCores 8  -Sockets 2)
Assert-Eq "2x8-core (16) -> 16"                16  (Get-OVLicensableCores -PhysicalCores 16 -Sockets 2)
Assert-Eq "2x10-core (20) -> 20"               20  (Get-OVLicensableCores -PhysicalCores 20 -Sockets 2)
Assert-Eq "2x18-core (36) -> 36"               36  (Get-OVLicensableCores -PhysicalCores 36 -Sockets 2)
Assert-Eq "1x6-core -> 16 (proc min 8 < server min 16)" 16 (Get-OVLicensableCores -PhysicalCores 6 -Sockets 1)
Assert-Eq "2x6-core (12) -> 16 (server min beats 2x8=16)" 16 (Get-OVLicensableCores -PhysicalCores 12 -Sockets 2)
Assert-Eq "4x4-core (16) -> 32 (8/proc x4)"    32  (Get-OVLicensableCores -PhysicalCores 16 -Sockets 4)
Assert-Eq "1x13-core (odd) -> 16"              16  (Get-OVLicensableCores -PhysicalCores 13 -Sockets 1)
Assert-Eq "2x9-core (18) -> 18"                18  (Get-OVLicensableCores -PhysicalCores 18 -Sockets 2)

Write-Host "`n== Per-host model selection ==" -ForegroundColor Cyan
$pricing = @{ StandardPerCore = 73.50; DatacenterPerCore = 423.19 }

# 16-core host, 2 VMs -> Standard (1 set) cheapest. Std=16*73.5=1176; DC=16*423.19=6771.
$h16 = [pscustomobject]@{ HostName='HV1'; Hypervisor='Hyper-V'; Cluster=$null; Sockets=2; PhysicalCores=16 }
$vms2 = 1..2 | ForEach-Object { [pscustomobject]@{ vCPU = 4 } }
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms2 -Pricing $pricing -HasSA $true
Assert-Eq   "16c/2VM recommends Standard" 'Standard (stacked)' $p.RecommendedModel
Assert-Near "16c/2VM cost ~1176"          1176 $p.EstimatedCost

# 16-core host, 20 VMs -> Datacenter cheapest (well past break-even ~11.5).
$vms20 = 1..20 | ForEach-Object { [pscustomobject]@{ vCPU = 2 } }
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms20 -Pricing $pricing -HasSA $true
Assert-Eq   "16c/20VM recommends Datacenter" 'Datacenter (all cores)' $p.RecommendedModel
Assert-Near "16c/20VM cost ~6771"            6771 $p.EstimatedCost 0.10

# Per-VM should win for a few small VMs WITH SA: 3x 2-vCPU VMs -> per-VM = 3*8=24 cores*73.5=1764
# vs Standard stacked ceil(3/2)=2 sets *16 =32 cores *73.5 = 2352. Per-VM cheaper.
$vms3 = 1..3 | ForEach-Object { [pscustomobject]@{ vCPU = 2 } }
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms3 -Pricing $pricing -HasSA $true
Assert-Eq "16c/3 small VM + SA recommends Per-VM" 'Per-VM (vCore, SA)' $p.RecommendedModel
Assert-Eq "16c/3 small VM per-VM cost = 1764"      1764 $p.EstimatedCost

# Without SA, per-VM is unavailable -> Standard stacked for the same 3 VMs.
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms3 -Pricing $pricing -HasSA $false
Assert-Eq "16c/3 VM no SA falls back to Standard" 'Standard (stacked)' $p.RecommendedModel

# Force Datacenter overrides cheaper Standard.
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms2 -Pricing $pricing -HasSA $true -ForceDatacenter:$true -ForceReasons @('S2D')
Assert-Eq "ForceDatacenter overrides Standard" 'Datacenter (all cores)' $p.RecommendedModel

Write-Host "`n== End-to-end Get-OVLicensePosition on a synthetic estate ==" -ForegroundColor Cyan
$dataset = [ordered]@{
    GeneratedAt = '2026-06-12T00:00:00'
    Hosts = @(
        [pscustomobject]@{ HostName='esx01'; Hypervisor='VMware'; Cluster='Prod'; Sockets=2; PhysicalCores=32; LogicalProcs=64 }
    )
    VMMap = @(
        [pscustomobject]@{ Hypervisor='VMware'; VMName='APP01'; HostName='esx01'; GuestHostName='app01'; vCPU=4; IsWindowsServer=$true }
        [pscustomobject]@{ Hypervisor='VMware'; VMName='APP02'; HostName='esx01'; GuestHostName='app02'; vCPU=4; IsWindowsServer=$true }
        [pscustomobject]@{ Hypervisor='VMware'; VMName='LINUX1';HostName='esx01'; GuestHostName='lin01'; vCPU=2; IsWindowsServer=$false }
    )
    Servers = @(
        [pscustomobject]@{ ComputerName='app01'; Reachable=$true; OSCaption='Microsoft Windows Server 2022 Standard'; IsVirtual=$true;  Sockets=1; PhysicalCores=4;  SqlInstances=@(); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='app02'; Reachable=$true; OSCaption='Microsoft Windows Server 2022 Standard'; IsVirtual=$true;  Sockets=1; PhysicalCores=4;  SqlInstances=@([pscustomobject]@{Instance='MSSQLSERVER';Edition='Standard Edition';Version='16.0'}); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='phys01';Reachable=$true; OSCaption='Microsoft Windows Server 2019 Standard'; IsVirtual=$false; Sockets=2; PhysicalCores=24; SqlInstances=@(); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='dead01';Reachable=$false;Error='unreachable'; OSCaption=$null; IsVirtual=$null; Sockets=$null; PhysicalCores=$null; SqlInstances=@(); InstalledRoles=@() }
    )
    CalFootprint = [pscustomobject]@{ EnabledUsers=120; EnabledWorkstations=140; EnabledServers=3 }
}
$lic = Get-OVLicensePosition -Dataset $dataset -Licensing @{ StandardPerCore=73.50; DatacenterPerCore=423.19; HasSoftwareAssurance=$true }
Assert-Eq "estate: 2 host positions (esx01 + phys01)" 2 (@($lic.HostPositions).Count)
Assert-Eq "estate: esx01 sees 2 Windows VMs" 2 (($lic.HostPositions | Where-Object HostName -eq 'esx01').WindowsVMCount)
Assert-Eq "estate: 1 SQL instance rolled up" 1 (@($lic.SqlInstances).Count)
Assert-Eq "estate: 1 unreachable warning surfaced (not zero-cored)" $true ([bool](@($lic.Warnings) -match 'dead01'))

# esx01: 32 licensable cores, 2 Windows VMs (4 vCPU each). With SA, per-VM = 2*max(8,4)=16 cores*73.5=1176
# Standard stacked = ceil(2/2)=1 set * 32 cores * 73.5 = 2352. Datacenter = 32*423.19=13542. Per-VM wins.
$esx = $lic.HostPositions | Where-Object HostName -eq 'esx01'
Assert-Eq "esx01 recommends Per-VM (2 small VMs + SA)" 'Per-VM (vCore, SA)' $esx.RecommendedModel
Assert-Eq "esx01 per-VM cost = 1176" 1176 $esx.EstimatedCost

Write-Host "`n== PreferDatacenterAtVMCount (operational-simplicity override) ==" -ForegroundColor Cyan
# 16-core host, 3 small VMs + SA: cheapest is Per-VM. With threshold 3 -> flip to Datacenter.
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms3 -Pricing $pricing -HasSA $true -PreferDatacenterAtVMs 3
Assert-Eq   "threshold met -> Recommended is Datacenter"     'Datacenter (all cores)' $p.RecommendedModel
Assert-Eq   "threshold met -> Cheapest still Per-VM"          'Per-VM (vCore, SA)'     $p.CheapestModel
Assert-Eq   "threshold met -> PreferenceApplied true"         $true                    $p.PreferenceApplied
Assert-Near "threshold met -> premium = DC(6771.04) - PerVM(1764)" 5007.04 $p.OperationalPremium 0.10

# Threshold NOT met (3 VMs < 5) -> stays cheapest.
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms3 -Pricing $pricing -HasSA $true -PreferDatacenterAtVMs 5
Assert-Eq   "threshold not met -> stays Per-VM"      'Per-VM (vCore, SA)' $p.RecommendedModel
Assert-Eq   "threshold not met -> PreferenceApplied false" $false          $p.PreferenceApplied
Assert-Eq   "threshold not met -> premium 0"          0                    $p.OperationalPremium

# Default (0) leaves the cheapest pick untouched.
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms3 -Pricing $pricing -HasSA $true -PreferDatacenterAtVMs 0
Assert-Eq   "preference disabled -> Per-VM"          'Per-VM (vCore, SA)' $p.RecommendedModel

# Compliance force takes precedence and does not double-count as a 'preference'.
$p = Get-OVHostLicensePosition -HostInfo $h16 -WindowsVMs $vms3 -Pricing $pricing -HasSA $true -ForceDatacenter:$true -ForceReasons @('S2D') -PreferDatacenterAtVMs 3
Assert-Eq   "forced + threshold -> Datacenter"       'Datacenter (all cores)' $p.RecommendedModel
Assert-Eq   "forced -> PreferenceApplied false (compliance, not preference)" $false $p.PreferenceApplied
Assert-Eq   "forced -> premium 0"                    0 $p.OperationalPremium

# Estate rollup reports the preference count and total premium.
$lic3 = Get-OVLicensePosition -Dataset $dataset -Licensing @{ StandardPerCore=73.50; DatacenterPerCore=423.19; HasSoftwareAssurance=$true; PreferDatacenterAtVMCount=2 }
$esxFlip = $lic3.HostPositions | Where-Object HostName -eq 'esx01'
Assert-Eq   "estate: esx01 (2 VMs) flipped to Datacenter" 'Datacenter (all cores)' $esxFlip.RecommendedModel
Assert-Eq   "estate: PreferenceHostCount = 1"             1     $lic3.PreferenceHostCount
Assert-Eq   "estate: OperationalPremiumTotal > 0"         $true ($lic3.OperationalPremiumTotal -gt 0)

Write-Host "`n== Nutanix AHV (Prism v2.0 response shaping) ==" -ForegroundColor Cyan
Import-Module (Join-Path $root 'src/OVAudit.Sources.psm1') -Force
$prismHosts = @(
    [pscustomobject]@{ uuid='u1'; name='ahv-01'; num_cpu_sockets=2; num_cpu_cores=24; num_cpu_threads=48; cpu_model='Xeon Gold'; block_model_name='NX-3060' }
    [pscustomobject]@{ uuid='u2'; name='ahv-02'; num_cpu_sockets=2; num_cpu_cores=32; num_cpu_threads=64; cpu_model='Xeon Gold'; block_model_name='NX-3060' }
)
$prismVMs = @(
    [pscustomobject]@{ name='WIN-APP'; num_vcpus=2; num_cores_per_vcpu=4; host_uuid='u1'; power_state='on' }   # 2x4 = 8 vCPU
    [pscustomobject]@{ name='WIN-DB';  num_vcpus=4; num_cores_per_vcpu=2; host_uuid='u2'; power_state='on' }   # 4x2 = 8 vCPU
    [pscustomobject]@{ name='OFFLINE'; num_vcpus=1; num_cores_per_vcpu=1; host_uuid=$null; power_state='off' } # no host
)
$ntx = ConvertFrom-OVPrismData -HostEntities $prismHosts -VmEntities $prismVMs -ClusterName 'Cluster-A'
Assert-Eq "AHV: 2 hosts shaped"                 2        (@($ntx.Hosts).Count)
Assert-Eq "AHV: ahv-01 physical cores = 24"     24       (($ntx.Hosts | Where-Object HostName -eq 'ahv-01').PhysicalCores)
Assert-Eq "AHV: cluster name carried"           'Cluster-A' (($ntx.Hosts | Where-Object HostName -eq 'ahv-01').Cluster)
Assert-Eq "AHV: WIN-APP vCPU = num_vcpus x cores_per_vcpu = 8" 8 (($ntx.VMs | Where-Object VMName -eq 'WIN-APP').vCPU)
Assert-Eq "AHV: WIN-APP mapped to host ahv-01"  'ahv-01' (($ntx.VMs | Where-Object VMName -eq 'WIN-APP').HostName)
Assert-Eq "AHV: powered-off VM has null host"   $true    ($null -eq (($ntx.VMs | Where-Object VMName -eq 'OFFLINE').HostName))

# AHV hosts flow through the (hypervisor-agnostic) engine and get licensed.
$dsN = [ordered]@{
    GeneratedAt='2026-06-12T00:00:00'; Hosts=$ntx.Hosts; VMMap=$ntx.VMs; AdServers=@(); CalFootprint=$null
    Servers=@(
        [pscustomobject]@{ ComputerName='WIN-APP'; Reachable=$true; OSCaption='Microsoft Windows Server 2022 Standard';   IsVirtual=$true; Sockets=1; PhysicalCores=8; SqlInstances=@(); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='WIN-DB';  Reachable=$true; OSCaption='Microsoft Windows Server 2022 Datacenter'; IsVirtual=$true; Sockets=1; PhysicalCores=8; SqlInstances=@(); InstalledRoles=@() }
    )
}
$licN = Get-OVLicensePosition -Dataset $dsN -Licensing @{ StandardPerCore=73.50; DatacenterPerCore=423.19; HasSoftwareAssurance=$true }
Assert-Eq "AHV estate: 2 host positions"        2  (@($licN.HostPositions).Count)
Assert-Eq "AHV estate: ahv-01 sees 1 Windows VM" 1 (($licN.HostPositions | Where-Object HostName -eq 'ahv-01').WindowsVMCount)
Assert-Eq "AHV estate: ahv-02 licensed on 32 cores" 32 (($licN.HostPositions | Where-Object HostName -eq 'ahv-02').PhysicalCores)

Write-Host "`n== Nutanix NGT guest-OS classification ==" -ForegroundColor Cyan
$ngtVMs = @(
    [pscustomobject]@{ name='SRV-NGT'; num_vcpus=4; num_cores_per_vcpu=1; host_uuid='u1'; power_state='on'; nutanix_guest_tools=[pscustomobject]@{ guest_os_version='Microsoft Windows Server 2022 Datacenter' } }
    [pscustomobject]@{ name='VDI-NGT'; num_vcpus=2; num_cores_per_vcpu=1; host_uuid='u1'; power_state='on'; nutanix_guest_tools=[pscustomobject]@{ guest_os_version='Microsoft Windows 11 Enterprise' } }
    [pscustomobject]@{ name='LNX-NGT'; num_vcpus=2; num_cores_per_vcpu=1; host_uuid='u1'; power_state='on'; nutanix_guest_tools=[pscustomobject]@{ guest_os_version='CentOS Linux 7' } }
    [pscustomobject]@{ name='NO-NGT';  num_vcpus=2; num_cores_per_vcpu=1; host_uuid='u1'; power_state='on' }   # NGT not installed
)
$ngtShaped = ConvertFrom-OVPrismData -HostEntities $prismHosts -VmEntities $ngtVMs -ClusterName 'C'
Assert-Eq "NGT: Windows Server VM -> IsWindowsServer true"  $true  (($ngtShaped.VMs | Where-Object VMName -eq 'SRV-NGT').IsWindowsServer)
Assert-Eq "NGT: Win11 VDI -> IsWindowsServer false"         $false (($ngtShaped.VMs | Where-Object VMName -eq 'VDI-NGT').IsWindowsServer)
Assert-Eq "NGT: Linux -> IsWindowsServer false"             $false (($ngtShaped.VMs | Where-Object VMName -eq 'LNX-NGT').IsWindowsServer)
Assert-Eq "NGT: absent -> IsWindowsServer null (AD classifies)" $true ($null -eq (($ngtShaped.VMs | Where-Object VMName -eq 'NO-NGT').IsWindowsServer))
Assert-Eq "NGT: guest OS string captured"                   'Microsoft Windows Server 2022 Datacenter' (($ngtShaped.VMs | Where-Object VMName -eq 'SRV-NGT').GuestOS)

Write-Host "`n== SCCM backfill: unreachable server with backfilled cores is still licensed ==" -ForegroundColor Cyan
$ds2 = [ordered]@{
    GeneratedAt = '2026-06-12T00:00:00'; Hosts = @(); VMMap = @(); AdServers = @(); CalFootprint = $null
    Servers = @(
        [pscustomobject]@{ ComputerName='offline01'; Reachable=$false; DataSource='SCCM (last inventory)'; OSCaption='Microsoft Windows Server 2022 Standard'; IsVirtual=$false; Sockets=2; PhysicalCores=24; LogicalProcs=48; SqlInstances=@(); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='nodata01';  Reachable=$false; DataSource=$null; OSCaption=$null; IsVirtual=$null; Sockets=$null; PhysicalCores=$null; SqlInstances=@(); InstalledRoles=@() }
    )
}
$lic2 = Get-OVLicensePosition -Dataset $ds2 -Licensing @{ StandardPerCore=73.50; DatacenterPerCore=423.19; HasSoftwareAssurance=$true }
Assert-Eq "backfilled offline01 IS licensed (1 host position)" 1 (@($lic2.HostPositions).Count)
Assert-Eq "offline01 position uses its 24 cores" 24 (($lic2.HostPositions | Where-Object HostName -eq 'offline01').PhysicalCores)
Assert-Eq "nodata01 surfaced as warning, not zero-cored" $true ([bool](@($lic2.Warnings) -match 'nodata01'))

Write-Host "`n== Executive summary generation (HTML + Word .doc; PDF best-effort) ==" -ForegroundColor Cyan
Import-Module (Join-Path $root 'src/OVAudit.ExecSummary.psm1') -Force
$dataset.LicensePosition = $lic   # reuse the synthetic estate from above
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ovtest_' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
$res = Export-OVExecutiveSummary -Dataset $dataset -OutputPath $tmp -CustomerName 'Contoso Ltd' -PreparedBy 'US Signal' 3>$null
Assert-Eq   "exec summary HTML created"            $true (Test-Path $res.Html)
Assert-Eq   "exec summary Word .doc created"        $true (Test-Path $res.Doc)
Assert-Eq   "baseline (all-Datacenter) >= recommended" $true ($res.BaselineDatacenterCost -ge $res.RecommendedCost)
Assert-Eq   "estimated savings is non-negative"     $true ($res.EstimatedSavings -ge 0)
$docText = Get-Content $res.Doc -Raw
Assert-Eq   "deliverable contains no double-hyphens" $true (-not ($docText -match '--'))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n== Merge-OVDiscoveryTargets (reconcile AD + hypervisor + SCCM, flag non-AD) ==" -ForegroundColor Cyan
$adSrv = @(
    [pscustomobject]@{ DNSHostName='SRV01.contoso.com'; Name='SRV01' }
    [pscustomobject]@{ DNSHostName=$null;               Name='SRV02' }   # short name only
)
$hvVMs = @(
    [pscustomobject]@{ GuestHostName='srv01.contoso.com'; VMName='SRV01-vm'; Hypervisor='VMware' }       # merges into SRV01
    [pscustomobject]@{ GuestHostName='srv02.contoso.com'; VMName='SRV02';    Hypervisor='VMware' }        # upgrades SRV02 to FQDN
    [pscustomobject]@{ VMName='SHADOW01'; Hypervisor='Hyper-V' }                                          # no GuestHostName prop; NOT in AD
)
$sccmSrv = @([pscustomobject]@{ ComputerName='DMZ01' })   # SCCM-only, not in AD
$disc = Merge-OVDiscoveryTargets -AdServers $adSrv -HypervisorVMs $hvVMs -SccmServers $sccmSrv
Assert-Eq "discovery: 4 distinct targets" 4 (@($disc).Count)
$srv01 = $disc | Where-Object Short -eq 'srv01'
Assert-Eq "SRV01 is InAD"                 $true  $srv01.InAD
Assert-Eq "SRV01 merged AD + hypervisor"  $true  ($srv01.Sources.Contains('AD') -and $srv01.Sources.Contains('Hypervisor:VMware'))
$srv02 = $disc | Where-Object Short -eq 'srv02'
Assert-Eq "SRV02 name upgraded to FQDN"   'srv02.contoso.com' $srv02.Name
$shadow = $disc | Where-Object Short -eq 'shadow01'
Assert-Eq "SHADOW01 found, NOT in AD"     $false $shadow.InAD
Assert-Eq "SHADOW01 source is hypervisor only" 'Hypervisor:Hyper-V' ($shadow.Sources -join ';')
$dmz = $disc | Where-Object Short -eq 'dmz01'
Assert-Eq "DMZ01 (SCCM-only) not in AD"   $false $dmz.InAD

Write-Host "`n== ConvertFrom-OVAzureGraph (Arc + Azure VM shaping) ==" -ForegroundColor Cyan
$arcRows = @(
    [pscustomobject]@{ name='arc-sql01'; computerName='ARC-SQL01'; osSku='Windows Server 2019 Datacenter'; osName='Windows Server 2019 Datacenter'; domain='corp.local'; logicalCores=32; coreCount=16; cloud='AWS'; location='us-east-1'; resourceGroup='rg-arc'; subscriptionId='sub1'; status='Connected' }
    [pscustomobject]@{ name='arc-noname'; osName='Windows Server 2022 Standard'; logicalCores=8; coreCount=4; cloud='vmware'; location='onprem'; resourceGroup='rg-arc'; subscriptionId='sub1'; status='Connected' }  # no computerName -> falls back to name
)
$vmRows = @(
    [pscustomobject]@{ name='azvm-web01'; vmSize='Standard_D4s_v5'; osType='Windows'; licenseType='Windows_Server'; location='eastus'; resourceGroup='rg-vm'; subscriptionId='sub1' }
)
$az = ConvertFrom-OVAzureGraph -ArcRows $arcRows -VmRows $vmRows
Assert-Eq "Azure: 3 records shaped"          3 (@($az).Count)
$sql = $az | Where-Object Name -eq 'arc-sql01'
Assert-Eq "Arc: Source = Azure Arc"          'Azure Arc' $sql.Source
Assert-Eq "Arc: physical cores from coreCount" 16 $sql.PhysicalCores
Assert-Eq "Arc: cloud carried (AWS)"         'AWS' $sql.Cloud
$noname = $az | Where-Object Name -eq 'arc-noname'
Assert-Eq "Arc: ComputerName falls back to name when computerName missing" 'arc-noname' $noname.ComputerName
$vm = $az | Where-Object Name -eq 'azvm-web01'
Assert-Eq "Azure VM: Source = Azure VM"      'Azure VM' $vm.Source
Assert-Eq "Azure VM: vmSize carried"         'Standard_D4s_v5' $vm.VmSize
Assert-Eq "Azure VM: AHB licenseType carried" 'Windows_Server' $vm.LicenseType
Assert-Eq "Azure VM: PhysicalCores null (vCPU/AHB-based)" $true ($null -eq $vm.PhysicalCores)

Write-Host "`n== Empty estate (nothing reachable) degrades gracefully, no crash ==" -ForegroundColor Cyan
$dsEmpty = [ordered]@{
    GeneratedAt='2026-06-16T00:00:00'; Hosts=@(); VMMap=@(); AdServers=@(); CalFootprint=$null
    Servers=@(
        [pscustomobject]@{ ComputerName='unreach1'; Reachable=$false; DataSource=$null; OSCaption=$null; IsVirtual=$null; Sockets=$null; PhysicalCores=$null; SqlInstances=@(); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='unreach2'; Reachable=$false; DataSource=$null; OSCaption=$null; IsVirtual=$null; Sockets=$null; PhysicalCores=$null; SqlInstances=@(); InstalledRoles=@() }
    )
}
$licEmpty = Get-OVLicensePosition -Dataset $dsEmpty -Licensing @{ StandardPerCore=73.50; DatacenterPerCore=423.19; HasSoftwareAssurance=$true }
Assert-Eq "empty: 0 host positions"           0     (@($licEmpty.HostPositions).Count)
Assert-Eq "empty: total cost = 0 (no crash)"  0     $licEmpty.EstimatedTotalCost
Assert-Eq "empty: warns 'No hosts could be assessed'" $true ([bool](@($licEmpty.Warnings) -match 'No hosts could be assessed'))
$dsEmpty.LicensePosition = $licEmpty
$tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('ovempty_' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
$resEmpty = Export-OVExecutiveSummary -Dataset $dsEmpty -OutputPath $tmp2 -CustomerName 'Empty Co' -PreparedBy 'US Signal' 3>$null
Assert-Eq "empty: exec summary still produced (no crash)" $true (Test-Path $resEmpty.Html)
Assert-Eq "empty: recommended cost 0"         0     $resEmpty.RecommendedCost
Remove-Item $tmp2 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n== AD classifies VMs as Windows Server when CIM is unreachable (Citrix/Nutanix case) ==" -ForegroundColor Cyan
$dsAd = [ordered]@{
    GeneratedAt='2026-06-17T00:00:00'; CalFootprint=$null
    Hosts = @([pscustomobject]@{ HostName='ahv1'; Hypervisor='Nutanix AHV'; Cluster='C1'; Sockets=2; PhysicalCores=32; LogicalProcs=64 })
    VMMap = @(
        [pscustomobject]@{ Hypervisor='Nutanix AHV'; VMName='D1-DC-1';     HostName='ahv1'; GuestHostName='D1-DC-1';     GuestOS=$null; vCPU=4; IsWindowsServer=$null }
        [pscustomobject]@{ Hypervisor='Nutanix AHV'; VMName='WIN11-VDI-1'; HostName='ahv1'; GuestHostName='WIN11-VDI-1'; GuestOS=$null; vCPU=2; IsWindowsServer=$null }
    )
    AdServers = @(
        [pscustomobject]@{ Name='D1-DC-1';     OS='Windows Server 2022 Datacenter' }
        [pscustomobject]@{ Name='WIN11-VDI-1'; OS='Windows 11 Enterprise' }
    )
    Servers = @(   # both unreachable over CIM (blank OS caption) -> must not be read as "not Windows"
        [pscustomobject]@{ ComputerName='D1-DC-1';     Reachable=$false; OSCaption=$null; IsVirtual=$true; Sockets=$null; PhysicalCores=$null; SqlInstances=@(); InstalledRoles=@() }
        [pscustomobject]@{ ComputerName='WIN11-VDI-1'; Reachable=$false; OSCaption=$null; IsVirtual=$true; Sockets=$null; PhysicalCores=$null; SqlInstances=@(); InstalledRoles=@() }
    )
}
$licAd = Get-OVLicensePosition -Dataset $dsAd -Licensing @{ StandardPerCore=73.50; DatacenterPerCore=423.19; HasSoftwareAssurance=$true }
$ahv1 = $licAd.HostPositions | Where-Object HostName -eq 'ahv1'
Assert-Eq "AD-class: server VM counted as Windows (no CIM)" 1 $ahv1.WindowsVMCount
Assert-Eq "AD-class: Win11 VDI excluded from Windows count"  1 $ahv1.WindowsVMCount  # still 1, not 2
Assert-Eq "AD-class: total VMs on host surfaced = 2"         2 $ahv1.TotalVMCount

Write-Host "`n== Import-OVLocalDrop (local-collector JSON ingest) ==" -ForegroundColor Cyan
$ldDir = Join-Path ([IO.Path]::GetTempPath()) ('ovld_' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $ldDir -Force | Out-Null
([pscustomobject]@{ ComputerName='LD-SRV1'; Reachable=$true; DataSource='Local collector'; OSCaption='Microsoft Windows Server 2022 Standard'; Edition='Standard'; Sockets=2; PhysicalCores=24; IsVirtual=$false; SqlInstances=@([pscustomobject]@{ Instance='MSSQLSERVER'; Edition='Standard Edition' }); InstalledRoles=@('FileAndStorage-Services') }) |
    ConvertTo-Json -Depth 6 | Out-File (Join-Path $ldDir 'LD-SRV1.json') -Encoding UTF8
'{ not valid json' | Out-File (Join-Path $ldDir 'broken.json') -Encoding UTF8
$ld = Import-OVLocalDrop -Path $ldDir 3>$null
Assert-Eq "LocalDrop: 1 valid record (malformed file skipped)" 1 (@($ld).Count)
Assert-Eq "LocalDrop: ComputerName read"   'LD-SRV1' (($ld | Select-Object -First 1).ComputerName)
Assert-Eq "LocalDrop: physical cores read" 24        (($ld | Select-Object -First 1).PhysicalCores)
Assert-Eq "LocalDrop: SQL instance carried" 'MSSQLSERVER' (($ld | Select-Object -First 1).SqlInstances[0].Instance)
Remove-Item $ldDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n== Hyper-V VM record (no GuestHostName property) does not crash StrictMode ==" -ForegroundColor Cyan
$dsHv = [ordered]@{
    GeneratedAt='2026-06-18T00:00:00'; CalFootprint=$null; AdServers=@()
    Hosts = @([pscustomobject]@{ HostName='hv01'; Hypervisor='Hyper-V'; Cluster=$null; Sockets=2; PhysicalCores=16; LogicalProcs=32 })
    VMMap = @([pscustomobject]@{ Hypervisor='Hyper-V'; VMName='HVWIN1'; HostName='hv01'; GuestOS='Windows Server 2022'; PowerState='Running'; vCPU=4; IsWindowsServer=$null })  # NO GuestHostName, like real Hyper-V
    Servers = @()
}
$licHv = Get-OVLicensePosition -Dataset $dsHv -Licensing @{ HasSoftwareAssurance=$true }
Assert-Eq "Hyper-V no-GuestHostName: no crash, classified via GuestOS" 1 (($licHv.HostPositions | Where-Object HostName -eq 'hv01').WindowsVMCount)

Write-Host "`n== Tri-state: undetermined VM excluded + warned (not silently dropped) ==" -ForegroundColor Cyan
$dsUnk = [ordered]@{
    GeneratedAt='2026-06-18T00:00:00'; CalFootprint=$null; AdServers=@()
    Hosts = @([pscustomobject]@{ HostName='ahvU'; Hypervisor='Nutanix AHV'; Cluster='C'; Sockets=2; PhysicalCores=16; LogicalProcs=32 })
    VMMap = @([pscustomobject]@{ Hypervisor='Nutanix AHV'; VMName='MYST1'; HostName='ahvU'; GuestHostName='MYST1'; GuestOS=$null; PowerState='on'; vCPU=4; IsWindowsServer=$null })
    Servers = @()
}
$licUnk = Get-OVLicensePosition -Dataset $dsUnk -Licensing @{ HasSoftwareAssurance=$true }
$hu = $licUnk.HostPositions | Where-Object HostName -eq 'ahvU'
Assert-Eq "Unknown VM excluded from Windows count"  0 $hu.WindowsVMCount
Assert-Eq "Unknown VM surfaced in UnknownVMCount"   1 $hu.UnknownVMCount
Assert-Eq "Unknown VM raises a warning"             $true ([bool](@($licUnk.Warnings) -match 'could not be classified'))
Assert-Eq "estate UnknownVMCount rolled up"         1 $licUnk.UnknownVMCount
$licAW = Get-OVLicensePosition -Dataset $dsUnk -Licensing @{ HasSoftwareAssurance=$true; UnknownVmTreatment='AssumeWindows' }
Assert-Eq "AssumeWindows counts the unknown VM"     1 (($licAW.HostPositions | Where-Object HostName -eq 'ahvU').WindowsVMCount)

Write-Host "`n== Zero-Windows-VM hypervisor host is not charged a phantom Standard set ==" -ForegroundColor Cyan
$dsZero = [ordered]@{
    GeneratedAt='2026-06-18T00:00:00'; CalFootprint=$null; AdServers=@()
    Hosts = @([pscustomobject]@{ HostName='esxZ'; Hypervisor='VMware'; Cluster='C'; Sockets=2; PhysicalCores=64; LogicalProcs=128 })
    VMMap = @([pscustomobject]@{ Hypervisor='VMware'; VMName='lnx1'; HostName='esxZ'; GuestHostName='lnx1'; GuestOS='Ubuntu'; PowerState='on'; vCPU=2; IsWindowsServer=$false })
    Servers = @()
}
$hz = (Get-OVLicensePosition -Dataset $dsZero -Licensing @{ HasSoftwareAssurance=$true }).HostPositions | Where-Object HostName -eq 'esxZ'
Assert-Eq "zero-Windows host costs 0 (no phantom set)" 0 $hz.EstimatedCost
Assert-Eq "zero-Windows host model = None"             'None (no Windows VMs)' $hz.RecommendedModel

Write-Host "`n== Windows VM with null host is surfaced, never silently dropped ==" -ForegroundColor Cyan
$dsNull = [ordered]@{
    GeneratedAt='2026-06-18T00:00:00'; CalFootprint=$null; AdServers=@()
    Hosts = @([pscustomobject]@{ HostName='ahvN'; Hypervisor='Nutanix AHV'; Cluster='C'; Sockets=2; PhysicalCores=16; LogicalProcs=32 })
    VMMap = @([pscustomobject]@{ Hypervisor='Nutanix AHV'; VMName='OFFWIN'; HostName=$null; GuestHostName='OFFWIN'; GuestOS='Windows Server 2019'; PowerState='off'; vCPU=4; IsWindowsServer=$true })
    Servers = @()
}
$licNull = Get-OVLicensePosition -Dataset $dsNull -Licensing @{ HasSoftwareAssurance=$true }
Assert-Eq "null-host Windows VM surfaced as unmapped" 1 $licNull.UnmappedWindowsVMCount
Assert-Eq "null-host VM raises a warning"             $true ([bool](@($licNull.Warnings) -match 'not mapped to an assessed host'))

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }
