#!/usr/bin/env bash
# ============================================================================
# Zava — Azure DNS POC Runbook
# ============================================================================
# Copy-paste scripts for every POC workstream.
# Designed for Jeremy, Mike & Matt to execute independently.
#
# SIEM: IBM QRadar (via Event Hub)
# Certificate Authority: DigiCert CertCentral (DCV uses _dnsauth TXT records)
# DNSSEC: Optional / Nice-to-have
#
# Sections:
#   0  - Configuration (SET THESE FIRST)
#   1  - Environment Setup
#   2  - Zone Import from Bind (Zone Migration)
#   3  - Bind Parity Validation
#   4  - RBAC & Delegation
#   5  - Automated Record Creation + DigiCert DCV
#   6  - DNS Query Logging → QRadar SIEM
#   7  - Zone Snapshots (Point-in-Time Export)
#   8  - Reporting (Azure Monitor Workbooks)
#   9  - DNS Record Failover (Traffic Manager Priority)
#   10 - Geographic DNS + Weighted Load Balancing (Optional)
#   11 - DNSSEC (Optional)
#   12 - Edge Case Testing
#   13 - Cleanup
#
# Prerequisites:
#   - Azure CLI installed (az --version >= 2.60)
#   - Logged in: az login
#   - Correct subscription set: az account set -s "<subscription-id>"
#   - Resource group rg-dns-poc exists in the enterprise landing zone
#
# Variables — SET THESE FIRST (Section 0)
# ============================================================================

# ============================================================================
# SECTION 0: CONFIGURATION — EDIT THESE BEFORE RUNNING ANYTHING
# ============================================================================

# -- Core settings --
SUBSCRIPTION_ID="<your-subscription-id>"          # Zava subscription
RESOURCE_GROUP="rg-dns-poc"                        # POC resource group
LOCATION="southcentralus"                          # Closest Azure region to Zava HQ (San Antonio)

# -- DNS settings --
PUBLIC_ZONE="poc.Zava.com"                       # Public DNS zone for POC
PRIVATE_ZONE="poc-internal.Zava.local"           # Private DNS zone for POC
VNET_NAME="<landing-zone-vnet-name>"               # Existing VNet in landing zone
VNET_RG="<vnet-resource-group>"                    # Resource group containing the VNet

# -- Bind zone files (local paths after export from Bind server) --
ZONE_FILE_1="./zone-files/Zava-zone1.zone"       # First Bind zone file
ZONE_FILE_2="./zone-files/Zava-zone2.zone"       # Second Bind zone file
ZONE_NAME_1="zone1.poc.Zava.com"                 # Azure zone name for file 1
ZONE_NAME_2="zone2.poc.Zava.com"                 # Azure zone name for file 2

# -- RBAC settings --
ADMIN_USER_OBJECT_ID="<admin-user-entra-object-id>"
OPERATOR_USER_OBJECT_ID="<operator-user-entra-object-id>"

# -- Logging / SIEM (IBM QRadar) --
EVENTHUB_NAMESPACE="ehns-dns-poc"                    # Event Hub namespace name
EVENTHUB_NAME="dns-logs"                     # Event Hub name
EVENTHUB_SKU="Standard"                               # Standard required for consumer groups + SAS policies
LOG_ANALYTICS_WORKSPACE="law-dns-poc"               # Log Analytics workspace for reporting

# -- Zone Snapshots --
SNAPSHOT_DIR="./zone-snapshots"                    # Directory to store zone export files

# -- Traffic Manager (Geo routing) --
TM_PROFILE_NAME="tm-poc-geo"
TM_DNS_NAME="tm-poc-geo"                       # Must be globally unique
US_ENDPOINT_IP="<us-endpoint-ip>"                  # US-facing IP
UK_ENDPOINT_IP="<uk-endpoint-ip>"                  # UK-facing IP

echo "============================================"
echo " Zava Azure DNS POC — Configuration Loaded"
echo "============================================"
echo " Subscription:  $SUBSCRIPTION_ID"
echo " Resource Group: $RESOURCE_GROUP"
echo " Location:       $LOCATION"
echo " Public Zone:    $PUBLIC_ZONE"
echo "============================================"


# ============================================================================
# SECTION 1: ENVIRONMENT SETUP (Day 1)
# ============================================================================

echo ""
echo "=== SECTION 1: Environment Setup ==="
echo ""

# 1.1 Set subscription
az account set --subscription "$SUBSCRIPTION_ID"

# 1.2 Verify resource group exists (should already be provisioned by platform team)
az group show --name "$RESOURCE_GROUP" --output table
# If it doesn't exist, create it:
# az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# 1.3 Create the public DNS zone
echo "Creating public DNS zone: $PUBLIC_ZONE"
az network dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --output table

# 1.4 Verify the zone was created — note the nameservers
echo "Zone nameservers (you'll need these for testing):"
az network dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --query "nameServers" \
  --output tsv


# ============================================================================
# SECTION 2: ZONE IMPORT FROM BIND (Day 1)
# ============================================================================

echo ""
echo "=== SECTION 2: Zone Import from Bind ==="
echo ""

# --------------------------------------------------------------------------
# STEP 2.0: PREPARE BIND ZONE FILES (run on the Bind server BEFORE this)
# --------------------------------------------------------------------------
# On your Bind server, export zones in RFC 1035 format:
#
#   named-checkzone Zava.com /etc/bind/zones/db.Zava.com > Zava-zone1.zone
#   named-checkzone internal.Zava.com /etc/bind/zones/db.internal > Zava-zone2.zone
#
# Copy the .zone files to this machine into ./zone-files/ directory.
# --------------------------------------------------------------------------

# 2.1 Create target zones for import
echo "Creating zone for import: $ZONE_NAME_1"
az network dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ZONE_NAME_1" \
  --output table

echo "Creating zone for import: $ZONE_NAME_2"
az network dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ZONE_NAME_2" \
  --output table

# 2.2 Import zone files
echo "Importing zone file 1..."
az network dns zone import \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ZONE_NAME_1" \
  --file-name "$ZONE_FILE_1"

echo "Importing zone file 2..."
az network dns zone import \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ZONE_NAME_2" \
  --file-name "$ZONE_FILE_2"

# 2.3 Verify record counts
echo ""
echo "Record count for $ZONE_NAME_1:"
az network dns record-set list \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$ZONE_NAME_1" \
  --query "length(@)" \
  --output tsv

echo "Record count for $ZONE_NAME_2:"
az network dns record-set list \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$ZONE_NAME_2" \
  --query "length(@)" \
  --output tsv

# 2.4 List all imported records (for visual inspection)
echo ""
echo "All records in $ZONE_NAME_1:"
az network dns record-set list \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$ZONE_NAME_1" \
  --output table

echo ""
echo "All records in $ZONE_NAME_2:"
az network dns record-set list \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$ZONE_NAME_2" \
  --output table


# ============================================================================
# SECTION 3: BIND PARITY VALIDATION (Day 2)
# ============================================================================

echo ""
echo "=== SECTION 3: Bind Parity — DNS Resolution Tests ==="
echo ""

# Get the Azure DNS nameserver for your zone
NS=$(az network dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --query "nameServers[0]" \
  --output tsv)

echo "Testing against nameserver: $NS"
echo ""

# 3.1 Create test records (all types)
echo "Creating test records for parity validation..."

# A record
az network dns record-set a add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "test-a" -a "10.0.1.100"

# AAAA record
az network dns record-set aaaa add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "test-aaaa" -a "2001:db8::1"

# CNAME record
az network dns record-set cname set-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "test-cname" -c "test-a.$PUBLIC_ZONE"

# MX record
az network dns record-set mx add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "test-mx" -e "mail.$PUBLIC_ZONE" -p 10

# TXT record
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "test-txt" -v "v=spf1 include:Zava.com ~all"

# SRV record
az network dns record-set srv add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_sip._tcp" -r 0 -p 5060 -w 10 -t "sip.$PUBLIC_ZONE"

# PTR record (for completeness)
az network dns record-set ptr add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "test-ptr" -d "host.$PUBLIC_ZONE"

# CAA record
az network dns record-set caa add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "@" -f 0 -t "issue" -v "letsencrypt.org"

echo ""
echo "--- Running dig tests ---"
echo ""

# 3.2 Validate each record type with dig
echo "=== A Record ==="
dig @"$NS" test-a."$PUBLIC_ZONE" A +short

