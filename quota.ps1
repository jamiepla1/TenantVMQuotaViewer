# PowerShell Script to Get VM, Storage, and App Service Plan Quota Consumption Across All Subscriptions in a Tenant
# Requires: Az PowerShell module

# Import required Azure modules
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Compute -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop
    Import-Module Az.Websites -ErrorAction Stop
}
catch {
    Write-Error "Failed to import required Az modules. Please ensure the Az module is installed"
    exit 1
}

# Configuration
$targetLocation = "uksouth"

# Azure Authentication
try {
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Host "No active Azure session found. Initiating device code authentication..." -ForegroundColor Yellow
        Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
    }
    else {
        Write-Host "Already connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
    }
}
catch {
    Write-Error "Failed to authenticate to Azure: $_"
    exit 1
}

# Get all subscriptions
try {
    $allSubscriptions = Get-AzSubscription -ErrorAction Stop
    if (-not $allSubscriptions) {
        Write-Warning "No subscriptions found in the tenant."
        exit 0
    }
    
    # Filter out Dev/Test subscriptions based on offer type
    $subscriptions = $allSubscriptions | Where-Object { 
        $_.SubscriptionPolicies.QuotaId -notmatch "MSAZR0148P"
    }
    
    if (-not $subscriptions) {
        Write-Warning "No production subscriptions found in the tenant."
        exit 0
    }
    
    Write-Host "Found $($allSubscriptions.Count) total subscription(s), processing $($subscriptions.Count) production subscription(s)." -ForegroundColor Green
}
catch {
    Write-Error "Failed to retrieve subscriptions: $_"
    exit 1
}

# Initialize result arrays
$vmQuotaResults = @()
$storageQuotaResults = @()
$appServiceQuotaResults = @()

