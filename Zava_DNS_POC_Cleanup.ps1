###############################################################################
# Azure DNS POC — CLEANUP Script (PowerShell / Azure CLI)
#
# Purpose: Remove the DNS POC resource group deployed by infrastructure\deploy.ps1
# Author:  Kim Vaddi (Microsoft)
# Updated: April 10, 2026
#
# USAGE:
#   .\Zava_DNS_POC_Cleanup.ps1
#
# WARNING: This is IRREVERSIBLE.
###############################################################################

$ErrorActionPreference = "Continue"

# ============================================================================
# CONFIGURATION — Auto-detected from latest deployment output JSON
# ============================================================================

$RG_NAME = ""

# Find the latest deployment output file and read the resource group name
$candidates = Get-ChildItem -Path $PSScriptRoot -Filter "deployment-outputs-*.json" |
              Sort-Object LastWriteTime -Descending
if (-not $candidates) {
    $candidates = Get-ChildItem -Path "$PSScriptRoot\infrastructure" -Filter "deployment-outputs-*.json" `
                  -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
}
if ($candidates) {
    $outputs = Get-Content $candidates[0].FullName -Raw | ConvertFrom-Json
    $RG_NAME = $outputs.resourceGroupName.value
    Write-Host "Detected resource group: $RG_NAME (from $($candidates[0].Name))" -ForegroundColor Cyan
}

if (-not $RG_NAME) {
    $RG_NAME = Read-Host "Could not detect resource group name. Enter it manually"
}

# ============================================================================
# CONFIRM BEFORE PROCEEDING
# ============================================================================

Write-Host "`nThis will PERMANENTLY DELETE resource group '$RG_NAME' and all resources inside it." -ForegroundColor Red
$confirm = Read-Host "Type 'DELETE' to confirm (anything else cancels)"
if ($confirm -ne "DELETE") {
    Write-Host "Cleanup cancelled." -ForegroundColor Yellow
    return
}

# ============================================================================
# REMOVE RESOURCE LOCKS (required before deletion)
# ============================================================================

Write-Host "`nChecking for resource locks on '$RG_NAME'..." -ForegroundColor Yellow
$locks = az lock list --resource-group $RG_NAME --query "[].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
if ($locks) {
    foreach ($lock in $locks) {
        Write-Host "  Removing lock: $($lock.name)"
        az lock delete --ids $lock.id -o none 2>$null
    }
    Write-Host "  All locks removed." -ForegroundColor Green
} else {
    Write-Host "  No locks found." -ForegroundColor Green
}

# ============================================================================
# DELETE RESOURCE GROUP
# ============================================================================

Write-Host "`nDeleting resource group '$RG_NAME'..." -ForegroundColor Yellow
az group delete --name $RG_NAME --yes --no-wait

Write-Host "Deletion initiated. This runs in the background and takes 2-5 minutes." -ForegroundColor Green
Write-Host "Check status: az group exists --name $RG_NAME"