echo "=== AAAA Record ==="
dig @"$NS" test-aaaa."$PUBLIC_ZONE" AAAA +short

echo "=== CNAME Record ==="
dig @"$NS" test-cname."$PUBLIC_ZONE" CNAME +short

echo "=== MX Record ==="
dig @"$NS" test-mx."$PUBLIC_ZONE" MX +short

echo "=== TXT Record ==="
dig @"$NS" test-txt."$PUBLIC_ZONE" TXT +short

echo "=== SRV Record ==="
dig @"$NS" _sip._tcp."$PUBLIC_ZONE" SRV +short

echo "=== SOA Record ==="
dig @"$NS" "$PUBLIC_ZONE" SOA +short

echo "=== NS Records ==="
dig @"$NS" "$PUBLIC_ZONE" NS +short

echo "=== CAA Record ==="
dig @"$NS" "$PUBLIC_ZONE" CAA +short

echo ""
echo "Compare the above output with your Bind server output."
echo "All record types should resolve correctly."


# ============================================================================
# SECTION 4: RBAC & DELEGATION (Day 3)
# ============================================================================

echo ""
echo "=== SECTION 4: RBAC & Delegation ==="
echo ""

# 4.1 Create custom role: DNS Record Operator
# This role can manage record sets but CANNOT create/delete zones.

cat > dns-record-operator-role.json << 'EOF'
{
  "Name": "DNS Record Operator - Zava POC",
  "IsCustom": true,
  "Description": "Can manage DNS record sets within zones but cannot create, modify, or delete DNS zones themselves.",
  "Actions": [
    "Microsoft.Network/dnsZones/read",
    "Microsoft.Network/dnsZones/*/read",
    "Microsoft.Network/dnsZones/A/*",
    "Microsoft.Network/dnsZones/AAAA/*",
    "Microsoft.Network/dnsZones/CNAME/*",
    "Microsoft.Network/dnsZones/MX/*",
    "Microsoft.Network/dnsZones/TXT/*",
    "Microsoft.Network/dnsZones/SRV/*",
    "Microsoft.Network/dnsZones/PTR/*",
    "Microsoft.Network/dnsZones/CAA/*",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/SUBSCRIPTION_ID_PLACEHOLDER/resourceGroups/rg-dns-poc"
  ]
}
EOF

# Replace placeholder with actual subscription ID
sed -i "s/SUBSCRIPTION_ID_PLACEHOLDER/$SUBSCRIPTION_ID/g" dns-record-operator-role.json

echo "Creating custom role: DNS Record Operator..."
az role definition create --role-definition dns-record-operator-role.json --output table

# 4.2 Assign ADMIN role (DNS Zone Contributor — built-in)
echo "Assigning DNS Zone Contributor to Admin user..."
az role assignment create \
  --assignee "$ADMIN_USER_OBJECT_ID" \
  --role "DNS Zone Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

# 4.3 Assign OPERATOR role (custom, zone-scoped)
echo "Assigning DNS Record Operator to Operator user..."
az role assignment create \
  --assignee "$OPERATOR_USER_OBJECT_ID" \
  --role "DNS Record Operator - Zava POC" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/dnsZones/$PUBLIC_ZONE"

# 4.4 RBAC Validation Tests
echo ""
echo "=== RBAC Validation ==="
echo ""
echo "TEST 1: Log in as the OPERATOR user and try these commands:"
echo ""
echo "  # Should SUCCEED — operator can add records"
echo "  az network dns record-set a add-record -g $RESOURCE_GROUP -z $PUBLIC_ZONE -n 'operator-test' -a '10.0.1.200'"
echo ""
echo "  # Should FAIL — operator cannot create zones"
echo "  az network dns zone create -g $RESOURCE_GROUP -n 'operator-should-fail.Zava.com'"
echo ""
echo "  # Should FAIL — operator cannot delete zones"
echo "  az network dns zone delete -g $RESOURCE_GROUP -n '$PUBLIC_ZONE' --yes"
echo ""
echo "TEST 2: Log in as the ADMIN user and try these commands:"
echo ""
echo "  # Should SUCCEED — admin can create zones"
echo "  az network dns zone create -g $RESOURCE_GROUP -n 'admin-test-zone.Zava.com'"
echo ""
echo "  # Should SUCCEED — admin can delete zones"
echo "  az network dns zone delete -g $RESOURCE_GROUP -n 'admin-test-zone.Zava.com' --yes"
echo ""


# ============================================================================
# SECTION 5: AUTOMATED RECORD CREATION + DIGICERT DCV WORKFLOW (Day 4)
# ============================================================================

echo ""
echo "=== SECTION 5: Automated Record Creation & DigiCert DCV ==="
echo ""

# --------------------------------------------------------------------------
# 5.1 Basic Record CRUD (Create / Read / Update / Delete)
# --------------------------------------------------------------------------

echo "--- 5.1 Record CRUD Lifecycle ---"

# CREATE
echo "Creating A record: automation-test -> 10.0.2.1"
az network dns record-set a add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "automation-test" -a "10.0.2.1" \
  --output table

# READ
echo "Reading the record:"
az network dns record-set a show \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "automation-test" \
  --output table

# UPDATE (add a second IP to the record set)
echo "Adding second IP to record set:"
az network dns record-set a add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "automation-test" -a "10.0.2.2" \
  --output table

# UPDATE TTL
echo "Updating TTL to 60 seconds:"
az network dns record-set a update \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "automation-test" --set "ttl=60" \
  --output table

# DELETE (single record from set)
echo "Removing first IP from record set:"
az network dns record-set a remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "automation-test" -a "10.0.2.1"

# DELETE (entire record set)
echo "Deleting entire record set:"
az network dns record-set a delete \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "automation-test" --yes

echo "CRUD lifecycle complete."

# --------------------------------------------------------------------------
# 5.2 DCV (Domain Control Validation) TXT Record Automation — WITH PROOF
# --------------------------------------------------------------------------
#
# Zava uses DigiCert CertCentral. DigiCert DCV uses _dnsauth TXT records
# (not _acme-challenge). This section tests BOTH conventions:
#   - _dnsauth (DigiCert CertCentral — Zava's production workflow)
#   - _acme-challenge (ACME standard — certbot, acme.sh, cert-manager)
#
# What we prove:
#   ✅ TXT record creation via Azure CLI (API-driven)
#   ✅ Record is globally resolvable within measurable time
#   ✅ Record VALUE matches the expected challenge token (byte-exact)
#   ✅ Multiple simultaneous DCV challenges (SAN / multi-domain certs)
#   ✅ Wildcard cert DCV (same _dnsauth record location)
#   ✅ Cleanup removes the record completely (no stale challenges)
#   ✅ Full cycle timing (create → resolvable → cleanup) measured
#   ✅ Automated PASS/FAIL verdict for each test
#   ✅ DigiCert _dnsauth convention tested alongside ACME _acme-challenge
# --------------------------------------------------------------------------

echo ""
echo "============================================================"
echo " 5.2 DCV TXT Record Automation — Proof of Functionality"
echo "============================================================"
echo ""

DCV_PASS_COUNT=0
DCV_FAIL_COUNT=0
DCV_RESULTS=""

# Helper: verify a TXT record matches expected value with retries
# Usage: verify_dcv_txt <fqdn> <expected_value> <max_wait_seconds>
verify_dcv_txt() {
  local FQDN="$1"
  local EXPECTED="$2"
  local MAX_WAIT="${3:-60}"
  local ELAPSED=0
  local INTERVAL=5

  while [ $ELAPSED -lt $MAX_WAIT ]; do
    RESULT=$(dig @"$NS" "$FQDN" TXT +short 2>/dev/null | tr -d '"')
    if [ "$RESULT" = "$EXPECTED" ]; then
      echo "  ✅ VERIFIED in ${ELAPSED}s — dig returned: \"$RESULT\""
      return 0
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "  ⏳ ${ELAPSED}s — waiting for propagation (got: \"$RESULT\")"
  done

  echo "  ❌ FAILED after ${MAX_WAIT}s — expected: \"$EXPECTED\", got: \"$RESULT\""
  return 1
}

