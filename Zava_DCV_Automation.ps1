# ============================================================================
# Zava DNS POC — DCV Automation Script
# ============================================================================
# Addresses 5 gaps identified in DCV_Gap_Analysis.md:
#   Gap 1: Service Identity (Service Principal for certbot/automation)
#   Gap 2: Certificate Issuance (DigiCert API — CUSTOMER INPUT REQUIRED)
#   Gap 3: Key Vault for certificate storage
#   Gap 4: Renewal Automation scaffold
#   Gap 5: DigiCert-specific integration (CUSTOMER INPUT REQUIRED)
#
# PREFERRED DEPLOYMENT: PowerShell (test here first, then backport)
# PREREQUISITES: Run Zava_DNS_POC_Deployment.ps1 Sections 0-2 first
#
# ============================================================================
# CUSTOMER ACTION REQUIRED — Items customer must provide:
#   1. DigiCert CertCentral API key (from DigiCert admin console)
#   2. DigiCert Organization ID
#   3. Decision: ACME (acme.digicert.com) or CertCentral API?
#   4. Real domain with NS delegation to Azure DNS
#   5. Approval to create Entra service principal in their tenant
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Gap1","Gap3","Gap4","Gap2","Gap5","All")]
    [string]$RunGap = "All",

    [Parameter(Mandatory=$false)]
    [switch]$SkipCustomerDependentGaps
)

# ============================================================================
# SECTION 0: CONFIGURATION (inherits from main deployment)
# ============================================================================

$RG_NAME        = "rg-dns-poc"
$LOCATION       = "southcentralus"
$DOMAIN         = "poc.Zava.com"
$SUBSCRIPTION   = (az account show --query id -o tsv)
$KV_NAME        = "kv-dns-poc-$(Get-Random -Maximum 9999)"  # Must be globally unique
$SP_NAME        = "sp-certbot-dns-poc"
$SP_DISPLAY     = "Certbot DNS Automation - Zava POC"

# ── CUSTOMER-PROVIDED VALUES (replace placeholders before running Gap 2/5) ──
$DIGICERT_API_KEY    = "<CUSTOMER-ACTION-REQUIRED: DigiCert CertCentral API key>"
$DIGICERT_ORG_ID     = "<CUSTOMER-ACTION-REQUIRED: DigiCert Organization ID>"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Zava DCV Automation — Configuration Loaded" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Subscription: $SUBSCRIPTION"
Write-Host "  Resource Group: $RG_NAME"
Write-Host "  Domain: $DOMAIN"
Write-Host "  Key Vault: $KV_NAME"
Write-Host "  Service Principal: $SP_NAME"
Write-Host "  Running: $RunGap"
Write-Host ""

# ============================================================================
# GAP 1: SERVICE IDENTITY — Create Service Principal for cert automation
# ============================================================================
# Creates: Entra ID service principal with DNS Record Operator role
# Scope: DNS zone only (least-privilege)
# Output: appId, password, tenant (for certbot credentials)
# ============================================================================

function Invoke-Gap1 {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host " GAP 1: SERVICE IDENTITY — Create Service Principal" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""

    # 1.1 Check if SP already exists
    Write-Host "Step 1/4: Checking if SP '$SP_NAME' already exists..."
    $existingSP = az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv 2>$null
    if ($existingSP) {
        Write-Host "  SP already exists: appId = $existingSP" -ForegroundColor Yellow
        Write-Host "  Skipping creation. Delete first if you need to recreate."
        return
    }

    # 1.2 Create SP with scoped RBAC
    $DNS_ZONE_SCOPE = "/subscriptions/$SUBSCRIPTION/resourceGroups/$RG_NAME/providers/Microsoft.Network/dnsZones/$DOMAIN"

    Write-Host "Step 2/4: Creating service principal '$SP_NAME'..."
    Write-Host "  Scope: $DNS_ZONE_SCOPE"

    # Check if custom role exists
    $customRole = az role definition list --name "DNS Record Operator - Zava POC" --query "[0].roleName" -o tsv 2>$null
    if ($customRole) {
        $ROLE_NAME = "DNS Record Operator - Zava POC"
        Write-Host "  Using custom role: $ROLE_NAME"
    } else {
        $ROLE_NAME = "DNS Zone Contributor"
        Write-Host "  Custom role not found. Using built-in: $ROLE_NAME" -ForegroundColor Yellow
    }

    $spResult = az ad sp create-for-rbac `
        --name $SP_NAME `
        --role $ROLE_NAME `
        --scopes $DNS_ZONE_SCOPE `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: Could not create service principal" -ForegroundColor Red
        Write-Host "  Error: $spResult"
        Write-Host "  Check: Do you have Owner or User Access Administrator on the subscription?"
        return
    }

    $sp = $spResult | ConvertFrom-Json
    Write-Host ""
    Write-Host "  ✅ PASS: Service principal created successfully" -ForegroundColor Green
    Write-Host ""

    # 1.3 Display credentials (user must save these)
    Write-Host "Step 3/4: Service Principal Credentials" -ForegroundColor Cyan
    Write-Host "  ┌──────────────────────────────────────────────────────┐"
    Write-Host "  │ SAVE THESE — they won't be shown again              │"
    Write-Host "  ├──────────────────────────────────────────────────────┤"
    Write-Host "  │ Client ID:     $($sp.appId)"
    Write-Host "  │ Client Secret: $($sp.password)"
    Write-Host "  │ Tenant ID:     $($sp.tenant)"
    Write-Host "  └──────────────────────────────────────────────────────┘"
    Write-Host ""

    # 1.4 Generate certbot credentials file
    Write-Host "Step 4/4: Generating certbot credentials template..."
    $certbotConfig = @"
