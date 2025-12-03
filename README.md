# Azure VM Quota Finder

A PowerShell script to retrieve virtual machine vCPU quota consumption across all subscriptions in an Azure tenant, with an interactive HTML report.

## Overview

This script iterates through every subscription in your Azure tenant and retrieves the current VM quota usage for a specified region (default: UK South). It generates a comprehensive HTML report showing tenant-wide aggregated SKU usage with expandable subscription-level details.

## Features

- ✅ **Automatic Authentication** - Detects existing Azure session or prompts for device code authentication
- ✅ **Tenant-Wide Scanning** - Iterates through all accessible subscriptions
- ✅ **vCPU Focused** - Filters to only compute-related quotas (vCPUs, Virtual Machines, Availability Sets, etc.)
- ✅ **HTML Report** - Generates an interactive HTML report with:
  - Tenant name and ID display
  - Aggregated SKU usage across all subscriptions
  - Visual progress bars with colour-coded usage levels
  - Expandable dropdowns showing per-subscription breakdown
  - Search/filter functionality
  - Sortable columns
- ✅ **High Usage Alerts** - Highlights quotas at 80%+ usage in both console and report
- ✅ **Error Handling** - Comprehensive try-catch blocks with informative error messages

## Prerequisites

- **PowerShell Core 7+** (recommended) or **PowerShell 5.1+**
- **Azure PowerShell Modules**:
  - `Az.Accounts`
  - `Az.Compute`

### Install Azure PowerShell Modules

```powershell
Install-Module -Name Az.Accounts -Scope CurrentUser -Repository PSGallery -Force
Install-Module -Name Az.Compute -Scope CurrentUser -Repository PSGallery -Force
```

## Usage

```powershell
# Run the script
./quotafinder.ps1

# Or with PowerShell Core explicitly
pwsh -File ./quotafinder.ps1
```

The script will:
1. Check for an existing Azure session (or prompt for device code authentication)
2. Retrieve all subscriptions in your tenant
3. Query VM quotas for UK South region across all subscriptions
4. Display results in the console
5. Generate `VMQuotaReport.html` in the script directory

## Configuration

To change the target region, modify the `$targetLocation` variable in the script:

```powershell
$targetLocation = "uksouth"  # Change to your desired region
```

## Output

### Console Output

```
SubscriptionName    SubscriptionId                       Location  ResourceType                CurrentUsage  Limit  UsagePercentage
----------------    --------------                       --------  ------------                ------------  -----  ---------------
Production-Sub-001  xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx uksouth   Total Regional vCPUs        442           475    93.05
Production-Sub-002  yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy uksouth   Standard FSv2 Family vCPUs  512           520    98.46

Quotas with usage over 80%:
...
```

### HTML Report

The HTML report (`VMQuotaReport.html`) includes:

| Section | Description |
|---------|-------------|
| **Header** | Tenant name, tenant ID, region, report generation timestamp |
| **Summary Table** | All SKU families aggregated across subscriptions |
| **Progress Bars** | Visual usage indicators (green < 50%, yellow 50-80%, red ≥ 80%) |
| **Expandable Rows** | Click any row to see which subscriptions contribute to that SKU's usage |
| **Search Box** | Filter results by SKU name |

## Report Fields

| Field | Description |
|-------|-------------|
| SKU Name | VM family quota type (e.g., "Standard DSv5 Family vCPUs") |
| Total Used | Sum of current usage across all subscriptions |
| Total Limit | Sum of quota limits across all subscriptions |
| Usage % | Percentage of total quota consumed |
| Subscriptions | Number of subscriptions with this quota allocated |

## Quota Types Included

The script filters to include only compute-related quotas:
- Total Regional vCPUs
- Total Regional Low-priority vCPUs
- Virtual Machines
- Availability Sets
- Dedicated vCPUs
- All VM Family vCPUs (DSv5, FSv2, NCASv3_T4, etc.)

## Permissions Required

The account running this script needs:

- **Reader** role on all subscriptions to be queried
- Or specifically: `Microsoft.Compute/locations/usages/read` permission

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No subscriptions found" | Ensure you're authenticated and have access to subscriptions |
| "Failed to import Az modules" | Run the Install-Module commands above |
| Device code not appearing | Check the terminal output for the authentication URL and code |
| Some subscriptions skipped | Check you have Reader access to those subscriptions |
| Report shows 0 for some SKUs | Those SKU families have no quota allocated in the region |

## Customisation

### Change Threshold for High Usage Alerts

Find and modify this line in the script:

```powershell
$highUsage = $quotaResults | Where-Object { $_.UsagePercentage -ge 80 }
```

### Add Additional Regions

Modify the script to loop through multiple regions or accept a parameter.

## License

Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
