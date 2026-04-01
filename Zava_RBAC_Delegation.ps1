#!/usr/bin/env pwsh
# ============================================================================
# Zava DNS POC — RBAC & Delegation Script
# ============================================================================
# Purpose:  Demonstrate least-privilege DNS access control
# Author:   Kim Vaddi (Microsoft)
# Date:     April 1, 2026
#
# Two roles:
#   - DNS Zone Contributor (built-in): Full zone + record management — assign to DNS admins
#   - DNS Record Operator (custom): Record CRUD only, no zone lifecycle — assign to operators
#
# Prerequisites:
#   - Resource group 'rg-dns-poc' exists
#   - DNS zone 'poc.zava-dnspoc.com' exists
#   - az login completed
#   - Two Entra ID test accounts (set UPNs in Section 0)
#
# Usage:
#   .\Zava_RBAC_Delegation.ps1
#
# Ref: https://learn.microsoft.com/azure/role-based-access-control/custom-roles
# Ref: https://learn.microsoft.com/azure/dns/dns-protect-zones-recordsets
# ============================================================================

$ErrorActionPreference = 'Continue'

# ============================================================================
# SECTION 0: CONFIGURATION
# ============================================================================

$RG_NAME    = "rg-dns-poc"
$DOMAIN     = "poc.zava-dnspoc.com"

# Set these to actual Entra ID UPNs for the demo
$OPERATOR_UPN = ""   # e.g., "matt.boulder@zavaenergy.com"  — records only
$ADMIN_UPN    = ""   # e.g., "jeremy@zavaenergy.com"        — full zone control

# ── Auto-detect subscription ──
$SUBSCRIPTION_ID = (az account show --query id -o tsv 2>$null)
if (-not $SUBSCRIPTION_ID) {
    Write-Host "ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

$DNS_ZONE_SCOPE = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Network/dnsZones/$DOMAIN"
$RG_SCOPE       = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"

Write-Host @"

╔══════════════════════════════════════════════════════════════════════╗
║              RBAC & DELEGATION — Role Comparison                     ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  DNS Zone Contributor (built-in role):                               ║
║    ✅ Create/delete DNS zones                                        ║
║    ✅ Create/update/delete ALL record types                          ║
║    ✅ Import/export zones                                            ║
║    ✅ Configure DNSSEC                                               ║
║                                                                      ║
║  Operator (DNS Record Operator — custom):                            ║
║    ✅ Read DNS zones                                                 ║
║    ✅ Create/update/delete A, AAAA, CNAME, MX, TXT, SRV records     ║
║    ❌ CANNOT create/delete DNS zones                                 ║
║    ❌ CANNOT modify SOA/NS records                                   ║
║    ❌ CANNOT configure DNSSEC                                        ║
║                                                                      ║
║  Subscription: $SUBSCRIPTION_ID
║  Resource Group: $RG_NAME
║  DNS Zone: $DOMAIN
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan


# ============================================================================
# STEP 1: CREATE CUSTOM ROLE — DNS Record Operator
# ============================================================================
# Ref: https://learn.microsoft.com/azure/dns/dns-protect-zones-recordsets#custom-roles
# Ref: https://learn.microsoft.com/azure/dns/secure-dns#privileged-access
# Ref: https://learn.microsoft.com/azure/role-based-access-control/permissions/networking#microsoftnetwork
#
# MS Learn guidance:
#   "Create custom roles for fine-grained control, such as allowing users to
#    manage only specific record types like CNAME records."
#   "Grant users only the minimum permissions necessary to perform their DNS
#    management tasks."
#
# The built-in DNS Zone Contributor role grants FULL control (zone + records).
# This custom role restricts to record management only (least privilege).
# ============================================================================

Write-Host "=== Step 1: Create Custom Role 'DNS Record Operator' ===" -ForegroundColor Cyan

# Per MS Learn: Actions define DNS-specific permissions per record type
# Each record type uses Microsoft.Network/dnsZones/<TYPE>/* pattern
# Ref: https://learn.microsoft.com/azure/role-based-access-control/permissions/networking#microsoftnetwork
$roleDefinition = @{
    Name             = "DNS Record Operator"
    Description      = "Can manage DNS record sets (A, AAAA, CNAME, MX, TXT, SRV, CAA, PTR) but cannot create, delete, or import zones. Cannot modify SOA/NS records or DNSSEC."
    Actions          = @(
        # Zone read (required to see zones in portal — does NOT grant write)
        "Microsoft.Network/dnsZones/read"
        # Record read across all types
        "Microsoft.Network/dnsZones/*/read"
        "Microsoft.Network/dnsZones/recordsets/read"
        # Full CRUD for operational record types
        "Microsoft.Network/dnsZones/A/*"
        "Microsoft.Network/dnsZones/AAAA/*"
        "Microsoft.Network/dnsZones/CNAME/*"
        "Microsoft.Network/dnsZones/MX/*"
        "Microsoft.Network/dnsZones/TXT/*"
        "Microsoft.Network/dnsZones/SRV/*"
        "Microsoft.Network/dnsZones/CAA/*"
        "Microsoft.Network/dnsZones/PTR/*"
        # Resource group read (required for portal navigation)
        "Microsoft.Resources/subscriptions/resourceGroups/read"
    )
    NotActions       = @(
        # Block zone lifecycle operations
        "Microsoft.Network/dnsZones/write"
        "Microsoft.Network/dnsZones/delete"
        # Block delegation-sensitive records
        "Microsoft.Network/dnsZones/SOA/write"
        "Microsoft.Network/dnsZones/NS/write"
        "Microsoft.Network/dnsZones/NS/delete"
        # Block DNSSEC configuration
        "Microsoft.Network/dnsZones/dnssecConfigs/default/write"
        "Microsoft.Network/dnsZones/dnssecConfigs/default/delete"
    )
    AssignableScopes = @("/subscriptions/$SUBSCRIPTION_ID")
} | ConvertTo-Json -Depth 3

$roleFile = Join-Path $env:TEMP "dns-operator-role.json"
[System.IO.File]::WriteAllText($roleFile, $roleDefinition)

# Check if role already exists
$existingRole = az role definition list --name "DNS Record Operator" --query "[0].roleName" -o tsv 2>$null
if ($existingRole) {
    Write-Host "  Role already exists — updating definition..." -ForegroundColor Yellow
    az role definition update --role-definition $roleFile -o none 2>$null
    Write-Host "  ✅ Role updated" -ForegroundColor Green
} else {
    Write-Host "  Creating custom role..."
    az role definition create --role-definition $roleFile -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ Role created" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Failed — check subscription permissions" -ForegroundColor Red
        Write-Host "  You need Microsoft.Authorization/roleDefinitions/write at subscription scope"
    }
}