# Azure DNS credentials for certbot-dns-azure plugin
# Generated by Zava DCV Automation — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# SECURITY: Store this file with restricted permissions (chmod 600)

dns_azure_sp_client_id = $($sp.appId)
dns_azure_sp_client_secret = $($sp.password)
dns_azure_tenant_id = $($sp.tenant)
dns_azure_environment = AzurePublicCloud

# Zone mapping: domain → Azure DNS zone resource ID
dns_azure_zone1 = ${DOMAIN}:/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/dnsZones/${DOMAIN}
"@

    $certbotConfig | Out-File -FilePath ".\azure-certbot.ini" -Encoding utf8
    Write-Host "  Saved: ./azure-certbot.ini" -ForegroundColor Green
    Write-Host "  ⚠️  DO NOT commit this file to git (contains secrets)" -ForegroundColor Yellow
    Write-Host ""

    # 1.5 Verify SP can authenticate
    Write-Host "--- GAP 1 VERIFICATION ---"
    Write-Host "  Testing SP authentication..."
    $testLogin = az login --service-principal `
        --username $sp.appId `
        --password $sp.password `
        --tenant $sp.tenant `
        --output none 2>&1

    if ($LASTEXITCODE -eq 0) {
        # Test DNS TXT record create as SP
        $testToken = "gap1-verify-$(Get-Random)"
        az network dns record-set txt add-record `
            -g $RG_NAME -z $DOMAIN `
            -n "_gap1-test" -v $testToken -o none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ PASS: SP can create DNS TXT records" -ForegroundColor Green
            # Cleanup
            az network dns record-set txt delete -g $RG_NAME -z $DOMAIN -n "_gap1-test" --yes -o none 2>$null
        } else {
            Write-Host "  ❌ FAIL: SP cannot create DNS records (check RBAC)" -ForegroundColor Red
        }

        # Re-login as original user
        Write-Host "  Re-authenticating as original user..."
        az login --output none 2>$null
    } else {
        Write-Host "  ❌ FAIL: SP authentication failed" -ForegroundColor Red
        Write-Host "  Error: $testLogin"
    }

    Write-Host ""
    Write-Host "═══ GAP 1 COMPLETE ═══" -ForegroundColor Green
    Write-Host ""
}


# ============================================================================
# GAP 3: KEY VAULT — Deploy Azure Key Vault for certificate storage
# ============================================================================
# Creates: Key Vault + RBAC for SP + access policies
# Dependencies: Gap 1 (SP must exist for RBAC assignment)
# ============================================================================

