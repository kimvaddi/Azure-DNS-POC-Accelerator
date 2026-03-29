###############################################################################
# Azure DNS POC — CLEANUP Script (PowerShell / Azure CLI)
#
# Purpose: Tear down ALL resources deployed by Zava_DNS_POC_Deployment.ps1
# Author:  Kim Vaddi (Microsoft)
# Date:    March 27, 2026
#
# WHEN TO RUN:
#   - After POC is complete and results documented
#   - After go/no-go decision by Charles Mylak
#   - When you want to stop incurring costs ($11/mo Event Hub + ~$30/mo web apps)
#
# WHAT THIS DELETES:
#   - Resource Group (rg-dns-poc) and ALL resources inside it
#   - DNSSEC configuration (must be removed before zone can be deleted)
#   - Resource locks (must be removed before RG can be deleted)
#   - Custom RBAC role (DNS Record Operator)
#   - Subscription-level diagnostic settings (Activity Log → Event Hub)
#   - RBAC role assignments on Event Hub
#   - Zone snapshot files are LOCAL — not deleted by this script
#
# WHAT THIS DOES NOT DELETE:
#   - NS delegation records at the registrar (customer must remove manually)
#   - QRadar log source configuration (customer must remove manually)
#   - Local files (zone exports, role JSON, sample Bind file)
#   - The subscription itself
#
# WARNING: This is IRREVERSIBLE. All DNS records, zones, web apps, logs,
#          and configuration will be permanently deleted.
#
# USAGE:
#   1. Review each step below
#   2. Run the script in PowerShell
#   3. Confirm when prompted
###############################################################################


# ============================================================================
# CONFIGURATION — Must match the deployment script values
# ============================================================================

$RG_NAME           = "rg-dns-poc"
$DOMAIN            = "zava-dnspoc-001.com"  # Set to the domain purchased by deploy.ps1
$PRIVATE_ZONE      = "poc-internal.zava.local"  # Private DNS zone
$SUBSCRIPTION_ID   = "<your-subscription-id>"  # Must match the subscription used during deployment
$_UNIQUE_SUFFIX    = $SUBSCRIPTION_ID.Substring($SUBSCRIPTION_ID.Length - 4)
$EH_NAMESPACE      = "ehns-dns-poc-$_UNIQUE_SUFFIX"  # Must match deployment

# ============================================================================
# STEP 1: CONFIRM BEFORE PROCEEDING
# ============================================================================

Write-Host @"

╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║   AZURE DNS POC CLEANUP                                              ║
║                                                                      ║
║   This will PERMANENTLY DELETE all POC resources:                    ║
║                                                                      ║
║   Resource Group:     $RG_NAME                                       ║
║   DNS Zone:           $DOMAIN                                        ║
║   Private Zone:       $PRIVATE_ZONE                                  ║
║   Traffic Managers:   tm-poc-failover, tm-poc-geo, tm-poc-weighted   ║
║   Web Apps:           webapp-poc-us, webapp-poc-uk                   ║
║   Event Hub:          $EH_NAMESPACE                                  ║
║   Log Analytics:      law-dns-poc                                    ║
║   Storage:            stqradarpoc*                                   ║
║   VNet:               vnet-dns-poc                                   ║
║   Custom RBAC Role:   DNS Record Operator                            ║
║   DNSSEC:             Zone signing removed                           ║
║                                                                      ║
║   This action is IRREVERSIBLE.                                       ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Red

$confirm = Read-Host "Type 'DELETE' to confirm cleanup (anything else to cancel)"
if ($confirm -ne "DELETE") {
    Write-Host "Cleanup cancelled." -ForegroundColor Yellow
    return
}

Write-Host "`n=== CLEANUP STARTING ===" -ForegroundColor Red

# ============================================================================
# STEP 2: REMOVE DNSSEC (must be done BEFORE zone deletion)
# ============================================================================

Write-Host "--- Step 2: Removing DNSSEC zone signing ---"
az network dns dnssec-config delete `
  -g $RG_NAME -z $DOMAIN --yes -o none 2>$null
Write-Host "  DNSSEC removed (or was not configured)"

# ============================================================================
# STEP 3: REMOVE RESOURCE LOCKS (must be done BEFORE RG deletion)
# ============================================================================

Write-Host "--- Step 3: Removing resource locks ---"
$locks = az lock list --resource-group $RG_NAME --query "[].name" -o tsv 2>$null
if ($locks) {
    foreach ($lockName in $locks) {
        az lock delete --name $lockName --resource-group $RG_NAME -o none
        Write-Host "  Deleted lock: $lockName"
    }
} else {
    Write-Host "  No locks found"
}

# ============================================================================
# STEP 4: REMOVE SUBSCRIPTION-LEVEL DIAGNOSTIC SETTINGS
# These live at the subscription level, NOT inside the RG — won't be
# deleted by az group delete.
# ============================================================================

Write-Host "--- Step 4: Removing subscription-level diagnostic settings ---"
az monitor diagnostic-settings subscription delete `
  --name "activity-log-to-eh-and-law" -o none 2>$null
