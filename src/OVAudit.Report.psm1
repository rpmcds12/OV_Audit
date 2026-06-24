#requires -Version 5.1
<#
    OVAudit.Report.psm1
    Renders the audit dataset to a shareable report.
    Prefers the ImportExcel module for a multi-sheet .xlsx; if it isn't
    installed, falls back to a self-contained styled HTML report (no Excel,
    no external dependency) plus the CSVs the orchestrator already wrote.
#>

Set-StrictMode -Version Latest

function Get-OVUnionColumns {
    # Union of all property names across a heterogeneous collection, so a mixed
    # VMware + Hyper-V + Nutanix set does not lose columns to the first-object
    # header (Export-Excel / ConvertTo-* take columns from the first object only).
    param([object[]] $Items)
    $cols = [System.Collections.Generic.List[string]]::new()
    foreach ($i in @($Items)) {
        foreach ($p in $i.PSObject.Properties.Name) { if (-not $cols.Contains($p)) { $cols.Add($p) | Out-Null } }
    }
    return @($cols)
}

function Export-OVReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Dataset,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $lp = $Dataset.LicensePosition
    if (-not $lp) { Write-Warning "No LicensePosition in dataset — skipping report."; return }

    # Flatten host positions for tabular output (drop nested Options object).
    $hostRows = $lp.HostPositions | Select-Object HostName, Hypervisor, Cluster, Sockets,
        PhysicalCores, LicensableCores, TotalVMCount, WindowsVMCount, UnknownVMCount, RecommendedModel,
        RecommendedCores, RecommendedPacks, EstimatedCost, CheapestModel, CheapestCost,
        PreferenceApplied, OperationalPremium, ForceDatacenter, ForceReasons, BreakEvenVMs

    $serverRows = $Dataset.Servers | Select-Object ComputerName, Reachable, Protocol, OSCaption,
        Edition, OSVersion, OSBuild, Sockets, PhysicalCores, LogicalProcs, IsVirtual, Hypervisor,
        PhysicalHost, Manufacturer, Model, Error

    # Currency label drives the report symbols (engine stamps it onto Pricing).
    $cur = if ($lp.Pricing -is [hashtable] -and $lp.Pricing.ContainsKey('Currency')) { $lp.Pricing.Currency } else { 'USD' }

    # SQL / Windows Server instance counts are CIM-only; show "Not measured" when
    # no per-server detail was captured rather than a misleading 0.
    $scannedWithOs  = @($Dataset.Servers | Where-Object { $_.OSCaption }).Count
    $detailMeasured = $scannedWithOs -gt 0
    $sqlValue    = if ($detailMeasured) { @($lp.SqlInstances).Count } else { 'Not measured (no servers reached)' }
    $winSrvValue = if ($detailMeasured) { @($Dataset.Servers | Where-Object { $_.OSCaption -match 'Windows.*Server' }).Count } else { 'Not measured (no servers reached)' }
    $winVmValue  = if (@($lp.HostPositions).Count) { $s = (@($lp.HostPositions) | Measure-Object WindowsVMCount -Sum).Sum; if ($null -eq $s) { 0 } else { $s } } else { 0 }
    $clientVdiValue = if ($lp.PSObject.Properties['ClientVdiVMCount']) { [int]$lp.ClientVdiVMCount } else { 0 }

    $summaryRows = @(
        [pscustomobject]@{ Metric = 'Generated';                          Value = $lp.GeneratedAt }
        [pscustomobject]@{ Metric = 'Software Assurance';                 Value = $lp.SoftwareAssurance }
        [pscustomobject]@{ Metric = "Standard per core (assumed, $cur)";   Value = $lp.Pricing.StandardPerCore }
        [pscustomobject]@{ Metric = "Datacenter per core (assumed, $cur)"; Value = $lp.Pricing.DatacenterPerCore }
        [pscustomobject]@{ Metric = 'Hosts assessed';                     Value = @($lp.HostPositions).Count }
        [pscustomobject]@{ Metric = 'Windows VMs (counted)';              Value = $winVmValue }
        [pscustomobject]@{ Metric = 'Windows Server instances (scanned)'; Value = $winSrvValue }
        [pscustomobject]@{ Metric = 'Windows client / VDI VMs (excluded from Server cores)'; Value = $clientVdiValue }
        [pscustomobject]@{ Metric = 'Estimated total cost';               Value = $lp.EstimatedTotalCost }
        [pscustomobject]@{ Metric = 'SQL instances found';                Value = $sqlValue }
        [pscustomobject]@{ Metric = 'Warnings';                           Value = @($lp.Warnings).Count }
    )

    $xlsx = Join-Path $OutputPath 'OV-Audit-Report.xlsx'
    $haveImportExcel = Get-Module -ListAvailable -Name ImportExcel -ErrorAction SilentlyContinue

    if ($haveImportExcel) {
        Import-Module ImportExcel -ErrorAction Stop
        if (Test-Path $xlsx) { Remove-Item $xlsx -Force }
        $common = @{ Path = $xlsx; AutoSize = $true; FreezeTopRow = $true; BoldTopRow = $true }
        $summaryRows         | Export-Excel @common -WorksheetName 'Summary'
        $lp.SummaryByModel   | Export-Excel @common -WorksheetName 'By Model'
        $hostRows            | Export-Excel @common -WorksheetName 'Host Positions'
        $serverRows          | Export-Excel @common -WorksheetName 'Servers'
        $hostCols = Get-OVUnionColumns @($Dataset.Hosts)
        if ($hostCols.Count) { @($Dataset.Hosts) | Select-Object $hostCols | Export-Excel @common -WorksheetName 'Hypervisor Hosts' }
        else { @($Dataset.Hosts) | Export-Excel @common -WorksheetName 'Hypervisor Hosts' }
        $vmCols = Get-OVUnionColumns @($Dataset.VMMap)
        if ($vmCols.Count) { @($Dataset.VMMap) | Select-Object $vmCols | Export-Excel @common -WorksheetName 'VM Map' }
        else { @($Dataset.VMMap) | Export-Excel @common -WorksheetName 'VM Map' }
        @($lp.SqlInstances)  | Export-Excel @common -WorksheetName 'SQL'
        if ($lp.CalFootprint) { @($lp.CalFootprint) | Export-Excel @common -WorksheetName 'CALs' }
        @($lp.Warnings | ForEach-Object { [pscustomobject]@{ Warning = $_ } }) |
            Export-Excel @common -WorksheetName 'Warnings'
        Write-Host "[OV-Audit] Excel report: $xlsx" -ForegroundColor Green
    }
    else {
        Write-Warning "ImportExcel not installed (Install-Module ImportExcel) — writing HTML report instead."
        Export-OVHtmlReport -Dataset $Dataset -SummaryRows $summaryRows -HostRows $hostRows `
            -ServerRows $serverRows -OutputPath $OutputPath
    }
}

function Export-OVHtmlReport {
    param($Dataset, $SummaryRows, $HostRows, $ServerRows, [string] $OutputPath)

    $lp = $Dataset.LicensePosition
    $cur = if ($lp.Pricing -is [hashtable] -and $lp.Pricing.ContainsKey('Currency')) { $lp.Pricing.Currency } else { 'USD' }
    $sym = if ($cur -eq 'USD') { '$' } else { "$cur " }
    $detailMeasured = @($Dataset.Servers | Where-Object { $_.OSCaption }).Count -gt 0
    $sqlKpi = if ($detailMeasured) { "$(@($lp.SqlInstances).Count)" } else { 'Not measured' }
    $css = @'
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b}
 h1{color:#0a3d62} h2{color:#0a3d62;border-bottom:2px solid #dfe6e9;padding-bottom:4px;margin-top:32px}
 table{border-collapse:collapse;width:100%;margin:8px 0;font-size:13px}
 th{background:#0a3d62;color:#fff;text-align:left;padding:6px 8px}
 td{border:1px solid #dfe6e9;padding:6px 8px}
 tr:nth-child(even){background:#f5f7fa}
 .warn{background:#fff3cd;border:1px solid #ffe69c;padding:8px 12px;border-radius:6px;margin:4px 0}
 .kpi{display:inline-block;background:#0a3d62;color:#fff;padding:12px 18px;border-radius:8px;margin:6px;min-width:140px}
 .kpi b{display:block;font-size:22px}
</style>
'@
    $totalCost = "{0:N0}" -f $lp.EstimatedTotalCost
    $kpis = @"
<div>
 <div class='kpi'>Hosts assessed<b>$(@($lp.HostPositions).Count)</b></div>
 <div class='kpi'>Est. total cost<b>$sym$totalCost</b></div>
 <div class='kpi'>SQL instances<b>$sqlKpi</b></div>
 <div class='kpi'>Warnings<b>$(@($lp.Warnings).Count)</b></div>
</div>
"@
    $warnHtml = ($lp.Warnings | ForEach-Object { "<div class='warn'>&#9888; $([System.Web.HttpUtility]::HtmlEncode($_))</div>" }) -join "`n"
    if (-not $warnHtml) { $warnHtml = '<p>None.</p>' }

    $frag = {
        param($title, $data)
        if (-not $data) { return "<h2>$title</h2><p>No data.</p>" }
        "<h2>$title</h2>" + ($data | ConvertTo-Html -Fragment)
    }

    $html = @"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>OV-Audit — Windows Server License Position</title>$css</head><body>
<h1>OV-Audit &mdash; Windows Server License Position</h1>
<p>Generated $($lp.GeneratedAt) &middot; Software Assurance assumed: <b>$($lp.SoftwareAssurance)</b> &middot;
Pricing: Standard $sym$($lp.Pricing.StandardPerCore)/core, Datacenter $sym$($lp.Pricing.DatacenterPerCore)/core (override with actual Open Value pricing).</p>
$kpis
$(& $frag 'Recommended position by edition' $lp.SummaryByModel)
$(& $frag 'Per-host cheapest-compliant position' $HostRows)
$(& $frag 'SQL Server instances' $lp.SqlInstances)
$(if ($lp.CalFootprint) { & $frag 'CAL footprint' @($lp.CalFootprint) })
$(& $frag 'Full server inventory' $ServerRows)
<h2>Warnings &amp; gaps</h2>
$warnHtml
<hr><p style='color:#888;font-size:12px'>Estimates use assumed list pricing and are not a quote. Validate against the customer's live Microsoft Product Terms at quote time. Read-only audit; no environment changes were made.</p>
</body></html>
"@
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $out = Join-Path $OutputPath 'OV-Audit-Report.html'
    $html | Out-File -FilePath $out -Encoding UTF8
    Write-Host "[OV-Audit] HTML report: $out" -ForegroundColor Green
}

Export-ModuleMember -Function Export-OVReport
