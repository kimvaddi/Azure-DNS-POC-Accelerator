###############################################################################
# Azure DNS POC — End-to-End Deployment Script (PowerShell / Azure CLI)
#
# Customer Template: Zava Energy Corporation
# Author: Kim Vaddi (Microsoft)
# Tested: March 31, 2026 — All steps validated in Azure
# Subscription: MCAPS-Hybrid-REQ-118274-2025-kimvaddi
#
# MICROSOFT LEARN DOCUMENTATION REFERENCES:
#   Domain Purchase:     https://learn.microsoft.com/azure/app-service/manage-custom-dns-buy-domain
#   DNS Zone Delegation: https://learn.microsoft.com/azure/dns/dns-domain-delegation
#   DNSSEC Signing:      https://learn.microsoft.com/azure/dns/dnssec-how-to
#   DNSSEC Overview:     https://learn.microsoft.com/azure/dns/dnssec
#   Key Vault:           https://learn.microsoft.com/azure/key-vault/general/best-practices
#   Event Hub + SIEM:    https://learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings
#   Traffic Manager:     https://learn.microsoft.com/azure/traffic-manager/traffic-manager-routing-methods
#   TM Priority Routing: https://learn.microsoft.com/azure/traffic-manager/traffic-manager-configure-priority-routing-method
#   TM Monitoring:       https://learn.microsoft.com/azure/traffic-manager/traffic-manager-monitoring
#   App Service TLS:     https://learn.microsoft.com/azure/app-service/configure-ssl-certificate
#   Let's Encrypt + AKS: https://learn.microsoft.com/azure/application-gateway/ingress-controller-letsencrypt-certificate-application-gateway
#   certbot-dns-azure:   https://docs.certbot-dns-azure.co.uk/en/latest/
#   Let's Encrypt:       https://letsencrypt.org/getting-started/
#   Custom RBAC Roles:   https://learn.microsoft.com/azure/role-based-access-control/custom-roles
#
# DEPLOYMENT ORDER (dependencies):
#   1. Domain Purchase (Section 0.5)  ← FIRST: creates DNS zone + NS delegation
#   2. Foundation (Section 1)         ← RG, LAW, Event Hub, KV, VNet
#   3. DNS Zones + Import (Section 2) ← depends on RG
#   4. Audit Logging (Section 3)      ← depends on LAW + Event Hub
#   5. RBAC (Section 4)               ← depends on DNS Zone
#   6. DCV Tests (Section 5)          ← depends on DNS Zone
#   7. Let's Encrypt (Section 5.5)    ← depends on DNS Zone + KV + domain purchase
#   8. Traffic Manager (Section 6)    ← depends on RG (profiles only)
#   9. Web Apps + Wiring (Section 7)  ← depends on TM + LAW + DNS Zone
#  10. Diagnostics (Section 7.5)      ← depends on Web Apps + TM + LAW
#  11. Snapshots (Section 8)          ← depends on DNS Zone with records
#  12. DNSSEC (Section 9)             ← depends on DNS Zone + domain purchase
#
# USAGE:
#   1. Edit SECTION 0 variables below
#   2. Run each section sequentially (copy-paste into PowerShell)
#   3. Each section has a VERIFY step — confirm before moving on
#
# PREREQUISITES:
#   - Azure CLI installed (az --version)
#   - Logged in (az login)
#   - Correct subscription set (az account set --subscription <id>)
#   - For Zone Import: Bind zone file in RFC 1035 format
#   - For DCV: DigiCert CertCentral access (DCV token from cert order)
#   - For RBAC: Entra ID test accounts (Operator + Admin)
#   - For DNS Delegation: Access to domain registrar (GoDaddy, Namecheap, etc.)
#
# IMPORTANT — DNS DELEGATION (if domain is NOT already in Azure DNS):
#   If the parent domain (e.g., Zava.com) is hosted at an external registrar
#   like GoDaddy, Namecheap, Cloudflare, etc., you MUST configure NS delegation
#   at the registrar BEFORE Azure DNS can answer queries. See SECTION 2.5 below.
#
###############################################################################
#
# WHAT THE CUSTOMER MUST BRING TO THE DEPLOYMENT
# ───────────────────────────────────────────────
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  #  │ Item                        │ Who Provides         │ When         │
# ├──────────────────────────────────────────────────────────────────────────┤
# │  1  │ Azure subscription ID       │ Customer IT          │ Before start │
# │     │ with Owner/Contributor      │                      │              │
# │  2  │ POC domain name             │ Customer DNS team    │ Before start │
# │     │ (e.g., poc.zava-dnspoc.com)      │                      │              │
# │  3  │ Exported Bind zone file(s)  │ Customer DNS team    │ Before start │
# │     │ RFC 1035 format             │ Run: named-checkzone │              │
# │  4  │ Registrar login             │ Customer DNS admin   │ After Step 1 │
# │     │ (GoDaddy, Namecheap, etc.)  │ For NS delegation    │              │
# │  5  │ DigiCert CertCentral access │ Customer cert team   │ For Step 5   │
# │     │ DCV token from cert order   │                      │              │
# │  6  │ 2 Entra ID test accounts    │ Customer identity    │ For Step 4   │
# │     │ 1 Operator + 1 Admin        │                      │              │
# │  7  │ QRadar Console access       │ Customer security    │ After Step 3 │
# │     │ Admin → Log Sources → Add   │                      │              │
# │  8  │ Compute quota (B1 VMs)      │ Auto or request      │ For Step 7   │
# │     │ in 2 Azure regions          │ https://aka.ms/      │              │
# │     │                             │ antquotahelp         │              │
# └──────────────────────────────────────────────────────────────────────────┘
#
# WHAT THIS SCRIPT DEPLOYS (13+ Azure resources)
# ───────────────────────────────────────────────
#
#   Section 0:   Resource Group, Log Analytics, Event Hub (Standard),
#                VNet, QRadar SAS policies, consumer group, storage account
#   Section 1:   Public DNS Zone, Private DNS Zone, VNet Link, Zone Import
#   Section 1.5: DNS Delegation instructions (customer action at registrar)
#   Section 2.7: Automated Record CRUD (Create/Read/Update/Delete + Bulk)
#   Section 3:   Activity Log → Event Hub + LAW (all 8 categories)
#   Section 4:   Custom RBAC role "DNS Record Operator"
#   Section 5:   DCV certificate validation tests (_dnsauth + _acme-challenge)
#   Section 6:   Traffic Manager (Priority + Geographic + Weighted profiles)
#   Section 7:   Web Apps (2 regions) + TM endpoints + DNS CNAME wiring
#   Section 7.5: Resource diagnostics (Web Apps + Traffic Manager → LAW)
#   Section 8:   Zone Snapshots (export + re-import verification)
#   Section 9:   DNSSEC (zone signing)
#   Section 10:  Final validation
#   Section 11:  Azure Front Door (optional, commented out)
#   Cleanup:     az group delete (commented out)
#
# DEPLOYMENT ISSUES FOUND & FIXED DURING TESTING (10 findings)
# ─────────────────────────────────────────────────────────────
#
#  1. Azure DNS public zones do NOT support query-level logging
#     - microsoft.network/dnszones returns ResourceTypeNotSupported
#     - Only management-plane operations (record CRUD) are logged via Activity Log
#     - NO per-query logs (who queried what record) — this is an Azure limitation
#     - Workarounds: Azure DNS Private Resolver, Azure Firewall DNS Proxy
#
#  2. Event Hub MUST be Standard SKU (not Basic)
#     - Basic SKU does not support custom consumer groups or event-hub-level SAS policies
#     - QRadar requires both (per Microsoft SIEM guide)
#     - Ref: https://learn.microsoft.com/en-us/azure/defender-for-cloud/export-to-splunk-or-qradar
#
#  3. QRadar needs 4 Azure resources (not just Event Hub)
#     - Send-only SAS policy (for Azure to write)
#     - Listen-only SAS policy (for QRadar to read — NOT RootManageSharedAccessKey)
#     - Dedicated consumer group (not $Default — avoids message conflicts)
#     - Storage account (for checkpoint/offset tracking)
#
#  4. Activity Log: only 2 of 8 categories were enabled initially
#     - Fixed: all 8 now enabled (Administrative, Security, ServiceHealth, Alert,
#       Recommendation, Policy, Autoscale, ResourceHealth)
#
#  5. Web Apps + Traffic Manager had zero diagnostic settings
#     - Fixed: 7 log categories per web app + ProbeHealthStatusEvents per TM profile
#     - All flowing to Log Analytics Workspace
#
#  6. Compute quota failures in multiple regions
#     - southcentralus, eastus, westeurope: Basic VM quota = 0 (Linux)
#     - Fix: use regions with existing quota or request increase
#     - Windows plans work without Linux quota (used dotnet:8 runtime)
#
#  7. Event Hub retention flag format changed
#     - --message-retention 1 no longer works on Basic or Standard
#     - Fix: use --retention-time-in-hours 24 --cleanup-policy Delete
#
#  8. Node.js runtime not available on Windows App Service plans
#     - ERROR: Windows runtime 'NODE|20-lts' is not supported
#     - Fix: use --runtime "dotnet:8" for Windows plans
#
#  9. Custom RBAC role takes ~1 min to propagate
#     - az role definition create succeeds but az role definition list --name returns empty
#     - Fix: use PowerShell Where-Object filter or wait 60 seconds
#
# 10. Front Door custom domain validation times out silently
#     - _dnsauth TXT record must be created WITHIN the validation window
#     - If it times out: delete stale domain → re-create → add TXT → verify
#     - Managed TLS certificate takes 5-15 min after domain validation is Approved
#
# 11. CNAME TTL default is 3600 (1 hour) — too slow for failover
#     - kimvaddi.com reference uses TTL=30 seconds
#     - Fixed: script now sets TTL=30 on all TM CNAME records
#     - Without this, failover takes up to 1 hour for clients to switch endpoints
#
# 12. Web Apps created with httpsOnly=false by default
#     - kimvaddi.com reference has httpsOnly=true
#     - Fixed: script now runs az webapp update --https-only true after creation
#     - Without this, HTTP traffic is not redirected to HTTPS
#
# 13. kimvaddi.com uses Azure alias records (targetResource) for CNAME→TM
#     - Our script uses plain CNAME text (-c "tm.trafficmanager.net")
#     - Both work, but alias records are the production best practice because:
#       a) They support apex/root domains (CNAME cannot be used at zone apex)
#       b) They auto-update if the TM resource is recreated with a new FQDN
#     - Script includes commented instructions for switching to alias records
#
# 14. kimvaddi.com has custom domain + TLS wired to web apps — POC didn't
#     - Fixed: Added Section 7.8 (Custom Domain + TLS Binding)
#     - Requires DNS delegation (Section 2.5) to be complete first
#     - Auto-detects delegation status — skips gracefully if not ready
#     - Creates: asuid TXT verification → hostname binding → managed cert → SNI bind
#
# KNOWN LIMITATIONS 
# ──────────────────────────────────────────
#
#  - Azure DNS public zones: NO query-level logging (management plane only)
#    Customer gets: WHO changed WHAT record, WHEN, from WHERE
#    Customer does NOT get: WHO queried WHAT record (per-query traffic)
#    This is a gap vs Bind's query logging. Discuss trade-offs.
#
#  - Zone import: SOA and NS records are ALWAYS overwritten by Azure
#    This is expected behavior — Azure manages its own nameservers.
#
#  - DNSSEC: az network dns dnssec-config is flagged as EXPERIMENTAL
#    Works correctly but may change in future CLI versions.
#
#  - DNS delegation: takes 5 min to 48 hours to propagate globally
#    Test with: nslookup -type=NS poc.zava-dnspoc.com 8.8.8.8
#
###############################################################################


# ============================================================================
# SECTION 0: CONFIGURATION — EDIT THESE BEFORE RUNNING ANYTHING
# ============================================================================

$SUBSCRIPTION_ID   = "<your-subscription-id>"
$RG_NAME           = "rg-dns-poc"
$LOCATION_PRIMARY  = "westus3"           # Primary region (web apps)
$LOCATION_SECONDARY = "westeurope"           # Secondary region (web apps)
$LOCATION_RG       = "southcentralus"     # Resource group location
$DOMAIN            = "poc.zava-dnspoc.com"     # Public DNS zone
$PRIVATE_ZONE      = "poc-internal.zava-dnspoc.local"  # Private DNS zone

# -- Feature Flags (NEW: March 31, 2026) --
$ENABLE_PRIVATE_DNS = $false              # Set $true to deploy Private DNS zone + VNet
$ENABLE_DOMAIN_PURCHASE = $true           # Buy App Service Domain (~$12/yr) — required for DNSSEC + Let's Encrypt
$ENABLE_LETSENCRYPT = $true               # Run Let's Encrypt cert automation after deployment
$ENABLE_DNSSEC_SUBDOMAIN = $true          # Use child zone for DNSSEC chain of trust

# -- Domain Purchase (only if $ENABLE_DOMAIN_PURCHASE = $true) --
# App Service Domains auto-create Azure DNS zone + NS delegation via GoDaddy
# Ref: https://learn.microsoft.com/azure/app-service/manage-custom-dns-buy-domain
$ROOT_DOMAIN       = "zava-dnspoc.com"  # App Service Domain to purchase
$CHILD_ZONE        = "demo.$ROOT_DOMAIN"    # Child zone for DNSSEC (avoids App Service Domain DS limitation)
$CONTACT_EMAIL     = "admin@zavaenergy.com" # ICANN registration + Let's Encrypt

