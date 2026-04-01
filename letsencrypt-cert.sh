#!/usr/bin/env bash
###############################################################################
# Let's Encrypt Certificate Automation for Azure DNS POC
#
# PURPOSE: Fully automated cert lifecycle using certbot + certbot-dns-azure
#   1. Retrieves SP credentials from Azure Key Vault
#   2. Generates certbot config (no secrets on disk permanently)
#   3. Runs staging dry-run to validate plumbing
#   4. Issues production cert via DNS-01 challenge
#   5. Converts PEM → PFX → imports to Key Vault
#   6. Cleans up temporary files
#
# USAGE:
#   ./letsencrypt-cert.sh                          # Full flow (staging → prod → KV)
#   ./letsencrypt-cert.sh --staging-only           # Dry-run only (no real cert)
#   ./letsencrypt-cert.sh --renew                  # Renew existing cert
#   ./letsencrypt-cert.sh --domain custom.domain   # Override domain
#
# PREREQUISITES:
#   - Azure CLI logged in (az login)
#   - pip install certbot certbot-dns-azure
#   - openssl (for PEM → PFX conversion)
#   - Key Vault with SP credentials (from Zava_DNS_POC_E2E.ps1 Phase 4)
#
# ZERO-SECRET PATTERN:
#   SP credentials are retrieved from Key Vault at runtime, written to a
#   temp file with 600 permissions, used by certbot, then deleted. No
#   secrets persist on disk or appear in logs.
#
###############################################################################
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DOMAIN="${DOMAIN:-demo.zava-dnspoc.com}"
RG_NAME="${RG_NAME:-rg-dns-poc}"
KV_NAME="${KV_NAME:-}"
CONTACT_EMAIL="${CONTACT_EMAIL:-admin@zavaenergy.com}"
PROPAGATION_WAIT=60
CERT_NAME_PREFIX="le"
STAGING_ONLY=false
RENEW_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --staging-only)  STAGING_ONLY=true; shift ;;
        --renew)         RENEW_ONLY=true; shift ;;
        --domain)        DOMAIN="$2"; shift 2 ;;
        --kv)            KV_NAME="$2"; shift 2 ;;
        --rg)            RG_NAME="$2"; shift 2 ;;
        --email)         CONTACT_EMAIL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--staging-only] [--renew] [--domain DOMAIN] [--kv KV_NAME] [--rg RG_NAME]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Derived
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
CERT_KV_NAME="${CERT_NAME_PREFIX}-$(echo "$DOMAIN" | tr '.' '-')"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Let's Encrypt Certificate Automation               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Domain:       $DOMAIN"
echo "║  Resource Group: $RG_NAME"
echo "║  Subscription:  $SUBSCRIPTION_ID"
echo "║  Key Vault:     ${KV_NAME:-<auto-detect>}"
echo "║  Mode:          $(if $STAGING_ONLY; then echo STAGING; elif $RENEW_ONLY; then echo RENEW; else echo FULL; fi)"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

echo "=== Pre-Flight Checks ==="

# Azure CLI
if ! command -v az &>/dev/null; then
    echo "❌ Azure CLI not found. Install: https://aka.ms/installazurecli"
    exit 1
fi
echo "  ✅ Azure CLI: $(az version --query '\"azure-cli\"' -o tsv)"

# certbot
if ! command -v certbot &>/dev/null; then
    echo "  ⚠️  certbot not found. Installing..."
    pip install certbot certbot-dns-azure 2>&1 | tail -3
    if ! command -v certbot &>/dev/null; then
        echo "❌ certbot installation failed. Run: pip install certbot certbot-dns-azure"
        exit 1
    fi
fi
echo "  ✅ certbot: $(certbot --version 2>&1 | head -1)"

# openssl
if ! command -v openssl &>/dev/null; then
    echo "❌ openssl not found. Install it for PEM → PFX conversion."
    exit 1
fi
echo "  ✅ openssl: $(openssl version)"

# Auto-detect Key Vault if not specified
if [ -z "$KV_NAME" ]; then
    KV_NAME=$(az keyvault list -g "$RG_NAME" --query "[?starts_with(name, 'kv-')].name | [0]" -o tsv 2>/dev/null)
    if [ -z "$KV_NAME" ]; then
        echo "❌ No Key Vault found in $RG_NAME. Run E2E script Phase 2 first."
        exit 1
    fi
fi
echo "  ✅ Key Vault: $KV_NAME"

# Verify DNS zone exists
ZONE_CHECK=$(az network dns zone show -g "$RG_NAME" -n "$DOMAIN" --query name -o tsv 2>/dev/null)
if [ -z "$ZONE_CHECK" ]; then
    echo "❌ DNS zone $DOMAIN not found in $RG_NAME"
    exit 1
fi
echo "  ✅ DNS Zone: $ZONE_CHECK"

echo ""