function Invoke-Gap3 {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host " GAP 3: KEY VAULT — Certificate Storage" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""

    # 3.1 Check if KV already exists
    Write-Host "Step 1/4: Checking for existing Key Vault..."
    $existingKV = az keyvault list -g $RG_NAME --query "[?starts_with(name, 'kv-dns-poc')].name" -o tsv 2>$null
    if ($existingKV) {
        Write-Host "  Key Vault already exists: $existingKV" -ForegroundColor Yellow
        $script:KV_NAME = $existingKV
    } else {
        # 3.2 Create Key Vault
        Write-Host "Step 2/4: Creating Key Vault '$KV_NAME'..."
        az keyvault create `
            --name $KV_NAME `
            --resource-group $RG_NAME `
            --location $LOCATION `
            --enable-rbac-authorization true `
            --sku standard `
            --tags project=dns-poc customer=Zava environment=poc `
            --output none

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: Could not create Key Vault" -ForegroundColor Red
            return
        }
        Write-Host "  ✅ Key Vault created: $KV_NAME" -ForegroundColor Green
    }

    # 3.3 Assign RBAC: current user as Key Vault Administrator
    Write-Host "Step 3/4: Assigning RBAC roles..."
    $currentUser = az ad signed-in-user show --query id -o tsv 2>$null
    if ($currentUser) {
        az role assignment create `
            --assignee $currentUser `
            --role "Key Vault Administrator" `
            --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" `
            --output none 2>$null
        Write-Host "  ✅ Current user: Key Vault Administrator" -ForegroundColor Green
    }

    # Assign SP as Key Vault Certificates Officer (if SP exists)
    $spAppId = az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv 2>$null
    if ($spAppId) {
        az role assignment create `
            --assignee $spAppId `
            --role "Key Vault Certificates Officer" `
            --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" `
            --output none 2>$null
        Write-Host "  ✅ SP '$SP_NAME': Key Vault Certificates Officer" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  SP not found — run Gap 1 first, then re-run Gap 3" -ForegroundColor Yellow
    }

    # 3.4 Verify Key Vault
    Write-Host "Step 4/4: Verifying Key Vault..."
    $kvStatus = az keyvault show --name $KV_NAME --query "properties.provisioningState" -o tsv 2>$null
    if ($kvStatus -eq "Succeeded") {
        Write-Host "  ✅ PASS: Key Vault '$KV_NAME' is ready (RBAC-enabled)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ FAIL: Key Vault status = $kvStatus" -ForegroundColor Red
    }

    # Test: store and retrieve a test secret
    Write-Host "  Testing secret store/retrieve..."
    az keyvault secret set --vault-name $KV_NAME --name "gap3-test" --value "test-$(Get-Date -Format 'yyyyMMdd')" --output none 2>$null
    $testValue = az keyvault secret show --vault-name $KV_NAME --name "gap3-test" --query "value" -o tsv 2>$null
    if ($testValue) {
        Write-Host "  ✅ PASS: Secret store/retrieve works" -ForegroundColor Green
        az keyvault secret delete --vault-name $KV_NAME --name "gap3-test" --output none 2>$null
    } else {
        Write-Host "  ❌ FAIL: Could not store/retrieve secret (RBAC propagation may need ~60s)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "═══ GAP 3 COMPLETE ═══" -ForegroundColor Green
    Write-Host ""
}


# ============================================================================
# GAP 4: RENEWAL AUTOMATION — Scaffold for automated cert renewal
# ============================================================================
# Creates: PowerShell runbook template for Azure Automation
# NOTE: This is a scaffold — full execution requires Gaps 2+5 (customer input)
# ============================================================================

function Invoke-Gap4 {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host " GAP 4: RENEWAL AUTOMATION — Scaffold" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""

    # 4.1 Generate the renewal runbook template
    Write-Host "Step 1/2: Generating cert renewal runbook template..."

    $runbookContent = @'
# ============================================================================
# Cert Renewal Runbook — Azure Automation / Scheduled Task
# ============================================================================
# This runbook automates: DCV challenge → cert issuance → Key Vault import
# Run as: Service Principal (sp-certbot-dns-poc)
# Schedule: Weekly or when cert expiry < 30 days
#
# CUSTOMER ACTION REQUIRED:
#   - Set $DIGICERT_API_KEY and $DIGICERT_ORG_ID below
#   - Or configure certbot with azure-certbot.ini
# ============================================================================

param(
    [string]$Domain = "poc.Zava.com",
    [string]$ResourceGroup = "rg-dns-poc",
    [string]$KeyVaultName = "<your-kv-name>",
    [string]$DigiCertApiKey = "<CUSTOMER-ACTION-REQUIRED>",
    [string]$DigiCertOrgId = "<CUSTOMER-ACTION-REQUIRED>",
    [int]$RenewalThresholdDays = 30
)

Write-Host "=== Cert Renewal Check — $(Get-Date) ==="

# Step 1: Check cert expiry in Key Vault
$certs = az keyvault certificate list --vault-name $KeyVaultName --query "[].{name:name, expires:attributes.expires}" -o json | ConvertFrom-Json
$needsRenewal = @()

foreach ($cert in $certs) {
    $expiry = [datetime]$cert.expires
    $daysLeft = ($expiry - (Get-Date)).Days
    Write-Host "  Cert: $($cert.name) | Expires: $expiry | Days left: $daysLeft"
    if ($daysLeft -lt $RenewalThresholdDays) {
        $needsRenewal += $cert
        Write-Host "    → NEEDS RENEWAL" -ForegroundColor Yellow
    }
}

if ($needsRenewal.Count -eq 0) {
    Write-Host "All certificates are valid. No renewal needed."
    exit 0
}

# Step 2: For each cert needing renewal, trigger DCV
foreach ($cert in $needsRenewal) {
    Write-Host "Renewing: $($cert.name)..."

    # ── OPTION A: DigiCert CertCentral API ──
    # CUSTOMER ACTION: Uncomment and configure when DigiCert API key is available
    <#
    $headers = @{ "X-DC-DEVKEY" = $DigiCertApiKey; "Content-Type" = "application/json" }
    $body = @{
        certificate = @{
            common_name = $Domain
            dns_names = @($Domain, "*.$Domain")
            csr = "<CSR-content>"
        }
        organization = @{ id = [int]$DigiCertOrgId }
        validity_years = 1
        dcv_method = "dns-txt-token"
    } | ConvertTo-Json -Depth 4

    $order = Invoke-RestMethod -Uri "https://www.digicert.com/services/v2/order/certificate/ssl_wildcard" `
        -Method Post -Headers $headers -Body $body
    Write-Host "  Order ID: $($order.id)"
    Write-Host "  DCV Token: $($order.dcv_token)"

    # Create DNS record
    az network dns record-set txt add-record -g $ResourceGroup -z $Domain -n "_dnsauth" -v $order.dcv_token -o none

    # Trigger DCV check
    Invoke-RestMethod -Uri "https://www.digicert.com/services/v2/order/certificate/$($order.id)/recheck-dcv" `
        -Method Put -Headers $headers

    # Wait and poll for cert
    Start-Sleep -Seconds 60
    $certData = Invoke-RestMethod -Uri "https://www.digicert.com/services/v2/order/certificate/$($order.id)/download/format/pem_all" `
        -Method Get -Headers $headers
    #>

    # ── OPTION B: certbot with ACME ──
    # CUSTOMER ACTION: Uncomment when certbot + azure-certbot.ini are configured
    <#
    certbot certonly `
        --authenticator dns-azure `
        --dns-azure-credentials ./azure-certbot.ini `
        --dns-azure-propagation-seconds 30 `
        --server https://acme.digicert.com/v2/acme/directory/ `
        -d $Domain `
        -d *.$Domain `
        --non-interactive --agree-tos
    #>

    Write-Host "  ⚠️ CUSTOMER ACTION REQUIRED: Configure DigiCert API key or certbot credentials"
    Write-Host "  This runbook is a scaffold — uncomment Option A or B above after customer provides credentials"
}

Write-Host "=== Renewal check complete ==="
'@

    $runbookContent | Out-File -FilePath ".\cert-renewal-runbook.ps1" -Encoding utf8
    Write-Host "  ✅ Saved: ./cert-renewal-runbook.ps1" -ForegroundColor Green

    # 4.2 Verify the runbook parses
    Write-Host "Step 2/2: Validating runbook syntax..."
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\cert-renewal-runbook.ps1", [ref]$null, [ref]$errors)
    if ($errors.Count -eq 0) {
        Write-Host "  ✅ PASS: Runbook syntax is valid (0 parse errors)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ FAIL: $($errors.Count) parse errors" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "    Line $($_.Extent.StartLineNumber): $($_.Message)" }
    }

    Write-Host ""
    Write-Host "  NOTE: This is a SCAFFOLD. To make it operational:" -ForegroundColor Yellow
    Write-Host "    1. Customer provides DigiCert API key (Option A) or configures certbot (Option B)"
    Write-Host "    2. Import runbook into Azure Automation Account"
    Write-Host "    3. Create a weekly schedule trigger"
    Write-Host "    4. Configure the SP credentials as Automation Run As account"
    Write-Host ""
    Write-Host "═══ GAP 4 COMPLETE ═══" -ForegroundColor Green
    Write-Host ""
}