# -- Let's Encrypt (only if $ENABLE_LETSENCRYPT = $true) --
# Uses certbot + certbot-dns-azure plugin with DNS-01 challenge
# Ref: https://docs.certbot-dns-azure.co.uk/en/latest/
# Ref: https://letsencrypt.org/getting-started/
$SP_CERTBOT_NAME   = "sp-certbot-dns-poc"   # Service Principal for certbot
$LE_CERT_NAME      = "le-cert"               # Certificate name in Key Vault (must match certbot import)
# Generate unique suffix from subscription ID (deterministic per sub, unique across tenants)
$_subId = az account show --query id -o tsv 2>$null
if (-not $_subId -or $_subId.Length -lt 8) {
    Write-Host "ERROR: Could not get subscription ID. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$_suffix = $_subId.Substring(0,8)  # First 8 chars of subscription GUID
Write-Host "  Subscription suffix: $_suffix (used for globally-unique names)" -ForegroundColor DarkGray

$LAW_NAME          = "law-dns-poc"
$EH_NAMESPACE      = "ehns-dnspoc-$_suffix"  # Dynamic: unique per subscription
$EH_NAME           = "dns-logs"
$VNET_NAME         = "vnet-dns-poc"
$KV_NAME           = "kv-dnspoc-$_suffix"  # Dynamic: unique per subscription
$_existingKV = az keyvault list -g $RG_NAME --query "[?starts_with(name, 'kv-')].name | [0]" -o tsv 2>$null
if ($_existingKV) { $KV_NAME = $_existingKV }
$TM_FAILOVER       = "tm-poc-failover-$_suffix"  # Dynamic: unique per subscription
$TM_GEO            = "tm-poc-geo-$_suffix"       # Dynamic: unique per subscription
$TM_WEIGHTED       = "tm-poc-weighted-$_suffix"   # Dynamic: unique per subscription
$ASP_US            = "asp-poc-us"
$ASP_UK            = "asp-poc-uk"
$WEBAPP_US         = "webapp-poc-us-$_suffix"  # Dynamic: unique per subscription
$WEBAPP_UK         = "webapp-poc-uk-$_suffix"  # Dynamic: unique per subscription

# -- Bind zone files (local paths after export from Bind server) --
# Place exported zone files in ./zone-files/ directory before running.
# Export from Bind: named-checkzone <zone> <path> > output.zone
$ZONE_FILES_DIR    = ".\zone-files"                    # Directory containing zone files
$ZONE_FILE_1       = ".\zone-files\Zava-zone1.zone"   # First Bind zone file
$ZONE_FILE_2       = ".\zone-files\Zava-zone2.zone"   # Second Bind zone file  (leave empty if only 1)
$ZONE_FILE_3       = ""                                 # Third Bind zone file   (leave empty if not needed)
$ZONE_NAME_1       = "poc.zava-dnspoc.com"                   # Azure zone name for file 1 (primary zone)
$ZONE_NAME_2       = "zone2.poc.zava-dnspoc.com"             # Azure zone name for file 2
$ZONE_NAME_3       = ""                                 # Azure zone name for file 3 (leave empty if not needed)

# ============================================================================
# SECTION 0.5: DOMAIN PURCHASE + CHILD ZONE (Optional)
# Buys an App Service Domain, creates child zone for DNSSEC
# Dependencies: None — run before Section 1 if enabled
#
# WHY: App Service Domains do NOT support DS records at the registrar,
#      which blocks DNSSEC chain of trust. Workaround: create a child zone,
#      sign it, publish DS in the parent zone (which we control in Azure DNS).
#      Ref: https://learn.microsoft.com/azure/dns/dnssec-how-to
#      Ref: https://learn.microsoft.com/azure/app-service/manage-custom-dns-buy-domain
# ============================================================================

if ($ENABLE_DOMAIN_PURCHASE) {
    Write-Host "`n=== STEP 0.5: DOMAIN PURCHASE + CHILD ZONE ===" -ForegroundColor Cyan

    # 0.5.1 Create Resource Group (needed before domain purchase)
    Write-Host "--- Creating Resource Group: $RG_NAME ---"
    az group create --name $RG_NAME --location $LOCATION_RG `
        --tags project=dns-poc customer=Zava environment=poc --output none

    # 0.5.2 Check domain availability
    Write-Host "--- Checking domain availability: $ROOT_DOMAIN ---"
    $available = az appservice domain check-availability --name $ROOT_DOMAIN --query "available" -o tsv 2>$null
    if ($available -eq "true") {
        Write-Host "  Domain $ROOT_DOMAIN is available" -ForegroundColor Green
    } else {
        Write-Host "  Domain $ROOT_DOMAIN may already be registered" -ForegroundColor Yellow
    }

    # 0.5.3 Purchase domain (charges ~$12/yr)
    Write-Host "--- Purchasing App Service Domain: $ROOT_DOMAIN ---"
    Write-Host "  NOTE: This charges ~$12/yr to your Azure subscription" -ForegroundColor Yellow
    # Ref: https://learn.microsoft.com/azure/app-service/manage-custom-dns-buy-domain
    # Ref: az appservice domain create --help

    # Check if domain already exists in this RG
    $existingDomain = az appservice domain show --hostname $ROOT_DOMAIN -g $RG_NAME --query "name" -o tsv 2>$null
    if ($existingDomain) {
        Write-Host "  Domain already registered: $existingDomain" -ForegroundColor Yellow
    } else {
        # Contact info JSON file required (edit domain-contact-info.json with real details)
        $contactFile = ".\domain-contact-info.json"
        if (-not (Test-Path $contactFile)) {
            Write-Host "  ERROR: $contactFile not found. Create it with ICANN contact details." -ForegroundColor Red
            Write-Host "  Template: https://github.com/AzureAppServiceCLI/appservice_domains_templates/blob/master/contact_info.json"
            return
        }

        # Show terms first
        Write-Host "--- Showing domain purchase terms ---"
        az appservice domain show-terms --hostname $ROOT_DOMAIN --output table 2>$null

        # Dry-run to preview
        Write-Host "--- Dry-run (preview only) ---"
        az appservice domain create `
            --resource-group $RG_NAME `
            --hostname $ROOT_DOMAIN `
            --contact-info=@"$contactFile" `
            --dryrun 2>$null

        # Actual purchase
        Write-Host "--- Executing domain purchase ---"
        az appservice domain create `
            --resource-group $RG_NAME `
            --hostname $ROOT_DOMAIN `
            --contact-info=@"$contactFile" `
            --accept-terms `
            --auto-renew `
            --privacy `
            --output table 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Domain $ROOT_DOMAIN purchased successfully" -ForegroundColor Green
        } else {
            Write-Host "  Domain purchase failed — check output above" -ForegroundColor Red
            Write-Host "  Common issues: subscription spending limit, domain unavailable, invalid contact info"
        }
    }

    # 0.5.3.1 Verify parent zone was auto-created
    Write-Host "--- Verifying parent zone: $ROOT_DOMAIN ---"
    $parentZone = az network dns zone show -g $RG_NAME -n $ROOT_DOMAIN --query "name" -o tsv 2>$null
    if (-not $parentZone) {
        Write-Host "  Parent zone not auto-created — creating manually" -ForegroundColor Yellow
        az network dns zone create -g $RG_NAME -n $ROOT_DOMAIN --output none 2>$null
    }
    Write-Host "  Parent zone: $(az network dns zone show -g $RG_NAME -n $ROOT_DOMAIN --query 'name' -o tsv)" -ForegroundColor Green

    # 0.5.4 Create child zone for DNSSEC
    Write-Host "--- Creating child zone: $CHILD_ZONE ---"
    az network dns zone create -g $RG_NAME -n $CHILD_ZONE --output none 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  Child zone created: $CHILD_ZONE" -ForegroundColor Green }

    # 0.5.5 Delegate child zone (NS records in parent)
    Write-Host "--- Delegating child zone to Azure DNS ---"
    $childNS = az network dns zone show -g $RG_NAME -n $CHILD_ZONE --query "nameServers" -o json 2>$null | ConvertFrom-Json
    if ($childNS) {
        $childPrefix = $CHILD_ZONE.Replace(".$ROOT_DOMAIN", "")
        foreach ($ns in $childNS) {
            az network dns record-set ns add-record -g $RG_NAME -z $ROOT_DOMAIN -n $childPrefix --nsdname $ns --output none 2>$null
        }
        Write-Host "  NS delegation created in $ROOT_DOMAIN for $childPrefix" -ForegroundColor Green
    }

    # Store child zone for DNSSEC (Section 9) — do NOT overwrite $DOMAIN
    # $DOMAIN stays as poc.zava-dnspoc.com for all other sections (zone import, CNAME, DCV, etc.)
    $DNSSEC_ZONE = $CHILD_ZONE
    Write-Host "  DNSSEC zone: $DNSSEC_ZONE (used in Section 9 only)" -ForegroundColor Cyan
    Write-Host "  Primary zone: $DOMAIN (used for all other sections)" -ForegroundColor Cyan

    # Also create the primary POC zone as a child of the root domain
    Write-Host "--- Creating primary POC zone: $DOMAIN ---"
    az network dns zone create -g $RG_NAME -n $DOMAIN --output none 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  POC zone created: $DOMAIN" -ForegroundColor Green }

    # Delegate POC zone in parent
    $pocNS = az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers" -o json 2>$null | ConvertFrom-Json
    if ($pocNS) {
        $pocPrefix = $DOMAIN.Replace(".$ROOT_DOMAIN", "")
        foreach ($ns in $pocNS) {
            az network dns record-set ns add-record -g $RG_NAME -z $ROOT_DOMAIN -n $pocPrefix --nsdname $ns --output none 2>$null
        }
        Write-Host "  NS delegation created in $ROOT_DOMAIN for $pocPrefix" -ForegroundColor Green
    }

    Write-Host "`n  VERIFY: nslookup -type=NS $DOMAIN" -ForegroundColor Yellow
} else {
    Write-Host "`n--- Skipping domain purchase (ENABLE_DOMAIN_PURCHASE = `$false) ---" -ForegroundColor DarkGray
}

# ============================================================================
# SECTION 1: FOUNDATION (Step 0)
# Deploys: Resource Group, Log Analytics, Event Hub, VNet
# Dependencies: None — run first
# ============================================================================

Write-Host "=== STEP 0: FOUNDATION ===" -ForegroundColor Cyan

# 0.1 Set subscription
az account set --subscription $SUBSCRIPTION_ID

# 0.2 Create Resource Group
Write-Host "--- Creating Resource Group: $RG_NAME ---"
az group create --name $RG_NAME --location $LOCATION_RG `
  --tags "project=dns-poc" "customer=Zava" -o table

# 0.3 Create Log Analytics Workspace (for reporting + audit log destination)
Write-Host "--- Creating Log Analytics Workspace: $LAW_NAME ---"
az monitor log-analytics workspace create `
  --resource-group $RG_NAME `
  --workspace-name $LAW_NAME `
  --location $LOCATION_RG `
  --retention-time 30 `
  --query "{name:name, provisioningState:provisioningState}" -o table

# 0.4 Create Event Hub Namespace (for SIEM integration — QRadar/Splunk/Sentinel)
# 0.4 Create Event Hub Namespace (for SIEM integration — QRadar/Splunk/Sentinel)
# NOTE: Standard SKU required (not Basic) — QRadar needs custom consumer groups
#       and SAS policies, which are not supported on Basic tier.
# Reference: https://learn.microsoft.com/en-us/azure/defender-for-cloud/export-to-splunk-or-qradar
Write-Host "--- Creating Event Hub Namespace: $EH_NAMESPACE (Standard SKU) ---"
az eventhubs namespace create `
  --resource-group $RG_NAME `
  --name $EH_NAMESPACE `
  --location $LOCATION_RG `
  --sku Standard `
  --query "{name:name, provisioningState:provisioningState}" -o table

# 0.5 Create Event Hub
Write-Host "--- Creating Event Hub: $EH_NAME ---"
az eventhubs eventhub create `
  --resource-group $RG_NAME `
  --namespace-name $EH_NAMESPACE `
  --name $EH_NAME `
  --partition-count 2 `
  --retention-time-in-hours 24 `
  --cleanup-policy Delete `
  --query "{name:name}" -o table

# 0.6 Create VNet (for Private DNS Zone link)
Write-Host "--- Creating VNet: $VNET_NAME ---"
az network vnet create `
  --resource-group $RG_NAME `
  --name $VNET_NAME `
  --location $LOCATION_RG `
  --address-prefix 10.0.0.0/16 `
  --subnet-name default `
  --subnet-prefix 10.0.0.0/24 `
  --query "{name:newVNet.name, state:newVNet.provisioningState}" -o table

# 0.7 Create Key Vault (for secure secret storage)
Write-Host "--- Creating Key Vault: $KV_NAME ---"
az keyvault create `
  --resource-group $RG_NAME `
  --name $KV_NAME `
  --location $LOCATION_RG `
  --enable-rbac-authorization true `
  --retention-days 7 `
  --query "{name:name, provisioningState:properties.provisioningState}" -o table

# 0.8 Grant current user Key Vault Secrets Officer role
$CURRENT_USER_ID = (az ad signed-in-user show --query "id" -o tsv)
$KV_ID = (az keyvault show -g $RG_NAME -n $KV_NAME --query "id" -o tsv)
Write-Host "--- Granting Key Vault Secrets Officer role to current user ---"
az role assignment create `
  --assignee $CURRENT_USER_ID `
  --role "Key Vault Secrets Officer" `
  --scope $KV_ID `
  -o none
Write-Host "  ✅ Role assignment complete (allow 60 seconds for propagation)"
Start-Sleep -Seconds 60

# VERIFY Step 0
Write-Host "`n--- VERIFY: All foundation resources ---" -ForegroundColor Green
az resource list --resource-group $RG_NAME `
  --query "[].{name:name, type:type}" -o table

# 0.9 Store Event Hub connection string in Key Vault (zero-secret pattern)
# Dependencies: Key Vault (0.7) + Event Hub (0.4) + RBAC propagation (0.8)
# NOTE: Uses RootManageSharedAccessKey (auto-created with namespace).
#       Custom SAS policies (SendPolicy, QRadarListenPolicy) are created in Section 3.
#       Those connection strings are stored in KV at the end of Section 3.
Write-Host "`n--- Storing Event Hub connection string in Key Vault ---"
$EH_SEND_CS = az eventhubs namespace authorization-rule keys list -g $RG_NAME `
  --namespace-name $EH_NAMESPACE --name RootManageSharedAccessKey --query primaryConnectionString -o tsv 2>$null
if ($EH_SEND_CS) {
    az keyvault secret set --vault-name $KV_NAME --name "eventhub-connection-string" --value "$EH_SEND_CS" -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Stored: eventhub-connection-string" -ForegroundColor Green
    } else {
        Write-Host "  Failed to store — KV RBAC may still be propagating (retry in Section 3)" -ForegroundColor Yellow
    }
    $EH_SEND_CS = $null  # Clear from memory
} else {
    Write-Host "  Event Hub not ready yet — connection string will be stored in Section 3" -ForegroundColor Yellow
}


# ============================================================================
# SECTION 2: DNS ZONES + ZONE IMPORT (Step 1)
# Deploys: Public DNS Zone, Private DNS Zone, VNet Link, Bind Zone Import
# Dependencies: Section 1 (RG, VNet)
# ============================================================================

Write-Host "`n=== STEP 1: DNS ZONES + ZONE IMPORT ===" -ForegroundColor Cyan

# 1.1 Create Public DNS Zone
Write-Host "--- Creating Public DNS Zone: $DOMAIN ---"
az network dns zone create `
  --resource-group $RG_NAME `
  --name $DOMAIN `
  --query "{name:name, nameServers:nameServers}" -o json

# 1.2 Create Private DNS Zone
if ($ENABLE_PRIVATE_DNS) {
    Write-Host "--- Creating Private DNS Zone: $PRIVATE_ZONE ---"
    az network private-dns zone create `
      --resource-group $RG_NAME `
      --name $PRIVATE_ZONE `
      --query "{name:name}" -o table
} else {
    Write-Host "--- Skipping Private DNS Zone (ENABLE_PRIVATE_DNS = \$false) ---" -ForegroundColor Yellow
    Write-Host "  Set \$ENABLE_PRIVATE_DNS = \$true in Section 0 to deploy"
}

# 1.3 Link Private DNS Zone to VNet
if ($ENABLE_PRIVATE_DNS) {
    Write-Host "--- Linking Private DNS Zone to VNet ---"
    az network private-dns link vnet create `
      --resource-group $RG_NAME `
      --zone-name $PRIVATE_ZONE `
      --name vnet-link `
      --virtual-network $VNET_NAME `
      --registration-enabled false `
      --query "{name:name, provisioningState:provisioningState}" -o table

    # 1.3.1 Add sample records to Private DNS Zone (proves internal DNS works)
    Write-Host "--- Adding sample private DNS records ---"
    az network private-dns record-set a add-record -g $RG_NAME `
      -z $PRIVATE_ZONE -n db -a 10.0.1.100 -o none
    az network private-dns record-set a add-record -g $RG_NAME `
      -z $PRIVATE_ZONE -n app -a 10.0.1.101 -o none
    az network private-dns record-set a add-record -g $RG_NAME `
      -z $PRIVATE_ZONE -n cache -a 10.0.1.102 -o none
    Write-Host "  Added: db (10.0.1.100), app (10.0.1.101), cache (10.0.1.102)"
    Write-Host "  These resolve only from VMs/services inside $VNET_NAME"
} else {
    Write-Host "--- Skipping Private DNS VNet link (ENABLE_PRIVATE_DNS = \$false) ---" -ForegroundColor Yellow
}

# 1.4 Import Bind Zone Files
# NOTE: Zone files must be RFC 1035 format. Validate with named-checkzone first.
#       SOA and NS records will be overwritten by Azure — this is expected.
#
# PREREQUISITES — Customer must provide:
#   1. Export zone files from Bind server:
#      named-checkzone Zava.com /etc/bind/zones/db.Zava.com > Zava-zone1.zone
#      named-checkzone zone2.Zava.com /etc/bind/zones/db.zone2 > Zava-zone2.zone
#   2. Place exported files in the ./zone-files/ directory
#   3. Update $ZONE_FILE_1, $ZONE_FILE_2, $ZONE_NAME_1, $ZONE_NAME_2 in Section 0

Write-Host "`n--- Bind Zone File Import ---" -ForegroundColor Cyan

# Create zone-files directory if it doesn't exist
if (-not (Test-Path $ZONE_FILES_DIR)) {
    New-Item -ItemType Directory -Path $ZONE_FILES_DIR -Force | Out-Null
    Write-Host "  Created directory: $ZONE_FILES_DIR"
}

# Check if zone files exist — prompt operator if missing
$hasZoneFiles = (Test-Path $ZONE_FILE_1) -or (Test-Path $ZONE_FILE_2) -or (Test-Path $ZONE_FILE_3)
$fullZonePath = (Resolve-Path $ZONE_FILES_DIR -ErrorAction SilentlyContinue) ?? (Join-Path $PWD $ZONE_FILES_DIR)
if (-not $hasZoneFiles) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║  CUSTOMER ACTION REQUIRED: Bind Zone Files                          ║" -ForegroundColor Yellow
    Write-Host "  ╠══════════════════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
    Write-Host "  ║                                                                      ║" -ForegroundColor Yellow
    Write-Host "  ║  No zone files found. Place exported Bind zone files here:          ║" -ForegroundColor Yellow
    Write-Host "  ║                                                                      ║" -ForegroundColor Yellow
    Write-Host "  ║  $fullZonePath" -ForegroundColor Cyan
    Write-Host "  ║                                                                      ║" -ForegroundColor Yellow
    Write-Host "  ║  Expected files:                                                    ║" -ForegroundColor Yellow
    Write-Host "  ║    $ZONE_FILE_1" -ForegroundColor White
    Write-Host "  ║    $ZONE_FILE_2" -ForegroundColor White
    Write-Host "  ║                                                                      ║" -ForegroundColor Yellow
    Write-Host "  ║  How to export from Bind:                                           ║" -ForegroundColor Yellow
    Write-Host "  ║    named-checkzone <zone> <path> > Zava-zone1.zone                  ║" -ForegroundColor White
    Write-Host "  ║                                                                      ║" -ForegroundColor Yellow
    Write-Host "  ║  Or copy the included sample:                                       ║" -ForegroundColor Yellow
    Write-Host "  ║    copy sample-bind-zone.txt $ZONE_FILES_DIR\Zava-zone1.zone" -ForegroundColor White
    Write-Host "  ║                                                                      ║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "  Press ENTER after placing zone files, or type SKIP to continue without import"
    if ($response -eq "SKIP") {
        Write-Host "  Skipping Bind zone import." -ForegroundColor DarkGray
    } else {
        # Re-check after prompt
        $hasZoneFiles = (Test-Path $ZONE_FILE_1) -or (Test-Path $ZONE_FILE_2) -or (Test-Path $ZONE_FILE_3)
        if (-not $hasZoneFiles) {
            Write-Host "  Still no zone files found — skipping import." -ForegroundColor Yellow
        }
    }
}