# Helper: verify a TXT record is REMOVED (returns NXDOMAIN or empty)
verify_dcv_removed() {
  local FQDN="$1"
  local MAX_WAIT="${2:-30}"
  local ELAPSED=0
  local INTERVAL=5

  while [ $ELAPSED -lt $MAX_WAIT ]; do
    RESULT=$(dig @"$NS" "$FQDN" TXT +short 2>/dev/null | tr -d '"')
    if [ -z "$RESULT" ]; then
      echo "  ✅ CONFIRMED REMOVED in ${ELAPSED}s — no TXT record found"
      return 0
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  echo "  ❌ STILL PRESENT after ${MAX_WAIT}s — got: \"$RESULT\""
  return 1
}

# ==========================================================================
# TEST 1: Standard DCV — Single domain certificate
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 1: Standard DCV — Single Domain Certificate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: Let's Encrypt / CA issues DNS-01 challenge"
echo " for: $PUBLIC_ZONE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_1="dcv-proof-single-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"
SECONDS=0

echo ""
echo "Step 1/5: Challenge token generated: $TOKEN_1"

echo "Step 2/5: Creating _acme-challenge.$PUBLIC_ZONE TXT record..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge" \
  -v "$TOKEN_1" \
  --output none
CREATE_TIME=$SECONDS
echo "  Record created via Azure CLI in ${CREATE_TIME}s"

echo "Step 3/5: Verifying record resolves with EXACT token value..."
SECONDS=0
if verify_dcv_txt "_acme-challenge.$PUBLIC_ZONE" "$TOKEN_1" 60; then
  VERIFY_TIME=$SECONDS
  echo "Step 4/5: PROOF — Record is globally resolvable and matches challenge token"
  echo "  Full dig output:"
  dig @"$NS" _acme-challenge."$PUBLIC_ZONE" TXT
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 1 PASS: Standard DCV — created in ${CREATE_TIME}s, verified in ${VERIFY_TIME}s"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 1 FAIL: Standard DCV — record did not resolve with expected value"
fi

echo "Step 5/5: Cleaning up challenge record..."
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge" \
  -v "$TOKEN_1" --output none

verify_dcv_removed "_acme-challenge.$PUBLIC_ZONE" 30


# ==========================================================================
# TEST 2: Subdomain DCV — Certificate for app.poc.Zava.com
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 2: Subdomain DCV — Certificate for app.$PUBLIC_ZONE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: Cert requested for app.$PUBLIC_ZONE"
echo " Challenge record goes to: _acme-challenge.app.$PUBLIC_ZONE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_2="dcv-proof-subdomain-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"
SECONDS=0

echo "Creating _acme-challenge.app.$PUBLIC_ZONE TXT record..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.app" \
  -v "$TOKEN_2" \
  --output none

echo "Verifying..."
if verify_dcv_txt "_acme-challenge.app.$PUBLIC_ZONE" "$TOKEN_2" 60; then
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 2 PASS: Subdomain DCV (app.$PUBLIC_ZONE)"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 2 FAIL: Subdomain DCV (app.$PUBLIC_ZONE)"
fi

# Cleanup
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.app" \
  -v "$TOKEN_2" --output none


# ==========================================================================
# TEST 3: Wildcard DCV — Certificate for *.poc.Zava.com
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 3: Wildcard DCV — Certificate for *.$PUBLIC_ZONE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: Wildcard cert for *.$PUBLIC_ZONE"
echo " Per RFC 8555, the challenge record is STILL: _acme-challenge.$PUBLIC_ZONE"
echo " (same as standard — but the ACME order specifies wildcard)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_3="dcv-proof-wildcard-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"
SECONDS=0

echo "Creating _acme-challenge.$PUBLIC_ZONE TXT record (wildcard DCV)..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge" \
  -v "$TOKEN_3" \
  --output none

echo "Verifying..."
if verify_dcv_txt "_acme-challenge.$PUBLIC_ZONE" "$TOKEN_3" 60; then
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 3 PASS: Wildcard DCV (*.$PUBLIC_ZONE)"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 3 FAIL: Wildcard DCV (*.$PUBLIC_ZONE)"
fi

# Cleanup
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge" \
  -v "$TOKEN_3" --output none


# ==========================================================================
# TEST 4: Multi-Domain SAN DCV — Simultaneous challenges for 3 subdomains
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 4: Multi-Domain SAN DCV — 3 Simultaneous Challenges"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: SAN cert for www, api, portal subdomains"
echo " All 3 challenges created at once (parallel validation)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_WWW="dcv-san-www-$(date +%s)"
TOKEN_API="dcv-san-api-$(date +%s)"
TOKEN_PORTAL="dcv-san-portal-$(date +%s)"

echo "Creating 3 DCV records simultaneously..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.www" -v "$TOKEN_WWW" --output none &
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.api" -v "$TOKEN_API" --output none &
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.portal" -v "$TOKEN_PORTAL" --output none &
wait
echo "All 3 records created."

echo ""
echo "Verifying all 3 challenges..."
SAN_PASS=0

echo "  Checking www..."
if verify_dcv_txt "_acme-challenge.www.$PUBLIC_ZONE" "$TOKEN_WWW" 60; then
  SAN_PASS=$((SAN_PASS + 1))
fi

echo "  Checking api..."
if verify_dcv_txt "_acme-challenge.api.$PUBLIC_ZONE" "$TOKEN_API" 60; then
  SAN_PASS=$((SAN_PASS + 1))
fi

echo "  Checking portal..."
if verify_dcv_txt "_acme-challenge.portal.$PUBLIC_ZONE" "$TOKEN_PORTAL" 60; then
  SAN_PASS=$((SAN_PASS + 1))
fi

if [ $SAN_PASS -eq 3 ]; then
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 4 PASS: Multi-domain SAN DCV — all 3/3 subdomains verified"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 4 FAIL: Multi-domain SAN DCV — only $SAN_PASS/3 verified"
fi

# Cleanup all 3
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.www" -v "$TOKEN_WWW" --output none
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.api" -v "$TOKEN_API" --output none
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.portal" -v "$TOKEN_PORTAL" --output none


# ==========================================================================
# TEST 5: Full Cycle Timing — End-to-End DCV Performance Measurement
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 5: Full Cycle Timing — Create → Verify → Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Measures total time from record creation to confirmed"
echo " resolution and back to confirmed removal."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_5="dcv-timing-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"
TOTAL_START=$SECONDS

echo "Phase 1: CREATE"
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.timing" \
  -v "$TOKEN_5" \
  --output none
CREATE_DONE=$SECONDS
CREATE_ELAPSED=$((CREATE_DONE - TOTAL_START))
echo "  Create completed in ${CREATE_ELAPSED}s"

echo "Phase 2: VERIFY (polling until resolvable)"
VERIFY_START=$SECONDS
if verify_dcv_txt "_acme-challenge.timing.$PUBLIC_ZONE" "$TOKEN_5" 90; then
  VERIFY_DONE=$SECONDS
  PROPAGATION_TIME=$((VERIFY_DONE - VERIFY_START))
  echo "  Propagation time: ${PROPAGATION_TIME}s"
else
  PROPAGATION_TIME="TIMEOUT"
  echo "  ❌ Propagation timed out"
fi

echo "Phase 3: CLEANUP"
CLEANUP_START=$SECONDS
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_acme-challenge.timing" \
  -v "$TOKEN_5" --output none
verify_dcv_removed "_acme-challenge.timing.$PUBLIC_ZONE" 30
CLEANUP_DONE=$SECONDS
CLEANUP_TIME=$((CLEANUP_DONE - CLEANUP_START))

TOTAL_TIME=$((CLEANUP_DONE - TOTAL_START))

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  DCV FULL CYCLE TIMING RESULTS              │"
echo "├─────────────────────────────────────────────┤"
echo "│  API Create call:    ${CREATE_ELAPSED}s                     │"
echo "│  DNS Propagation:    ${PROPAGATION_TIME}s                     │"
echo "│  Cleanup + Confirm:  ${CLEANUP_TIME}s                     │"
echo "│  ─────────────────────────────────────────  │"
echo "│  TOTAL CYCLE:        ${TOTAL_TIME}s                     │"
echo "└─────────────────────────────────────────────┘"

if [ "$PROPAGATION_TIME" != "TIMEOUT" ] && [ "$TOTAL_TIME" -lt 120 ]; then
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 5 PASS: Full DCV cycle completed in ${TOTAL_TIME}s (create: ${CREATE_ELAPSED}s, propagation: ${PROPAGATION_TIME}s, cleanup: ${CLEANUP_TIME}s)"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 5 FAIL: Full DCV cycle exceeded 120s or timed out"
fi