# ============================================================================
# GAP 2+5: DIGICERT INTEGRATION (CUSTOMER-DEPENDENT)
# ============================================================================
# These gaps require customer-provided credentials.
# This function validates readiness and provides instructions.
# ============================================================================

function Invoke-Gap2And5 {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " GAP 2+5: DIGICERT INTEGRATION (Customer-Dependent)" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""

    $ready = $true

    # Check prerequisites
    Write-Host "Checking prerequisites..."

    # SP exists?
    $spAppId = az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv 2>$null
    if ($spAppId) {
        Write-Host "  ✅ Service Principal exists: $spAppId" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Service Principal not found — run Gap 1 first" -ForegroundColor Red
        $ready = $false
    }

    # Key Vault exists?
    $existingKV = az keyvault list -g $RG_NAME --query "[?starts_with(name, 'kv-dns-poc')].name" -o tsv 2>$null
    if ($existingKV) {
        Write-Host "  ✅ Key Vault exists: $existingKV" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Key Vault not found — run Gap 3 first" -ForegroundColor Red
        $ready = $false
    }

    # DigiCert API key provided?
    if ($DIGICERT_API_KEY -like "*CUSTOMER-ACTION*") {
        Write-Host "  ❌ DigiCert API key not set (placeholder detected)" -ForegroundColor Red
        $ready = $false
    } else {
        Write-Host "  ✅ DigiCert API key is set" -ForegroundColor Green
    }

    # DNS zone resolves?
    $ns = az network dns zone show -g $RG_NAME -n $DOMAIN --query "nameServers[0]" -o tsv 2>$null
    if ($ns) {
        Write-Host "  ✅ DNS zone exists: $DOMAIN (NS: $ns)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ DNS zone not found or not deployed" -ForegroundColor Red
        $ready = $false
    }

    Write-Host ""
    if (-not $ready) {
        Write-Host "═══ GAP 2+5 BLOCKED — Prerequisites not met ═══" -ForegroundColor Red
        Write-Host ""
        Write-Host "  CUSTOMER ACTION REQUIRED:" -ForegroundColor Yellow
        Write-Host "  1. Provide DigiCert CertCentral API key"
        Write-Host "  2. Provide DigiCert Organization ID"
        Write-Host "  3. Delegate NS records for $DOMAIN to Azure DNS"
        Write-Host "  4. Update `$DIGICERT_API_KEY and `$DIGICERT_ORG_ID in this script"
        Write-Host "  5. Re-run: .\Zava_DCV_Automation.ps1 -RunGap Gap2"
        Write-Host ""
    } else {
        Write-Host "  All prerequisites met. DigiCert integration can proceed." -ForegroundColor Green
        Write-Host "  TODO: Implement actual DigiCert API calls (order cert, trigger DCV, download cert)"
        Write-Host ""
    }

    Write-Host "═══ GAP 2+5 CHECK COMPLETE ═══" -ForegroundColor Yellow
    Write-Host ""
}


# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Zava DCV Automation — Closing 5 Identified Gaps        ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Gap 1: Service Identity (SP)          — Implementable  ║" -ForegroundColor Cyan
Write-Host "║  Gap 3: Key Vault (cert storage)       — Implementable  ║" -ForegroundColor Cyan
Write-Host "║  Gap 4: Renewal Automation (scaffold)  — Implementable  ║" -ForegroundColor Cyan
Write-Host "║  Gap 2: Cert Issuance (DigiCert API)   — Customer Dep   ║" -ForegroundColor Cyan
Write-Host "║  Gap 5: DigiCert Integration           — Customer Dep   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

switch ($RunGap) {
    "Gap1" { Invoke-Gap1 }
    "Gap3" { Invoke-Gap3 }
    "Gap4" { Invoke-Gap4 }
    "Gap2" { Invoke-Gap2And5 }
    "Gap5" { Invoke-Gap2And5 }
    "All"  {
        Invoke-Gap1
        Invoke-Gap3
        Invoke-Gap4
        if (-not $SkipCustomerDependentGaps) {
            Invoke-Gap2And5
        } else {
            Write-Host "Skipping customer-dependent gaps (Gap 2+5) as requested." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  DCV Automation Summary                                  ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Files created:                                          ║" -ForegroundColor Cyan
Write-Host "║    ./azure-certbot.ini    (SP credentials for certbot)   ║" -ForegroundColor Cyan
Write-Host "║    ./cert-renewal-runbook.ps1  (renewal automation)      ║" -ForegroundColor Cyan
Write-Host "║                                                          ║" -ForegroundColor Cyan
Write-Host "║  Next steps:                                             ║" -ForegroundColor Cyan
Write-Host "║    1. Customer provides DigiCert API key + Org ID        ║" -ForegroundColor Cyan
Write-Host "║    2. Uncomment Option A or B in cert-renewal-runbook    ║" -ForegroundColor Cyan
Write-Host "║    3. Import runbook into Azure Automation Account       ║" -ForegroundColor Cyan
Write-Host "║    4. Test with: .\Zava_DCV_Automation.ps1 -RunGap Gap2  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