# Process each subscription
foreach ($subscription in $subscriptions) {
    Write-Host "Processing subscription: $($subscription.Name)" -ForegroundColor Cyan
    
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Could not set context for subscription $($subscription.Name): $_"
        continue
    }
    
    # Get VM quotas
    Write-Host "  Fetching VM quotas..." -ForegroundColor Gray
    try {
        $vmUsage = Get-AzVMUsage -Location $targetLocation -ErrorAction Stop
        if ($vmUsage) {
            foreach ($usage in $vmUsage) {
                $resourceName = $usage.Name.LocalizedValue
                if ($resourceName -match "vCPU|Virtual Machine|Availability Sets|Dedicated|Low-priority") {
                    $vmQuotaResults += [PSCustomObject]@{
                        SubscriptionName = $subscription.Name
                        SubscriptionId   = $subscription.Id
                        Location         = $targetLocation
                        Category         = "VM"
                        ResourceType     = $resourceName
                        CurrentUsage     = $usage.CurrentValue
                        Limit            = $usage.Limit
                        UsagePercentage  = if ($usage.Limit -gt 0) { [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) } else { 0 }
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve VM quota: $_"
    }
    
    # Get Storage quotas
    Write-Host "  Fetching Storage quotas..." -ForegroundColor Gray
    try {
        $normalizedLocation = $targetLocation.ToLower() -replace '\s', ''
        $storageUsageData = Invoke-AzRestMethod -Path "/subscriptions/$($subscription.Id)/providers/Microsoft.Storage/locations/$normalizedLocation/usages?api-version=2023-01-01" -Method GET
        
        if ($storageUsageData.StatusCode -eq 200) {
            $usages = ($storageUsageData.Content | ConvertFrom-Json).value
            if ($usages) {
                foreach ($usage in $usages) {
                    $resourceName = if ($usage.name.localizedValue) { $usage.name.localizedValue } else { $usage.name.value }
                    if ($resourceName) {
                        $storageQuotaResults += [PSCustomObject]@{
                            SubscriptionName = $subscription.Name
                            SubscriptionId   = $subscription.Id
                            Location         = $targetLocation
                            Category         = "Storage"
                            ResourceType     = $resourceName
                            CurrentUsage     = [int]$usage.currentValue
                            Limit            = [int]$usage.limit
                            UsagePercentage  = if ($usage.limit -gt 0) { [math]::Round(($usage.currentValue / $usage.limit) * 100, 2) } else { 0 }
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve Storage quota: $_"
    }
    
    # Get App Service quotas
    Write-Host "  Fetching App Service quotas..." -ForegroundColor Gray
    try {
        $normalizedLocation = $targetLocation.ToLower() -replace '\s', ''
        $aspUsageData = Invoke-AzRestMethod -Path "/subscriptions/$($subscription.Id)/providers/Microsoft.Web/locations/$normalizedLocation/usages?api-version=2023-01-01" -Method GET
        
        if ($aspUsageData.StatusCode -eq 200) {
            $usages = ($aspUsageData.Content | ConvertFrom-Json).value
            if ($usages) {
                foreach ($usage in $usages) {
                    $resourceName = if ($usage.name.localizedValue) { $usage.name.localizedValue } else { $usage.name.value }
                    if ($resourceName) {
                        $appServiceQuotaResults += [PSCustomObject]@{
                            SubscriptionName = $subscription.Name
                            SubscriptionId   = $subscription.Id
                            Location         = $targetLocation
                            Category         = "App Service"
                            ResourceType     = $resourceName
                            CurrentUsage     = [int]$usage.currentValue
                            Limit            = [int]$usage.limit
                            UsagePercentage  = if ($usage.limit -gt 0) { [math]::Round(($usage.currentValue / $usage.limit) * 100, 2) } else { 0 }
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve App Service quota: $_"
    }
}

# Display results
Write-Host "`n=== VM Quotas ===" -ForegroundColor Green
$vmQuotaResults | Format-Table -AutoSize

Write-Host "`n=== Storage Quotas ===" -ForegroundColor Green
$storageQuotaResults | Format-Table -AutoSize

Write-Host "`n=== App Service Quotas ===" -ForegroundColor Green
$appServiceQuotaResults | Format-Table -AutoSize

# Generate summaries
Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan

function Create-Summary {
    param($results)
    
    $results | Group-Object -Property ResourceType | ForEach-Object {
        $totalUsage = ($_.Group | Measure-Object -Property CurrentUsage -Sum).Sum
        $totalLimit = ($_.Group | Measure-Object -Property Limit -Sum).Sum
        $usagePercentage = if ($totalLimit -gt 0) { [math]::Round(($totalUsage / $totalLimit) * 100, 2) } else { 0 }
        
        $subscriptionDetails = $_.Group | Where-Object { $_.CurrentUsage -gt 0 -or $_.Limit -gt 0 } | 
            Sort-Object -Property CurrentUsage -Descending |
            Select-Object SubscriptionName, SubscriptionId, CurrentUsage, Limit, UsagePercentage
        
        [PSCustomObject]@{
            Category            = $_.Group[0].Category
            ResourceType        = $_.Name
            TotalUsage          = $totalUsage
            TotalLimit          = $totalLimit
            UsagePercentage     = $usagePercentage
            SubscriptionCount   = $_.Count
            SubscriptionDetails = $subscriptionDetails
        }
    } | Sort-Object -Property UsagePercentage -Descending
}

$vmSummary = Create-Summary -results $vmQuotaResults
$storageSummary = Create-Summary -results $storageQuotaResults
$appServiceSummary = Create-Summary -results $appServiceQuotaResults

# Get tenant info
$tenantId = (Get-AzContext).Tenant.Id
$tenantInfo = Get-AzTenant -TenantId $tenantId -ErrorAction SilentlyContinue
$tenantName = if ($tenantInfo.Name) { $tenantInfo.Name } else { "Unknown" }
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Function to generate table rows
function Generate-TableRows {
    param($summary)
    
    $html = ""
    foreach ($item in $summary) {
        $progressClass = if ($item.UsagePercentage -ge 80) { "progress-critical" }
                         elseif ($item.UsagePercentage -ge 50) { "progress-high" }
                         elseif ($item.UsagePercentage -ge 25) { "progress-medium" }
                         else { "progress-low" }
        
        $usageClass = if ($item.UsagePercentage -ge 80) { "usage-critical" }
                      elseif ($item.UsagePercentage -ge 50) { "usage-high" }
                      elseif ($item.UsagePercentage -ge 25) { "usage-medium" }
                      else { "usage-low" }
        
        $progressWidth = [math]::Min($item.UsagePercentage, 100)
        $hasDetails = $item.SubscriptionDetails -and $item.SubscriptionDetails.Count -gt 0
        $rowId = [guid]::NewGuid().ToString("N").Substring(0, 8)
        
        if ($hasDetails) {
            $html += "<tr class='expandable-row' onclick='toggleDetails(`"$rowId`")'>"
            $html += "<td><span class='expand-icon' id='icon-$rowId'>▶</span><strong>$($item.ResourceType)</strong></td>"
            $html += "<td>$($item.TotalUsage.ToString('N0'))</td>"
            $html += "<td>$($item.TotalLimit.ToString('N0'))</td>"
            $html += "<td><span class='usage-text $usageClass'>$($item.UsagePercentage)%</span></td>"
            $html += "<td><div class='progress-bar'><div class='progress-fill $progressClass' style='width: $progressWidth%'></div></div></td>"
            $html += "<td>$($item.SubscriptionCount)</td>"
            $html += "</tr>"
            
            $html += "<tr class='subscription-details' id='details-$rowId'>"
            $html += "<td colspan='6'><table class='sub-table'>"
            $html += "<thead><tr><th>Subscription</th><th>Subscription ID</th><th>Usage</th><th>Limit</th><th>Usage %</th></tr></thead>"
            $html += "<tbody>"
            
            foreach ($sub in $item.SubscriptionDetails) {
                $subUsageClass = if ($sub.UsagePercentage -ge 80) { "usage-critical" }
                                 elseif ($sub.UsagePercentage -ge 50) { "usage-high" }
                                 elseif ($sub.UsagePercentage -ge 25) { "usage-medium" }
                                 else { "usage-low" }
                
                $html += "<tr>"
                $html += "<td>$($sub.SubscriptionName)</td>"
                $html += "<td style='font-family: monospace; font-size: 11px;'>$($sub.SubscriptionId)</td>"
                $html += "<td>$($sub.CurrentUsage.ToString('N0'))</td>"
                $html += "<td>$($sub.Limit.ToString('N0'))</td>"
                $html += "<td><span class='usage-text $subUsageClass'>$($sub.UsagePercentage)%</span></td>"
                $html += "</tr>"
            }
            
            $html += "</tbody></table></td></tr>"
        } else {
            $html += "<tr>"
            $html += "<td><span class='expand-icon no-expand'>-</span><strong>$($item.ResourceType)</strong></td>"
            $html += "<td>$($item.TotalUsage.ToString('N0'))</td>"
            $html += "<td>$($item.TotalLimit.ToString('N0'))</td>"
            $html += "<td><span class='usage-text $usageClass'>$($item.UsagePercentage)%</span></td>"
            $html += "<td><div class='progress-bar'><div class='progress-fill $progressClass' style='width: $progressWidth%'></div></div></td>"
            $html += "<td>$($item.SubscriptionCount)</td>"
            $html += "</tr>"
        }
    }
    
    return $html
}

# Build HTML
$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Quota Report - All Services</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        .header {
            background: white;
            border-radius: 10px;
            padding: 30px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        }
        .header h1 { color: #333; margin-bottom: 10px; }
        .header-info { display: flex; gap: 30px; flex-wrap: wrap; margin-top: 15px; }
        .header-info-item {
            background: #f8f9fa;
            padding: 10px 20px;
            border-radius: 5px;
            border-left: 4px solid #667eea;
        }
        .header-info-item label { font-size: 12px; color: #666; display: block; }
        .header-info-item span { font-size: 14px; font-weight: 600; color: #333; }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
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
        .card-value { font-size: 36px; font-weight: 700; color: #667eea; }
        .card-label { color: #666; margin-top: 5px; font-size: 14px; }
        .content-container {
            background: white;
            border-radius: 10px;
            padding: 25px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        }
        .section-header {
            background: #f8f9fa;
            padding: 15px 20px;
            margin: 20px 0 0 0;
            border-radius: 8px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: all 0.3s;
            border-left: 5px solid #667eea;
        }
        .section-header:hover { background: #e9ecef; }
        .section-header:first-child { margin-top: 0; }
        .section-header h3 {
            margin: 0;
            color: #333;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .section-toggle {
            font-size: 24px;
            font-weight: bold;
            color: #667eea;
            transition: transform 0.3s;
        }
        .section-toggle.collapsed { transform: rotate(-90deg); }
        .section-content {
            max-height: 5000px;
            overflow: hidden;
            transition: max-height 0.3s ease-out;
        }
        .section-content.collapsed { max-height: 0; }
        .section-vm .section-header { border-left-color: #1976d2; }
        .section-storage .section-header { border-left-color: #f57c00; }
        .section-appservice .section-header { border-left-color: #7b1fa2; }
        .category-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 11px;
            font-weight: 600;
            text-transform: uppercase;
        }
        .category-vm { background: #e3f2fd; color: #1976d2; }
        .category-storage { background: #fff3e0; color: #f57c00; }
        .category-appservice { background: #f3e5f5; color: #7b1fa2; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th {
            background: #667eea;
            color: white;
            padding: 15px 12px;
            text-align: left;
            font-weight: 600;
        }
        td { padding: 12px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f8f9fa; }
        .progress-bar {
            width: 100%;
            height: 20px;
            background: #e9ecef;
            border-radius: 10px;
            overflow: hidden;
        }
        .progress-fill { height: 100%; border-radius: 10px; transition: width 0.3s ease; }
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
        .expandable-row { cursor: pointer; }
        .expandable-row:hover { background: #e8f4f8; }
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
        .expand-icon.expanded { transform: rotate(90deg); }
        .subscription-details { display: none; background: #f8f9fa; }
        .subscription-details.show { display: table-row; }
        .subscription-details td { padding: 0; }
        .sub-table { width: 100%; margin: 0; border-collapse: collapse; }
        .sub-table th { background: #8b9dc3; padding: 10px 12px; font-size: 12px; }
        .sub-table td { padding: 8px 12px; font-size: 13px; border-bottom: 1px solid #e0e0e0; }
        .sub-table tr:last-child td { border-bottom: none; }
        .sub-table tr:hover { background: #eef2f7; }
        .no-expand { opacity: 0.5; }
        .footer { text-align: center; color: white; margin-top: 20px; padding: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔍 Azure Quota Report - All Services</h1>
            <p>Tenant-wide quota consumption summary for VM, Storage, and App Service Plans</p>
            <div class="header-info">
                <div class="header-info-item"><label>Tenant Name</label><span>$tenantName</span></div>
                <div class="header-info-item"><label>Tenant ID</label><span>$tenantId</span></div>
                <div class="header-info-item"><label>Location</label><span>$targetLocation</span></div>
                <div class="header-info-item"><label>Report Generated</label><span>$reportDate</span></div>
                <div class="header-info-item"><label>Subscriptions Scanned</label><span>$($subscriptions.Count)</span></div>
            </div>
        </div>

        <div class="summary-cards">
            <div class="card"><div class="card-value">$($vmSummary.Count)</div><div class="card-label">VM Quota Types</div></div>
            <div class="card"><div class="card-value">$($storageSummary.Count)</div><div class="card-label">Storage Quota Types</div></div>
            <div class="card"><div class="card-value">$($appServiceSummary.Count)</div><div class="card-label">App Service Quota Types</div></div>
            <div class="card"><div class="card-value">$(($vmSummary + $storageSummary + $appServiceSummary | Where-Object { $_.UsagePercentage -ge 80 }).Count)</div><div class="card-label">Quotas at 80%+ Usage</div></div>
            <div class="card"><div class="card-value">$(($vmSummary + $storageSummary + $appServiceSummary | Where-Object { $_.TotalUsage -gt 0 }).Count)</div><div class="card-label">Quotas with Active Usage</div></div>
        </div>

        <div class="content-container">
            <h2>📊 All Quota Types - Tenant-Wide Summary</h2>
            
            <!-- VM Section -->
            <div class="section-vm">
                <div class="section-header" onclick="toggleSection('vm-section')">
                    <h3>💻 VM Quotas <span class="category-badge category-vm">$($vmSummary.Count) Types</span></h3>
                    <span class="section-toggle" id="vm-section-toggle">▼</span>
                </div>
                <div class="section-content" id="vm-section-content">
                    <table>
                        <thead>
                            <tr>
                                <th>Resource Type</th>
                                <th>Total Usage</th>
                                <th>Total Limit</th>
                                <th>Usage %</th>
                                <th>Usage Bar</th>
                                <th>Subscriptions</th>
                            </tr>
                        </thead>
                        <tbody>
$(Generate-TableRows -summary $vmSummary)
                        </tbody>
                    </table>
                </div>
            </div>
            
            <!-- Storage Section -->
            <div class="section-storage">
                <div class="section-header" onclick="toggleSection('storage-section')">
                    <h3>💾 Storage Quotas <span class="category-badge category-storage">$($storageSummary.Count) Types</span></h3>
                    <span class="section-toggle" id="storage-section-toggle">▼</span>
                </div>
                <div class="section-content" id="storage-section-content">
                    <table>
                        <thead>
                            <tr>
                                <th>Resource Type</th>
                                <th>Total Usage</th>
                                <th>Total Limit</th>
                                <th>Usage %</th>
                                <th>Usage Bar</th>
                                <th>Subscriptions</th>
                            </tr>
                        </thead>
                        <tbody>
$(Generate-TableRows -summary $storageSummary)
                        </tbody>
                    </table>
                </div>
            </div>
            
            <!-- App Service Section -->
            <div class="section-appservice">
                <div class="section-header" onclick="toggleSection('appservice-section')">
                    <h3>🌐 App Service Quotas <span class="category-badge category-appservice">$($appServiceSummary.Count) Types</span></h3>
                    <span class="section-toggle" id="appservice-section-toggle">▼</span>
                </div>
                <div class="section-content" id="appservice-section-content">
                    <table>
                        <thead>
                            <tr>
                                <th>Resource Type</th>
                                <th>Total Usage</th>
                                <th>Total Limit</th>
                                <th>Usage %</th>
                                <th>Usage Bar</th>
                                <th>Subscriptions</th>
                            </tr>
                        </thead>
                        <tbody>
$(Generate-TableRows -summary $appServiceSummary)
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div class="footer">
            <p>Generated by Azure Quota Finder | PowerShell Script</p>
        </div>
    </div>

    <script>
        function toggleSection(sectionId) {
            const content = document.getElementById(sectionId + '-content');
            const toggle = document.getElementById(sectionId + '-toggle');
            
            if (content.classList.contains('collapsed')) {
                content.classList.remove('collapsed');
                toggle.classList.remove('collapsed');
                toggle.textContent = '▼';
            } else {
                content.classList.add('collapsed');
                toggle.classList.add('collapsed');
                toggle.textContent = '▶';
            }
        }
        
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
    </script>
</body>
</html>
"@

# Save HTML report
$htmlPath = Join-Path -Path (Get-Location) -ChildPath "AllQuotaReport.html"
[System.IO.File]::WriteAllText($htmlPath, $htmlContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "HTML report generated: $htmlPath" -ForegroundColor Green