# ==========================================================================
# TEST 6: Real ACME Client Integration (certbot dry-run)
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 6: Real ACME Client — certbot with Azure DNS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " This test uses certbot with the Azure DNS plugin to"
echo " perform a REAL DNS-01 challenge (dry-run / staging)."
echo ""
echo " PREREQUISITES (install before running):"
echo "   pip install certbot certbot-dns-azure"
echo ""
echo " You also need an azure.ini credentials file:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Generate the azure.ini config for certbot
cat > azure-certbot.ini << CERTEOF
# Azure DNS credentials for certbot
# See: https://certbot-dns-azure.readthedocs.io/
dns_azure_sp_client_id = <service-principal-client-id>
dns_azure_sp_client_secret = <service-principal-secret>
dns_azure_tenant_id = <tenant-id>

dns_azure_environment = AzurePublicCloud

# Map domain to Azure DNS zone resource ID
dns_azure_zone1 = $PUBLIC_ZONE:/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/dnsZones/$PUBLIC_ZONE
CERTEOF
chmod 600 azure-certbot.ini

echo ""
echo "azure-certbot.ini written. Edit it with your service principal credentials."
echo ""
echo "To run a REAL DCV test with certbot (using Let's Encrypt STAGING):"
echo ""
echo "  certbot certonly \\"
echo "    --authenticator dns-azure \\"
echo "    --dns-azure-credentials ./azure-certbot.ini \\"
echo "    --dns-azure-propagation-seconds 30 \\"
echo "    --server https://acme-staging-v02.api.letsencrypt.org/directory \\"
echo "    -d $PUBLIC_ZONE \\"
echo "    -d *.$PUBLIC_ZONE \\"
echo "    --dry-run"
echo ""
echo "Expected output: 'The dry run was successful.' — this proves the full"
echo "ACME DNS-01 flow works end-to-end with Azure DNS."
echo ""
echo "For acme.sh users:"
echo ""
echo "  export AZUREDNS_SUBSCRIPTIONID=$SUBSCRIPTION_ID"
echo "  export AZUREDNS_TENANTID=<tenant-id>"
echo "  export AZUREDNS_APPID=<service-principal-client-id>"
echo "  export AZUREDNS_CLIENTSECRET=<service-principal-secret>"
echo ""
echo "  acme.sh --issue --dns dns_azure \\"
echo "    -d $PUBLIC_ZONE \\"
echo "    -d *.$PUBLIC_ZONE \\"
echo "    --staging"


# ==========================================================================
# TEST 7: DigiCert DCV — _dnsauth TXT Record (Zava's Production Flow)
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 7: DigiCert DCV — _dnsauth TXT Record"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: DigiCert CertCentral issues DCV challenge"
echo " DigiCert uses _dnsauth (not _acme-challenge)"
echo " This is Zava's PRODUCTION workflow with DigiCert"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_DC="digicert-dcv-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"
SECONDS=0

echo ""
echo "Step 1/4: DigiCert DCV token (simulated): $TOKEN_DC"

echo "Step 2/4: Creating _dnsauth.$PUBLIC_ZONE TXT record..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_dnsauth" \
  -v "$TOKEN_DC" \
  --output none
DC_CREATE_TIME=$SECONDS
echo "  Record created in ${DC_CREATE_TIME}s"

echo "Step 3/4: Verifying _dnsauth record resolves..."
SECONDS=0
if verify_dcv_txt "_dnsauth.$PUBLIC_ZONE" "$TOKEN_DC" 60; then
  DC_VERIFY_TIME=$SECONDS
  echo "  Full dig output:"
  dig @"$NS" _dnsauth."$PUBLIC_ZONE" TXT
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 7 PASS: DigiCert _dnsauth DCV — created in ${DC_CREATE_TIME}s, verified in ${DC_VERIFY_TIME}s"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 7 FAIL: DigiCert _dnsauth DCV — record did not resolve"
fi

echo "Step 4/4: Cleaning up _dnsauth record..."
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_dnsauth" \
  -v "$TOKEN_DC" --output none
verify_dcv_removed "_dnsauth.$PUBLIC_ZONE" 30


# ==========================================================================
# TEST 8: DigiCert DCV — Subdomain _dnsauth (app.poc.Zava.com)
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 8: DigiCert DCV — Subdomain Certificate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: DigiCert cert for app.$PUBLIC_ZONE"
echo " Challenge: _dnsauth.app.$PUBLIC_ZONE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_DC_SUB="digicert-sub-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"

echo "Creating _dnsauth.app.$PUBLIC_ZONE TXT record..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_dnsauth.app" \
  -v "$TOKEN_DC_SUB" \
  --output none

echo "Verifying..."
if verify_dcv_txt "_dnsauth.app.$PUBLIC_ZONE" "$TOKEN_DC_SUB" 60; then
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 8 PASS: DigiCert subdomain DCV (_dnsauth.app)"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 8 FAIL: DigiCert subdomain DCV (_dnsauth.app)"
fi

# Cleanup
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_dnsauth.app" \
  -v "$TOKEN_DC_SUB" --output none


# ==========================================================================
# TEST 9: DigiCert DCV — Wildcard _dnsauth (*.poc.Zava.com)
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " TEST 9: DigiCert DCV — Wildcard Certificate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Scenario: DigiCert wildcard cert for *.$PUBLIC_ZONE"
echo " Challenge: _dnsauth.$PUBLIC_ZONE (same as root)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TOKEN_DC_WILD="digicert-wild-$(date +%s)-$(openssl rand -hex 16 2>/dev/null || echo $RANDOM)"

echo "Creating _dnsauth.$PUBLIC_ZONE TXT record (wildcard)..."
az network dns record-set txt add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_dnsauth" \
  -v "$TOKEN_DC_WILD" \
  --output none