Write-Host "  Removed: activity-log-to-eh-and-law"

# ============================================================================
# STEP 5: REMOVE RBAC ROLE ASSIGNMENTS ON EVENT HUB
# Must be done before deleting the Event Hub namespace, otherwise
# the assignments become orphaned.
# ============================================================================

Write-Host "--- Step 5: Removing Event Hub RBAC role assignments ---"
$EH_NS_ID = (az eventhubs namespace show -g $RG_NAME -n $EH_NAMESPACE --query "id" -o tsv 2>$null)
if ($EH_NS_ID) {
    $assignments = az role assignment list --scope $EH_NS_ID `
      --query "[?contains(roleDefinitionName,'Event Hubs')].id" -o tsv 2>$null
    if ($assignments) {
        foreach ($id in $assignments) {
            az role assignment delete --ids $id -o none 2>$null
        }
        Write-Host "  Event Hub RBAC assignments removed"
    } else {
        Write-Host "  No Event Hub RBAC assignments found"
    }
} else {
    Write-Host "  Event Hub namespace not found — skipping"
}

# ============================================================================
# STEP 6: REMOVE CUSTOM RBAC ROLE DEFINITION
# Must be done AFTER removing role assignments that use it.
# The role is scoped to the RG, but the definition is subscription-level.
# ============================================================================

Write-Host "--- Step 6: Removing custom RBAC role 'DNS Record Operator' ---"
az role definition delete --name "DNS Record Operator" -o none 2>$null
if ($?) {
    Write-Host "  Custom role 'DNS Record Operator' deleted"
} else {
    Write-Host "  Role not found or already deleted"
}

# ============================================================================
# STEP 7: DELETE THE RESOURCE GROUP (and everything inside it)
# This deletes: DNS zones, TM profiles, web apps, ASPs, Event Hub,
# LAW, VNet, storage accounts, private DNS zones, NSGs, etc.
# ============================================================================

Write-Host "--- Step 7: Deleting resource group $RG_NAME ---"
Write-Host "  This may take 2-5 minutes..." -ForegroundColor Yellow
az group delete --name $RG_NAME --yes --no-wait
Write-Host "  Resource group deletion initiated (running in background)"

# ============================================================================
# STEP 8: VERIFY CLEANUP + REMIND ABOUT MANUAL STEPS
# ============================================================================

Write-Host @"

=== CLEANUP INITIATED ===

Azure resources:
  Resource group '$RG_NAME' deletion is running in background.
  Check status: az group exists --name $RG_NAME

  Resources deleted by this script:
    ✅ DNSSEC signing removed
    ✅ Resource locks removed
    ✅ Subscription diagnostic settings removed
    ✅ Event Hub RBAC assignments removed
    ✅ Custom RBAC role 'DNS Record Operator' removed
    ✅ Resource group deletion initiated (2-5 min)

MANUAL STEPS (customer must do):

  1. REGISTRAR: Remove NS delegation records for 'poc' at your registrar
     (GoDaddy/Namecheap: delete the NS records pointing to azure-dns.com)

  2. QRADAR: Remove the Azure Event Hub log source in QRadar Console
     (Admin → Log Sources → delete the poc Event Hub source)

  3. LOCAL FILES: Optionally delete these local files:
     - .\dns-operator-role.json
     - .\sample-bind-zone.txt
     - .\snapshot-*.zone
     - .\Zava_DNS_POC_Deployment.ps1 (keep for reference/reuse)

  4. VERIFY: After 5 minutes, confirm cleanup:
     az group exists --name $RG_NAME
     Expected: false

"@ -ForegroundColor Green

# ============================================================================
# OPTIONAL: WAIT FOR DELETION TO COMPLETE
# Uncomment to block until the RG is fully deleted.
# ============================================================================

# Write-Host "Waiting for resource group deletion to complete..."
# az group wait --name $RG_NAME --deleted --timeout 600
# Write-Host "Resource group $RG_NAME fully deleted." -ForegroundColor Green