# ============================================================================
# STEP 1: DETERMINE AUTH METHOD (CLI credentials preferred, SP as fallback)
# ============================================================================

echo "=== Step 1: Configuring authentication ==="

# Option A: Azure CLI credentials (recommended — simplest, works with FDPO tenants)
# Option B: Service Principal cert credentials (for CI/CD automation)
USE_CLI_CREDS=true

CLIENT_ID=$(az keyvault secret show --vault-name "$KV_NAME" --name "certbot-sp-client-id" --query "value" -o tsv 2>/dev/null)
TENANT_ID=$(az keyvault secret show --vault-name "$KV_NAME" --name "certbot-sp-tenant-id" --query "value" -o tsv 2>/dev/null)

if [ "$USE_CLI_CREDS" = "true" ]; then
    # Verify az login is active
    az account show > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Azure CLI not logged in. Run 'az login' first."
        exit 1
    fi
    echo "  ✅ Using Azure CLI credentials (az login session)"
else
    CLIENT_SECRET=$(az keyvault secret show --vault-name "$KV_NAME" --name "certbot-sp-client-secret" --query "value" -o tsv 2>/dev/null)
    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$TENANT_ID" ]; then
        echo "❌ Missing SP credentials in Key Vault. Expected secrets:"
        echo "   - certbot-sp-client-id"
        echo "   - certbot-sp-client-secret (or use --create-cert for cert-based auth)"
        echo "   - certbot-sp-tenant-id"
        echo "   Set USE_CLI_CREDS=true to use Azure CLI credentials instead."
        exit 1
    fi
    echo "  ✅ SP credentials retrieved (not displayed)"
fi

# ============================================================================
# STEP 2: GENERATE CERTBOT CONFIG (temp file, 600 permissions)
# ============================================================================

echo "=== Step 2: Generating certbot config ==="

INI_PATH=$(mktemp /tmp/azure-certbot-XXXXXX.ini)
ZONE_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/dnszones/${DOMAIN}"

cat > "$INI_PATH" << EOF
$(if [ "$USE_CLI_CREDS" = "true" ]; then
echo "dns_azure_use_cli_credentials = true"
else
echo "dns_azure_sp_client_id = ${CLIENT_ID}"
echo "dns_azure_sp_client_secret = ${CLIENT_SECRET}"
echo "dns_azure_tenant_id = ${TENANT_ID}"
fi)
dns_azure_environment = AzurePublicCloud
dns_azure_zone1 = ${DOMAIN}:${ZONE_RESOURCE_ID}
EOF

chmod 600 "$INI_PATH"

# Clear secrets from shell (only relevant for SP auth)
if [ "$USE_CLI_CREDS" != "true" ]; then
    unset CLIENT_ID CLIENT_SECRET TENANT_ID
fi

echo "  ✅ Config written to $INI_PATH (mode 600)"

# Cleanup trap — always remove secrets file
cleanup() {
    if [ -f "$INI_PATH" ]; then
        rm -f "$INI_PATH"
        echo "  🔒 Cleaned up credentials file"
    fi
    if [ -f "/tmp/le-cert.pfx" ]; then
        rm -f "/tmp/le-cert.pfx"
    fi
}
trap cleanup EXIT

# ============================================================================
# STEP 3: STAGING DRY-RUN
# ============================================================================

echo ""
echo "=== Step 3: Staging dry-run ==="
echo "  Testing ACME DNS-01 flow without issuing a real cert..."
echo ""

STAGING_START=$SECONDS

certbot certonly \
    --authenticator dns-azure \
    --dns-azure-config "$INI_PATH" \
    --dns-azure-propagation-seconds "$PROPAGATION_WAIT" \
    --server https://acme-staging-v02.api.letsencrypt.org/directory \
    -d "$DOMAIN" \
    -d "*.$DOMAIN" \
    --dry-run \
    --non-interactive \
    --agree-tos \
    -m "$CONTACT_EMAIL" 2>&1 | tee /tmp/certbot-staging.log

STAGING_ELAPSED=$((SECONDS - STAGING_START))

if grep -q "dry run was successful\|would have been successful" /tmp/certbot-staging.log; then
    echo ""
    echo "  ✅ STAGING DRY-RUN PASSED (${STAGING_ELAPSED}s)"
    echo "     DNS-01 challenge + Azure DNS plugin working correctly"
else
    echo ""
    echo "  ❌ STAGING DRY-RUN FAILED (${STAGING_ELAPSED}s)"
    echo "     Check /tmp/certbot-staging.log for details"
    echo ""
    echo "  Common causes:"
    echo "    - NS delegation not propagated yet (wait up to 48 hours for new domains)"
    echo "    - SP doesn't have DNS Zone Contributor on $DOMAIN"
    echo "    - Azure DNS zone not publicly resolvable"
    exit 1
fi