echo "Verifying..."
if verify_dcv_txt "_dnsauth.$PUBLIC_ZONE" "$TOKEN_DC_WILD" 60; then
  DCV_PASS_COUNT=$((DCV_PASS_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ✅ TEST 9 PASS: DigiCert wildcard DCV (_dnsauth for *.$PUBLIC_ZONE)"
else
  DCV_FAIL_COUNT=$((DCV_FAIL_COUNT + 1))
  DCV_RESULTS="${DCV_RESULTS}\n  ❌ TEST 9 FAIL: DigiCert wildcard DCV"
fi

# Cleanup
az network dns record-set txt remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "_dnsauth" \
  -v "$TOKEN_DC_WILD" --output none


# ==========================================================================
# DCV TEST SUMMARY — PROOF REPORT
# ==========================================================================
echo ""
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  DCV AUTOMATION PROOF — TEST RESULTS SUMMARY             ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo -e "║$DCV_RESULTS"
echo "║                                                           ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  PASSED: $DCV_PASS_COUNT / $((DCV_PASS_COUNT + DCV_FAIL_COUNT))                                            ║"
echo "║  FAILED: $DCV_FAIL_COUNT / $((DCV_PASS_COUNT + DCV_FAIL_COUNT))                                            ║"
echo "╠═══════════════════════════════════════════════════════════╣"
if [ $DCV_FAIL_COUNT -eq 0 ]; then
echo "║  VERDICT: ✅ DCV AUTOMATION FULLY VALIDATED               ║"
echo "║  Azure DNS supports automated certificate domain          ║"
echo "║  validation via DNS-01 for single, subdomain, wildcard,   ║"
echo "║  and multi-domain SAN certificates.                       ║"
else
echo "║  VERDICT: ⚠️  DCV AUTOMATION PARTIALLY VALIDATED           ║"
echo "║  $DCV_FAIL_COUNT test(s) failed — review results above.             ║"
fi
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""


# --------------------------------------------------------------------------
# 5.3 Certificate Storage — Where Do the Certs Go?
# --------------------------------------------------------------------------
#
# After DCV succeeds and the CA issues the certificate, the cert files
# are stored differently depending on which tool you use:
#
#   certbot  →  /etc/letsencrypt/live/<domain>/  (Linux)
#               C:\Certbot\live\<domain>\         (Windows)
#   acme.sh  →  ~/.acme.sh/<domain>/
#
# For PRODUCTION, store certs in Azure Key Vault instead of on disk.
# --------------------------------------------------------------------------

echo ""
echo "============================================================"
echo " 5.3 Certificate Storage — Azure Key Vault Setup"
echo "============================================================"
echo ""

# Use a deterministic unique Key Vault name per subscription to avoid global name collisions.
KV_SUFFIX=$(echo "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]')
KEY_VAULT_NAME="kv-zava-dns-poc-${KV_SUFFIX}"

# 5.3.1 Create a Key Vault for certificate storage
echo "Creating Key Vault for cert storage..."
az keyvault create \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --enable-rbac-authorization true \
  --output table

echo ""
echo "Key Vault created. In production, certs go here instead of on disk."
echo ""

# 5.3.2 Grant current user permission to import certificates
CURRENT_USER=$(az ad signed-in-user show --query id --output tsv 2>/dev/null)
if [ -n "$CURRENT_USER" ]; then
  echo "Granting Key Vault Certificates Officer role to current user..."
  az role assignment create \
    --assignee "$CURRENT_USER" \
    --role "Key Vault Certificates Officer" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME" \
    --output none 2>/dev/null
  echo "  Role assigned."
fi

# 5.3.3 Show how to import a cert (after ACME client creates it)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " After your ACME client (certbot/acme.sh) issues a cert:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Step 1: Convert PEM → PFX (if needed):"
echo "   openssl pkcs12 -export -out cert.pfx \\"
echo "     -inkey /etc/letsencrypt/live/$PUBLIC_ZONE/privkey.pem \\"
echo "     -in /etc/letsencrypt/live/$PUBLIC_ZONE/fullchain.pem \\"
echo "     -passout pass:"
echo ""
echo " Step 2: Import into Key Vault:"
echo "   az keyvault certificate import \\"
echo "     --vault-name $KEY_VAULT_NAME \\" 
echo "     --name poc-Zava-com \\"
echo "     --file cert.pfx"
echo ""
echo " Step 3: Verify in Key Vault:"
echo "   az keyvault certificate show \\"
echo "     --vault-name $KEY_VAULT_NAME \\" 
echo "     --name poc-Zava-com \\"
echo "     --query '{name:name, expires:attributes.expires, thumbprint:x509ThumbprintHex}' \\"
echo "     --output table"
echo ""
echo " Step 4: View in portal:"
echo "   portal.azure.com → Key vaults → $KEY_VAULT_NAME → Certificates"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " CERT STORAGE SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  POC:        Certs on disk (certbot/acme.sh default)"
echo "  Production: Certs in Azure Key Vault"
echo "  Access:     RBAC-controlled (Key Vault Certificates Officer)"
echo "  Monitoring: Key Vault expiration alerts"
echo "  Renewal:    Cron job → ACME client → DCV via Azure DNS → Key Vault import"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""


# --------------------------------------------------------------------------
# 5.4 Bulk Record Creation (PowerShell alternative)
# --------------------------------------------------------------------------
# If Zava prefers PowerShell, here's a bulk creation script:

cat > bulk-records.ps1 << 'PSEOF'
# PowerShell — Bulk DNS record creation from CSV
# Usage: .\bulk-records.ps1

$rg = "rg-dns-poc"
$zone = "poc.Zava.com"

# Define records as an array of objects
$records = @(
    @{ Name = "web1";    Type = "A";      Value = "10.0.3.1" }
    @{ Name = "web2";    Type = "A";      Value = "10.0.3.2" }
    @{ Name = "api";     Type = "CNAME";  Value = "web1.poc.Zava.com" }
    @{ Name = "mail";    Type = "MX";     Value = "mail.poc.Zava.com"; Priority = 10 }
    @{ Name = "spf";     Type = "TXT";    Value = "v=spf1 include:Zava.com ~all" }
)

foreach ($r in $records) {
    switch ($r.Type) {
        "A"     { az network dns record-set a add-record -g $rg -z $zone -n $r.Name -a $r.Value }
        "CNAME" { az network dns record-set cname set-record -g $rg -z $zone -n $r.Name -c $r.Value }
        "MX"    { az network dns record-set mx add-record -g $rg -z $zone -n $r.Name -e $r.Value -p $r.Priority }
        "TXT"   { az network dns record-set txt add-record -g $rg -z $zone -n $r.Name -v $r.Value }
    }
    Write-Host "Created $($r.Type) record: $($r.Name) → $($r.Value)"
}
PSEOF

echo "PowerShell bulk creation script written to: bulk-records.ps1"


# ============================================================================
# SECTION 6: DNS QUERY LOGGING → SIEM (Day 5)
# ============================================================================

echo ""
echo "=== SECTION 6: DNS Query Logging → SIEM ==="
echo ""

# 6.0 Ensure NS variable is set (in case Section 3 was skipped)
NS=$(az network dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --query "nameServers[0]" \
  --output tsv 2>/dev/null)
echo "Using nameserver: $NS"
echo ""

# 6.1 Create Event Hub Namespace
echo "Creating Event Hub namespace..."
az eventhubs namespace create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$EVENTHUB_NAMESPACE" \
  --location "$LOCATION" \
  --sku "$EVENTHUB_SKU" \
  --output table

# 6.2 Create Event Hub
echo "Creating Event Hub..."
az eventhubs eventhub create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$EVENTHUB_NAMESPACE" \
  --name "$EVENTHUB_NAME" \
  --message-retention 1 \
  --partition-count 2 \
  --output table

# 6.3 Get Event Hub authorization rule ID (for diagnostic settings)
EVENTHUB_RULE_ID=$(az eventhubs namespace authorization-rule show \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$EVENTHUB_NAMESPACE" \
  --name "RootManageSharedAccessKey" \
  --query "id" --output tsv)

echo "Event Hub Rule ID: $EVENTHUB_RULE_ID"

# 6.4 Get DNS Zone resource ID
DNS_ZONE_ID=$(az network dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --query "id" --output tsv)

echo "DNS Zone ID: $DNS_ZONE_ID"

# 6.5 Create Diagnostic Setting on the DNS zone
echo "Enabling diagnostic settings (query logs → Event Hub)..."
az monitor diagnostic-settings create \
  --name "dns-logs-to-eventhub" \
  --resource "$DNS_ZONE_ID" \
  --event-hub "$EVENTHUB_NAME" \
  --event-hub-rule "$EVENTHUB_RULE_ID" \
  --logs '[{"category": "DnsDiagnosticEvents", "enabled": true, "retentionPolicy": {"enabled": false, "days": 0}}]' \
  --output table

echo ""
echo "Diagnostic settings configured."
echo ""
echo "--- IBM QRadar SIEM Integration ---"
echo ""
echo "Zava uses IBM QRadar. Follow these steps to connect:"
echo ""
echo "STEP 1: Get the Event Hub connection string:"
echo "  az eventhubs namespace authorization-rule keys list \\"
echo "    --resource-group $RESOURCE_GROUP \\"
echo "    --namespace-name $EVENTHUB_NAMESPACE \\"
echo "    --name RootManageSharedAccessKey --query primaryConnectionString -o tsv"
echo ""
echo "STEP 2: In QRadar Admin Console:"
echo "  a. Go to Admin > Log Sources > Add"
echo "  b. Log Source Type: Microsoft Azure Event Hub"
echo "  c. Protocol: Microsoft Azure Event Hub"
echo "  d. Paste the connection string from Step 1"
echo "  e. Event Hub Name: $EVENTHUB_NAME"
echo "  f. Consumer Group: \$Default"
echo "  g. Storage Account: (create one for checkpoint tracking)"
echo ""
echo "STEP 3: QRadar will auto-detect the DSM (Device Support Module)"
echo "  for Azure DNS diagnostic events."
echo ""
echo "STEP 4: Verify in QRadar:"
echo "  - Log Activity tab > filter by Log Source = Azure Event Hub"
echo "  - You should see DNS query events within 5-10 minutes"
echo ""
echo "For QRadar documentation:"
echo "  https://www.ibm.com/docs/en/dsm?topic=azureel-microsoft-azure-event-hubs"
echo ""

# 6.6 Verify diagnostic setting is active
echo "Verifying diagnostic setting..."
az monitor diagnostic-settings show \
  --name "dns-logs-to-eventhub" \
  --resource "$DNS_ZONE_ID" \
  --output table

# 6.7 Generate test queries to produce log data
echo ""
echo "Generating test queries to produce log data..."
for i in $(seq 1 10); do
  dig @"$NS" test-a."$PUBLIC_ZONE" A +short > /dev/null 2>&1
  dig @"$NS" test-txt."$PUBLIC_ZONE" TXT +short > /dev/null 2>&1
done
echo "Sent 20 test queries. Check your SIEM for ingested events."
echo "(Allow 5-10 minutes for logs to flow through Event Hub to QRadar)"


# ============================================================================
# SECTION 7: ZONE SNAPSHOTS — POINT-IN-TIME EXPORT (Day 2)
# ============================================================================
# Required by Zava: ability to take point-in-time zone backups and restore.
# Azure DNS supports zone export to RFC 1035 format files at any time.
# ============================================================================

echo ""
echo "=== SECTION 7: Zone Snapshots (Point-in-Time Export) ==="
echo ""

# 7.1 Create snapshot directory
mkdir -p "$SNAPSHOT_DIR"

# 7.2 On-demand zone snapshot
SNAPSHOT_FILE="$SNAPSHOT_DIR/snapshot-${PUBLIC_ZONE}-$(date +%Y%m%d-%H%M%S).zone"

echo "Taking zone snapshot: $PUBLIC_ZONE → $SNAPSHOT_FILE"
az network dns zone export \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --file-name "$SNAPSHOT_FILE"

# 7.3 Verify snapshot file exists and has content
if [ -f "$SNAPSHOT_FILE" ]; then
  RECORD_COUNT=$(grep -c "IN" "$SNAPSHOT_FILE" 2>/dev/null || echo "0")
  echo "  ✅ Snapshot created: $SNAPSHOT_FILE"
  echo "  Records in snapshot: $RECORD_COUNT"
  echo ""
  echo "  First 20 lines of snapshot:"
  head -20 "$SNAPSHOT_FILE"
else
  echo "  ❌ Snapshot file not found — export may have failed"
fi

# 7.4 Verify snapshot is valid — re-import to a test zone
echo ""
echo "Validating snapshot by re-importing to a test zone..."
SNAPSHOT_TEST_ZONE="snapshot-test.poc.Zava.com"

az network dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SNAPSHOT_TEST_ZONE" \
  --output none 2>/dev/null

az network dns zone import \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SNAPSHOT_TEST_ZONE" \
  --file-name "$SNAPSHOT_FILE" 2>/dev/null

REIMPORT_COUNT=$(az network dns record-set list \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$SNAPSHOT_TEST_ZONE" \
  --query "length(@)" --output tsv 2>/dev/null)

echo "  Original zone record count: $(az network dns record-set list \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$PUBLIC_ZONE" \
  --query "length(@)" --output tsv)"
echo "  Re-imported zone record count: $REIMPORT_COUNT"

if [ "$REIMPORT_COUNT" -gt 0 ] 2>/dev/null; then
  echo "  ✅ PASS: Snapshot is valid — re-import successful"
else
  echo "  ⚠️  Check re-import results manually"
fi

# Cleanup test zone
az network dns zone delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SNAPSHOT_TEST_ZONE" --yes --output none 2>/dev/null

echo ""
echo "--- Scheduled Snapshots ---"
echo ""
echo "For automated daily snapshots, add this to a cron job or Azure Automation:"
echo ""
echo '  SNAPSHOT_FILE="./zone-snapshots/snapshot-poc.Zava.com-$(date +%Y%m%d).zone"'
echo '  az network dns zone export -g rg-dns-poc -n poc.Zava.com -f "$SNAPSHOT_FILE"'
echo '  echo "Zone snapshot taken: $SNAPSHOT_FILE"'
echo ""
echo "Retention: Keep last 30 daily snapshots (delete older with find -mtime +30)"
echo ""


# ============================================================================
# SECTION 8: REPORTING — AZURE MONITOR WORKBOOKS (Day 5)
# ============================================================================
# Required by Zava: operational dashboards for DNS query volumes,
# top queried records, change history, and error rates.
# ============================================================================

echo ""
echo "=== SECTION 8: Reporting (Azure Monitor Workbooks) ==="
echo ""

# 8.1 Create Log Analytics workspace for reporting
echo "Creating Log Analytics workspace for reporting..."
az monitor log-analytics workspace create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
  --location "$LOCATION" \
  --output table

# 8.2 Get workspace ID
LA_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
  --query "id" --output tsv)

echo "Log Analytics Workspace ID: $LA_WORKSPACE_ID"

# 8.3 Add Log Analytics as diagnostic destination (in addition to Event Hub for QRadar)
DNS_ZONE_ID=$(az network dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PUBLIC_ZONE" \
  --query "id" --output tsv)

echo "Adding Log Analytics as diagnostic destination..."
az monitor diagnostic-settings create \
  --name "dns-logs-to-loganalytics" \
  --resource "$DNS_ZONE_ID" \
  --workspace "$LA_WORKSPACE_ID" \
  --logs '[{"category": "DnsDiagnosticEvents", "enabled": true, "retentionPolicy": {"enabled": false, "days": 0}}]' \
  --output table

echo ""
echo "Diagnostic settings now route logs to BOTH:"
echo "  1. Event Hub → QRadar (SIEM / security)"
echo "  2. Log Analytics → Azure Monitor Workbooks (reporting / operations)"

# 8.4 Verify Activity Log captures management operations
echo ""
echo "--- Activity Log (Audit Trail) ---"
echo ""
echo "Verify management plane audit logging by creating and checking a test record:"

az network dns record-set a add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "audit-test" -a "10.0.99.99" --output none

echo "Waiting 30 seconds for Activity Log entry..."
sleep 30

echo "Recent DNS-related Activity Log entries:"
az monitor activity-log list \
  --resource-group "$RESOURCE_GROUP" \
  --offset 1h \
  --query "[?contains(resourceType, 'dnsZones')].{Time:eventTimestamp, Operation:operationName.localizedValue, Status:status.localizedValue, User:caller}" \
  --output table

# Cleanup
az network dns record-set a delete \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "audit-test" --yes --output none

# 8.5 Sample KQL queries for reporting dashboards
echo ""
echo "--- Sample KQL Queries for Azure Monitor Workbooks ---"
echo ""
echo "Once DNS query logs flow to Log Analytics (allow 10-15 min),"
echo "use these KQL queries in Azure Monitor Workbooks:"
echo ""
echo "QUERY 1: DNS query volume over time (15-min intervals)"
echo '  AzureDiagnostics'
echo '  | where Category == "DnsDiagnosticEvents"'
echo '  | summarize QueryCount = count() by bin(TimeGenerated, 15m)'
echo '  | render timechart'
echo ""
echo "QUERY 2: Top 10 most queried record names"
echo '  AzureDiagnostics'
echo '  | where Category == "DnsDiagnosticEvents"'
echo '  | summarize QueryCount = count() by tostring(query_s)'
echo '  | top 10 by QueryCount'
echo '  | render barchart'
echo ""
echo "QUERY 3: DNS error rates (NXDOMAIN, SERVFAIL)"
echo '  AzureDiagnostics'
echo '  | where Category == "DnsDiagnosticEvents"'
echo '  | summarize Count = count() by tostring(resultCode_s)'
echo '  | render piechart'
echo ""
echo "QUERY 4: Change history (management plane via Activity Log)"
echo '  AzureActivity'
echo '  | where ResourceProviderValue == "MICROSOFT.NETWORK"'
echo '  | where OperationNameValue contains "dnsZones"'
echo '  | project TimeGenerated, Caller, OperationNameValue,'
echo '           ActivityStatusValue, ResourceGroup'
echo '  | order by TimeGenerated desc'
echo ""
echo "To create a Workbook:"
echo "  1. Azure Portal → Monitor → Workbooks → New"
echo "  2. Add each query above as a separate tile"
echo "  3. Save as 'Zava DNS POC - Operations Dashboard'"
echo ""


# ============================================================================
# SECTION 9: DNS RECORD FAILOVER — TRAFFIC MANAGER PRIORITY (Day 6)
# ============================================================================
# Optional for Zava but included in their scorecard.
# Traffic Manager Priority routing = automatic DNS failover.
# ============================================================================

echo ""
echo "=== SECTION 9: DNS Record Failover (Traffic Manager Priority) ==="
echo ""

# 9.1 Create Traffic Manager profile with Priority routing
echo "Creating Traffic Manager profile with Priority (failover) routing..."
az network traffic-manager profile create \
  --resource-group "$RESOURCE_GROUP" \
  --name "tm-poc-failover" \
  --routing-method Priority \
  --unique-dns-name "tm-poc-failover" \
  --ttl 30 \
  --protocol HTTP \
  --port 80 \
  --path "/" \
  --output table

# 9.2 Add primary endpoint (priority 1)
echo "Adding PRIMARY endpoint (priority 1)..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "tm-poc-failover" \
  --name "primary-endpoint" \
  --type externalEndpoints \
  --target "$US_ENDPOINT_IP" \
  --priority 1 \
  --output table

# 9.3 Add secondary endpoint (priority 2 — failover target)
echo "Adding SECONDARY endpoint (priority 2 — failover target)..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "tm-poc-failover" \
  --name "secondary-endpoint" \
  --type externalEndpoints \
  --target "$UK_ENDPOINT_IP" \
  --priority 2 \
  --output table

# 9.4 Test normal resolution (should return primary)
echo ""
echo "Testing normal resolution (primary should respond)..."
echo "  dig tm-poc-failover.trafficmanager.net +short"
dig tm-poc-failover.trafficmanager.net +short

# 9.5 Simulate failover (disable primary endpoint)
echo ""
echo "Simulating failover — disabling primary endpoint..."
az network traffic-manager endpoint update \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "tm-poc-failover" \
  --name "primary-endpoint" \
  --type externalEndpoints \
  --endpoint-status Disabled \
  --output none

echo "Waiting 60 seconds for failover propagation..."
sleep 60

echo "Testing failover resolution (secondary should respond)..."
FAILOVER_RESULT=$(dig tm-poc-failover.trafficmanager.net +short 2>/dev/null)
echo "  Result: $FAILOVER_RESULT"

if [ "$FAILOVER_RESULT" = "$UK_ENDPOINT_IP" ]; then
  echo "  ✅ PASS: DNS failover works — traffic redirected to secondary"
else
  echo "  ⚠️  Check: Expected $UK_ENDPOINT_IP, got $FAILOVER_RESULT"
  echo "  (Failover may take up to 2 minutes to propagate)"
fi

# 9.6 Restore primary endpoint
echo ""
echo "Restoring primary endpoint..."
az network traffic-manager endpoint update \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "tm-poc-failover" \
  --name "primary-endpoint" \
  --type externalEndpoints \
  --endpoint-status Enabled \
  --output none

echo "Primary endpoint re-enabled. Failover test complete."


# ============================================================================
# SECTION 10: OPTIONAL FEATURES — GEO, WEIGHTED, DNSSEC (Days 7-8)
# ============================================================================
# These are OPTIONAL / nice-to-have per Zava's confirmed scorecard.
# DNSSEC is explicitly NOT a requirement for this POC.
# ============================================================================

echo ""
echo "=== SECTION 10: Optional Features (Geo, Weighted, DNSSEC) ==="
echo ""

# --------------------------------------------------------------------------
# 10.1 DNSSEC (Optional — not a requirement)
# --------------------------------------------------------------------------
echo "--- 10.1 DNSSEC (Optional) ---"
echo ""

# 10.1.1 Enable DNSSEC signing on the zone
echo "Enabling DNSSEC zone signing on $PUBLIC_ZONE..."
az network dns dnssec-config create \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$PUBLIC_ZONE" \
  --output table

# 10.1.2 Retrieve the DS record details
echo ""
echo "DS record information (publish this at the parent zone / registrar):"
az network dns dnssec-config show \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$PUBLIC_ZONE" \
  --output json

# 10.1.3 Validate DNSSEC with dig
echo ""
echo "--- DNSSEC Validation ---"
echo ""
echo "Testing DNSSEC signatures..."
dig +dnssec "$PUBLIC_ZONE" @"$NS" SOA
echo ""
echo "Look for:"
echo "  - RRSIG records in the response (zone is signed)"
echo "  - AD flag in the header (Authenticated Data — chain of trust valid)"
echo ""
echo "NOTE: Full chain-of-trust validation requires the DS record to be"
echo "published at the parent zone (registrar). For the POC, you can verify"
echo "that the zone IS signed (RRSIG present) even before DS publication."


# ----------------------------------------------------------------------------
# 10.2 GEO-BASED DNS ROUTING (Optional)
# ----------------------------------------------------------------------------

echo ""
echo "--- 10.2 Geo-Based DNS Routing (Traffic Manager) ---"
echo ""

# 10.2.1 Create Traffic Manager profile with Geographic routing
echo "Creating Traffic Manager profile with Geographic routing..."
az network traffic-manager profile create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$TM_PROFILE_NAME" \
  --routing-method Geographic \
  --unique-dns-name "$TM_DNS_NAME" \
  --ttl 30 \
  --protocol HTTP \
  --port 80 \
  --path "/" \
  --output table

# 10.2.2 Add US endpoint
echo "Adding US endpoint..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "$TM_PROFILE_NAME" \
  --name "us-endpoint" \
  --type externalEndpoints \
  --target "$US_ENDPOINT_IP" \
  --endpoint-status Enabled \
  --geo-mapping "US" \
  --output table

# 10.2.3 Add UK endpoint
echo "Adding UK endpoint..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "$TM_PROFILE_NAME" \
  --name "uk-endpoint" \
  --type externalEndpoints \
  --target "$UK_ENDPOINT_IP" \
  --endpoint-status Enabled \
  --geo-mapping "GB" \
  --output table

# 10.2.4 Add catch-all / default endpoint (World)
echo "Adding default (World) endpoint..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "$TM_PROFILE_NAME" \
  --name "default-endpoint" \
  --type externalEndpoints \
  --target "$US_ENDPOINT_IP" \
  --endpoint-status Enabled \
  --geo-mapping "WORLD" \
  --output table

# 10.2.5 Test resolution
echo ""
echo "Traffic Manager DNS name: $TM_DNS_NAME.trafficmanager.net"
echo ""
echo "Test from your location:"
echo "  dig $TM_DNS_NAME.trafficmanager.net +short"
echo ""
echo "To test from different geos, use online DNS check tools:"
echo "  - https://www.whatsmydns.net/#A/$TM_DNS_NAME.trafficmanager.net"
echo "  - Or use a VPN to test from UK/US locations"
echo ""
echo "Expected behavior:"
echo "  - Query from US → resolves to $US_ENDPOINT_IP"
echo "  - Query from UK → resolves to $UK_ENDPOINT_IP"
echo "  - Query from anywhere else → resolves to $US_ENDPOINT_IP (default)"


# ----------------------------------------------------------------------------
# 10.3 WEIGHTED LOAD DISTRIBUTION (Optional)
# ----------------------------------------------------------------------------

echo ""
echo "--- 10.3 Weighted Load Distribution ---"
echo ""

# 10.3.1 Create a second Traffic Manager profile with Weighted routing
echo "Creating Traffic Manager profile with Weighted routing..."
az network traffic-manager profile create \
  --resource-group "$RESOURCE_GROUP" \
  --name "tm-poc-weighted" \
  --routing-method Weighted \
  --unique-dns-name "tm-poc-weighted" \
  --ttl 30 \
  --protocol HTTP \
  --port 80 \
  --path "/" \
  --output table

# 10.3.2 Add endpoints with weights
echo "Adding endpoint 1 (weight 70)..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "tm-poc-weighted" \
  --name "primary" \
  --type externalEndpoints \
  --target "$US_ENDPOINT_IP" \
  --weight 70 \
  --output table

echo "Adding endpoint 2 (weight 30)..."
az network traffic-manager endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --profile-name "tm-poc-weighted" \
  --name "secondary" \
  --type externalEndpoints \
  --target "$UK_ENDPOINT_IP" \
  --weight 30 \
  --output table

echo ""
echo "Weighted routing configured: 70% → primary, 30% → secondary"
echo "Test with repeated queries:"
echo "  for i in \$(seq 1 20); do dig tm-poc-weighted.trafficmanager.net +short; done"


# ============================================================================
# SECTION 11: PRIVATE DNS ZONE + VNET LINK (Optional)
# ============================================================================

echo ""
echo "=== SECTION 11: Private DNS Zone ==="
echo ""

# 11.1 Create Private DNS zone
echo "Creating Private DNS zone: $PRIVATE_ZONE"
az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PRIVATE_ZONE" \
  --output table

# 11.2 Link to existing VNet in landing zone
VNET_ID=$(az network vnet show \
  --resource-group "$VNET_RG" \
  --name "$VNET_NAME" \
  --query "id" --output tsv)

echo "Linking Private DNS zone to VNet..."
az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$PRIVATE_ZONE" \
  --name "link-to-landing-zone-vnet" \
  --virtual-network "$VNET_ID" \
  --registration-enabled false \
  --output table

# 11.3 Add test records to Private DNS
echo "Adding test records to private zone..."
az network private-dns record-set a add-record \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$PRIVATE_ZONE" \
  --record-set-name "internal-app" \
  --ipv4-address "10.0.10.100" \
  --output table

echo ""
echo "Private DNS zone created and linked to VNet."
echo "To validate: From a VM in the linked VNet, run:"
echo "  nslookup internal-app.$PRIVATE_ZONE"
echo ""
echo "Expected: resolves to 10.0.10.100"
echo ""
echo "--- Public + Private DNS Coexistence Model ---"
echo ""
echo "  Public zones ($PUBLIC_ZONE):  Resolved by internet clients"
echo "  Private zones ($PRIVATE_ZONE): Resolved only within linked VNets"
echo "  Both can coexist in the same resource group."
echo "  Azure DNS resolver in VNets checks private zones first."


# ============================================================================
# SECTION 12: EDGE CASE TESTING (Day 8)
# ============================================================================

echo ""
echo "=== SECTION 12: Edge Case & Propagation Tests ==="
echo ""

# 12.1 TTL and propagation latency
echo "--- TTL & Propagation Test ---"
echo "Creating record with 10s TTL..."
az network dns record-set a add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "ttl-test" -a "10.0.99.1"

az network dns record-set a update \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "ttl-test" --set "ttl=10"

echo "Record created. Querying..."
dig @"$NS" ttl-test."$PUBLIC_ZONE" A +short
echo ""

echo "Updating record to new IP..."
SECONDS=0
az network dns record-set a remove-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "ttl-test" -a "10.0.99.1"
az network dns record-set a add-record \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "ttl-test" -a "10.0.99.2"

echo "Waiting for propagation..."
for i in $(seq 1 12); do
  sleep 5
  RESULT=$(dig @"$NS" ttl-test."$PUBLIC_ZONE" A +short 2>/dev/null)
  echo "  ${SECONDS}s: $RESULT"
  if [ "$RESULT" = "10.0.99.2" ]; then
    echo "  Propagation confirmed in ${SECONDS} seconds."
    break
  fi
done

# 12.2 NXDOMAIN (negative caching)
echo ""
echo "--- NXDOMAIN Test ---"
echo "Querying non-existent record..."
dig @"$NS" this-does-not-exist."$PUBLIC_ZONE" A
echo "(Should return NXDOMAIN / status: NXDOMAIN)"

# 12.3 Large record set
echo ""
echo "--- Large Record Set Test ---"
echo "Creating 50 A records in a single record set..."
for i in $(seq 1 50); do
  az network dns record-set a add-record \
    -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
    -n "large-set" -a "10.1.1.$i" --output none 2>/dev/null
done
echo "Querying large record set..."
dig @"$NS" large-set."$PUBLIC_ZONE" A +short | wc -l
echo "(Should return 50 IPs)"

# Cleanup
echo "Cleaning up large record set..."
az network dns record-set a delete \
  -g "$RESOURCE_GROUP" -z "$PUBLIC_ZONE" \
  -n "large-set" --yes


# ============================================================================
# SECTION 13: CLEANUP (After POC — Run only when done)
# ============================================================================

echo ""
echo "=== SECTION 13: CLEANUP ==="
echo ""
echo "!!! WARNING: Only run this AFTER the POC is complete !!!"
echo "!!! This deletes ALL POC resources !!!"
echo ""
echo "STEP 1: Delete the resource group (removes most resources):"
echo ""
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo ""
echo "  This deletes:"
echo "    - All DNS zones (public and private)"
echo "    - Traffic Manager profiles (failover, geo, weighted)"
echo "    - Event Hub namespace ($EVENTHUB_NAMESPACE)"
echo "    - Log Analytics workspace ($LOG_ANALYTICS_WORKSPACE)"
echo "    - Key Vault ($KEY_VAULT_NAME)"
echo "    - Diagnostic settings"
echo "    - All RBAC assignments scoped to this resource group"
echo ""
echo "STEP 2: Delete custom role definition (resource group deletion doesn't remove this):"
echo ""
echo "  az role definition delete --name 'DNS Record Operator - Zava POC'"
echo ""
echo "STEP 3: Clean up local files:"
echo ""
echo "  rm -rf $SNAPSHOT_DIR                    # Zone snapshot files"
echo "  rm -f dns-record-operator-role.json     # RBAC role definition"
echo "  rm -f azure-certbot.ini                 # certbot credentials"
echo "  rm -f bulk-records.ps1                  # PowerShell bulk script"
echo ""
echo "STEP 4: Verify cleanup is complete:"
echo ""
echo "  az group show --name $RESOURCE_GROUP 2>/dev/null && echo 'Still exists' || echo 'Deleted'"
echo ""


# ============================================================================
# QUICK REFERENCE CARD
# ============================================================================

echo ""
echo "========================================"
echo " QUICK REFERENCE — Common Commands"
echo "========================================"
echo ""
echo "--- Zone Management ---"
echo "List all zones:"
echo "  az network dns zone list -g $RESOURCE_GROUP -o table"
echo ""
echo "List records in a zone:"
echo "  az network dns record-set list -g $RESOURCE_GROUP -z $PUBLIC_ZONE -o table"
echo ""
echo "Add an A record:"
echo "  az network dns record-set a add-record -g $RESOURCE_GROUP -z $PUBLIC_ZONE -n <name> -a <ip>"
echo ""
echo "Delete a record set:"
echo "  az network dns record-set a delete -g $RESOURCE_GROUP -z $PUBLIC_ZONE -n <name> --yes"
echo ""
echo "--- Zone Snapshots ---"
echo "Export zone to file (on-demand snapshot):"
echo "  az network dns zone export -g $RESOURCE_GROUP -n $PUBLIC_ZONE -f snapshot-\$(date +%Y%m%d).zone"
echo ""
echo "Re-import from snapshot:"
echo "  az network dns zone import -g $RESOURCE_GROUP -n $PUBLIC_ZONE -f snapshot.zone"
echo ""
echo "--- DigiCert DCV ---"
echo "Create _dnsauth TXT (DigiCert DCV):"
echo "  az network dns record-set txt add-record -g $RESOURCE_GROUP -z $PUBLIC_ZONE -n '_dnsauth' -v '<token>'"
echo ""
echo "Verify _dnsauth resolves:"
echo "  dig @<nameserver> _dnsauth.$PUBLIC_ZONE TXT +short"
echo ""
echo "Clean up _dnsauth:"
echo "  az network dns record-set txt remove-record -g $RESOURCE_GROUP -z $PUBLIC_ZONE -n '_dnsauth' -v '<token>'"
echo ""
echo "--- Logging & Reporting ---"
echo "Check diagnostic settings:"
echo "  az monitor diagnostic-settings list --resource <zone-resource-id> -o table"
echo ""
echo "Get Event Hub connection string (for QRadar):"
echo "  az eventhubs namespace authorization-rule keys list -g $RESOURCE_GROUP \\"
echo "    --namespace-name $EVENTHUB_NAMESPACE -n RootManageSharedAccessKey --query primaryConnectionString -o tsv"
echo ""
echo "View Activity Log (audit trail):"
echo "  az monitor activity-log list -g $RESOURCE_GROUP --offset 1h \\"
echo "    --query \"[?contains(resourceType,'dnsZones')].{Time:eventTimestamp,Op:operationName.localizedValue,User:caller}\" -o table"
echo ""
echo "--- DNS Testing ---"
echo "Check zone nameservers:"
echo "  az network dns zone show -g $RESOURCE_GROUP -n $PUBLIC_ZONE --query nameServers -o tsv"
echo ""
echo "Test DNS resolution:"
echo "  dig @<nameserver> <record>.$PUBLIC_ZONE <type> +short"
echo ""
echo "--- Traffic Manager ---"
echo "Check failover profile:"
echo "  az network traffic-manager profile show -g $RESOURCE_GROUP -n tm-poc-failover -o table"
echo ""
echo "Check endpoint status:"
echo "  az network traffic-manager endpoint list -g $RESOURCE_GROUP --profile-name tm-poc-failover -o table"
echo ""
echo "========================================"