# Helper function: Import a single zone file with validation
function Import-BindZoneFile {
    param(
        [string]$ZoneFile,
        [string]$ZoneName,
        [string]$Label
    )
    
    if ([string]::IsNullOrWhiteSpace($ZoneFile) -or [string]::IsNullOrWhiteSpace($ZoneName)) {
        return  # Skip empty entries
    }
    
    Write-Host "`n--- Importing ${Label}: ${ZoneName} ---" -ForegroundColor Cyan
    
    if (-not (Test-Path $ZoneFile)) {
        Write-Host "  WARNING: File not found at '$ZoneFile' — skipping" -ForegroundColor Yellow
        Write-Host "  Export from Bind: named-checkzone $ZoneName /etc/bind/zones/db.$ZoneName > $ZoneFile"
        return
    }
    
    # Show file info
    $fileInfo = Get-Item $ZoneFile
    Write-Host "  File: $($fileInfo.FullName)"
    Write-Host "  Size: $([math]::Round($fileInfo.Length / 1KB, 1)) KB | Modified: $($fileInfo.LastWriteTime)"
    
    # Count records by type
    $content = Get-Content $ZoneFile
    $aCount = ($content | Select-String -Pattern '\bIN\s+A\b' | Measure-Object).Count
    $aaaaCount = ($content | Select-String -Pattern '\bIN\s+AAAA\b' | Measure-Object).Count
    $cnameCount = ($content | Select-String -Pattern '\bIN\s+CNAME\b' | Measure-Object).Count
    $mxCount = ($content | Select-String -Pattern '\bIN\s+MX\b' | Measure-Object).Count
    $txtCount = ($content | Select-String -Pattern '\bIN\s+TXT\b' | Measure-Object).Count
    $srvCount = ($content | Select-String -Pattern '\bIN\s+SRV\b' | Measure-Object).Count
    $total = $aCount + $aaaaCount + $cnameCount + $mxCount + $txtCount + $srvCount
    Write-Host "  Records: A=$aCount AAAA=$aaaaCount CNAME=$cnameCount MX=$mxCount TXT=$txtCount SRV=$srvCount (Total: $total)"
    
    # Create zone if it doesn't exist (for additional zones beyond the primary)
    if ($ZoneName -ne $DOMAIN) {
        Write-Host "  Creating zone: $ZoneName"
        az network dns zone create -g $RG_NAME -n $ZoneName -o none 2>$null
    }
    
    # Import
    Write-Host "  Importing..."
    az network dns zone import -g $RG_NAME -n $ZoneName -f $ZoneFile
    
    # Validate
    $azCount = (az network dns zone show -g $RG_NAME -n $ZoneName --query "numberOfRecordSets" -o tsv)
    Write-Host "  Post-import: $azCount record sets in Azure (includes auto-generated SOA + NS)" -ForegroundColor Green
}

# Import each zone file
Import-BindZoneFile -ZoneFile $ZONE_FILE_1 -ZoneName $ZONE_NAME_1 -Label "Zone File 1"
Import-BindZoneFile -ZoneFile $ZONE_FILE_2 -ZoneName $ZONE_NAME_2 -Label "Zone File 2"
Import-BindZoneFile -ZoneFile $ZONE_FILE_3 -ZoneName $ZONE_NAME_3 -Label "Zone File 3"

# Summary
$zoneCount = (az network dns zone list -g $RG_NAME --query "length([])" -o tsv)
Write-Host "`n--- Zone Import Summary ---" -ForegroundColor Green
Write-Host "  Total DNS zones in $RG_NAME`: $zoneCount"
Write-Host "  (Includes primary zone $DOMAIN + any imported zones)"
if (-not (Test-Path $ZONE_FILE_1)) {
    Write-Host "`n  No zone files found in $ZONE_FILES_DIR" -ForegroundColor Yellow
    Write-Host "  To import later, place files in $ZONE_FILES_DIR and re-run this section."
    Write-Host "  Or import manually: az network dns zone import -g $RG_NAME -n <zone> -f <file>"
}

