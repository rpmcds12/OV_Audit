#requires -Version 5.1
<#
    OVAudit.ExecSummary.psm1
    Generates a customer-facing executive summary from the audit dataset:
      • OV-Audit-Executive-Summary.html  (print-ready, always)
      • OV-Audit-Executive-Summary.pdf   (via headless Edge/Chrome if present)
      • OV-Audit-Executive-Summary.doc    (Word-openable, editable, no Office needed)

    Prose is plain business English by design (no marketing filler, no double
    hyphens) so it can go to a customer with minimal editing.
#>

Set-StrictMode -Version Latest

function Format-OVMoney {
    param($Value, [string] $Currency = 'USD')
    $sym = if ($Currency -eq 'USD') { '$' } else { '' }
    return ('{0}{1:N0}' -f $sym, [double]$Value)
}

function Get-OVPlural {
    # Pick the grammatically correct phrase for a count (keeps customer prose clean).
    param([int] $Count, [string] $Singular, [string] $Plural)
    if ($Count -eq 1) { $Singular } else { $Plural }
}

function ConvertTo-OVPdf {
    <# Render an HTML file to PDF using headless Edge or Chrome. Returns $true on success. #>
    param([string] $HtmlPath, [string] $PdfPath)
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    $exe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $exe) { return $false }
    $uri = ([System.Uri](Resolve-Path $HtmlPath).Path).AbsoluteUri
    $procArgs = @('--headless', '--disable-gpu', '--no-pdf-header-footer',
                  "--print-to-pdf=$PdfPath", $uri)
    try {
        Start-Process -FilePath $exe -ArgumentList $procArgs -Wait -NoNewWindow -ErrorAction Stop
        return (Test-Path $PdfPath)
    } catch { return $false }
}

