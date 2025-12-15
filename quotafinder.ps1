# PowerShell Script to Get App Service Plan Quota Consumption Across All Subscriptions in a Tenant
# Requires: Az PowerShell module

# Import required Azure modules
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Websites -ErrorAction Stop
}
catch {
    Write-Error "Failed to import required Az modules. Please ensure the Az module is installed: Install-Module -Name Az.Accounts, Az.Websites -Scope CurrentUser"
    exit 1
}

# Configuration - specify the location to check
$targetLocation = "uksouth"

# Check for existing Azure session, if not connected, use device code authentication
try {
    $context = Get-AzContext -ErrorAction SilentlyContinue

    if (-not $context) {
        Write-Host "No active Azure session found. Initiating device code authentication..." -ForegroundColor Yellow
        Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
    }
    else {
        Write-Host "Already connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
        Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Green
    }
}
catch {
    Write-Error "Failed to authenticate to Azure: $_"
    exit 1
}

# Get all subscriptions in the tenant
try {
    $subscriptions = Get-AzSubscription -ErrorAction Stop
    
    if (-not $subscriptions) {
        Write-Warning "No subscriptions found in the tenant."
        exit 0
    }
    
    Write-Host "Found $($subscriptions.Count) subscription(s) to process." -ForegroundColor Green
}
catch {
    Write-Error "Failed to retrieve subscriptions: $_"
    exit 1
}

# Create an array to store results
$quotaResults = @()

foreach ($subscription in $subscriptions) {
    Write-Host "Processing subscription: $($subscription.Name) ($($subscription.Id))" -ForegroundColor Cyan
    
    # Set the current subscription context
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Could not set context for subscription $($subscription.Name): $_"
        continue
    }
    
    # Get App Service Plan quota usage for UK South
    try {
        # Use the correct API path with proper location name normalization (remove spaces, lowercase)
        $normalizedLocation = $targetLocation.ToLower() -replace '\s', ''
        $aspUsageData = Invoke-AzRestMethod -Path "/subscriptions/$($subscription.Id)/providers/Microsoft.Web/locations/$normalizedLocation/usages?api-version=2023-01-01" -Method GET
        
        if ($aspUsageData.StatusCode -eq 200) {
            $usages = ($aspUsageData.Content | ConvertFrom-Json).value
            
            if ($usages) {
                foreach ($usage in $usages) {
                    $resourceName = if ($usage.name.localizedValue) { $usage.name.localizedValue } else { $usage.name.value }
                    
                    if ($resourceName) {
                        $quotaResults += [PSCustomObject]@{
                            SubscriptionName = $subscription.Name
                            SubscriptionId   = $subscription.Id
                            Location         = $targetLocation
                            ResourceType     = $resourceName
                            CurrentUsage     = [int]$usage.currentValue
                            Limit            = [int]$usage.limit
                            UsagePercentage  = if ($usage.limit -gt 0) { [math]::Round(($usage.currentValue / $usage.limit) * 100, 2) } else { 0 }
                        }
                    }
                }
            }
            else {
                Write-Host "  No App Service quota data found for $targetLocation" -ForegroundColor Yellow
            }
        }
        elseif ($aspUsageData.StatusCode -eq 400) {
            Write-Warning "Bad request for subscription $($subscription.Name). This might indicate the subscription doesn't have App Service registered or the location is invalid."
        }
        else {
            Write-Warning "API request failed with status code: $($aspUsageData.StatusCode) for subscription $($subscription.Name)"
        }
    }
    catch {
        Write-Warning "Could not retrieve quota for $targetLocation in subscription $($subscription.Name): $_"
    }
}

# Display results
$quotaResults | Format-Table -AutoSize

# Optionally export to CSV
# $quotaResults | Export-Csv -Path "AppServicePlanQuotaReport.csv" -NoTypeInformation

# Show summary of high usage quotas (over 80%)
Write-Host "`nQuotas with usage over 80%:" -ForegroundColor Yellow
$quotaResults | Where-Object { $_.UsagePercentage -ge 80 } | Format-Table -AutoSize

# Generate HTML Report with tenant-wide SKU summary
Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan

# Group by ResourceType and calculate tenant-wide totals, including subscription details
$skuSummary = $quotaResults | Group-Object -Property ResourceType | ForEach-Object {
    $totalUsage = ($_.Group | Measure-Object -Property CurrentUsage -Sum).Sum
    $totalLimit = ($_.Group | Measure-Object -Property Limit -Sum).Sum
    $usagePercentage = if ($totalLimit -gt 0) { [math]::Round(($totalUsage / $totalLimit) * 100, 2) } else { 0 }
    
    # Get subscription details - those with usage > 0 OR limit > 0
    $subscriptionDetails = $_.Group | Where-Object { $_.CurrentUsage -gt 0 -or $_.Limit -gt 0 } | 
        Sort-Object -Property CurrentUsage -Descending |
        Select-Object SubscriptionName, SubscriptionId, CurrentUsage, Limit, UsagePercentage
    
    [PSCustomObject]@{
        ResourceType        = $_.Name
        TotalUsage          = $totalUsage
        TotalLimit          = $totalLimit
        UsagePercentage     = $usagePercentage
        SubscriptionCount   = $_.Count
        SubscriptionDetails = $subscriptionDetails
    }
} | Sort-Object -Property UsagePercentage -Descending

# Get tenant info
$tenantId = (Get-AzContext).Tenant.Id
$tenantInfo = Get-AzTenant -TenantId $tenantId -ErrorAction SilentlyContinue
$tenantName = if ($tenantInfo.Name) { $tenantInfo.Name } else { "Unknown" }
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Build HTML content
$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure App Service Plan Quota Report - Tenant Wide Summary</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
        }
        .header {
            background: white;
            border-radius: 10px;
            padding: 30px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        }
        .header h1 {
            color: #333;
            margin-bottom: 10px;
        }
        .header-info {
            display: flex;
            gap: 30px;
            flex-wrap: wrap;
            margin-top: 15px;
        }
        .header-info-item {
            background: #f8f9fa;
            padding: 10px 20px;
            border-radius: 5px;
            border-left: 4px solid #667eea;
        }
        .header-info-item label {
            font-size: 12px;
            color: #666;
            display: block;
        }
        .header-info-item span {
            font-size: 14px;
            font-weight: 600;
            color: #333;
        }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }
        .card {
            background: white;
            border-radius: 10px;
            padding: 25px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            text-align: center;
        }
        .card-value {
            font-size: 36px;
            font-weight: 700;
            color: #667eea;
        }
        .card-label {
            color: #666;
            margin-top: 5px;
        }
        .table-container {
            background: white;
            border-radius: 10px;
            padding: 25px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            overflow-x: auto;
        }
        .table-container h2 {
            margin-bottom: 20px;
            color: #333;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th {
            background: #667eea;
            color: white;
            padding: 15px 12px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 12px;
            border-bottom: 1px solid #eee;
        }
        tr:hover {
            background: #f8f9fa;
        }
        .progress-bar {
            width: 100%;
            height: 20px;
            background: #e9ecef;
            border-radius: 10px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            border-radius: 10px;
            transition: width 0.3s ease;
        }
        .progress-low { background: linear-gradient(90deg, #28a745, #34ce57); }
        .progress-medium { background: linear-gradient(90deg, #ffc107, #ffda6a); }
        .progress-high { background: linear-gradient(90deg, #fd7e14, #ff922b); }
        .progress-critical { background: linear-gradient(90deg, #dc3545, #e35d6a); }
        .usage-text {
            font-weight: 600;
            padding: 4px 8px;
            border-radius: 4px;
            display: inline-block;
            min-width: 60px;
            text-align: center;
        }
        .usage-low { background: #d4edda; color: #155724; }
        .usage-medium { background: #fff3cd; color: #856404; }
        .usage-high { background: #ffe5d0; color: #8a4500; }
        .usage-critical { background: #f8d7da; color: #721c24; }
        .search-box {
            margin-bottom: 20px;
        }
        .search-box input {
            width: 100%;
            padding: 12px 20px;
            border: 2px solid #e9ecef;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        .search-box input:focus {
            outline: none;
            border-color: #667eea;
        }
        .expandable-row {
            cursor: pointer;
        }
        .expandable-row:hover {
            background: #e8f4f8;
        }
        .expand-icon {
            display: inline-block;
            width: 20px;
            height: 20px;
            text-align: center;
            background: #667eea;
            color: white;
            border-radius: 4px;
            margin-right: 8px;
            font-weight: bold;
            font-size: 14px;
            line-height: 20px;
            transition: transform 0.2s;
        }
        .expand-icon.expanded {
            transform: rotate(90deg);
        }
        .subscription-details {
            display: none;
            background: #f8f9fa;
        }
        .subscription-details.show {
            display: table-row;
        }
        .subscription-details td {
            padding: 0;
        }
        .sub-table {
            width: 100%;
            margin: 0;
            border-collapse: collapse;
        }
        .sub-table th {
            background: #8b9dc3;
            padding: 10px 12px;
            font-size: 12px;
        }
        .sub-table td {
            padding: 8px 12px;
            font-size: 13px;
            border-bottom: 1px solid #e0e0e0;
        }
        .sub-table tr:last-child td {
            border-bottom: none;
        }
        .sub-table tr:hover {
            background: #eef2f7;
        }
        .no-expand {
            opacity: 0.5;
        }
        .footer {
            text-align: center;
            color: white;
            margin-top: 20px;
            padding: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔍 Azure App Service Plan Quota Report</h1>
            <p>Tenant-wide quota consumption summary for UK South region</p>
            <div class="header-info">
                <div class="header-info-item">
                    <label>Tenant Name</label>
                    <span>$tenantName</span>
                </div>
                <div class="header-info-item">
                    <label>Tenant ID</label>
                    <span>$tenantId</span>
                </div>
                <div class="header-info-item">
                    <label>Location</label>
                    <span>$targetLocation</span>
                </div>
                <div class="header-info-item">
                    <label>Report Generated</label>
                    <span>$reportDate</span>
                </div>
                <div class="header-info-item">
                    <label>Subscriptions Scanned</label>
                    <span>$($subscriptions.Count)</span>
                </div>
            </div>
        </div>

        <div class="summary-cards">
            <div class="card">
                <div class="card-value">$($skuSummary.Count)</div>
                <div class="card-label">Total SKU Types</div>
            </div>
            <div class="card">
                <div class="card-value">$(($skuSummary | Where-Object { $_.UsagePercentage -ge 80 }).Count)</div>
                <div class="card-label">SKUs at 80%+ Usage</div>
            </div>
            <div class="card">
                <div class="card-value">$(($skuSummary | Where-Object { $_.UsagePercentage -ge 50 -and $_.UsagePercentage -lt 80 }).Count)</div>
                <div class="card-label">SKUs at 50-80% Usage</div>
            </div>
            <div class="card">
                <div class="card-value">$(($skuSummary | Where-Object { $_.TotalUsage -gt 0 }).Count)</div>
                <div class="card-label">SKUs with Active Usage</div>
            </div>
        </div>

        <div class="table-container">
            <h2>📊 Tenant-Wide SKU Quota Summary</h2>
            <div class="search-box">
                <input type="text" id="searchInput" onkeyup="filterTable()" placeholder="Search for SKU types...">
            </div>
            <table id="quotaTable">
                <thead>
                    <tr>
                        <th>SKU / Resource Type</th>
                        <th>Total Usage</th>
                        <th>Total Limit</th>
                        <th>Usage %</th>
                        <th>Usage Bar</th>
                        <th>Subscriptions</th>
                    </tr>
                </thead>
                <tbody>
"@

foreach ($sku in $skuSummary) {
    $progressClass = if ($sku.UsagePercentage -ge 80) { "progress-critical" }
                     elseif ($sku.UsagePercentage -ge 50) { "progress-high" }
                     elseif ($sku.UsagePercentage -ge 25) { "progress-medium" }
                     else { "progress-low" }
    
    $usageClass = if ($sku.UsagePercentage -ge 80) { "usage-critical" }
                  elseif ($sku.UsagePercentage -ge 50) { "usage-high" }
                  elseif ($sku.UsagePercentage -ge 25) { "usage-medium" }
                  else { "usage-low" }
    
    $progressWidth = [math]::Min($sku.UsagePercentage, 100)
    
    # Check if there are subscription details to show
    $hasDetails = $sku.SubscriptionDetails -and $sku.SubscriptionDetails.Count -gt 0
    $rowId = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
    
    if ($hasDetails) {
        $htmlContent += @"
                    <tr class="expandable-row" onclick="toggleDetails('$rowId')">
                        <td><span class="expand-icon" id="icon-$rowId">▶</span><strong>$($sku.ResourceType)</strong></td>
                        <td>$($sku.TotalUsage.ToString("N0"))</td>
                        <td>$($sku.TotalLimit.ToString("N0"))</td>
                        <td><span class="usage-text $usageClass">$($sku.UsagePercentage)%</span></td>
                        <td>
                            <div class="progress-bar">
                                <div class="progress-fill $progressClass" style="width: $progressWidth%"></div>
                            </div>
                        </td>
                        <td>$($sku.SubscriptionCount)</td>
                    </tr>
                    <tr class="subscription-details" id="details-$rowId">
                        <td colspan="6">
                            <table class="sub-table">
                                <thead>
                                    <tr>
                                        <th>Subscription Name</th>
                                        <th>Subscription ID</th>
                                        <th>Usage</th>
                                        <th>Limit</th>
                                        <th>Usage %</th>
                                    </tr>
                                </thead>
                                <tbody>
"@
        foreach ($sub in $sku.SubscriptionDetails) {
            $subUsageClass = if ($sub.UsagePercentage -ge 80) { "usage-critical" }
                             elseif ($sub.UsagePercentage -ge 50) { "usage-high" }
                             elseif ($sub.UsagePercentage -ge 25) { "usage-medium" }
                             else { "usage-low" }
            
            $htmlContent += @"
                                    <tr>
                                        <td>$($sub.SubscriptionName)</td>
                                        <td style="font-family: monospace; font-size: 11px;">$($sub.SubscriptionId)</td>
                                        <td>$($sub.CurrentUsage.ToString("N0"))</td>
                                        <td>$($sub.Limit.ToString("N0"))</td>
                                        <td><span class="usage-text $subUsageClass">$($sub.UsagePercentage)%</span></td>
                                    </tr>
"@
        }
        $htmlContent += @"
                                </tbody>
                            </table>
                        </td>
                    </tr>
"@
    } else {
        $htmlContent += @"
                    <tr>
                        <td><span class="expand-icon no-expand">-</span><strong>$($sku.ResourceType)</strong></td>
                        <td>$($sku.TotalUsage.ToString("N0"))</td>
                        <td>$($sku.TotalLimit.ToString("N0"))</td>
                        <td><span class="usage-text $usageClass">$($sku.UsagePercentage)%</span></td>
                        <td>
                            <div class="progress-bar">
                                <div class="progress-fill $progressClass" style="width: $progressWidth%"></div>
                            </div>
                        </td>
                        <td>$($sku.SubscriptionCount)</td>
                    </tr>
"@
    }
}

$htmlContent += @"
                </tbody>
            </table>
        </div>

        <div class="footer">
            <p>Generated by Azure App Service Plan Quota Finder | PowerShell Script</p>
        </div>
    </div>

    <script>
        function toggleDetails(rowId) {
            const detailsRow = document.getElementById('details-' + rowId);
            const icon = document.getElementById('icon-' + rowId);
            
            if (detailsRow.classList.contains('show')) {
                detailsRow.classList.remove('show');
                icon.classList.remove('expanded');
                icon.textContent = '▶';
            } else {
                detailsRow.classList.add('show');
                icon.classList.add('expanded');
                icon.textContent = '▼';
            }
        }
        
        function filterTable() {
            const input = document.getElementById('searchInput');
            const filter = input.value.toLowerCase();
            const table = document.getElementById('quotaTable');
            const rows = table.getElementsByTagName('tr');

            for (let i = 1; i < rows.length; i++) {
                const row = rows[i];
                // Skip subscription detail rows in filtering
                if (row.classList.contains('subscription-details')) {
                    continue;
                }
                const cells = row.getElementsByTagName('td');
                let found = false;
                for (let j = 0; j < cells.length; j++) {
                    if (cells[j].textContent.toLowerCase().includes(filter)) {
                        found = true;
                        break;
                    }
                }
                row.style.display = found ? '' : 'none';
                // Also hide the corresponding details row if main row is hidden
                const nextRow = rows[i + 1];
                if (nextRow && nextRow.classList.contains('subscription-details')) {
                    nextRow.style.display = found ? '' : 'none';
                    if (!found) {
                        nextRow.classList.remove('show');
                    }
                }
            }
        }
    </script>
</body>
</html>
"@

# Save HTML report
$htmlPath = Join-Path -Path (Get-Location) -ChildPath "AppServicePlanQuotaReport.html"
$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Host "HTML report generated: $htmlPath" -ForegroundColor Green