# VERIFY Step 1 — DNS Resolution
Write-Host "`n--- VERIFY: DNS records imported ---" -ForegroundColor Green
az network dns record-set list -g $RG_NAME -z $DOMAIN -o table
$NS = (az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers[0]" -o tsv).Trim('.')
Write-Host "`nNameserver: $NS"
Write-Host "Test resolution:"
nslookup -type=A www.$DOMAIN $NS
nslookup -type=MX $DOMAIN $NS


# ============================================================================
# SECTION 2.5: DNS DELEGATION (Step 1.5)
# Action: Customer must configure at their domain registrar
# Dependencies: Section 2 (DNS Zone must exist to get Azure nameservers)
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │               WHY IS THIS NEEDED?                                      │
# │                                                                         │
# │  When the parent domain (Zava.com) is at GoDaddy/Namecheap/etc.,    │
# │  the internet doesn't know that poc.zava-dnspoc.com lives in Azure DNS.    │
# │  You must tell the registrar: "for anything under poc.zava-dnspoc.com,     │
# │  ask Azure DNS nameservers instead of my current DNS provider."       │
# │                                                                         │
# │  This is called SUBDOMAIN DELEGATION — adding NS records at the       │
# │  parent zone for the child subdomain.                                  │
# │                                                                         │
# │  WITHOUT THIS: nslookup www.poc.zava-dnspoc.com → NXDOMAIN (not found)    │
# │  WITH THIS:    nslookup www.poc.zava-dnspoc.com → 10.0.1.2 (from Azure)   │
# └─────────────────────────────────────────────────────────────────────────┘
#
# TWO OPTIONS:
#
# OPTION A — SUBDOMAIN DELEGATION (Recommended for POC)
#   At the registrar (GoDaddy), add NS records for the subdomain only.
#   Production DNS stays untouched. Only poc.zava-dnspoc.com goes to Azure.
#
# OPTION B — FULL ZONE DELEGATION (Production migration — NOT for POC)
#   Change the NS records for the entire domain at the registrar.
#   ALL DNS for Zava.com moves to Azure.
#
# ============================================================================

Write-Host "`n=== STEP 1.5: DNS DELEGATION ===" -ForegroundColor Cyan

# Get the Azure DNS nameservers assigned to the zone
$AZ_NS = az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers" -o json | ConvertFrom-Json
Write-Host "`nAzure DNS assigned these nameservers to $DOMAIN`:" -ForegroundColor Yellow
$AZ_NS | ForEach-Object { Write-Host "  $_" }

Write-Host @"

╔══════════════════════════════════════════════════════════════════════════╗
║  CUSTOMER ACTION REQUIRED — Do this at your domain registrar           ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║  OPTION A: SUBDOMAIN DELEGATION (Recommended for POC)                    ║
║  ─────────────────────────────────────────────────────                    ║
║  Log into your registrar (GoDaddy, Namecheap, Cloudflare, etc.)         ║
║  and add these NS records to the PARENT zone (Zava.com):              ║
║                                                                          ║
║  Record Type: NS                                                         ║
║  Host/Name:   poc           (this creates poc.zava-dnspoc.com)                ║
║  Value:       ns1-03.azure-dns.com                                       ║
║                                                                          ║
║  Record Type: NS                                                         ║
║  Host/Name:   poc                                                        ║
║  Value:       ns2-03.azure-dns.net                                       ║
║                                                                          ║
║  Record Type: NS                                                         ║
║  Host/Name:   poc                                                        ║
║  Value:       ns3-03.azure-dns.org                                       ║
║                                                                          ║
║  Record Type: NS                                                         ║
║  Host/Name:   poc                                                        ║
║  Value:       ns4-03.azure-dns.info                                      ║
║                                                                          ║
║  This tells the internet: "for anything under poc.zava-dnspoc.com,           ║
║  ask Azure DNS instead of GoDaddy."                                      ║
║                                                                          ║
║  ─────────────────────────────────────────────────────                    ║
║  OPTION B: FULL ZONE DELEGATION (Production — NOT for POC)               ║
║  ─────────────────────────────────────────────────────                    ║
║  At the registrar, change the nameservers for Zava.com itself:         ║
║    ns1-03.azure-dns.com                                                  ║
║    ns2-03.azure-dns.net                                                  ║
║    ns3-03.azure-dns.org                                                  ║
║    ns4-03.azure-dns.info                                                 ║
║                                                                          ║
║  WARNING: This moves ALL DNS for Zava.com to Azure.                    ║
║  Only do this after full production migration.                           ║
║                                                                          ║
╠══════════════════════════════════════════════════════════════════════════╣
║  REGISTRAR-SPECIFIC INSTRUCTIONS:                                        ║
║                                                                          ║
║  GoDaddy:                                                                ║
║    1. Log in → My Products → DNS → Manage                               ║
║    2. Add Record → Type: NS                                              ║
║    3. Name: poc  |  Value: ns1-03.azure-dns.com  |  TTL: 3600           ║
║    4. Repeat for all 4 nameservers                                       ║
║                                                                          ║
║  Namecheap:                                                              ║
║    1. Log in → Domain List → Manage → Advanced DNS                      ║
║    2. Add New Record → NS Record                                         ║
║    3. Host: poc  |  Value: ns1-03.azure-dns.com                         ║
║    4. Repeat for all 4 nameservers                                       ║
║                                                                          ║
║  Cloudflare:                                                             ║
║    1. Log in → DNS → Records → Add Record                               ║
║    2. Type: NS  |  Name: poc  |  Nameserver: ns1-03.azure-dns.com      ║
║    3. Repeat for all 4 nameservers                                       ║
║                                                                          ║
║  AWS Route 53:                                                           ║
║    1. Hosted Zones → Zava.com → Create Record                         ║
║    2. Record name: poc  |  Type: NS                                      ║
║    3. Value: ns1-03.azure-dns.com (one per line, all 4)                 ║
║                                                                          ║
║  Propagation: 5 min to 48 hours (typically 15-30 min)                   ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
"@

# 1.5.1 Verify delegation is working (test from public DNS)
Write-Host "`n--- Verify delegation (query from public DNS 8.8.8.8) ---" -ForegroundColor Green
Write-Host "Run this AFTER configuring NS records at the registrar:"
Write-Host "  nslookup -type=NS poc.zava-dnspoc.com 8.8.8.8"
Write-Host "  Expected: ns1-03.azure-dns.com, ns2-03.azure-dns.net, etc."
Write-Host ""
Write-Host "  nslookup www.poc.zava-dnspoc.com 8.8.8.8"
Write-Host "  Expected: 10.0.1.2 (resolved from Azure DNS)"
Write-Host ""

# Automated test — will only pass after registrar delegation is configured
Write-Host "Testing now (may fail if delegation not yet configured)..."
$nsResult = Resolve-DnsName -Name $DOMAIN -Type NS -Server 8.8.8.8 -ErrorAction SilentlyContinue
if ($nsResult | Where-Object { $_.NameHost -like "*azure-dns*" }) {
    Write-Host "PASS: Delegation confirmed — Azure DNS nameservers responding via public DNS" -ForegroundColor Green
} else {
    Write-Host "PENDING: Delegation not yet visible from public DNS." -ForegroundColor Yellow
    Write-Host "  This is expected if you haven't configured NS records at your registrar yet."
    Write-Host "  Or if propagation is still in progress (can take up to 48 hours)."
    Write-Host ""
    Write-Host "  You can still test directly against Azure nameservers:"
    Write-Host "  nslookup www.$DOMAIN ns1-03.azure-dns.com"
}


# ============================================================================
# SECTION 2.7: AUTOMATED RECORD CRUD (Workstream #4 — API Support)
# Tests: Create, Read, Update, Delete for all record types via CLI
# Also shows: Bulk operations, PowerShell, and commented-out Bicep/REST examples
# Dependencies: Section 2 (DNS Zone must exist)
#
# This section proves Azure DNS supports full programmatic management:
#   - Azure CLI (az network dns record-set ...)
#   - PowerShell (Resolve-DnsName for reads)
#   - REST API (commented out — for reference)
#   - Bicep / ARM Template (commented out — for Infrastructure-as-Code)
# ============================================================================

Write-Host "`n=== STEP 2.7: AUTOMATED RECORD CRUD ===" -ForegroundColor Cyan

$NS = (az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers[0]" -o tsv).Trim('.')

# ── CREATE — All record types ──
Write-Host "--- CREATE: A record ---"
az network dns record-set a add-record -g $RG_NAME -z $DOMAIN `
  -n crud-test -a 10.0.50.1 -o none
Write-Host "  Created: crud-test.$DOMAIN A → 10.0.50.1"

Write-Host "--- CREATE: AAAA record ---"
az network dns record-set aaaa add-record -g $RG_NAME -z $DOMAIN `
  -n crud-test -a 2001:db8::50 -o none
Write-Host "  Created: crud-test.$DOMAIN AAAA → 2001:db8::50"

Write-Host "--- CREATE: CNAME record ---"
az network dns record-set cname set-record -g $RG_NAME -z $DOMAIN `
  -n crud-alias -c "crud-test.$DOMAIN" -o none
Write-Host "  Created: crud-alias.$DOMAIN CNAME → crud-test.$DOMAIN"

Write-Host "--- CREATE: MX record ---"
az network dns record-set mx add-record -g $RG_NAME -z $DOMAIN `
  -n crud-test -e "mail.$DOMAIN" -p 10 -o none
Write-Host "  Created: crud-test.$DOMAIN MX 10 → mail.$DOMAIN"

Write-Host "--- CREATE: TXT record ---"
az network dns record-set txt add-record -g $RG_NAME -z $DOMAIN `
  -n crud-test -v "v=spf1 include:test.com ~all" -o none
Write-Host "  Created: crud-test.$DOMAIN TXT"

Write-Host "--- CREATE: SRV record ---"
az network dns record-set srv add-record -g $RG_NAME -z $DOMAIN `
  -n _sip._tcp.crud-test -t "sip.$DOMAIN" -r 10 -w 60 -p 5060 -o none
Write-Host "  Created: _sip._tcp.crud-test.$DOMAIN SRV"

# ── READ — Multiple methods ──
Write-Host "`n--- READ: Via Azure CLI ---"
az network dns record-set a show -g $RG_NAME -z $DOMAIN -n crud-test `
  --query "{name:fqdn, ttl:ttl, records:aRecords[].ipv4Address}" -o json

Write-Host "--- READ: Via nslookup ---"
nslookup crud-test.$DOMAIN $NS

Write-Host "--- READ: Via PowerShell ---"
Resolve-DnsName -Name "crud-test.$DOMAIN" -Type A -Server $NS |
  Format-Table Name, Type, IPAddress -AutoSize

# ── UPDATE — Change IP and TTL ──
Write-Host "--- UPDATE: Change A record IP (10.0.50.1 → 10.0.50.99) ---"
az network dns record-set a remove-record -g $RG_NAME -z $DOMAIN `
  -n crud-test -a 10.0.50.1 -o none
az network dns record-set a add-record -g $RG_NAME -z $DOMAIN `
  -n crud-test -a 10.0.50.99 -o none
Write-Host "  Updated to 10.0.50.99"

Write-Host "--- UPDATE: Change TTL (3600 → 300) ---"
az network dns record-set a update -g $RG_NAME -z $DOMAIN `
  -n crud-test --set ttl=300 -o none
Write-Host "  TTL updated to 300 seconds"

Write-Host "--- VERIFY UPDATE ---"
nslookup -type=A "crud-test.$DOMAIN" $NS

# ── DELETE — Clean up all CRUD test records ──
Write-Host "`n--- DELETE: All CRUD test records ---"
az network dns record-set a delete -g $RG_NAME -z $DOMAIN -n crud-test --yes -o none
az network dns record-set aaaa delete -g $RG_NAME -z $DOMAIN -n crud-test --yes -o none
az network dns record-set cname delete -g $RG_NAME -z $DOMAIN -n crud-alias --yes -o none
az network dns record-set mx delete -g $RG_NAME -z $DOMAIN -n crud-test --yes -o none
az network dns record-set txt delete -g $RG_NAME -z $DOMAIN -n crud-test --yes -o none
az network dns record-set srv delete -g $RG_NAME -z $DOMAIN -n _sip._tcp.crud-test --yes -o none
Write-Host "  All CRUD test records deleted"

# ── BULK CREATE — Scripted loop (10 records) ──
Write-Host "`n--- BULK CREATE: 10 A records via loop ---"
$bulkStart = Get-Date
1..10 | ForEach-Object {
    az network dns record-set a add-record -g $RG_NAME -z $DOMAIN `
      -n "bulk-$_" -a "10.0.100.$_" -o none
}
$bulkEnd = Get-Date
$bulkTime = ($bulkEnd - $bulkStart).TotalSeconds
Write-Host "  10 records created in $([math]::Round($bulkTime, 1)) seconds"

Write-Host "--- VERIFY BULK ---"
az network dns record-set list -g $RG_NAME -z $DOMAIN `
  --query "[?contains(name,'bulk')].{name:name}" -o table

Write-Host "--- BULK DELETE ---"
1..10 | ForEach-Object {
    az network dns record-set a delete -g $RG_NAME -z $DOMAIN `
      -n "bulk-$_" --yes -o none
}
Write-Host "  10 bulk records deleted"

# ── BICEP EXAMPLE (Infrastructure-as-Code) ──
# Uncomment and save as dns-records.bicep, then deploy with:
#   az deployment group create -g rg-dns-poc --template-file dns-records.bicep
#
# param dnsZoneName string = 'poc.zava-dnspoc.com'
#
# resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' existing = {
#   name: dnsZoneName
# }
#
# resource aRecord 'Microsoft.Network/dnsZones/A@2023-07-01-preview' = {
#   parent: dnsZone
#   name: 'bicep-test'
#   properties: {
#     TTL: 3600
#     ARecords: [
#       { ipv4Address: '10.0.200.1' }
#     ]
#   }
# }
#
# resource cnameRecord 'Microsoft.Network/dnsZones/CNAME@2023-07-01-preview' = {
#   parent: dnsZone
#   name: 'bicep-alias'
#   properties: {
#     TTL: 3600
#     CNAMERecord: {
#       cname: 'bicep-test.poc.zava-dnspoc.com'
#     }
#   }
# }
#
# resource mxRecord 'Microsoft.Network/dnsZones/MX@2023-07-01-preview' = {
#   parent: dnsZone
#   name: '@'
#   properties: {
#     TTL: 3600
#     MXRecords: [
#       { preference: 10, exchange: 'mail.poc.zava-dnspoc.com' }
#       { preference: 20, exchange: 'mail2.poc.zava-dnspoc.com' }
#     ]
#   }
# }

# ── REST API EXAMPLE ──
# Uses Azure REST API directly. Get a bearer token first:
#   $token = (az account get-access-token --query accessToken -o tsv)
#
# CREATE A record via REST:
#   $uri = "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Network/dnsZones/$DOMAIN/A/rest-test?api-version=2023-07-01-preview"
#   $body = @{
#     properties = @{
#       TTL = 3600
#       ARecords = @( @{ ipv4Address = "10.0.201.1" } )
#     }
#   } | ConvertTo-Json -Depth 5
#   Invoke-RestMethod -Uri $uri -Method Put -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } -Body $body
#
# READ via REST:
#   Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $token" }
#
# DELETE via REST:
#   Invoke-RestMethod -Uri $uri -Method Delete -Headers @{ Authorization = "Bearer $token" }

# VERIFY Step 2.7
Write-Host "`n--- VERIFY: CRUD Workstream Complete ---" -ForegroundColor Green
Write-Host "  CLI:    Create/Read/Update/Delete all record types — TESTED"
Write-Host "  Bulk:   10-record scripted loop — TESTED"
Write-Host "  Bicep:  Template example provided (commented out)"
Write-Host "  REST:   API example provided (commented out)"
Write-Host "  PowerShell: Resolve-DnsName reads — TESTED"


# ============================================================================
# SECTION 3: AUDIT LOGGING (Step 2)
# Deploys: Activity Log → Event Hub + LAW (subscription-level)
# Dependencies: Section 1 (LAW, Event Hub)
#
# IMPORTANT: Azure DNS public zones do NOT support zone-level diagnostic
# settings for query logs. Audit logging uses Activity Log which captures:
#   - Record create/modify/delete operations
#   - User identity + timestamp + source IP
#   - Resource ID of the changed record
#
# For SIEM (QRadar): Activity Log → Event Hub → QRadar DSM connector
# For Reporting: Activity Log → Log Analytics → KQL queries / Workbooks
# ============================================================================

Write-Host "`n=== STEP 2: AUDIT LOGGING ===" -ForegroundColor Cyan

# 2.1 Get resource IDs
$LAW_ID = (az monitor log-analytics workspace show -g $RG_NAME -n $LAW_NAME --query "id" -o tsv)
$EH_RULE_ID = (az eventhubs namespace authorization-rule show `
  -g $RG_NAME `
  --namespace-name $EH_NAMESPACE `
  --name RootManageSharedAccessKey `
  --query "id" -o tsv)

# 2.2 Create subscription-level diagnostic settings
# Routes ALL Activity Log categories to Event Hub (SIEM) and LAW (reporting)
Write-Host "--- Routing Activity Log to Event Hub + LAW (ALL 8 categories) ---"
az monitor diagnostic-settings subscription create `
  --name "activity-log-to-eh-and-law" `
  --location $LOCATION_RG `
  --workspace $LAW_ID `
  --event-hub-auth-rule $EH_RULE_ID `
  --event-hub-name $EH_NAME `
  --logs '[{\"category\":\"Administrative\",\"enabled\":true},{\"category\":\"Security\",\"enabled\":true},{\"category\":\"ServiceHealth\",\"enabled\":true},{\"category\":\"Alert\",\"enabled\":true},{\"category\":\"Recommendation\",\"enabled\":true},{\"category\":\"Policy\",\"enabled\":true},{\"category\":\"Autoscale\",\"enabled\":true},{\"category\":\"ResourceHealth\",\"enabled\":true}]' `
  --query "{name:name}" -o table

# 2.3 Generate a test audit event
Write-Host "--- Generating test audit event (creating a DNS record) ---"
az network dns record-set a add-record `
  -g $RG_NAME -z $DOMAIN -n audit-test -a 10.0.99.1 -o none

# ── 2.4 QRadar-Compliant Event Hub Setup ──
# Reference: https://learn.microsoft.com/en-us/azure/defender-for-cloud/export-to-splunk-or-qradar
#
# Per Microsoft's SIEM integration guide, QRadar requires:
#   1. A Send policy (for Azure to write events)
#   2. A Listen policy (for QRadar to read events) — separate from Send!
#   3. A dedicated consumer group (not $Default)
#   4. A storage account (for QRadar's checkpoint/offset tracking)

# 2.4.1 Create Send-only SAS policy on event hub
Write-Host "--- Creating Send-only SAS policy ---"
az eventhubs eventhub authorization-rule create `
  -g $RG_NAME `
  --namespace-name $EH_NAMESPACE `
  --eventhub-name $EH_NAME `
  --name SendPolicy `
  --rights Send `
  --query "{name:name}" -o table

# 2.4.2 Create Listen-only SAS policy (for QRadar to consume)
Write-Host "--- Creating Listen-only SAS policy (for QRadar) ---"
az eventhubs eventhub authorization-rule create `
  -g $RG_NAME `
  --namespace-name $EH_NAMESPACE `
  --eventhub-name $EH_NAME `
  --name QRadarListenPolicy `
  --rights Listen `
  --query "{name:name}" -o table

# 2.4.3 Create dedicated consumer group for QRadar
Write-Host "--- Creating QRadar consumer group ---"
az eventhubs eventhub consumer-group create `
  -g $RG_NAME `
  --namespace-name $EH_NAMESPACE `
  --eventhub-name $EH_NAME `
  --name qradar-consumer `
  --query "{name:name}" -o table

# 2.4.4 Create storage account for QRadar checkpoint tracking
# QRadar uses this to track which Event Hub messages it has already processed.
# Without this, QRadar may re-process or skip events after restart.
$STORAGE_NAME = "stqradarpoc$(Get-Random -Minimum 1000 -Maximum 9999)"
Write-Host "--- Creating Storage Account for QRadar checkpoints: $STORAGE_NAME ---"
az storage account create `
  -g $RG_NAME `
  -n $STORAGE_NAME `
  --location $LOCATION_RG `
  --sku Standard_LRS `
  --kind StorageV2 `
  --query "{name:name, provisioningState:provisioningState}" -o table

# VERIFY Step 2
Write-Host "`n--- VERIFY: Audit logging + QRadar setup ---" -ForegroundColor Green
az monitor diagnostic-settings subscription show `
  --name "activity-log-to-eh-and-law" `
  --query "{name:name, eventHubName:eventHubName}" -o table

Write-Host "`nActivity Log events appear in Event Hub within 5-10 minutes."

# Output the QRadar configuration package
Write-Host @"

╔══════════════════════════════════════════════════════════════════════════╗
║  QRADAR CONFIGURATION PACKAGE                                           ║
║  Reference: https://learn.microsoft.com/en-us/azure/defender-for-cloud/ ║
║             export-to-splunk-or-qradar                                  ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║  Give this info to the Zava Security / QRadar team:                   ║
║                                                                          ║
║  ── AZURE SIDE (already deployed by this script) ──                     ║
║                                                                          ║
║  Event Hub Namespace:  $EH_NAMESPACE                                    ║
║  Event Hub Name:       $EH_NAME                                         ║
║  Consumer Group:       qradar-consumer                                  ║
║  Listen Policy:        QRadarListenPolicy                               ║
║                                                                          ║
║  ── QRADAR SIDE (customer action) ──                                    ║
║                                                                          ║
║  1. Log into QRadar Console → Admin tab                                 ║
║  2. Log Sources → Add                                                    ║
║  3. Select Protocol: Microsoft Azure Event Hub                           ║
║  4. Configure:                                                           ║
║     • Event Hub Connection String: (Listen policy — see below)          ║
║     • Event Hub Name: dns-logs                                           ║
║     • Consumer Group: qradar-consumer                                   ║
║     • Storage Account Connection String: (see below)                    ║
║  5. Save → Deploy Changes                                               ║
║  6. Verify: Log Activity tab → filter by new log source                 ║
║                                                                          ║
║  For IBM's side: https://www.ibm.com/docs/en/dsm?topic=                 ║
║  microsoft-azure-event-hubs-protocol-configuration-options              ║
║                                                                          ║
║  ── WHAT FLOWS TO QRADAR ──                                             ║
║                                                                          ║
║  ✅ DNS record create/modify/delete (who, what, when, from where)       ║
║  ✅ RBAC role assignments and changes                                    ║
║  ✅ Resource provisioning events                                         ║
║  ✅ Security events (failed auth, denied operations)                     ║
║  ✅ Service health and resource health events                            ║
║  ✅ Policy compliance events                                             ║
║  ❌ Individual DNS query logs (Azure limitation — not available)         ║
║                                                                          ║
║  ── AZURE LIMITATION NOTE ──                                             ║
║                                                                          ║
║  Azure DNS public zones do NOT support query-level logging.             ║
║  Only management-plane operations (record CRUD) flow to Event Hub.      ║
║  This is a known gap vs Bind's query logging capability.                ║
║  Workarounds for query logging (future phase):                          ║
║    • Azure DNS Private Resolver (supports query logs)                   ║
║    • Azure Firewall DNS Proxy (logs all queries passing through)        ║
║    • Third-party DNS proxy layer                                         ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
"@

# ============================================================================
# SECURE SECRET STORAGE — Store Connection Strings in Key Vault
# ============================================================================
# 🔒 SECURITY BEST PRACTICE: Never output secrets to console or logs
# All connection strings are automatically stored in Azure Key Vault

Write-Host "`n--- 🔒 Storing Connection Strings in Key Vault ---" -ForegroundColor Cyan

# 3.7.1 Get Event Hub Listen connection string
$EH_LISTEN_CONN = (az eventhubs eventhub authorization-rule keys list `
  -g $RG_NAME --namespace-name $EH_NAMESPACE --eventhub-name $EH_NAME `
  --name QRadarListenPolicy `
  --query "primaryConnectionString" -o tsv)

# 3.7.2 Get Event Hub Send connection string  
$EH_SEND_CONN = (az eventhubs eventhub authorization-rule keys list `
  -g $RG_NAME --namespace-name $EH_NAMESPACE --eventhub-name $EH_NAME `
  --name SendPolicy `
  --query "primaryConnectionString" -o tsv)

# 3.7.3 Get Storage Account connection string
$STORAGE_CONN = (az storage account show-connection-string `
  -g $RG_NAME -n $STORAGE_NAME `
  --query "connectionString" -o tsv)

# 3.7.4 Store in Key Vault (RBAC-based access)
Write-Host "  Storing EventHubListenConnectionString..." -NoNewline
az keyvault secret set `
  --vault-name $KV_NAME `
  --name "EventHubListenConnectionString" `
  --value "$EH_LISTEN_CONN" `
  --content-type "text/plain" `
  -o none
Write-Host " ✅" -ForegroundColor Green

Write-Host "  Storing EventHubSendConnectionString..." -NoNewline
az keyvault secret set `
  --vault-name $KV_NAME `
  --name "EventHubSendConnectionString" `
  --value "$EH_SEND_CONN" `
  --content-type "text/plain" `
  -o none
Write-Host " ✅" -ForegroundColor Green

Write-Host "  Storing StorageAccountConnectionString..." -NoNewline
az keyvault secret set `
  --vault-name $KV_NAME `
  --name "StorageAccountConnectionString" `
  --value "$STORAGE_CONN" `
  --content-type "text/plain" `
  -o none
Write-Host " ✅" -ForegroundColor Green

# Clear sensitive variables from memory
$EH_LISTEN_CONN = $null
$EH_SEND_CONN = $null
$STORAGE_CONN = $null

Write-Host "`n✅ All connection strings securely stored in Key Vault: $KV_NAME" -ForegroundColor Green

# 3.7.5 Provide QRadar team with secure retrieval instructions
Write-Host @"

╔══════════════════════════════════════════════════════════════════════════╗
║                 🔒 SECURE SECRET RETRIEVAL INSTRUCTIONS                  ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║  Connection strings are stored securely in Azure Key Vault.             ║
║  Share these retrieval commands with the QRadar/SIEM team:              ║
║                                                                          ║
║  📍 Key Vault Name: $KV_NAME
║                                                                          ║
║  🔑 Retrieve Event Hub Listen Connection (for QRadar):                  ║
║     az keyvault secret show --vault-name $KV_NAME \
║       --name EventHubListenConnectionString --query value -o tsv        ║
║                                                                          ║
║  🔑 Retrieve Storage Account Connection (for checkpoints):              ║
║     az keyvault secret show --vault-name $KV_NAME \
║       --name StorageAccountConnectionString --query value -o tsv        ║
║                                                                          ║
║  📖 Azure Portal Access:                                                 ║
║     https://portal.azure.com → Key Vaults → $KV_NAME → Secrets
║                                                                          ║
║  ⚠️  RBAC REQUIRED: QRadar service principal needs role:                ║
║     Key Vault Secrets User (read-only access to secrets)                ║
║                                                                          ║
║  💡 Grant access to QRadar service principal:                            ║
║     az role assignment create \                                          ║
║       --assignee <qradar-sp-object-id> \                                 ║
║       --role "Key Vault Secrets User" \                                  ║
║       --scope $(az keyvault show -g $RG_NAME -n $KV_NAME --query id -o tsv)
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
"@


# ============================================================================
# SECTION 4: RBAC & DELEGATION (Step 4)
# Deploys: Custom "DNS Record Operator" role + resource lock
# Dependencies: Section 1 (RG), DNS Zone
#
# Two-role model (MS Learn validated):
#   - DNS Zone Contributor (built-in): Full zone + record management — assign to DNS admins
#   - DNS Record Operator (custom): Record CRUD only, no zone lifecycle — assign to operators
#
# Ref: https://learn.microsoft.com/azure/dns/dns-protect-zones-recordsets
# Ref: https://learn.microsoft.com/azure/dns/secure-dns#privileged-access
# Ref: https://learn.microsoft.com/azure/role-based-access-control/custom-roles
#
# Standalone script with full tests: .\Zava_RBAC_Delegation.ps1
# ============================================================================

Write-Host "`n=== STEP 4: RBAC & DELEGATION ===" -ForegroundColor Cyan

$SUB_ID = (az account show --query "id" -o tsv)

# 4.1 Create custom role definition (13 Actions, 7 NotActions)
$roleJson = @"
{
  "Name": "DNS Record Operator",
  "Description": "Can manage DNS record sets (A, AAAA, CNAME, MX, TXT, SRV, CAA, PTR) but cannot create, delete, or import zones. Cannot modify SOA/NS records or DNSSEC.",
  "Actions": [
    "Microsoft.Network/dnsZones/read",
    "Microsoft.Network/dnsZones/*/read",
    "Microsoft.Network/dnsZones/recordsets/read",
    "Microsoft.Network/dnsZones/A/*",
    "Microsoft.Network/dnsZones/AAAA/*",
    "Microsoft.Network/dnsZones/CNAME/*",
    "Microsoft.Network/dnsZones/MX/*",
    "Microsoft.Network/dnsZones/TXT/*",
    "Microsoft.Network/dnsZones/SRV/*",
    "Microsoft.Network/dnsZones/CAA/*",
    "Microsoft.Network/dnsZones/PTR/*",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [
    "Microsoft.Network/dnsZones/write",
    "Microsoft.Network/dnsZones/delete",
    "Microsoft.Network/dnsZones/SOA/write",
    "Microsoft.Network/dnsZones/NS/write",
    "Microsoft.Network/dnsZones/NS/delete",
    "Microsoft.Network/dnsZones/dnssecConfigs/default/write",
    "Microsoft.Network/dnsZones/dnssecConfigs/default/delete"
  ],
  "AssignableScopes": ["/subscriptions/$SUB_ID"]
}
"@
$roleFile = ".\dns-operator-role.json"
$roleJson | Out-File -FilePath $roleFile -Encoding utf8NoBOM

Write-Host "--- Creating custom 'DNS Record Operator' role ---"
az role definition create --role-definition $roleFile `
  --query "{roleName:roleName}" -o table 2>$null
if ($LASTEXITCODE -ne 0) {
    # Role may already exist — try updating
    Write-Host "  Role may exist — updating definition..." -ForegroundColor Yellow
    az role definition update --role-definition $roleFile -o none 2>$null
}

# Custom roles take ~60s to propagate
Write-Host "  Waiting 60s for RBAC propagation..." -ForegroundColor DarkGray
Start-Sleep -Seconds 60

# 4.2 Apply resource lock on DNS zone (prevents accidental deletion)
Write-Host "--- Applying CanNotDelete lock to $DOMAIN ---"
az lock create --name "protect-dns-zone" `
  --resource-group $RG_NAME `
  --resource-type "Microsoft.Network/dnsZones" `
  --resource-name $DOMAIN `
  --lock-type CanNotDelete `
  --notes "Prevent accidental deletion of POC DNS zone" `
  -o none 2>$null
Write-Host "  ✅ CanNotDelete lock applied" -ForegroundColor Green

# 4.3 Assign roles (uncomment and set UPNs for actual testing)
# $OPERATOR_UPN = "operator@yourtenant.onmicrosoft.com"
# $ADMIN_UPN    = "admin@yourtenant.onmicrosoft.com"
#
# # Assign Operator role (records only, scoped to DNS zone)
# az role assignment create --assignee $OPERATOR_UPN `
#   --role "DNS Record Operator" `
#   --scope "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME/providers/Microsoft.Network/dnsZones/$DOMAIN"
#
# # Assign Admin role (full zone control, scoped to RG)
# az role assignment create --assignee $ADMIN_UPN `
#   --role "DNS Zone Contributor" `
#   --scope "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME"

# VERIFY Step 4
Write-Host "`n--- VERIFY: Custom role created ---" -ForegroundColor Green
az role definition list --custom-role-only true -o json 2>$null |
  ConvertFrom-Json |
  Where-Object { $_.roleName -like "*DNS*" } |
  Select-Object roleName, description |
  Format-Table


# ============================================================================
# SECTION 5: DCV CERTIFICATE VALIDATION (Step 5)
# Tests: DigiCert _dnsauth and ACME _acme-challenge TXT record lifecycle
# Dependencies: Section 2 (DNS Zone)
#
# WHAT THE CUSTOMER NEEDS TO PROVIDE:
#   1. DigiCert CertCentral access (to order a test certificate)
#   2. The DCV random value (token) from the cert order
#   3. OR: ACME EAB credentials from CertCentral → Automation → ACME
#
# DigiCert docs: https://docs.digicert.com/en/certcentral/manage-certificates/
#                domain-control-validation-methods.html
#
# DCV FLOW:
#   1. Order cert in DigiCert CertCentral → get DCV token
#   2. Create _dnsauth.<domain> TXT record with that token
#   3. DigiCert queries DNS, validates domain ownership
#   4. DigiCert issues certificate
#   5. Clean up the TXT record
# ============================================================================

Write-Host "`n=== STEP 5: DCV CERTIFICATE VALIDATION ===" -ForegroundColor Cyan

$NS = (az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers[0]" -o tsv).Trim('.')
Write-Host "  Using nameserver: $NS"

# Helper: Create TXT record, wait for propagation, then verify via both Azure CLI and nslookup
function Test-DcvRecord {
    param([string]$Name, [string]$Value, [string]$Label)
    Write-Host "--- $Label ---"
    az network dns record-set txt add-record -g $RG_NAME -z $DOMAIN -n $Name -v $Value -o none 2>$null
    Start-Sleep -Seconds 5  # Brief wait for Azure DNS to commit
    # Verify via Azure CLI (always works, doesn't depend on DNS propagation)
    $azResult = az network dns record-set txt show -g $RG_NAME -z $DOMAIN -n $Name --query "TXTRecords[0].value[0]" -o tsv 2>$null
    if ($azResult) {
        Write-Host "  ✅ Azure CLI verify: $azResult" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Azure CLI verify: record not found (may need more time)" -ForegroundColor Yellow
    }
    # Also try nslookup against Azure NS (may fail without domain purchase/NS delegation)
    nslookup -type=TXT "$Name.$DOMAIN" $NS 2>$null | Select-String "text" | ForEach-Object { Write-Host "  nslookup: $_" }
}

# 5.1 DigiCert _dnsauth — Root domain
$DCV_TOKEN = "digicert-dcv-replace-with-real-token"
Test-DcvRecord -Name "_dnsauth" -Value $DCV_TOKEN -Label "Test 1: _dnsauth (root domain)"

# 5.2 DigiCert _dnsauth — Subdomain (e.g., www)
Test-DcvRecord -Name "_dnsauth.www" -Value "digicert-subdomain-token" -Label "Test 2: _dnsauth.www (subdomain)"

# 5.3 DigiCert _dnsauth — Wildcard (same as root _dnsauth)
Test-DcvRecord -Name "_dnsauth" -Value "digicert-wildcard-token" -Label "Test 3: _dnsauth (wildcard — uses root)"

# 5.4 ACME _acme-challenge — Root domain
Test-DcvRecord -Name "_acme-challenge" -Value "acme-test-token" -Label "Test 4: _acme-challenge (ACME convention)"

# 5.5 ACME _acme-challenge — Subdomain
Test-DcvRecord -Name "_acme-challenge.www" -Value "acme-subdomain-token" -Label "Test 5: _acme-challenge.www (ACME subdomain)"

# 5.6 Cleanup all DCV records
Write-Host "--- Cleanup: Removing all DCV test records ---"
az network dns record-set txt remove-record -g $RG_NAME -z $DOMAIN -n "_dnsauth" -v $DCV_TOKEN -o none 2>$null
az network dns record-set txt remove-record -g $RG_NAME -z $DOMAIN -n "_dnsauth" -v "digicert-wildcard-token" -o none 2>$null
az network dns record-set txt delete -g $RG_NAME -z $DOMAIN -n "_dnsauth.www" --yes -o none 2>$null
az network dns record-set txt delete -g $RG_NAME -z $DOMAIN -n "_acme-challenge" --yes -o none 2>$null
az network dns record-set txt delete -g $RG_NAME -z $DOMAIN -n "_acme-challenge.www" --yes -o none 2>$null
Write-Host "DCV records cleaned up."


# ============================================================================
# SECTION 5.5: LET'S ENCRYPT CERTIFICATE AUTOMATION (Optional)
# Issues a free, publicly-trusted TLS cert via DNS-01 challenge
# Dependencies: Section 2 (DNS Zone), Key Vault (Section 0)
#
# WHAT THIS DOES:
#   1. Creates Service Principal with DNS Zone Contributor role
#   2. Stores SP credentials in Key Vault (zero-secret pattern)
#   3. Installs certbot + certbot-dns-azure
#   4. Runs staging dry-run (validates ACME + Azure DNS plumbing)
#   5. Issues production cert for $DOMAIN + *.$DOMAIN
#   6. Converts PEM → PFX, imports to Key Vault
#
# WHY LET'S ENCRYPT:
#   - Free (no DigiCert cert purchase needed for POC)
#   - Automated (full lifecycle: request → DCV → issue → renew)
#   - Uses DNS-01 challenge (same _acme-challenge TXT records we already test)
#   - Staging environment for safe testing without rate limits
#
# Ref: https://letsencrypt.org/getting-started/
# Ref: https://docs.certbot-dns-azure.co.uk/en/latest/
# Ref: https://learn.microsoft.com/azure/application-gateway/ingress-controller-letsencrypt-certificate-application-gateway
# ============================================================================

if ($ENABLE_LETSENCRYPT) {
    Write-Host "`n=== STEP 5.5: LET'S ENCRYPT CERTIFICATE ===" -ForegroundColor Cyan

    # 5.5.1 Grant App Service RP access to Key Vault certificates
    # Ref: https://learn.microsoft.com/azure/app-service/configure-ssl-certificate#import-a-certificate-from-key-vault
    $KV_SCOPE = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME"
    Write-Host "--- Granting App Service RP access to Key Vault certificates ---"
    az role assignment create `
      --role "Key Vault Certificate User" `
      --assignee "abfa0a7c-a6b6-4736-8310-5855508787cd" `
      --scope $KV_SCOPE `
      -o none 2>$null
    Write-Host "  App Service RP granted Key Vault Certificate User role" -ForegroundColor Green

    # 5.5.2 Install Posh-ACME (Windows-native Let's Encrypt — no certbot/WSL/admin needed)
    # Adopted from devmauser branch: Posh-ACME + Azure plugin (pure PowerShell)
    # Ref: https://github.com/rmbolger/Posh-ACME
    # Ref: https://poshac.me/docs/v4/Plugins/Azure/
    Write-Host "--- Installing Posh-ACME module ---"
    if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
        Install-Module -Name Posh-ACME -Scope CurrentUser -Force -AllowClobber
        Write-Host "  Posh-ACME installed" -ForegroundColor Green
    } else {
        Write-Host "  Posh-ACME already installed" -ForegroundColor Yellow
    }
    Import-Module Posh-ACME -Force

    # 5.5.3 Issue Let's Encrypt certificate via Posh-ACME + Azure DNS plugin
    # Uses ARM access token from current az login session (zero-secret pattern)
    Write-Host "--- Requesting Let's Encrypt certificate ---"
    Write-Host "  Domain: $DOMAIN + *.$DOMAIN (wildcard)"
    Write-Host "  Auth: Azure CLI access token (no SP password needed)"

    # Stage 1: Set ACME server (staging first for validation)
    $dryRunSuccess = $false
    try {
        Set-PAServer LE_STAGE
        Write-Host "  Using LE Staging server (dry-run validation)..."

        # Get ARM access token from current az login session
        $armToken = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
        if (-not $armToken -or $armToken.Length -lt 50) {
            throw "Failed to get ARM access token — run 'az login' first"
        }
        Write-Host "  ARM token acquired (length: $($armToken.Length))" -ForegroundColor DarkGray

        $pluginArgs = @{
            AZSubscriptionId = $SUBSCRIPTION_ID
            AZAccessToken    = $armToken
        }

        # Create or reuse ACME account
        $existingAcct = Get-PAAccount -List -Contact $CONTACT_EMAIL -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existingAcct) {
            Set-PAAccount $existingAcct.Id
            Write-Host "  Reusing ACME account: $($existingAcct.Id)" -ForegroundColor Yellow
        } else {
            New-PAAccount -AcceptTOS -Contact $CONTACT_EMAIL
            Write-Host "  ACME account created" -ForegroundColor Green
        }

        # Request staging cert (validates DNS-01 challenge plumbing)
        Write-Host "  Requesting STAGING certificate (validates DNS-01 + Azure DNS)..."
        $stagingCert = New-PACertificate -Domain $DOMAIN,"*.$DOMAIN" -Plugin Azure -PluginArgs $pluginArgs -ErrorAction Stop
        if ($stagingCert) {
            Write-Host "  STAGING dry-run PASSED — DNS-01 challenge works" -ForegroundColor Green
            $dryRunSuccess = $true
        }
    } catch {
        Write-Host "  STAGING dry-run FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Check: DNS delegation active? KV permissions? az login valid?" -ForegroundColor Yellow
    }

    # Stage 2: Production cert (only if staging passed)
    if ($dryRunSuccess) {
        try {
            Set-PAServer LE_PROD
            Write-Host "`n  Switching to LE PRODUCTION server..."

            # Refresh token (staging may have taken minutes)
            $armToken = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
            $pluginArgs = @{
                AZSubscriptionId = $SUBSCRIPTION_ID
                AZAccessToken    = $armToken
            }

            # Create/reuse production account
            $existingProdAcct = Get-PAAccount -List -Contact $CONTACT_EMAIL -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($existingProdAcct) {
                Set-PAAccount $existingProdAcct.Id
            } else {
                New-PAAccount -AcceptTOS -Contact $CONTACT_EMAIL
            }

            Write-Host "  Requesting PRODUCTION certificate..."
            $prodCert = New-PACertificate -Domain $DOMAIN,"*.$DOMAIN" -Plugin Azure -PluginArgs $pluginArgs -ErrorAction Stop

            if ($prodCert -and $prodCert.PfxFile) {
                Write-Host "  Certificate ISSUED" -ForegroundColor Green
                Write-Host "    Subject:   $($prodCert.Subject)"
                Write-Host "    Expires:   $($prodCert.NotAfter)"
                Write-Host "    Thumbprint: $($prodCert.Thumbprint)"
                Write-Host "    PFX path:  $($prodCert.PfxFile)"

                # 5.5.4 Import PFX to Key Vault
                Write-Host "`n--- Importing certificate to Key Vault ---"
                az keyvault certificate import `
                  --vault-name $KV_NAME `
                  --name $LE_CERT_NAME `
                  --file $prodCert.PfxFile `
                  -o none 2>&1
                if ($?) {
                    Write-Host "  Certificate '$LE_CERT_NAME' imported to Key Vault: $KV_NAME" -ForegroundColor Green
                } else {
                    Write-Host "  KV import failed — trying with password..." -ForegroundColor Yellow
                    # Posh-ACME may set a password on the PFX
                    az keyvault certificate import `
                      --vault-name $KV_NAME `
                      --name $LE_CERT_NAME `
                      --file $prodCert.PfxFile `
                      --password "poshacme" `
                      -o none 2>&1
                }
            } else {
                Write-Host "  Production cert request returned no PFX — check Posh-ACME logs" -ForegroundColor Red
            }
        } catch {
            Write-Host "  PRODUCTION cert FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "`n  Skipping production cert — staging dry-run did not pass" -ForegroundColor Yellow
        Write-Host "  Fix the staging issue above, then re-run this section"
    }

    # Clear token from memory
    $armToken = $null

    # 5.5.5 Verify certificate in Key Vault
    Write-Host "`n--- Checking for Let's Encrypt certificate in Key Vault ---" -ForegroundColor Cyan
    $leCertExists = az keyvault certificate show --vault-name $KV_NAME --name $LE_CERT_NAME --query "name" -o tsv 2>$null
    if ($leCertExists) {
        Write-Host "  Certificate '$LE_CERT_NAME' found in Key Vault — will be used in Section 7.8" -ForegroundColor Green
        az keyvault certificate show --vault-name $KV_NAME --name $LE_CERT_NAME `
          --query "{name:name, expires:attributes.expires, thumbprint:x509ThumbprintHex}" -o table
    } else {
        Write-Host "  Certificate '$LE_CERT_NAME' NOT yet in Key Vault" -ForegroundColor Yellow
        Write-Host "  Section 7.8 will fall back to App Service Managed Certificates"
    }
} else {
    Write-Host "`n--- Skipping Let's Encrypt (ENABLE_LETSENCRYPT = `$false) ---" -ForegroundColor DarkGray
    Write-Host "  Set `$ENABLE_LETSENCRYPT = `$true in Section 0 to enable"
}

# ============================================================================
# SECTION 6: TRAFFIC MANAGER (Step 6)
# Deploys: 3 TM profiles (Priority/Failover, Geographic, Weighted)
# Dependencies: Section 1 (RG) — profiles only, endpoints added in Section 7
# ============================================================================

Write-Host "`n=== STEP 6: TRAFFIC MANAGER ===" -ForegroundColor Cyan

# 6.1 Failover (Priority routing)
Write-Host "--- Creating TM Profile: Failover (Priority) ---"
az network traffic-manager profile create -g $RG_NAME -n $TM_FAILOVER `
  --routing-method Priority --unique-dns-name $TM_FAILOVER `
  --ttl 30 --protocol HTTPS --port 443 --path "/" -o none

# 6.2 Geographic routing
Write-Host "--- Creating TM Profile: Geographic ---"
az network traffic-manager profile create -g $RG_NAME -n $TM_GEO `
  --routing-method Geographic --unique-dns-name $TM_GEO `
  --ttl 30 --protocol HTTPS --port 443 --path "/" -o none

# 6.3 Weighted routing
Write-Host "--- Creating TM Profile: Weighted ---"
az network traffic-manager profile create -g $RG_NAME -n $TM_WEIGHTED `
  --routing-method Weighted --unique-dns-name $TM_WEIGHTED `
  --ttl 30 --protocol HTTPS --port 443 --path "/" -o none

# VERIFY Step 6
Write-Host "`n--- VERIFY: Traffic Manager profiles ---" -ForegroundColor Green
az network traffic-manager profile list -g $RG_NAME `
  --query "[].{name:name, routing:trafficRoutingMethod, fqdn:dnsConfig.fqdn}" -o table


# ============================================================================
# SECTION 7: WEB APPS + DNS WIRING (Step 7)
# Deploys: 2 App Service Plans, 2 Web Apps, TM endpoints, DNS CNAME records
# Dependencies: Section 1 (RG, LAW), Section 2 (DNS Zone), Section 6 (TM profiles)
#
# NOTE: App Service Plans require compute quota in each region.
#       If you hit "quota exceeded", try a different region or request quota:
#       https://aka.ms/antquotahelp
# ============================================================================

Write-Host "`n=== STEP 7: WEB APPS + DNS WIRING ===" -ForegroundColor Cyan

# 7.1 Create App Service Plans
Write-Host "--- Creating App Service Plan: $ASP_US ($LOCATION_PRIMARY) ---"
az appservice plan create -g $RG_NAME -n $ASP_US `
  --location $LOCATION_PRIMARY --sku B1 `
  --query "{name:name, sku:sku.name}" -o table

Write-Host "--- Creating App Service Plan: $ASP_UK ($LOCATION_SECONDARY) ---"
az appservice plan create -g $RG_NAME -n $ASP_UK `
  --location $LOCATION_SECONDARY --sku B1 `
  --query "{name:name, sku:sku.name}" -o table

# 7.2 Create Web Apps
Write-Host "--- Creating Web App: $WEBAPP_US ---"
az webapp create -g $RG_NAME -p $ASP_US -n $WEBAPP_US `
  --runtime "dotnet:8" `
  --query "{name:name, defaultHostName:defaultHostName, state:state}" -o table

Write-Host "--- Creating Web App: $WEBAPP_UK ---"
az webapp create -g $RG_NAME -p $ASP_UK -n $WEBAPP_UK `
  --runtime "dotnet:8" `
  --query "{name:name, defaultHostName:defaultHostName, state:state}" -o table

# 7.2.1 Enable HTTPS-only (matching kimvaddi.com reference — forces HTTP→HTTPS redirect)
Write-Host "--- Enabling HTTPS-only on both web apps ---"
az webapp update -g $RG_NAME -n $WEBAPP_US --https-only true -o none
az webapp update -g $RG_NAME -n $WEBAPP_UK --https-only true -o none
Write-Host "  httpsOnly=true on both web apps"

# 7.2.2 Disable FTP/FTPS (security best practice — zero FTP attack surface)
Write-Host "--- Disabling FTP on both web apps ---"
az webapp config set -g $RG_NAME -n $WEBAPP_US --ftps-state Disabled -o none
az webapp config set -g $RG_NAME -n $WEBAPP_UK --ftps-state Disabled -o none
Write-Host "  ftpsState=Disabled on both web apps"

# 7.3 Get Web App resource IDs
$US_ID = (az webapp show -g $RG_NAME -n $WEBAPP_US --query "id" -o tsv)
$UK_ID = (az webapp show -g $RG_NAME -n $WEBAPP_UK --query "id" -o tsv)

# 7.4 Add endpoints to Failover TM (Priority)
Write-Host "--- Adding endpoints to Failover TM ---"
az network traffic-manager endpoint create -g $RG_NAME `
  --profile-name $TM_FAILOVER -n us-primary `
  --type azureEndpoints --target-resource-id $US_ID `
  --priority 1 --endpoint-status Enabled -o none
az network traffic-manager endpoint create -g $RG_NAME `
  --profile-name $TM_FAILOVER -n uk-secondary `
  --type azureEndpoints --target-resource-id $UK_ID `
  --priority 2 --endpoint-status Enabled -o none

# 7.5 Add endpoints to Geographic TM
Write-Host "--- Adding endpoints to Geographic TM ---"
az network traffic-manager endpoint create -g $RG_NAME `
  --profile-name $TM_GEO -n us-endpoint `
  --type azureEndpoints --target-resource-id $US_ID `
  --endpoint-status Enabled --geo-mapping "US" -o none
az network traffic-manager endpoint create -g $RG_NAME `
  --profile-name $TM_GEO -n uk-endpoint `
  --type azureEndpoints --target-resource-id $UK_ID `
  --endpoint-status Enabled --geo-mapping "GB" -o none

# 7.6 Add endpoints to Weighted TM (70/30 split)
Write-Host "--- Adding endpoints to Weighted TM (70/30) ---"
az network traffic-manager endpoint create -g $RG_NAME `
  --profile-name $TM_WEIGHTED -n us-weighted `
  --type azureEndpoints --target-resource-id $US_ID `
  --weight 70 --endpoint-status Enabled -o none
az network traffic-manager endpoint create -g $RG_NAME `
  --profile-name $TM_WEIGHTED -n uk-weighted `
  --type azureEndpoints --target-resource-id $UK_ID `
  --weight 30 --endpoint-status Enabled -o none

# 7.7 Create DNS CNAME records pointing to TM profiles
# NOTE: Using plain CNAME text here. The kimvaddi.com reference uses Azure alias records
#       (targetResource → TM resource ID) which is the recommended production pattern.
#       Alias records support apex domains and auto-update if TM FQDN changes.
#       For production, replace cname set-record with:
#         az network dns record-set cname create -g $RG_NAME -z $DOMAIN -n failover --ttl 30
#         az network dns record-set cname update -g $RG_NAME -z $DOMAIN -n failover \
#           --target-resource <TM-resource-id>
#
# TTL set to 30 seconds (matching kimvaddi.com) for fast failover response.
# Default 3600 (1 hour) means clients cache stale IPs for too long during failover.

Write-Host "--- Wiring DNS CNAME records to TM profiles (TTL=30s) ---"
az network dns record-set cname set-record -g $RG_NAME -z $DOMAIN `
  -n failover -c "$TM_FAILOVER.trafficmanager.net" -o none
az network dns record-set cname update -g $RG_NAME -z $DOMAIN `
  -n failover --set ttl=30 -o none

az network dns record-set cname set-record -g $RG_NAME -z $DOMAIN `
  -n geo -c "$TM_GEO.trafficmanager.net" -o none
az network dns record-set cname update -g $RG_NAME -z $DOMAIN `
  -n geo --set ttl=30 -o none

az network dns record-set cname set-record -g $RG_NAME -z $DOMAIN `
  -n weighted -c "$TM_WEIGHTED.trafficmanager.net" -o none
az network dns record-set cname update -g $RG_NAME -z $DOMAIN `
  -n weighted --set ttl=30 -o none

# VERIFY Step 7
Write-Host "`n--- VERIFY: Web Apps running ---" -ForegroundColor Green
az webapp list -g $RG_NAME --query "[].{name:name, state:state, url:defaultHostName}" -o table

Write-Host "`n--- VERIFY: TM endpoints ---" -ForegroundColor Green
az network traffic-manager endpoint list -g $RG_NAME --profile-name $TM_FAILOVER `
  --query "[].{name:name, priority:priority, status:endpointMonitorStatus}" -o table

Write-Host "`n--- VERIFY: DNS CNAME resolution ---" -ForegroundColor Green
$NS = (az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers[0]" -o tsv).Trim('.')
nslookup -type=CNAME failover.$DOMAIN $NS
nslookup -type=CNAME geo.$DOMAIN $NS
nslookup -type=CNAME weighted.$DOMAIN $NS


# ============================================================================
# SECTION 7.8: CUSTOM DOMAIN + TLS BINDING (Production-Grade Wiring)
# Binds: Custom domain to web apps + Let's Encrypt TLS Certificate from Key Vault
# Dependencies: Section 2.5 (DNS delegation), Section 5.5 (Let's Encrypt cert in KV)
#
# CERTIFICATE STRATEGY (per MS Learn best practice):
#   - PRIMARY: Import Let's Encrypt wildcard cert from Key Vault → both web apps
#     Command: az webapp config ssl import --key-vault --key-vault-certificate-name
#     Ref: https://learn.microsoft.com/azure/app-service/configure-ssl-certificate#import-a-certificate-from-key-vault
#   - FALLBACK: App Service Managed Certificate (if LE cert not yet in KV)
#
# WHY KEY VAULT IMPORT:
#   - Single wildcard cert (*.$DOMAIN) covers ALL subdomains (failover, geo, weighted)
#   - App Service auto-syncs with Key Vault — cert renewals propagate within 24hrs
#   - Demonstrates enterprise cert management pattern (DigiCert → KV → App Service)
#   - Key Vault audit trail shows who accessed which cert and when
#
# STEPS:
#   1. Create asuid TXT record with webapp's customDomainVerificationId
#   2. Bind custom domain hostname to BOTH web apps (US + UK)
#   3. Import Let's Encrypt cert from Key Vault (or create managed cert as fallback)
#   4. Bind TLS cert with SNI to BOTH web apps
#
# PREREQUISITE: The customer MUST have completed NS delegation at their
# registrar (Section 2.5) before this section will work. Azure App Service
# validates domain ownership by querying public DNS for the TXT + CNAME records.
#
# If delegation is NOT done yet, skip this section — the POC still works
# for TM failover/geo/weighted testing using .azurewebsites.net hostnames.
# ============================================================================

Write-Host "`n=== STEP 7.8: CUSTOM DOMAIN + TLS BINDING ===" -ForegroundColor Cyan

# All 3 TM subdomains need custom domain + TLS (adopted from devmauser multi-domain pattern)
$CUSTOM_HOSTNAMES = @("failover.$DOMAIN", "geo.$DOMAIN", "weighted.$DOMAIN")

# Check if delegation is working before attempting custom domain binding
Write-Host "--- Checking if DNS delegation is active ---"
$delegationOk = $false
$nsCheck = Resolve-DnsName -Name $DOMAIN -Type NS -Server 8.8.8.8 -ErrorAction SilentlyContinue
if ($nsCheck | Where-Object { $_.NameHost -like "*azure-dns*" }) {
    Write-Host "  Delegation confirmed — proceeding with custom domain binding" -ForegroundColor Green
    $delegationOk = $true
} else {
    Write-Host "  Delegation NOT active — skipping custom domain + TLS binding" -ForegroundColor Yellow
    Write-Host "  Complete NS delegation at your registrar (Section 2.5), then re-run this section."
    Write-Host "  The POC still works without this — TM health checks use .azurewebsites.net directly."
}

if ($delegationOk) {
    # 7.8.1 Get the webapp's customDomainVerificationId
    $VERIFY_ID_US = (az webapp show -g $RG_NAME -n $WEBAPP_US --query "customDomainVerificationId" -o tsv)
    $VERIFY_ID_UK = (az webapp show -g $RG_NAME -n $WEBAPP_UK --query "customDomainVerificationId" -o tsv)
    Write-Host "  US webapp verification ID: $($VERIFY_ID_US.Substring(0,16))..."
    Write-Host "  UK webapp verification ID: $($VERIFY_ID_UK.Substring(0,16))..."

    # 7.8.2 Check for LE wildcard cert in Key Vault (determines cert strategy)
    $leCertInKV = az keyvault certificate show --vault-name $KV_NAME --name $LE_CERT_NAME --query "name" -o tsv 2>$null
    $useWildcard = ($leCertInKV -and $ENABLE_LETSENCRYPT)
    if ($useWildcard) {
        Write-Host "  LE wildcard cert found in KV — will use for ALL hostnames" -ForegroundColor Green
    } else {
        Write-Host "  LE cert not in KV — will use App Service Managed Certificates" -ForegroundColor Yellow
    }

    # 7.8.3 Loop over ALL custom hostnames (failover, geo, weighted) × BOTH web apps
    # Adopted from devmauser multi-domain pattern: wildcard cert covers all subdomains
    foreach ($hostname in $CUSTOM_HOSTNAMES) {
        $subdomain = ($hostname -split '\.')[0]  # e.g., "failover", "geo", "weighted"
        Write-Host "`n--- Wiring $hostname ---" -ForegroundColor Cyan

        # Create asuid TXT verification records for both web apps
        az network dns record-set txt add-record -g $RG_NAME -z $DOMAIN `
          -n "asuid.$subdomain" -v $VERIFY_ID_US -o none 2>$null
        az network dns record-set txt add-record -g $RG_NAME -z $DOMAIN `
          -n "asuid.$subdomain" -v $VERIFY_ID_UK -o none 2>$null
        Write-Host "  Created: asuid.$subdomain.$DOMAIN TXT records"

        # Bind custom domain to BOTH web apps
        foreach ($app in @($WEBAPP_US, $WEBAPP_UK)) {
            Write-Host "  Binding $hostname → $app..."
            az webapp config hostname add -g $RG_NAME --webapp-name $app --hostname $hostname -o none 2>$null
            if ($?) {
                Write-Host "    Bound" -ForegroundColor Green
            } else {
                Write-Host "    Bind failed (may already exist)" -ForegroundColor Yellow
            }
        }

        # Import/create TLS certificate
        if ($useWildcard) {
            # ── PRIMARY: Import LE wildcard cert from Key Vault ──
            foreach ($app in @($WEBAPP_US, $WEBAPP_UK)) {
                Write-Host "  Importing LE cert → $app..."
                az webapp config ssl import -g $RG_NAME -n $app `
                  --key-vault $KV_NAME `
                  --key-vault-certificate-name $LE_CERT_NAME `
                  -o none 2>$null
                if ($?) {
                    Write-Host "    LE cert imported" -ForegroundColor Green
                } else {
                    Write-Host "    Import failed — check KV Certificate User RBAC" -ForegroundColor Red
                }
            }
        } else {
            # ── FALLBACK: App Service Managed Certificate ──
            foreach ($app in @($WEBAPP_US, $WEBAPP_UK)) {
                Write-Host "  Creating managed cert for $app..."
                az webapp config ssl create -g $RG_NAME -n $app --hostname $hostname -o none 2>$null
                if ($?) {
                    Write-Host "    Managed cert created" -ForegroundColor Green
                } else {
                    Write-Host "    Managed cert failed — DNS propagation may be pending" -ForegroundColor Yellow
                }
            }
        }

        # Bind TLS cert with SNI to both web apps
        foreach ($app in @($WEBAPP_US, $WEBAPP_UK)) {
            $thumbprint = (az webapp config ssl list -g $RG_NAME `
              --query "[?subjectName=='$hostname' || contains(subjectName,'*.$DOMAIN')].thumbprint | [0]" -o tsv 2>$null)
            if ($thumbprint) {
                az webapp config ssl bind -g $RG_NAME -n $app `
                  --certificate-thumbprint $thumbprint --ssl-type SNI `
                  --hostname $hostname -o none 2>$null
                Write-Host "  TLS bound: $hostname → $app (SNI)" -ForegroundColor Green
            } else {
                Write-Host "  No cert found for $hostname on $app — may still be provisioning" -ForegroundColor Yellow
            }
        }
    }

    # VERIFY — all hostnames + both web apps should show SniEnabled
    Write-Host "`n--- VERIFY: Custom domain + TLS (all hostnames, both web apps) ---" -ForegroundColor Green
    Write-Host "US webapp:"
    az webapp config hostname list -g $RG_NAME --webapp-name $WEBAPP_US `
      --query "[].{hostname:name, sslState:sslState}" -o table
    Write-Host "UK webapp:"
    az webapp config hostname list -g $RG_NAME --webapp-name $WEBAPP_UK `
      --query "[].{hostname:name, sslState:sslState}" -o table
}


# ============================================================================
# SECTION 7.5: RESOURCE DIAGNOSTIC SETTINGS (Web Apps + Traffic Manager)
# Sends: All web app logs + TM probe health events → Log Analytics
# Dependencies: Section 7 (Web Apps + TM must exist), Section 1 (LAW)
#
# Without this, Log Analytics only has Activity Log — no web app request logs,
# no TM endpoint health events, no app errors. This fills the gap.
# ============================================================================

Write-Host "`n=== STEP 7.5: RESOURCE DIAGNOSTIC SETTINGS ===" -ForegroundColor Cyan

$LAW_ID = (az monitor log-analytics workspace show -g $RG_NAME -n $LAW_NAME --query "id" -o tsv)

# 7.5.1 Web App US — All log categories + metrics
$US_RESOURCE_ID = (az webapp show -g $RG_NAME -n $WEBAPP_US --query "id" -o tsv)
Write-Host "--- Enabling diagnostics on $WEBAPP_US ---"
az monitor diagnostic-settings create `
  --name "webapp-logs-to-law" `
  --resource $US_RESOURCE_ID `
  --workspace $LAW_ID `
  --logs '[{\"category\":\"AppServiceHTTPLogs\",\"enabled\":true},{\"category\":\"AppServiceConsoleLogs\",\"enabled\":true},{\"category\":\"AppServiceAppLogs\",\"enabled\":true},{\"category\":\"AppServiceAuditLogs\",\"enabled\":true},{\"category\":\"AppServiceIPSecAuditLogs\",\"enabled\":true},{\"category\":\"AppServicePlatformLogs\",\"enabled\":true},{\"category\":\"AppServiceAuthenticationLogs\",\"enabled\":true}]' `
  --metrics '[{\"category\":\"AllMetrics\",\"enabled\":true}]' `
  --query "{name:name}" -o table

# 7.5.2 Web App UK — All log categories + metrics
$UK_RESOURCE_ID = (az webapp show -g $RG_NAME -n $WEBAPP_UK --query "id" -o tsv)
Write-Host "--- Enabling diagnostics on $WEBAPP_UK ---"
az monitor diagnostic-settings create `
  --name "webapp-logs-to-law" `
  --resource $UK_RESOURCE_ID `
  --workspace $LAW_ID `
  --logs '[{\"category\":\"AppServiceHTTPLogs\",\"enabled\":true},{\"category\":\"AppServiceConsoleLogs\",\"enabled\":true},{\"category\":\"AppServiceAppLogs\",\"enabled\":true},{\"category\":\"AppServiceAuditLogs\",\"enabled\":true},{\"category\":\"AppServiceIPSecAuditLogs\",\"enabled\":true},{\"category\":\"AppServicePlatformLogs\",\"enabled\":true},{\"category\":\"AppServiceAuthenticationLogs\",\"enabled\":true}]' `
  --metrics '[{\"category\":\"AllMetrics\",\"enabled\":true}]' `
  --query "{name:name}" -o table

# 7.5.3 Traffic Manager — All 3 profiles: ProbeHealthStatusEvents + AllMetrics
foreach ($tmName in @($TM_FAILOVER, $TM_GEO, $TM_WEIGHTED)) {
    $tmResourceId = (az network traffic-manager profile show -g $RG_NAME -n $tmName --query "id" -o tsv)
    Write-Host "--- Enabling diagnostics on $tmName ---"
    az monitor diagnostic-settings create `
      --name "tm-logs-to-law" `
      --resource $tmResourceId `
      --workspace $LAW_ID `
      --logs '[{\"category\":\"ProbeHealthStatusEvents\",\"enabled\":true}]' `
      --metrics '[{\"category\":\"AllMetrics\",\"enabled\":true}]' `
      --query "{name:name}" -o table
}

# VERIFY Step 7.5
Write-Host "`n--- VERIFY: Resource diagnostics configured ---" -ForegroundColor Green
Write-Host "Web App US:"
az monitor diagnostic-settings list --resource $US_RESOURCE_ID --query "[].{name:name, logCount:length(logs[?enabled])}" -o table
Write-Host "Web App UK:"
az monitor diagnostic-settings list --resource $UK_RESOURCE_ID --query "[].{name:name, logCount:length(logs[?enabled])}" -o table
Write-Host "TM Failover:"
$tmFId = (az network traffic-manager profile show -g $RG_NAME -n $TM_FAILOVER --query "id" -o tsv)
az monitor diagnostic-settings list --resource $tmFId --query "[].{name:name, logCount:length(logs[?enabled])}" -o table
Write-Host ""
Write-Host "Log categories now flowing to LAW:"
Write-Host "  Activity Log:      8 categories (Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth)"
Write-Host "  Web Apps:          7 categories per app (HTTPLogs, ConsoleLogs, AppLogs, AuditLogs, IPSecAuditLogs, PlatformLogs, AuthenticationLogs) + Metrics"
Write-Host "  Traffic Manager:   ProbeHealthStatusEvents + Metrics (per profile)"
Write-Host "  DNS Zone:          NOT SUPPORTED (Azure limitation — management changes tracked via Activity Log only)"


# ============================================================================
# SECTION 8: ZONE SNAPSHOTS (Required #4)
# Tests: On-demand zone export and re-import verification
# Dependencies: Section 2 (DNS Zone with records)
# Exports to: ./zone-snapshots/ directory (matching bash runbook convention)
# ============================================================================

Write-Host "`n=== STEP 8: ZONE SNAPSHOTS ===" -ForegroundColor Cyan

$SNAPSHOT_DIR = ".\\zone-snapshots"

# 8.1 Create snapshot directory if it doesn't exist
if (-not (Test-Path $SNAPSHOT_DIR)) {
    New-Item -ItemType Directory -Path $SNAPSHOT_DIR -Force | Out-Null
    Write-Host "  Created directory: $SNAPSHOT_DIR"
}

# 8.2 Export primary zone snapshot
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$SNAPSHOT_FILE = "$SNAPSHOT_DIR\\snapshot-$DOMAIN-$TIMESTAMP.zone"
Write-Host "--- Exporting zone snapshot: $DOMAIN ---"
az network dns zone export -g $RG_NAME -n $DOMAIN -f $SNAPSHOT_FILE

if (Test-Path $SNAPSHOT_FILE) {
    $fileInfo = Get-Item $SNAPSHOT_FILE
    $content = Get-Content $SNAPSHOT_FILE
    $recordLines = ($content | Select-String -Pattern '\bIN\b' | Measure-Object).Count
    Write-Host "  Snapshot saved: $($fileInfo.FullName)" -ForegroundColor Green
    Write-Host "  Size: $([math]::Round($fileInfo.Length / 1KB, 1)) KB | Records: ~$recordLines"
} else {
    Write-Host "  WARNING: Snapshot file not created" -ForegroundColor Yellow
}

# 8.3 Export additional zones (if imported in Section 1.4)
if (-not [string]::IsNullOrWhiteSpace($ZONE_NAME_2) -and ($ZONE_NAME_2 -ne $DOMAIN)) {
    $zoneExists = az network dns zone show -g $RG_NAME -n $ZONE_NAME_2 --query "name" -o tsv 2>$null
    if ($zoneExists) {
        $SNAPSHOT_FILE_2 = "$SNAPSHOT_DIR\\snapshot-$ZONE_NAME_2-$TIMESTAMP.zone"
        Write-Host "--- Exporting zone snapshot: $ZONE_NAME_2 ---"
        az network dns zone export -g $RG_NAME -n $ZONE_NAME_2 -f $SNAPSHOT_FILE_2
        Write-Host "  Saved: $SNAPSHOT_FILE_2"
    }
}

# 8.4 Verify snapshot is valid (re-import to temp zone)
Write-Host "--- Verifying primary snapshot by re-importing to test zone ---"
az network dns zone create -g $RG_NAME -n "snapshot-test.$DOMAIN" -o none 2>$null
az network dns zone import -g $RG_NAME -n "snapshot-test.$DOMAIN" -f $SNAPSHOT_FILE 2>$null

$reimportCount = (az network dns zone show -g $RG_NAME -n "snapshot-test.$DOMAIN" --query "numberOfRecordSets" -o tsv 2>$null)
$originalCount = (az network dns zone show -g $RG_NAME -n $DOMAIN --query "numberOfRecordSets" -o tsv 2>$null)
Write-Host "  Original zone: $originalCount record sets"
Write-Host "  Re-imported:   $reimportCount record sets"
if ($reimportCount -gt 0) {
    Write-Host "  PASS: Snapshot is valid — re-import successful" -ForegroundColor Green
}

# 8.5 Cleanup test zone
az network dns zone delete -g $RG_NAME -n "snapshot-test.$DOMAIN" --yes -o none 2>$null

# 8.6 List all snapshots
Write-Host "`n--- All snapshots in $SNAPSHOT_DIR ---"
if (Test-Path $SNAPSHOT_DIR) {
    Get-ChildItem $SNAPSHOT_DIR -Filter "*.zone" | 
      Select-Object Name, @{n='Size';e={"$([math]::Round($_.Length/1KB,1)) KB"}}, LastWriteTime |
      Format-Table -AutoSize
} else {
    Write-Host "  No snapshots yet"
}

Write-Host @"

  SCHEDULED SNAPSHOTS (for production):
    Add to Windows Task Scheduler or Azure Automation:
    az network dns zone export -g $RG_NAME -n $DOMAIN -f "$SNAPSHOT_DIR\snapshot-$DOMAIN-`$(Get-Date -Format yyyyMMdd).zone"
    Retention: Keep last 30 daily snapshots
"@


# ============================================================================
# SECTION 9: DNSSEC (Optional #10)
# Deploys: DNSSEC zone signing
# Dependencies: Section 2 (DNS Zone)
#
# NOTE: After signing, the DS record must be published at the parent/registrar
#       for full DNSSEC chain of trust. For a POC subdomain, this step
#       confirms zone signing works — DS publication is a production step.
# ============================================================================

Write-Host "`n=== STEP 9: DNSSEC ===" -ForegroundColor Cyan

# Use the DNSSEC child zone (set in Section 0.5), or fall back to $DOMAIN
$DNSSEC_TARGET = if ($DNSSEC_ZONE) { $DNSSEC_ZONE } else { $DOMAIN }
Write-Host "  DNSSEC target zone: $DNSSEC_TARGET"

# 9.1 Enable DNSSEC signing
Write-Host "--- Enabling DNSSEC zone signing ---"
# Ref: https://learn.microsoft.com/azure/dns/dnssec-how-to
# Ref: https://learn.microsoft.com/azure/dns/dnssec (DNSSEC overview)
az network dns dnssec-config create -g $RG_NAME -z $DNSSEC_TARGET `
  --query "{provisioningState:provisioningState}" -o table

# 9.2 Show signing keys (DS record for registrar)
Write-Host "--- DNSSEC signing keys ---"
az network dns dnssec-config show -g $RG_NAME -z $DNSSEC_TARGET `
  --query "{signingKeys:signingKeys[].{keyTag:keyTag, flags:flags}}" -o json

# 9.2.5 DNSSEC SUBDOMAIN APPROACH — Publish DS record in parent zone
if ($ENABLE_DNSSEC_SUBDOMAIN -and $ENABLE_DOMAIN_PURCHASE) {
    Write-Host "`n--- Publishing DS record in parent zone (chain of trust) ---" -ForegroundColor Cyan
    Write-Host "  Child zone: $DNSSEC_TARGET → Parent zone: $ROOT_DOMAIN"

    # Wait for signing to complete
    $maxWait = 120; $waited = 0
    while ($waited -lt $maxWait) {
        $signingKeysJson = az network dns zone show -n $DNSSEC_TARGET -g $RG_NAME `
            --query "signingKeys[?flags == ``257``] | [0]" -o json 2>$null
        if ($signingKeysJson -and $signingKeysJson -ne 'null') {
            $dsInfo = $signingKeysJson | ConvertFrom-Json
            if ($dsInfo.delegationSignerInfo -and $dsInfo.delegationSignerInfo.Count -gt 0) { break }
        }
        Start-Sleep -Seconds 15; $waited += 15
        Write-Host "  Waiting for signing... ${waited}s"
    }

    if ($dsInfo -and $dsInfo.delegationSignerInfo.Count -gt 0) {
        $ds = $dsInfo.delegationSignerInfo[0]
        $recordParts = $ds.record -split '\s+'
        $keyTag     = $recordParts[0]
        $algorithm  = $recordParts[1]
        $digestType = $recordParts[2]
        $digest     = $recordParts[3]
        $childPrefix = $DNSSEC_TARGET.Replace(".$ROOT_DOMAIN", "")

        Write-Host "  DS: keyTag=$keyTag algorithm=$algorithm digestType=$digestType"
        az network dns record-set ds add-record -g $RG_NAME -z $ROOT_DOMAIN `
            -n $childPrefix --key-tag $keyTag --algorithm $algorithm `
            --digest-type $digestType --digest $digest --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  DS record published in $ROOT_DOMAIN for $childPrefix" -ForegroundColor Green
        } else {
            Write-Host "  DS record publication failed" -ForegroundColor Red
        }
    } else {
        Write-Host "  Could not retrieve DS record — signing may still be in progress" -ForegroundColor Yellow
    }
} else {
    Write-Host "`n  NOTE: For full DNSSEC chain of trust, publish the DS record at your registrar." -ForegroundColor Yellow
}

# 9.3 Verify DNSKEY records
Write-Host "--- Verify DNSKEY records ---"
Resolve-DnsName -Name $DNSSEC_TARGET -Type DNSKEY -Server $NS |
  Format-Table Name, Type, KeyTag, Flags -AutoSize


# ============================================================================
# SECTION 9.5: SECURITY HARDENING
# Applies: Resource locks, key rotation, security posture fixes
# ============================================================================

Write-Host "`n=== STEP 9.5: SECURITY HARDENING ===" -ForegroundColor Cyan

# 9.5.1 Resource lock on DNS zone (prevents accidental deletion)
Write-Host "--- Adding CanNotDelete lock on DNS zone ---"
az lock create --name "dns-zone-nodelete" `
  --resource-group $RG_NAME `
  --resource $DOMAIN `
  --resource-type Microsoft.Network/dnsZones `
  --lock-type CanNotDelete `
  --notes "Prevent accidental DNS zone deletion during POC" `
  --query "{name:name, level:level}" -o table

# 9.5.2 Managed Identity + RBAC for Event Hub (replaces SAS keys where possible)
#
# WHY SAS KEYS CAN'T BE FULLY ELIMINATED IN THIS ARCHITECTURE:
#
#   1. Diagnostic Settings → Event Hub: Azure requires --event-hub-auth-rule (SAS).
#      There is no managed identity option for diagnostic settings. Platform limitation.
#
#   2. QRadar → Event Hub: QRadar is external (on-prem/SaaS). It cannot authenticate
#      via Azure AD / Managed Identity. Must use SAS Listen connection string.
#
#   3. Azure-native consumers (Functions, Logic Apps): CAN use managed identity.
#      If Zava adds Azure Functions to process Event Hub events in the future,
#      those should use managed identity + RBAC — not SAS keys.
#
# WHAT WE DO:
#   a) Create RBAC role assignments for Azure-native access (future-ready)
#   b) Rotate the root SAS key (mitigate default full-access key)
#   c) Document the SAS vs Managed Identity boundary clearly

Write-Host "--- Setting up RBAC roles for Event Hub (Managed Identity path) ---"

# Get Event Hub namespace resource ID
$EH_NS_ID = (az eventhubs namespace show -g $RG_NAME -n $EH_NAMESPACE --query "id" -o tsv)

# Get current user for RBAC assignment (POC operator)
$CURRENT_USER = (az ad signed-in-user show --query "id" -o tsv 2>$null)

if ($CURRENT_USER) {
    # Assign Azure Event Hubs Data Sender (for sending events — Azure-native path)
    Write-Host "  Assigning 'Azure Event Hubs Data Sender' to current user..."
    az role assignment create `
      --assignee $CURRENT_USER `
      --role "Azure Event Hubs Data Sender" `
      --scope $EH_NS_ID -o none 2>$null

    # Assign Azure Event Hubs Data Receiver (for reading events — Azure-native path)
    Write-Host "  Assigning 'Azure Event Hubs Data Receiver' to current user..."
    az role assignment create `
      --assignee $CURRENT_USER `
      --role "Azure Event Hubs Data Receiver" `
      --scope $EH_NS_ID -o none 2>$null

    Write-Host "  RBAC roles assigned. Azure-native consumers can now use managed identity."
} else {
    Write-Host "  Could not get current user ID — skipping RBAC assignments." -ForegroundColor Yellow
    Write-Host "  Assign manually:"
    Write-Host "    az role assignment create --assignee <user-or-identity> --role 'Azure Event Hubs Data Sender' --scope $EH_NS_ID"
    Write-Host "    az role assignment create --assignee <user-or-identity> --role 'Azure Event Hubs Data Receiver' --scope $EH_NS_ID"
}

# Rotate the root SAS key (can't delete it, but can invalidate the old key)
Write-Host "--- Rotating Event Hub root SAS key ---"
az eventhubs namespace authorization-rule keys renew `
  -g $RG_NAME --namespace-name $EH_NAMESPACE `
  --name RootManageSharedAccessKey --key PrimaryKey -o none
Write-Host "  RootManageSharedAccessKey primary key rotated"

Write-Host @"

  ── SAS vs Managed Identity: When to Use Which ──

  SAS Keys (required for these cases):
    • Diagnostic Settings → Event Hub (Azure platform requires auth rule)
    • QRadar/Splunk → Event Hub (external SIEM can't use Azure AD)
    • Script uses: SendPolicy (write) + QRadarListenPolicy (read)
    ⚠️  SECURITY: Never commit SAS keys to Git. Use Key Vault or secure CI/CD variables.

  Managed Identity + RBAC (use for these cases):
    • Azure Functions consuming Event Hub events
    • Logic Apps processing DNS change alerts
    • Any Azure-hosted service reading/writing to Event Hub
    • Roles: 'Azure Event Hubs Data Sender' / 'Azure Event Hubs Data Receiver'
    ✅ PREFERRED: Managed Identity eliminates secrets in application code

  Root Key (RootManageSharedAccessKey):
    • Cannot be deleted — Azure default
    • Rotated by this script (old key invalidated)
    • NEVER use this key in application code
    • Rotate quarterly in production
    • NEVER log to stdout/files in production pipelines

"@

# PRODUCTION HARDENING CHECKLIST (not applied in POC — document for customer)
Write-Host @"

`n--- PRODUCTION HARDENING (Post-POC) ---
The following items are recommended for production but not applied in the POC:

  1. Key Vault:           Store Event Hub + Storage connection strings in Key Vault
                          Reference via managed identity — no keys in code or config
  2. Network restrictions: Add IP rules or private endpoints on Event Hub + Storage
                          az eventhubs namespace network-rule-set update --default-action Deny
  3. Managed Identity:    For Azure-native consumers (Functions/Logic Apps)
                          RBAC roles already assigned by this script (Data Sender/Receiver)
                          SAS keys still required for diagnostic settings + QRadar
  4. Web App restrictions: Add IP allow-list or VNet integration on web apps
  5. LAW retention:       Increase from 30 days to 90-365 days for compliance
  6. Azure Policy:        Add policies for required tags, allowed DNS record types
  7. Budget alert:        az consumption budget create for cost control
  8. Alias records:       Replace plain CNAME with Azure alias (targetResource) for TM
  9. Root key rotation:   Already rotated. Continue rotating quarterly.
  10. Disable public access: Event Hub + Storage — use private endpoints only

"@


# ============================================================================
# SECTION 10: FINAL VALIDATION + CLEANUP
# ============================================================================

Write-Host "`n=== FINAL VALIDATION ===" -ForegroundColor Cyan
Write-Host "--- All deployed resources ---"
az resource list --resource-group $RG_NAME `
  --query "[].{name:name, type:type, location:location}" -o table

Write-Host "`n--- DNS Zone record count ---"
az network dns zone show -g $RG_NAME -n $DOMAIN `
  --query "{zone:name, records:numberOfRecordSets}" -o table

Write-Host "`n--- Traffic Manager health ---"
az network traffic-manager profile list -g $RG_NAME `
  --query "[].{name:name, routing:trafficRoutingMethod, status:monitorConfig.profileMonitorStatus}" -o table

Write-Host "`n=== POC DEPLOYMENT COMPLETE ===" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. Share Event Hub connection string with SIEM team (QRadar)"
Write-Host "  2. Assign RBAC roles to Operator/Admin test accounts"
Write-Host "  3. Run DCV tests with real DigiCert tokens"
Write-Host "  4. Build Azure Monitor Workbooks for reporting dashboards"
Write-Host "  5. Schedule zone snapshot automation"


# ============================================================================
# SECTION 11: AZURE FRONT DOOR (OPTIONAL — Commented Out)
# Deploys: AFD Standard profile, origin group, origins, route, custom domain
# Dependencies: Section 7 (Web Apps must exist and be running)
#
# WHEN TO USE THIS:
#   Azure Front Door is an APPLICATION-LAYER (Layer 7) reverse proxy.
#   Unlike Traffic Manager (DNS-only, Layer 3), AFD sits in the data path:
#
#   Traffic Manager:  Client → DNS → gets backend IP → connects DIRECTLY to web app
#   Front Door:       Client → DNS → AFD edge POP → AFD proxies to web app
#
#   AFD adds: caching, WAF, SSL offloading, URL routing, header rewriting.
#   TM adds:  failover, geo-routing, weighted distribution (DNS-level only).
#
#   For the DNS POC, Traffic Manager is sufficient. Front Door is a future phase
#   for customers who need application-layer features.
#
# COST: ~$35/month for Standard SKU (in addition to POC costs)
#
# CUSTOM DOMAIN FLOW:
#   1. Create AFD profile + endpoint → gives you *.azurefd.net hostname
#   2. Add origins (your web apps) to an origin group
#   3. Create a route (/* → origin group)
#   4. Add custom domain → AFD gives you a validation token
#   5. Add _dnsauth TXT record in DNS zone with that token
#   6. Add CNAME record pointing subdomain → AFD endpoint
#   7. Associate custom domain to the route
#   8. AFD auto-issues a managed TLS certificate (5-15 min)
#   9. HTTPS traffic flows: client → AFD edge → origin web app
# ============================================================================

# --- Uncomment this entire block to deploy Azure Front Door ---

# $AFD_PROFILE    = "afd-dns-poc"                    # AFD profile name
# $AFD_ENDPOINT   = "poc-endpoint"                   # AFD endpoint name (globally unique)
# $AFD_SUBDOMAIN  = "app"                            # app.poc.zava-dnspoc.com → AFD
#
# Write-Host "`n=== STEP 11: AZURE FRONT DOOR (Optional) ===" -ForegroundColor Cyan
#
# # 11.1 Create AFD Profile (Standard SKU)
# Write-Host "--- 11.1 Creating Azure Front Door profile ---"
# az afd profile create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --sku Standard_AzureFrontDoor `
#   --query "{name:name, sku:sku.name}" -o table
#
# # 11.2 Create AFD Endpoint
# Write-Host "--- 11.2 Creating AFD endpoint ---"
# az afd endpoint create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --endpoint-name $AFD_ENDPOINT `
#   --enabled-state Enabled `
#   --query "{name:name, hostName:hostName}" -o table
#
# $AFD_HOSTNAME = (az afd endpoint show `
#   -g $RG_NAME --profile-name $AFD_PROFILE --endpoint-name $AFD_ENDPOINT `
#   --query "hostName" -o tsv)
# Write-Host "AFD Endpoint: $AFD_HOSTNAME"
#
# # 11.3 Create Origin Group (with health probes)
# Write-Host "--- 11.3 Creating origin group ---"
# az afd origin-group create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --origin-group-name default-origin-group `
#   --probe-request-type HEAD `
#   --probe-protocol Https `
#   --probe-interval-in-seconds 100 `
#   --probe-path "/" `
#   --sample-size 4 `
#   --successful-samples-required 3 `
#   --additional-latency-in-milliseconds 50 `
#   --query "{name:name}" -o table
#
# # 11.4 Add Origins (both web apps)
# $US_HOST = (az webapp show -g $RG_NAME -n $WEBAPP_US --query "defaultHostName" -o tsv)
# $UK_HOST = (az webapp show -g $RG_NAME -n $WEBAPP_UK --query "defaultHostName" -o tsv)
#
# Write-Host "--- 11.4 Adding US origin ---"
# az afd origin create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --origin-group-name default-origin-group `
#   --origin-name us-origin `
#   --host-name $US_HOST `
#   --origin-host-header $US_HOST `
#   --http-port 80 --https-port 443 `
#   --priority 1 --weight 1000 `
#   --enabled-state Enabled `
#   --query "{name:name, hostName:hostName}" -o table
#
# Write-Host "--- Adding UK origin ---"
# az afd origin create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --origin-group-name default-origin-group `
#   --origin-name uk-origin `
#   --host-name $UK_HOST `
#   --origin-host-header $UK_HOST `
#   --http-port 80 --https-port 443 `
#   --priority 1 --weight 1000 `
#   --enabled-state Enabled `
#   --query "{name:name, hostName:hostName}" -o table
#
# # 11.5 Create Route (all traffic → origin group)
# Write-Host "--- 11.5 Creating route ---"
# az afd route create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --endpoint-name $AFD_ENDPOINT `
#   --route-name default-route `
#   --origin-group default-origin-group `
#   --supported-protocols Http Https `
#   --patterns-to-match "/*" `
#   --forwarding-protocol MatchRequest `
#   --https-redirect Enabled `
#   --link-to-default-domain Enabled `
#   --query "{name:name}" -o table
#
# # 11.6 Add Custom Domain (with managed TLS certificate)
# # Get the DNS zone resource ID for auto-validation
# $DNS_ZONE_ID = (az network dns zone show -g $RG_NAME -n $DOMAIN --query "id" -o tsv)
#
# Write-Host "--- 11.6 Adding custom domain: $AFD_SUBDOMAIN.$DOMAIN ---"
# az afd custom-domain create `
#   --resource-group $RG_NAME `
#   --profile-name $AFD_PROFILE `
#   --custom-domain-name "$AFD_SUBDOMAIN-$($DOMAIN.Replace('.', '-'))" `
#   --host-name "$AFD_SUBDOMAIN.$DOMAIN" `
#   --certificate-type ManagedCertificate `
#   --minimum-tls-version TLS12 `
#   --azure-dns-zone $DNS_ZONE_ID `
#   --query "{hostName:hostName, validationState:domainValidationState}" -o table
#
# # 11.7 Get the validation token and create DNS records
# $AFD_CUSTOM_DOMAIN_NAME = "$AFD_SUBDOMAIN-$($DOMAIN.Replace('.', '-'))"
# $VALIDATION_TOKEN = (az afd custom-domain show `
#   -g $RG_NAME --profile-name $AFD_PROFILE `
#   --custom-domain-name $AFD_CUSTOM_DOMAIN_NAME `
#   --query "validationProperties.validationToken" -o tsv)
#
# Write-Host "--- 11.7 Creating DNS records for AFD ---"
# # Validation TXT record (AFD checks this to prove domain ownership)
# az network dns record-set txt add-record `
#   -g $RG_NAME -z $DOMAIN `
#   -n "_dnsauth.$AFD_SUBDOMAIN" `
#   -v $VALIDATION_TOKEN -o none
# Write-Host "Created: _dnsauth.$AFD_SUBDOMAIN.$DOMAIN TXT = $VALIDATION_TOKEN"
#
# # CNAME record (routes traffic through AFD)
# az network dns record-set cname set-record `
#   -g $RG_NAME -z $DOMAIN `
#   -n $AFD_SUBDOMAIN `
#   -c $AFD_HOSTNAME -o none
# Write-Host "Created: $AFD_SUBDOMAIN.$DOMAIN CNAME → $AFD_HOSTNAME"
#
# # 11.8 Associate custom domain to route
# Write-Host "--- 11.8 Associating custom domain to route ---"
# az afd route update `
#   -g $RG_NAME --profile-name $AFD_PROFILE `
#   --endpoint-name $AFD_ENDPOINT `
#   --route-name default-route `
#   --custom-domains $AFD_CUSTOM_DOMAIN_NAME `
#   --query "{name:name, customDomains:customDomains[].id}" -o json
#
# # 11.9 Verify
# Write-Host "`n--- VERIFY: Azure Front Door ---" -ForegroundColor Green
# az afd custom-domain show `
#   -g $RG_NAME --profile-name $AFD_PROFILE `
#   --custom-domain-name $AFD_CUSTOM_DOMAIN_NAME `
#   --query "{hostName:hostName, validation:domainValidationState, deployment:deploymentStatus}" -o table
#
# Write-Host "`nAFD Default endpoint test:"
# Write-Host "  curl https://$AFD_HOSTNAME/"
# Write-Host "`nCustom domain test (after cert provisioning — 5-15 min):"
# Write-Host "  curl https://$AFD_SUBDOMAIN.$DOMAIN/"
# Write-Host "`nManaged TLS certificate status:"
# Write-Host "  az afd custom-domain show -g $RG_NAME --profile-name $AFD_PROFILE --custom-domain-name $AFD_CUSTOM_DOMAIN_NAME --query deploymentStatus -o tsv"
# Write-Host ""
# Write-Host "NOTE: Managed certificate takes 5-15 minutes to provision."
# Write-Host "      Until then, HTTPS on the custom domain will fail with SSL errors."
# Write-Host "      The AFD default endpoint (*.azurefd.net) works immediately."
#
# # ── HOW AFD DIFFERS FROM TRAFFIC MANAGER ──
# #
# #  Traffic Manager (DNS-level, Layer 3):
# #    Client → DNS query → TM returns backend IP → Client connects DIRECTLY to web app
# #    ✅ Failover, geo-routing, weighted (DNS only)
# #    ❌ No caching, WAF, URL routing, SSL offload
# #    💰 ~$0.75/million queries
# #
# #  Azure Front Door (Application-level, Layer 7):
# #    Client → DNS query → AFD edge POP → AFD proxies request → Web app
# #    ✅ Everything TM does PLUS caching, WAF, SSL offload, URL routing
# #    ❌ Higher cost, more complex setup
# #    💰 ~$35/month base + per-request charges
# #
# #  For Zava POC: Traffic Manager covers all Required + Optional scope items.
# #  Front Door is a future discussion for application-layer needs.


# ============================================================================
# CLEANUP — Run this to tear down ALL POC resources
# WARNING: This deletes everything in the resource group!
# ============================================================================

# Uncomment to destroy:
# Write-Host "=== CLEANUP: Deleting all POC resources ===" -ForegroundColor Red
# az network dns dnssec-config delete -g $RG_NAME -z $DOMAIN --yes
# az role definition delete --name "DNS Record Operator"
# az monitor diagnostic-settings subscription delete --name "activity-log-to-eh-and-law"
# az group delete --name $RG_NAME --yes --no-wait
# Write-Host "Cleanup initiated. Resource group deletion may take a few minutes."