function Export-OVExecutiveSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Dataset,
        [Parameter(Mandatory)] [string] $OutputPath,
        [string] $CustomerName = 'the customer',
        [string] $PreparedBy   = 'US Signal',
        [string] $ReportDate
    )

    $lp = $Dataset.LicensePosition
    if (-not $lp) { Write-Warning "No LicensePosition in dataset; cannot build executive summary."; return }
    if (-not $ReportDate) { $ReportDate = (Get-Date).ToString('MMMM d, yyyy') }
    $cur = if ($lp.Pricing.ContainsKey('Currency')) { $lp.Pricing.Currency } else { 'USD' }

    $hp = @($lp.HostPositions)
    $hostCount   = $hp.Count
    $vmTotal     = ($hp | Measure-Object WindowsVMCount -Sum).Sum
    $physicalCount = @($hp | Where-Object { $_.Hypervisor -eq 'Physical' }).Count
    $recommendedCost = [double]$lp.EstimatedTotalCost
    $recommendedCores = ($hp | Measure-Object RecommendedCores -Sum).Sum

    # Baseline for comparison: Datacenter on every host (the common over-buy).
    $allDcCost = 0.0
    foreach ($p in $hp) {
        $dcOpt = $p.Options | Where-Object { $_.Model -like 'Datacenter*' } | Select-Object -First 1
        if ($dcOpt) { $allDcCost += [double]$dcOpt.Cost }
    }
    $savings = [math]::Max(0, $allDcCost - $recommendedCost)
    $savingsPct = if ($allDcCost -gt 0) { [math]::Round(100 * $savings / $allDcCost, 0) } else { 0 }

    # Model mix.
    $models = $lp.SummaryByModel
    $nPerVm = @($hp | Where-Object { $_.RecommendedModel -like 'Per-VM*' }).Count
    $nStd   = @($hp | Where-Object { $_.RecommendedModel -like 'Standard*' }).Count
    $nDc    = @($hp | Where-Object { $_.RecommendedModel -like 'Datacenter*' }).Count

    # Windows Server instance count + SQL.
    $winServers = @($Dataset.Servers | Where-Object { $_.OSCaption -match 'Windows.*Server' }).Count
    $sqlCount = @($lp.SqlInstances).Count
    # AdServers is optional in the dataset; access it safely under StrictMode.
    $adServers = if ($Dataset -is [System.Collections.IDictionary]) {
        if ($Dataset.Contains('AdServers')) { $Dataset['AdServers'] } else { $null }
    } elseif ($Dataset.PSObject.Properties['AdServers']) { $Dataset.AdServers } else { $null }
    $staleCount = if ($adServers) { @($adServers | Where-Object { $_.Stale }).Count } else { 0 }
    $noData = @($lp.Warnings | Where-Object { $_ -match 'no core data' }).Count

    # ── Narrative ───────────────────────────────────────────────────────────
    $summaryPara = "$PreparedBy reviewed $CustomerName's server environment to establish " +
        "the Windows Server licensing position needed for the upcoming Open Value renewal. " +
        "The review covered $hostCount physical $(Get-OVPlural $hostCount 'host' 'hosts') running $winServers Windows Server " +
        "$(Get-OVPlural $winServers 'instance' 'instances'). The recommended position totals $(Format-OVMoney $recommendedCost $cur) " +
        "at current reference pricing."
    if ($savings -gt 0) {
        $summaryPara += " Matching the licensing edition on each host to the number of workloads it runs, " +
            "rather than applying Datacenter everywhere, lowers the figure by about " +
            "$(Format-OVMoney $savings $cur) ($savingsPct percent) compared with a Datacenter-on-every-host approach."
    }

    $opportunities = [System.Collections.Generic.List[string]]::new()
    if ($nPerVm -gt 0) {
        $opportunities.Add("$nPerVm $(Get-OVPlural $nPerVm 'host qualifies' 'hosts qualify') for per-virtual-machine licensing under Software Assurance, which is the lowest-cost option where a host runs only a few Windows workloads.")
    }
    if ($nStd -gt 0) {
        $opportunities.Add("$nStd $(Get-OVPlural $nStd 'host is' 'hosts are') best covered by Standard edition, which fits a host running a small number of virtual machines.")
    }
    if ($nDc -gt 0) {
        $opportunities.Add("$nDc $(Get-OVPlural $nDc 'host is' 'hosts are') dense enough to justify Datacenter, which allows unlimited Windows virtual machines and removes per-machine counting.")
    }
    if ($staleCount -gt 0) {
        $opportunities.Add("$staleCount server $(Get-OVPlural $staleCount 'account has' 'accounts have') not authenticated in more than 60 days. Confirming whether these are still in use could remove their cores from the count before renewal.")
    }
    if ($lp.CalFootprint) {
        $c = $lp.CalFootprint
        $cheaper = if ($c.EnabledUsers -le $c.EnabledWorkstations) { 'User' } else { 'Device' }
        $opportunities.Add("With $($c.EnabledUsers) enabled users and $($c.EnabledWorkstations) managed devices, $cheaper CALs are the more economical choice for Windows Server access. Remote Desktop access, where used, needs separate RDS CALs.")
    }
    if ($sqlCount -gt 0) {
        $opportunities.Add("$sqlCount SQL Server $(Get-OVPlural $sqlCount 'instance was' 'instances were') found and $(Get-OVPlural $sqlCount 'is' 'are') listed in the detailed workbook. SQL is licensed separately and is often a larger cost than the operating system, so it is worth reviewing in the same renewal.")
    }
    $prefHosts = if ($lp.PSObject.Properties['PreferenceHostCount']) { [int]$lp.PreferenceHostCount } else { 0 }
    if ($prefHosts -gt 0) {
        $premium = $lp.OperationalPremiumTotal
        $opportunities.Add("$prefHosts $(Get-OVPlural $prefHosts 'host was' 'hosts were') set to Datacenter for operational simplicity rather than the lowest-cost option, which adds about $(Format-OVMoney $premium $cur). Per-virtual-machine licensing would recover that amount where the added tracking is acceptable.")
    }

    $risks = [System.Collections.Generic.List[string]]::new()
    if ($noData -gt 0) {
        $risks.Add("$noData $(Get-OVPlural $noData 'server could not be measured and has' 'servers could not be measured and have') no inventory on record. $(Get-OVPlural $noData 'It is' 'They are') excluded from the totals rather than assumed to have no cores, so the final count may rise once $(Get-OVPlural $noData 'it is' 'they are') reached.")
    }
    foreach ($p in ($hp | Where-Object ForceDatacenter)) {
        $risks.Add("$($p.HostName) requires Datacenter regardless of workload count: $($p.ForceReasons).")
    }
    if ($risks.Count -eq 0) { $risks.Add("No blocking data gaps were identified during collection.") }

    # ── HTML body (shared by .html, .pdf, .doc) ──────────────────────────────
    $oppHtml  = ($opportunities | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join "`n"
    $riskHtml = ($risks         | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join "`n"
    $modelRows = ($models | ForEach-Object {
        "<tr><td>$($_.Model)</td><td style='text-align:right'>$($_.Hosts)</td><td style='text-align:right'>$($_.Cores)</td><td style='text-align:right'>$(Format-OVMoney $_.Cost $cur)</td></tr>"
    }) -join "`n"

    $css = @'
<style>
 @page { margin: 18mm; }
 body { font-family: Calibri, "Segoe UI", Arial, sans-serif; color:#222; line-height:1.45; font-size:11pt; }
 h1 { color:#0a3d62; font-size:21pt; margin:0 0 2px 0; }
 h2 { color:#0a3d62; font-size:13pt; border-bottom:1px solid #cfd8dc; padding-bottom:3px; margin-top:20px; }
 .meta { color:#607d8b; font-size:10pt; margin-bottom:14px; }
 .kpis { width:100%; border-collapse:collapse; margin:10px 0; }
 .kpis td { border:1px solid #cfd8dc; padding:8px 10px; text-align:center; }
 .kpis .n { font-size:18pt; color:#0a3d62; font-weight:bold; display:block; }
 .kpis .l { font-size:9pt; color:#607d8b; }
 table.data { width:100%; border-collapse:collapse; margin:8px 0; font-size:10.5pt; }
 table.data th { background:#0a3d62; color:#fff; text-align:left; padding:6px 8px; }
 table.data td { border:1px solid #cfd8dc; padding:5px 8px; }
 .highlight { background:#e8f0fe; border-left:4px solid #0a3d62; padding:10px 14px; margin:10px 0; }
 ul { margin:6px 0 6px 0; } li { margin:4px 0; }
 .foot { color:#90a4ae; font-size:9pt; margin-top:24px; border-top:1px solid #cfd8dc; padding-top:8px; }
</style>
'@

    $bodyHtml = @"
<h1>Windows Server Licensing Assessment</h1>
<div class='meta'>Prepared for $([System.Net.WebUtility]::HtmlEncode($CustomerName)) by $([System.Net.WebUtility]::HtmlEncode($PreparedBy)) &bull; $ReportDate</div>

<h2>Summary</h2>
<p>$([System.Net.WebUtility]::HtmlEncode($summaryPara))</p>
<div class='highlight'><b>Recommended position:</b> $(Format-OVMoney $recommendedCost $cur) across $recommendedCores core licenses on $hostCount host$(if($hostCount -ne 1){'s'}).
$(if($savings -gt 0){"Estimated avoided cost versus Datacenter on every host: <b>$(Format-OVMoney $savings $cur)</b>."})</div>

<table class='kpis'><tr>
 <td><span class='n'>$hostCount</span><span class='l'>Physical hosts</span></td>
 <td><span class='n'>$winServers</span><span class='l'>Windows Server instances</span></td>
 <td><span class='n'>$vmTotal</span><span class='l'>Windows VMs</span></td>
 <td><span class='n'>$recommendedCores</span><span class='l'>Recommended cores</span></td>
 <td><span class='n'>$sqlCount</span><span class='l'>SQL instances</span></td>
</tr></table>

<h2>Recommended position by edition</h2>
<table class='data'><tr><th>Licensing model</th><th style='text-align:right'>Hosts</th><th style='text-align:right'>Core licenses</th><th style='text-align:right'>Estimated cost</th></tr>
$modelRows
</table>

<h2>Where the cost comes from</h2>
<ul>
$oppHtml
</ul>

<h2>Risks and data gaps</h2>
<ul>
$riskHtml
</ul>

<h2>Method and assumptions</h2>
<p>The assessment is read-only. It draws the server list from Active Directory, takes physical core counts and virtual-machine placement directly from the hypervisors, and reads operating system, processor, SQL, and role detail from each server. Windows Server is licensed on physical host cores, so host core counts come from the hypervisor rather than from inside each virtual machine.</p>
<p>Software Assurance is assumed to be $(if($lp.SoftwareAssurance){'in place'}else{'absent'}), which $(if($lp.SoftwareAssurance){'allows the per-virtual-machine option and Flexible Virtualization'}else{'means every potential host must be licensed for clustered workloads'}). Pricing uses reference figures of $(Format-OVMoney $lp.Pricing.StandardPerCore $cur) per Standard core and $(Format-OVMoney $lp.Pricing.DatacenterPerCore $cur) per Datacenter core. Replace these with the negotiated Open Value pricing for a final number.</p>

<div class='foot'>These figures are an estimate for planning and are not a quote. The final position should be confirmed against the customer's specific Microsoft Product Terms at the time of purchase. A detailed per-host workbook accompanies this summary.</div>
"@

    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

    # 1) HTML
    $htmlPath = Join-Path $OutputPath 'OV-Audit-Executive-Summary.html'
    $html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Windows Server Licensing Assessment</title>$css</head><body>$bodyHtml</body></html>"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Host "[OV-Audit] Executive summary (HTML): $htmlPath" -ForegroundColor Green

    # 2) Word-openable .doc (HTML with Office namespaces; Word opens & re-saves as .docx)
    $docPath = Join-Path $OutputPath 'OV-Audit-Executive-Summary.doc'
    $wordHtml = "<html xmlns:o='urn:schemas-microsoft-com:office:office' xmlns:w='urn:schemas-microsoft-com:office:word' xmlns='http://www.w3.org/TR/REC-html40'><head><meta charset='utf-8'>$css</head><body>$bodyHtml</body></html>"
    $wordHtml | Out-File -FilePath $docPath -Encoding UTF8
    Write-Host "[OV-Audit] Executive summary (Word .doc): $docPath" -ForegroundColor Green

    # 3) PDF via headless Edge/Chrome (best effort)
    $pdfPath = Join-Path $OutputPath 'OV-Audit-Executive-Summary.pdf'
    if (ConvertTo-OVPdf -HtmlPath $htmlPath -PdfPath $pdfPath) {
        Write-Host "[OV-Audit] Executive summary (PDF): $pdfPath" -ForegroundColor Green
    } else {
        Write-Warning "PDF step skipped (no Edge/Chrome found). Open the .html and print to PDF, or open the .doc in Word and export to PDF."
    }

    $pdfResult = if (Test-Path $pdfPath) { $pdfPath } else { $null }
    return [pscustomobject]@{
        Html = $htmlPath; Doc = $docPath; Pdf = $pdfResult
        RecommendedCost = $recommendedCost; BaselineDatacenterCost = $allDcCost; EstimatedSavings = $savings
    }
}

Export-ModuleMember -Function Export-OVExecutiveSummary, ConvertTo-OVPdf, Format-OVMoney