if $STAGING_ONLY; then
    echo ""
    echo "  ℹ️  --staging-only flag set. Stopping here."
    echo "  To issue a real cert, run: $0"
    exit 0
fi

# ============================================================================
# STEP 4: PRODUCTION CERTIFICATE ISSUANCE
# ============================================================================

if $RENEW_ONLY; then
    echo ""
    echo "=== Step 4: Renewing existing certificate ==="
    certbot renew \
        --dns-azure-config "$INI_PATH" \
        --dns-azure-propagation-seconds "$PROPAGATION_WAIT" \
        --non-interactive 2>&1 | tee /tmp/certbot-renew.log

    if grep -q "No renewals to attempt\|renewed successfully" /tmp/certbot-renew.log; then
        echo "  ✅ Renewal check complete"
    else
        echo "  ⚠️  Renewal returned unexpected output — check /tmp/certbot-renew.log"
    fi
else
    echo ""
    echo "=== Step 4: Issuing PRODUCTION certificate ==="
    echo "  Domain: $DOMAIN + *.$DOMAIN"
    echo "  CA: Let's Encrypt (acme-v02.api.letsencrypt.org)"
    echo ""

    PROD_START=$SECONDS

    certbot certonly \
        --authenticator dns-azure \
        --dns-azure-config "$INI_PATH" \
        --dns-azure-propagation-seconds "$PROPAGATION_WAIT" \
        -d "$DOMAIN" \
        -d "*.$DOMAIN" \
        --non-interactive \
        --agree-tos \
        -m "$CONTACT_EMAIL" 2>&1 | tee /tmp/certbot-prod.log

    PROD_ELAPSED=$((SECONDS - PROD_START))

    if grep -q "Successfully received certificate\|Congratulations" /tmp/certbot-prod.log; then
        echo ""
        echo "  ✅ PRODUCTION CERT ISSUED (${PROD_ELAPSED}s)"
        certbot certificates --domain "$DOMAIN" 2>/dev/null
    else
        echo ""
        echo "  ❌ PRODUCTION CERT FAILED (${PROD_ELAPSED}s)"
        echo "     Check /tmp/certbot-prod.log"
        exit 1
    fi
fi

# ============================================================================
# STEP 5: IMPORT TO KEY VAULT
# ============================================================================

echo ""
echo "=== Step 5: Importing certificate to Key Vault ==="

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
FULLCHAIN="$CERT_DIR/fullchain.pem"
PRIVKEY="$CERT_DIR/privkey.pem"
PFX_PATH="/tmp/le-cert.pfx"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$PRIVKEY" ]; then
    echo "  ⚠️  Certificate files not found at $CERT_DIR"
    echo "     Checking alternative locations..."
    CERT_DIR=$(certbot certificates --domain "$DOMAIN" 2>/dev/null | grep "Certificate Path" | awk '{print $3}' | xargs dirname)
    FULLCHAIN="$CERT_DIR/fullchain.pem"
    PRIVKEY="$CERT_DIR/privkey.pem"
fi

if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    echo "  Converting PEM → PFX..."
    openssl pkcs12 -export \
        -in "$FULLCHAIN" \
        -inkey "$PRIVKEY" \
        -out "$PFX_PATH" \
        -passout pass: 2>/dev/null

    echo "  Importing to Key Vault: $KV_NAME"
    az keyvault certificate import \
        --vault-name "$KV_NAME" \
        --name "$CERT_KV_NAME" \
        --file "$PFX_PATH" \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "  ✅ Certificate imported: $CERT_KV_NAME"
        echo ""
        echo "  Certificate details:"
        az keyvault certificate show \
            --vault-name "$KV_NAME" \
            --name "$CERT_KV_NAME" \
            --query "{name:name, expires:attributes.expires, thumbprint:x509ThumbprintHex}" \
            -o table 2>/dev/null
    else
        echo "  ❌ Key Vault import failed"
        echo "     You may need Key Vault Certificates Officer role"
    fi

    rm -f "$PFX_PATH"
else
    echo "  ❌ Certificate files not found"
    echo "     Expected: $FULLCHAIN and $PRIVKEY"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Certificate Automation Complete                     ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Domain:     $DOMAIN"
echo "║  Wildcard:   *.$DOMAIN"
echo "║  Key Vault:  $KV_NAME"
echo "║  Cert Name:  $CERT_KV_NAME"
echo "║  Renewal:    certbot renew (every 60-90 days)"
echo "║                                                      ║"
echo "║  To auto-renew, add to crontab:                     ║"
echo "║  0 3 * * 1 $0 --renew"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo "    1. Bind cert to App Service:  az webapp config ssl bind ..."
echo "    2. Set up auto-renewal:       crontab (Linux) or Azure Automation"
echo "    3. Verify:                    az keyvault certificate show --vault-name $KV_NAME --name $CERT_KV_NAME"