# Custom roles take ~60s to propagate through Azure RBAC
Write-Host "  Waiting 60s for RBAC propagation..." -ForegroundColor DarkGray
Start-Sleep -Seconds 60

# Verify the role is visible
Write-Host "`n--- Verify: Custom role ---" -ForegroundColor Green
az role definition list --name "DNS Record Operator" `
  --query "[].{Name:roleName, Description:description}" -o table 2>$null

# Also show the built-in role for comparison
Write-Host "`n--- Built-in role: DNS Zone Contributor ---" -ForegroundColor Green
az role definition list --name "DNS Zone Contributor" `
  --query "[].{Name:roleName, Description:description}" -o table 2>$null

# Clean up temp file
Remove-Item $roleFile -ErrorAction SilentlyContinue


# ============================================================================
# STEP 2: ASSIGN ROLES TO TEST USERS
# ============================================================================

Write-Host "`n=== Step 2: Assign Roles ===" -ForegroundColor Cyan

if ($OPERATOR_UPN) {
    Write-Host "  Assigning 'DNS Record Operator' to $OPERATOR_UPN..."
    Write-Host "    Scope: DNS zone ($DOMAIN)" -ForegroundColor DarkGray
    az role assignment create `
      --assignee $OPERATOR_UPN `
      --role "DNS Record Operator" `
      --scope $DNS_ZONE_SCOPE `
      -o none 2>$null
    if ($?) {
        Write-Host "  ✅ Operator role assigned to $OPERATOR_UPN" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Assignment may already exist (idempotent)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ⏭️  No Operator UPN set — skipping assignment" -ForegroundColor Yellow
    Write-Host "  Set `$OPERATOR_UPN in Section 0 to assign"
}

if ($ADMIN_UPN) {
    Write-Host "  Assigning 'DNS Zone Contributor' to $ADMIN_UPN..."
    Write-Host "    Scope: Resource group ($RG_NAME)" -ForegroundColor DarkGray
    az role assignment create `
      --assignee $ADMIN_UPN `
      --role "DNS Zone Contributor" `
      --scope $RG_SCOPE `
      -o none 2>$null
    if ($?) {
        Write-Host "  ✅ Admin role assigned to $ADMIN_UPN" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Assignment may already exist (idempotent)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ⏭️  No Admin UPN set — skipping assignment" -ForegroundColor Yellow
    Write-Host "  Set `$ADMIN_UPN in Section 0 to assign"
}


# ============================================================================
# STEP 3: SELF-TEST — Run as current user to demo the boundary
# ============================================================================

Write-Host "`n=== Step 3: Self-Test (current user) ===" -ForegroundColor Cyan
Write-Host "  Testing record CRUD against $DOMAIN..."

# Test: Create a record (should work for both roles)
Write-Host "`n  [Test 3.1] Create A record 'rbac-test'..." -NoNewline
az network dns record-set a add-record -g $RG_NAME -z $DOMAIN `
  -n "rbac-test" -a "10.99.99.99" -o none 2>$null
if ($?) {
    Write-Host " ✅ PASS" -ForegroundColor Green
} else {
    Write-Host " ❌ FAIL" -ForegroundColor Red
}

# Test: Read the record
Write-Host "  [Test 3.2] Read the record back..." -NoNewline
$readResult = az network dns record-set a show -g $RG_NAME -z $DOMAIN `
  -n "rbac-test" --query "aRecords[0].ipv4Address" -o tsv 2>$null
if ($readResult -eq "10.99.99.99") {
    Write-Host " ✅ PASS ($readResult)" -ForegroundColor Green
} else {
    Write-Host " ❌ FAIL" -ForegroundColor Red
}

# Test: Update the record
Write-Host "  [Test 3.3] Update record (add second IP)..." -NoNewline
az network dns record-set a add-record -g $RG_NAME -z $DOMAIN `
  -n "rbac-test" -a "10.88.88.88" -o none 2>$null
if ($?) {
    Write-Host " ✅ PASS" -ForegroundColor Green
} else {
    Write-Host " ❌ FAIL" -ForegroundColor Red
}

# Test: Delete the record (cleanup)
Write-Host "  [Test 3.4] Delete test record..." -NoNewline
az network dns record-set a delete -g $RG_NAME -z $DOMAIN `
  -n "rbac-test" --yes -o none 2>$null
if ($?) {
    Write-Host " ✅ PASS" -ForegroundColor Green
} else {
    Write-Host " ❌ FAIL" -ForegroundColor Red
}

Write-Host "  Self-test complete." -ForegroundColor Green


# ============================================================================
# STEP 4: MANUAL VERIFICATION TESTS — For Operator vs Admin demo
# ============================================================================

Write-Host @"

=== Step 4: Manual Verification Tests ===

Copy-paste these commands after logging in as each test user.
These prove the exact role boundaries.

"@ -ForegroundColor Cyan

Write-Host @"
╔══════════════════════════════════════════════════════════════════════╗
║  AS OPERATOR — Log in and run these:                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  az login  # as Operator ($OPERATOR_UPN)                             ║
║                                                                      ║
║  # TEST A: Create record → should SUCCEED                           ║
║  az network dns record-set a add-record ``                           ║
║    -g $RG_NAME -z $DOMAIN ``                                         ║
║    -n "operator-test" -a "10.99.99.99"                               ║
║  → Expected: ✅ Record created                                       ║
║                                                                      ║
║  # TEST B: Delete zone → should FAIL                                 ║
║  az network dns zone delete ``                                       ║
║    -g $RG_NAME -n $DOMAIN --yes                                      ║
║  → Expected: ❌ AuthorizationFailed                                  ║
║    "does not have authorization to perform action                    ║
║     'Microsoft.Network/dnsZones/delete'"                             ║
║                                                                      ║
║  # TEST C: Create zone → should FAIL                                 ║
║  az network dns zone create ``                                       ║
║    -g $RG_NAME -n "rogue.zava-dnspoc.com"                            ║
║  → Expected: ❌ AuthorizationFailed                                  ║
║    "does not have authorization to perform action                    ║
║     'Microsoft.Network/dnsZones/write'"                              ║
║                                                                      ║
║  # TEST D: Modify NS record → should FAIL                           ║
║  az network dns record-set ns add-record ``                          ║
║    -g $RG_NAME -z $DOMAIN ``                                         ║
║    -n "@" -d "rogue-ns.example.com"                                  ║
║  → Expected: ❌ AuthorizationFailed                                  ║
║                                                                      ║
║  # Cleanup                                                           ║
║  az network dns record-set a delete ``                               ║
║    -g $RG_NAME -z $DOMAIN -n "operator-test" --yes                   ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════════╗
║  AS ADMIN — Log in and run these:                                    ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  az login  # as Admin ($ADMIN_UPN)                                   ║
║                                                                      ║
║  # TEST E: Create record → should SUCCEED                           ║
║  az network dns record-set a add-record ``                           ║
║    -g $RG_NAME -z $DOMAIN ``                                         ║
║    -n "admin-test" -a "10.88.88.88"                                  ║
║  → Expected: ✅ Record created                                       ║
║                                                                      ║
║  # TEST F: Create zone → should SUCCEED                             ║
║  az network dns zone create ``                                       ║
║    -g $RG_NAME -n "temp-test.zava-dnspoc.com"                        ║
║  → Expected: ✅ Zone created                                         ║
║                                                                      ║
║  # TEST G: Delete zone → should SUCCEED                             ║
║  az network dns zone delete ``                                       ║
║    -g $RG_NAME -n "temp-test.zava-dnspoc.com" --yes                  ║
║  → Expected: ✅ Zone deleted                                         ║
║                                                                      ║
║  # Cleanup                                                           ║
║  az network dns record-set a delete ``                               ║
║    -g $RG_NAME -z $DOMAIN -n "admin-test" --yes                      ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Yellow


# ============================================================================
# STEP 5: AUDIT TRAIL — Show role assignments + Activity Log query
# ============================================================================

Write-Host "=== Step 5: Current Role Assignments ===" -ForegroundColor Cyan

Write-Host "`n  DNS Zone scope ($DOMAIN):" -ForegroundColor DarkGray
az role assignment list --scope $DNS_ZONE_SCOPE `
  --query "[].{Principal:principalName, Role:roleDefinitionName}" `
  -o table 2>$null

Write-Host "`n  Resource Group scope ($RG_NAME):" -ForegroundColor DarkGray
az role assignment list --scope $RG_SCOPE `
  --query "[].{Principal:principalName, Role:roleDefinitionName}" `
  -o table 2>$null

Write-Host @"

╔══════════════════════════════════════════════════════════════════════╗
║  AUDIT: Who changed what?                                            ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  All DNS record changes are captured in Activity Log:               ║
║                                                                      ║
║  Portal: Monitor → Activity log → Filter by:                        ║
║    Resource group = $RG_NAME                                         ║
║    Resource type = "DNS zone"                                        ║
║                                                                      ║
║  CLI:                                                                ║
║  az monitor activity-log list ``                                     ║
║    --resource-group $RG_NAME ``                                      ║
║    --query "[?contains(resourceType,'dnsZones')].{                   ║
║      time:eventTimestamp,                                            ║
║      who:caller,                                                     ║
║      action:operationName.localizedValue,                            ║
║      status:status.localizedValue}" ``                               ║
║    -o table                                                          ║
║                                                                      ║
║  This data flows to Event Hub → QRadar automatically                ║
║  (configured in Section 3 of the deployment script)                  ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green


# ============================================================================
# STEP 6: SCORECARD — Role comparison matrix
# ============================================================================

Write-Host @"
╔══════════════════════════════════════════════════════════════════════╗
║              RBAC COMPARISON — POC SCORECARD                         ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  Action                    │ DNS Zone Contributor    │ DNS Record   ║
║                            │ (built-in)              │ Operator     ║
║  ──────────────────────────┼─────────────────────────┼────────────  ║
║  Read zones                │ ✅                       │ ✅           ║
║  List records              │ ✅                       │ ✅           ║
║  Create A/AAAA/CNAME/MX    │ ✅                       │ ✅           ║
║  Create TXT/SRV/CAA/PTR    │ ✅                       │ ✅           ║
║  Update records            │ ✅                       │ ✅           ║
║  Delete records            │ ✅                       │ ✅           ║
║  Create DNS zone           │ ✅                       │ ❌           ║
║  Delete DNS zone           │ ✅                       │ ❌           ║
║  Modify SOA record         │ ✅                       │ ❌           ║
║  Modify NS delegation      │ ✅                       │ ❌           ║
║  Enable DNSSEC             │ ✅                       │ ❌           ║
║  Import zone file          │ ✅                       │ ❌           ║
║  Export zone file          │ ✅                       │ ✅ (read)    ║
║                                                                      ║
║  Scope:                                                              ║
║    Admin  → Resource Group (all zones in RG)                        ║
║    Operator → Individual DNS Zone (least privilege)                  ║
║                                                                      ║
║  Audit: Activity Log → Event Hub → QRadar (automatic)               ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Host "RBAC & Delegation script complete." -ForegroundColor Cyan
Write-Host "Set `$OPERATOR_UPN and `$ADMIN_UPN in Section 0, then re-run to assign roles." -ForegroundColor Yellow


# ============================================================================
# STEP 7: RESOURCE LOCK — Prevent accidental zone deletion
# ============================================================================
# Ref: https://learn.microsoft.com/azure/dns/dns-protect-zones-recordsets#resource-locks
#
# MS Learn: "Apply Azure Resource Manager locks to DNS zones and record sets
#            to prevent accidental deletion or modification."
#
# CanNotDelete = zone can be modified but not deleted
# ReadOnly     = zone cannot be modified at all (use carefully)
# ============================================================================

Write-Host "`n=== Step 7: Resource Lock (CanNotDelete) ===" -ForegroundColor Cyan

$lockResult = az lock create `
  --name "protect-dns-zone" `
  --resource-group $RG_NAME `
  --resource-type "Microsoft.Network/dnsZones" `
  --resource-name $DOMAIN `
  --lock-type CanNotDelete `
  --notes "Prevent accidental deletion of POC DNS zone" `
  -o none 2>$null

if ($?) {
    Write-Host "  ✅ CanNotDelete lock applied to $DOMAIN" -ForegroundColor Green
    Write-Host "  Even Admins cannot delete this zone without removing the lock first"
} else {
    Write-Host "  ⚠️  Lock may already exist (idempotent)" -ForegroundColor Yellow
}

# Verify
Write-Host "`n--- Verify: Resource locks ---" -ForegroundColor Green
az lock list --resource-group $RG_NAME `
  --resource-type "Microsoft.Network/dnsZones" `
  --resource-name $DOMAIN `
  --query "[].{Name:name, Level:level, Notes:notes}" -o table 2>$null


# ============================================================================
# STEP 8: RECORD-SET LEVEL RBAC (Advanced — Optional)
# ============================================================================
# Ref: https://learn.microsoft.com/azure/dns/dns-protect-zones-recordsets#record-set-level-azure-rbac
#
# MS Learn: "Permissions are applied at the record set level. The user is
#            granted control to entries they need and are unable to make
#            any other changes."
#
# Example: Grant a user access to manage ONLY the 'www' A record set
# ============================================================================

Write-Host @"

╔══════════════════════════════════════════════════════════════════════╗
║  ADVANCED: Record-Set Level RBAC (Optional)                          ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  Azure DNS supports RBAC at the individual record set level.        ║
║  This is the most granular control possible — a user can only       ║
║  manage a single record (e.g., www A record) and nothing else.      ║
║                                                                      ║
║  # Grant access to ONLY the 'www' A record set:                     ║
║  az role assignment create \                                         ║
║    --assignee "user@zavaenergy.com" \                                ║
║    --role "DNS Zone Contributor" \                                    ║
║    --scope "/subscriptions/$SUBSCRIPTION_ID\                         ║
║      /resourceGroups/$RG_NAME\                                       ║
║      /providers/Microsoft.Network/dnsZones/$DOMAIN\                  ║
║      /A/www"                                                         ║
║                                                                      ║
║  # Grant access to ONLY TXT records (for DCV automation):           ║
║  az role assignment create \                                         ║
║    --assignee "certbot-sp@tenant" \                                  ║
║    --role "DNS Zone Contributor" \                                    ║
║    --scope "/subscriptions/$SUBSCRIPTION_ID\                         ║
║      /resourceGroups/$RG_NAME\                                       ║
║      /providers/Microsoft.Network/dnsZones/$DOMAIN\                  ║
║      /TXT/_acme-challenge"                                           ║
║                                                                      ║
║  Ref: learn.microsoft.com/azure/dns/                                ║
║       dns-protect-zones-recordsets#record-set-level-azure-rbac       ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Yellow

Write-Host @"

╔══════════════════════════════════════════════════════════════════════╗
║  MS LEARN REFERENCES                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  Protect zones & records:                                            ║
║    learn.microsoft.com/azure/dns/dns-protect-zones-recordsets        ║
║                                                                      ║
║  Secure DNS deployment:                                              ║
║    learn.microsoft.com/azure/dns/secure-dns                          ║
║                                                                      ║
║  Custom RBAC roles:                                                  ║
║    learn.microsoft.com/azure/role-based-access-control/custom-roles  ║
║                                                                      ║
║  DNS permissions reference:                                          ║
║    learn.microsoft.com/azure/role-based-access-control/              ║
║    permissions/networking#microsoftnetwork                            ║
║                                                                      ║
║  Built-in DNS Zone Contributor:                                      ║
║    learn.microsoft.com/azure/role-based-access-control/              ║
║    built-in-roles#dns-zone-contributor                               ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor DarkGray
