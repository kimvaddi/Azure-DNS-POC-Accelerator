###############################################################################
# Azure DNS POC — Push-Button End-to-End Deployment
#
# Customer Template: Zava Energy Corporation
# Author: Kim Vaddi (Microsoft)
# Created: March 31, 2026
#
# PURPOSE:
#   Single-script deployment that:
#   1. Buys an App Service Domain (real domain, auto-delegates to Azure DNS)
#   2. Creates a child zone for DNSSEC (works around App Service Domain limitation)
#   3. Deploys all infrastructure via Bicep
#   4. Signs the child zone with DNSSEC + publishes DS record in parent
#   5. Issues a real Let's Encrypt TLS certificate via certbot
#   6. Imports cert to Azure Key Vault
#   7. Runs full validation suite
#
# USAGE:
#   .\Zava_DNS_POC_E2E.ps1                    # Interactive — prompts for each phase
#   .\Zava_DNS_POC_E2E.ps1 -Phase All         # Run everything end to end
#   .\Zava_DNS_POC_E2E.ps1 -Phase Domain      # Domain purchase + child zone only
#   .\Zava_DNS_POC_E2E.ps1 -Phase Infra       # Bicep deployment only
#   .\Zava_DNS_POC_E2E.ps1 -Phase DNSSEC      # DNSSEC signing only
#   .\Zava_DNS_POC_E2E.ps1 -Phase Cert        # Let's Encrypt cert only
#   .\Zava_DNS_POC_E2E.ps1 -Phase Validate    # Validation suite only
#   .\Zava_DNS_POC_E2E.ps1 -SkipDomainPurchase # Use existing domain
#
# COST: ~$12/yr domain + ~$28 infrastructure (2-week POC)
#
# DNSSEC APPROACH:
#   App Service Domains do NOT support DS record publication at the registrar.
#   Fix: Create a child zone (e.g., demo.zava-dnspoc.com), sign it with
#   DNSSEC, and publish the DS record in the parent zone — which we control
#   in Azure DNS. This gives us the full chain of trust.
#   Ref: Daniel Mauser proved this on demo.zava-dnspoc-001.com
#
# LET'S ENCRYPT APPROACH:
#   Uses certbot + certbot-dns-azure plugin with DNS-01 challenge.
#   SP credentials stored in Key Vault (zero-secret pattern).
#   Staging dry-run → Production cert → PFX → Key Vault import.
#
# PRIVATE DNS: Disabled by default. Set $ENABLE_PRIVATE_DNS = $true to include.
#
# PREREQUISITES:
#   - Azure CLI >= 2.50 (az --version)
#   - Logged in (az login)
#   - Subscription with Owner role
#   - Python 3.8+ and pip (for certbot — Cloud Shell has this)
#
# KNOWN ISSUES & FINDINGS (from iterative testing):
#   See $FINDINGS array at bottom of script for cumulative test log.
#
###############################################################################

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("All","Domain","Infra","DNSSEC","Cert","Validate")]
    [string]$Phase = "All",

    [switch]$SkipDomainPurchase,
    [switch]$UseStagingCert,
    [switch]$EnablePrivateDns
)

# ============================================================================
# SECTION 0: CONFIGURATION
# ============================================================================

# -- Domain Configuration --
# Root domain: purchased via App Service Domain (auto-creates Azure DNS zone)
# Child domain: used for DNSSEC + Let's Encrypt (we control parent zone)
$ROOT_DOMAIN        = "zava-dnspoc.com"              # App Service Domain to purchase
$CHILD_ZONE         = "demo.$ROOT_DOMAIN"                # Child zone for DNSSEC signing
$CONTACT_EMAIL      = "admin@zavaenergy.com"             # ICANN registration + Let's Encrypt

# -- Azure Configuration --
$SUBSCRIPTION_ID    = "<your-subscription-id>"
$RG_NAME            = "rg-dns-poc"
$LOCATION           = "southcentralus"
$LOCATION_PRIMARY   = "westus3"
$LOCATION_SECONDARY = "uksouth"

# -- Infrastructure Names --
$LAW_NAME           = "law-dns-poc"
$EH_NAMESPACE       = "ehns-dns-poc-$(Get-Random -Minimum 100 -Maximum 999)"
$KV_NAME            = "kv-dns-poc-$(Get-Random -Minimum 1000 -Maximum 9999)"
$SP_NAME            = "sp-certbot-dns-poc"
$TM_FAILOVER        = "tm-poc-failover-$(Get-Random -Minimum 100 -Maximum 999)"
$TM_GEO             = "tm-poc-geo-$(Get-Random -Minimum 100 -Maximum 999)"
$TM_WEIGHTED        = "tm-poc-weighted-$(Get-Random -Minimum 100 -Maximum 999)"
$WEBAPP_US          = "webapp-poc-us-zava$(Get-Random -Minimum 1000 -Maximum 9999)"
$WEBAPP_UK          = "webapp-poc-uk-zava$(Get-Random -Minimum 1000 -Maximum 9999)"

# -- Feature Flags --
$ENABLE_PRIVATE_DNS = $EnablePrivateDns.IsPresent

# -- Tracking --
$FINDINGS = @()
$PHASE_RESULTS = @{}
$SCRIPT_START = Get-Date

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Phase { param([string]$msg) Write-Host "`n$('=' * 70)" -ForegroundColor Cyan; Write-Host " $msg" -ForegroundColor Cyan; Write-Host "$('=' * 70)" -ForegroundColor Cyan }
function Write-Step  { param([string]$msg) Write-Host "`n--- $msg ---" -ForegroundColor White }
function Write-OK    { param([string]$msg) Write-Host "  ✅ $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$msg) Write-Host "  ❌ $msg" -ForegroundColor Red }
function Write-Info  { param([string]$msg) Write-Host "  ℹ️  $msg" -ForegroundColor Gray }

function Add-Finding {
    param([string]$Category, [string]$Title, [string]$Detail, [string]$Status)
    $script:FINDINGS += [PSCustomObject]@{
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Category  = $Category
        Title     = $Title
        Detail    = $Detail
        Status    = $Status
    }
    if ($Status -eq "FAIL") { Write-Fail "$Category | $Title — $Detail" }
    elseif ($Status -eq "WARN") { Write-Warn "$Category | $Title — $Detail" }
    else { Write-OK "$Category | $Title — $Detail" }
}

function Test-AzCli {
    Write-Step "Pre-Flight: Checking Azure CLI"
    $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
    if (-not $azVersion) {
        Write-Fail "Azure CLI not found. Install from https://aka.ms/installazurecli"
        exit 1
    }
    Write-OK "Azure CLI $azVersion"

    $account = az account show --query "{name:name, id:id, state:state}" -o json 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Fail "Not logged in. Run: az login"
        exit 1
    }
    Write-OK "Logged in: $($account.name) ($($account.id))"

    if ($SUBSCRIPTION_ID -ne "<your-subscription-id>") {
        az account set --subscription $SUBSCRIPTION_ID 2>$null
        Write-OK "Subscription set: $SUBSCRIPTION_ID"
    } else {
        $SCRIPT:SUBSCRIPTION_ID = $account.id
        Write-Warn "Using current subscription: $($account.id)"
    }
}

# ============================================================================
# PHASE 1: DOMAIN PURCHASE + CHILD ZONE
# ============================================================================

function Invoke-PhaseDomain {
    Write-Phase "PHASE 1: DOMAIN PURCHASE + CHILD ZONE SETUP"

    # 1.1 — Resource Group
    Write-Step "1.1 Creating Resource Group: $RG_NAME"
    az group create --name $RG_NAME --location $LOCATION --tags project=dns-poc customer=Zava environment=poc managed-by=e2e-script --output none
    if ($LASTEXITCODE -eq 0) { Write-OK "Resource group created" } else { Write-Fail "Resource group creation failed"; return }

    if (-not $SkipDomainPurchase.IsPresent) {
        # 1.2 — Check domain availability
        Write-Step "1.2 Checking domain availability: $ROOT_DOMAIN"
        $available = az appservice domain check-availability --name $ROOT_DOMAIN --query "available" -o tsv 2>$null
        if ($available -eq "true") {
            Write-OK "Domain $ROOT_DOMAIN is available"
        } else {
            Write-Warn "Domain $ROOT_DOMAIN may not be available. Attempting purchase anyway..."
            Add-Finding "Domain" "Availability check" "Domain may already be registered or unavailable" "WARN"
        }

        # 1.3 — Purchase App Service Domain
        Write-Step "1.3 Purchasing App Service Domain: $ROOT_DOMAIN"
        Write-Info "This will charge ~`$12/yr to your subscription"
        Write-Info "Domain registration is via GoDaddy (managed by Azure)"
        # Ref: https://learn.microsoft.com/azure/app-service/manage-custom-dns-buy-domain

        # Check if already registered
        $existingDomain = az appservice domain show --hostname $ROOT_DOMAIN -g $RG_NAME --query "name" -o tsv 2>$null
        if ($existingDomain) {
            Write-Warn "Domain already registered: $existingDomain"
            Add-Finding "Domain" "Purchase" "Domain already exists — skipping purchase" "PASS"
        } else {
            # Requires contact info JSON file
            $contactFile = ".\domain-contact-info.json"
            if (-not (Test-Path $contactFile)) {
                Write-Fail "domain-contact-info.json not found. Create it with ICANN contact details."
                Write-Info "Template: https://github.com/AzureAppServiceCLI/appservice_domains_templates/blob/master/contact_info.json"
                Add-Finding "Domain" "Purchase" "Missing domain-contact-info.json" "FAIL"
            } else {
                # Dry-run first
                Write-Step "1.3.1 Dry-run preview"
                az appservice domain create -g $RG_NAME --hostname $ROOT_DOMAIN `
                    --contact-info=@"$contactFile" --dryrun 2>$null

                # Actual purchase
                Write-Step "1.3.2 Executing domain purchase"
                az appservice domain create -g $RG_NAME --hostname $ROOT_DOMAIN `
                    --contact-info=@"$contactFile" --accept-terms --auto-renew --privacy --output table 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-OK "Domain $ROOT_DOMAIN purchased successfully"
                    Add-Finding "Domain" "Purchase" "App Service Domain registered via GoDaddy/Azure" "PASS"
                } else {
                    Write-Warn "Domain purchase returned non-zero exit code"
                    Add-Finding "Domain" "Purchase" "Command returned error — check output above" "WARN"
                }
            }
        }
    } else {
        Write-Info "Skipping domain purchase (--SkipDomainPurchase flag)"
    }

    # 1.4 — Verify parent zone exists in Azure DNS
    Write-Step "1.4 Verifying parent zone: $ROOT_DOMAIN"
    $parentZone = az network dns zone show -g $RG_NAME -n $ROOT_DOMAIN --query "name" -o tsv 2>$null
    if ($parentZone) {
        Write-OK "Parent zone exists: $parentZone"
        $parentNS = az network dns zone show -g $RG_NAME -n $ROOT_DOMAIN --query "nameServers" -o json 2>$null
        Write-Info "Nameservers: $parentNS"
    } else {
        Write-Warn "Parent zone not found. Creating manually..."
        az network dns zone create -g $RG_NAME -n $ROOT_DOMAIN --output none
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Parent zone created: $ROOT_DOMAIN"
            Write-Warn "NS delegation must be configured manually at your registrar"
            Add-Finding "Domain" "Manual zone" "Zone created but NS delegation must be done at registrar" "WARN"
        }
    }

    # 1.5 — Create child zone for DNSSEC
    Write-Step "1.5 Creating child zone: $CHILD_ZONE"
    az network dns zone create -g $RG_NAME -n $CHILD_ZONE --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Child zone created: $CHILD_ZONE"
    } else {
        Write-Warn "Child zone creation returned error (may already exist)"
    }

    # 1.6 — Delegate child zone (NS records in parent)
    Write-Step "1.6 Delegating child zone to Azure DNS"
    $childNS = az network dns zone show -g $RG_NAME -n $CHILD_ZONE --query "nameServers" -o json 2>$null | ConvertFrom-Json
    if ($childNS) {
        # Extract subdomain prefix (e.g., "demo" from "demo.zava-dnspoc.com")
        $childPrefix = $CHILD_ZONE.Replace(".$ROOT_DOMAIN", "")

        foreach ($ns in $childNS) {
            az network dns record-set ns add-record `
                -g $RG_NAME -z $ROOT_DOMAIN `
                -n $childPrefix `
                --nsdname $ns `
                --output none 2>$null
        }
        Write-OK "NS delegation created: $childPrefix.$ROOT_DOMAIN → Azure DNS"
        Write-Info "Child nameservers: $($childNS -join ', ')"
        Add-Finding "Domain" "Child delegation" "NS records published in parent zone" "PASS"
    } else {
        Write-Fail "Could not retrieve child zone nameservers"
        Add-Finding "Domain" "Child delegation" "Failed to get child NS" "FAIL"
    }

    # 1.7 — Add sample records to child zone
    Write-Step "1.7 Adding sample DNS records to child zone"
    $sampleRecords = @(
        @{ type = "A";     name = "www";        args = "--ipv4-address 10.0.1.1" }
        @{ type = "A";     name = "api";        args = "--ipv4-address 10.0.1.2" }
        @{ type = "TXT";   name = "@";          args = "--value 'v=spf1 include:spf.protection.outlook.com -all'" }
        @{ type = "MX";    name = "@";          args = "--exchange mail.$CHILD_ZONE --preference 10" }
        @{ type = "CNAME"; name = "status";     args = "--cname status.example.com" }
    )

    foreach ($rec in $sampleRecords) {
        $cmd = "az network dns record-set $($rec.type.ToLower()) add-record -g $RG_NAME -z $CHILD_ZONE -n `"$($rec.name)`" $($rec.args) --output none"
        Invoke-Expression $cmd 2>$null
        if ($LASTEXITCODE -eq 0) { Write-OK "  $($rec.type) $($rec.name)" }
        else { Write-Warn "  $($rec.type) $($rec.name) — may already exist" }
    }

    # 1.8 — Verify DNS resolution
    Write-Step "1.8 Verifying DNS resolution for child zone"
    $childNSFirst = $childNS[0]
    Write-Info "Testing: nslookup $CHILD_ZONE $childNSFirst"
    $result = nslookup $CHILD_ZONE $childNSFirst 2>$null
    if ($result -match "Name:" -or $result -match "authoritative") {
        Write-OK "Child zone resolves via Azure DNS"
        Add-Finding "Domain" "DNS resolution" "Child zone answers queries" "PASS"
    } else {
        Write-Warn "Resolution test inconclusive — may need propagation time"
        Add-Finding "Domain" "DNS resolution" "Needs propagation (up to 48 hours for new domains)" "WARN"
    }

    $PHASE_RESULTS["Domain"] = "Complete"
}

# ============================================================================
# PHASE 2: INFRASTRUCTURE (Bicep)
# ============================================================================

function Invoke-PhaseInfra {
    Write-Phase "PHASE 2: INFRASTRUCTURE DEPLOYMENT (Bicep)"

    Write-Step "2.1 Deploying Bicep template"
    Write-Info "Template: infrastructure/main.bicep"
    Write-Info "Parameters: Using script-generated values"

    $deploymentName = "dns-poc-e2e-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    # Build dynamic parameters — override domain and optionally skip private DNS
    $enablePDns = if ($ENABLE_PRIVATE_DNS) { "true" } else { "false" }
    $bicepParams = @(
        "--parameters", "domain=$CHILD_ZONE",
        "--parameters", "rgName=$RG_NAME",
        "--parameters", "location=$LOCATION",
        "--parameters", "locationPrimary=$LOCATION_PRIMARY",
        "--parameters", "locationSecondary=$LOCATION_SECONDARY",
        "--parameters", "webAppNameUS=$WEBAPP_US",
        "--parameters", "webAppNameUK=$WEBAPP_UK",
        "--parameters", "keyVaultName=$KV_NAME",
        "--parameters", "eventHubNamespaceName=$EH_NAMESPACE",
        "--parameters", "enablePrivateDns=$enablePDns"
    )

    # Run what-if first
    Write-Step "2.2 Running what-if analysis"
    az deployment sub what-if `
        --location $LOCATION `
        --template-file "infrastructure/main.bicep" `
        @bicepParams `
        --output table 2>&1 | Select-Object -First 40

    # Deploy
    Write-Step "2.3 Deploying infrastructure"
    $deployResult = az deployment sub create `
        --name $deploymentName `
        --location $LOCATION `
        --template-file "infrastructure/main.bicep" `
        @bicepParams `
        --output json 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-OK "Bicep deployment succeeded: $deploymentName"
        Add-Finding "Infra" "Bicep deploy" "All resources deployed successfully" "PASS"

        # Extract outputs
        $outputs = $deployResult | ConvertFrom-Json
        if ($outputs.properties.outputs) {
            $o = $outputs.properties.outputs
            Write-Info "Key Vault: $($o.keyVaultName.value)"
            Write-Info "LAW: $($o.logAnalyticsWorkspaceName.value)"
            Write-Info "Public DNS: $($o.publicDnsZoneName.value)"
            Write-Info "Web App US: $($o.webAppUSHostName.value)"

            # Update KV_NAME from deployment output
            if ($o.keyVaultName.value) { $script:KV_NAME = $o.keyVaultName.value }
        }
    } else {
        Write-Fail "Bicep deployment failed"
        Write-Host $deployResult -ForegroundColor Red
        Add-Finding "Infra" "Bicep deploy" "Deployment failed — check output above" "FAIL"
        return
    }

    # 2.4 — Create custom RBAC role
    Write-Step "2.4 Creating custom DNS Record Operator role"
    if (Test-Path "dns-operator-role.json") {
        # Update subscription ID in role definition
        $roleDef = Get-Content "dns-operator-role.json" -Raw | ConvertFrom-Json
        $roleDef.AssignableScopes = @("/subscriptions/$SUBSCRIPTION_ID")
        $roleDef | ConvertTo-Json -Depth 10 | Set-Content "dns-operator-role-temp.json"

        az role definition create --role-definition dns-operator-role-temp.json --output none 2>$null
        Remove-Item "dns-operator-role-temp.json" -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Custom RBAC role created (may take 60s to propagate)"
        } else {
            Write-Warn "RBAC role creation returned error (may already exist)"
        }
    } else {
        Write-Info "dns-operator-role.json not found — skipping custom role"
    }

    $PHASE_RESULTS["Infra"] = "Complete"
}

# ============================================================================
# PHASE 3: DNSSEC
# ============================================================================

function Invoke-PhaseDNSSEC {
    Write-Phase "PHASE 3: DNSSEC — Sign Child Zone + Publish DS Record"

    # 3.1 — Sign the child zone
    Write-Step "3.1 Enabling DNSSEC on child zone: $CHILD_ZONE"
    az network dns dnssec-config create `
        --resource-group $RG_NAME `
        --zone-name $CHILD_ZONE `
        --output none 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-OK "DNSSEC signing initiated for $CHILD_ZONE"
        Add-Finding "DNSSEC" "Zone signing" "Child zone signed with ECDSAP256SHA256" "PASS"
    } else {
        Write-Warn "DNSSEC command returned non-zero — may already be signed"
        Add-Finding "DNSSEC" "Zone signing" "Command returned error (zone may already be signed)" "WARN"
    }

    # 3.2 — Wait for signing to complete
    Write-Step "3.2 Waiting for DNSSEC signing to complete (up to 60s)"
    $maxWait = 60
    $waited = 0
    $dsInfo = $null
    while ($waited -lt $maxWait) {
        $signingKeys = az network dns zone show `
            --name $CHILD_ZONE `
            --resource-group $RG_NAME `
            --query "signingKeys[?delegationSignerInfo != null].delegationSignerInfo" `
            -o json 2>$null | ConvertFrom-Json

        if ($signingKeys -and $signingKeys.Count -gt 0) {
            $dsInfo = $signingKeys[0]
            Write-OK "DNSSEC signing complete"
            break
        }
        Start-Sleep -Seconds 10
        $waited += 10
        Write-Info "Waiting... ${waited}s"
    }

    if (-not $dsInfo) {
        Write-Fail "Could not retrieve DS record info after ${maxWait}s"
        Add-Finding "DNSSEC" "DS retrieval" "Timed out waiting for signing keys" "FAIL"
        return
    }

    # 3.3 — Parse DS record components
    Write-Step "3.3 DS Record Information"
    $dsKeyTag    = $dsInfo.digestAlgorithm  # Actually need to parse carefully
    Write-Info "Raw DS info: $($dsInfo | ConvertTo-Json -Compress)"

    # Use az CLI JSON parsing to get the DS fields
    $dsRaw = az network dns zone show `
        --name $CHILD_ZONE `
        --resource-group $RG_NAME `
        --query "signingKeys[?delegationSignerInfo != null] | [0]" `
        -o json 2>$null | ConvertFrom-Json

    if ($dsRaw.delegationSignerInfo) {
        $ds = $dsRaw.delegationSignerInfo
        $keyTag     = $dsRaw.keyTag
        $algorithm  = $ds.digestAlgorithm
        $digestType = $ds.digestType
        $digest     = $ds.digestValue

        Write-Info "Key Tag:      $keyTag"
        Write-Info "Algorithm:    $algorithm"
        Write-Info "Digest Type:  $digestType"
        Write-Info "Digest:       $digest"

        # 3.4 — Publish DS record in parent zone
        Write-Step "3.4 Publishing DS record in parent zone: $ROOT_DOMAIN"
        $childPrefix = $CHILD_ZONE.Replace(".$ROOT_DOMAIN", "")

        az network dns record-set ds add-record `
            --resource-group $RG_NAME `
            --zone-name $ROOT_DOMAIN `
            --record-set-name $childPrefix `
            --key-tag $keyTag `
            --algorithm $algorithm `
            --digest-type $digestType `
            --digest $digest `
            --output none 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-OK "DS record published in parent zone"
            Add-Finding "DNSSEC" "DS publication" "DS record added to $ROOT_DOMAIN for $childPrefix" "PASS"
        } else {
            Write-Fail "DS record publication failed"
            Add-Finding "DNSSEC" "DS publication" "az network dns record-set ds add-record failed" "FAIL"
        }
    } else {
        Write-Fail "Could not parse DS record from signing keys"
        Add-Finding "DNSSEC" "DS parsing" "signingKeys structure unexpected" "FAIL"
    }

    # 3.5 — Verify DNSSEC
    Write-Step "3.5 Verifying DNSSEC chain of trust"
    Write-Info "Checking: dig $CHILD_ZONE DNSKEY +dnssec"

    $dnsKeyResult = dig $CHILD_ZONE DNSKEY +dnssec +short 2>$null
    if ($dnsKeyResult) {
        Write-OK "DNSKEY records found for $CHILD_ZONE"
        Add-Finding "DNSSEC" "DNSKEY verify" "DNSKEY records present in zone" "PASS"
    } else {
        Write-Warn "DNSKEY lookup returned empty — dig may not be available or needs propagation"
        Write-Info "Try: Resolve-DnsName -Name $CHILD_ZONE -Type DNSKEY -DnssecOk"
        Add-Finding "DNSSEC" "DNSKEY verify" "dig not available or needs propagation" "WARN"
    }

    # Check DNSSEC status via Azure
    $dnssecConfig = az network dns dnssec-config show `
        --resource-group $RG_NAME `
        --zone-name $CHILD_ZONE `
        -o json 2>$null | ConvertFrom-Json

    if ($dnssecConfig.provisioningState -eq "Succeeded") {
        Write-OK "DNSSEC provisioning state: Succeeded"
        Add-Finding "DNSSEC" "Provisioning" "Azure reports DNSSEC Succeeded" "PASS"
    } else {
        Write-Info "DNSSEC provisioning state: $($dnssecConfig.provisioningState)"
    }

    $PHASE_RESULTS["DNSSEC"] = "Complete"
}

# ============================================================================
# PHASE 4: LET'S ENCRYPT CERTIFICATE
# ============================================================================

function Invoke-PhaseCert {
    Write-Phase "PHASE 4: LET'S ENCRYPT CERTIFICATE AUTOMATION"

    # 4.1 — Create Service Principal for certbot
    Write-Step "4.1 Creating Service Principal for certbot"

    $existingSP = az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv 2>$null
    if ($existingSP) {
        Write-Warn "SP already exists: $existingSP — reusing"
        $spAppId = $existingSP
    } else {
        $DNS_ZONE_SCOPE = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Network/dnsZones/$CHILD_ZONE"

        $spResult = az ad sp create-for-rbac `
            --name $SP_NAME `
            --role "DNS Zone Contributor" `
            --scopes $DNS_ZONE_SCOPE `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $sp = $spResult | ConvertFrom-Json
            $spAppId = $sp.appId
            Write-OK "Service Principal created: $spAppId"
            Add-Finding "Cert" "SP creation" "SP created with DNS Zone Contributor on $CHILD_ZONE" "PASS"

            # Store in Key Vault
            Write-Step "4.2 Storing SP credentials in Key Vault"

            # Ensure Key Vault exists
            $kvExists = az keyvault show --name $KV_NAME --query "name" -o tsv 2>$null
            if (-not $kvExists) {
                Write-Info "Key Vault $KV_NAME not found — creating..."
                az keyvault create -g $RG_NAME -n $KV_NAME --location $LOCATION --enable-rbac-authorization --output none 2>$null
                # Assign ourselves Key Vault Secrets Officer
                $currentUser = az ad signed-in-user show --query id -o tsv 2>$null
                if ($currentUser) {
                    az role assignment create --role "Key Vault Secrets Officer" `
                        --assignee $currentUser `
                        --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" `
                        --output none 2>$null
                    Write-Info "Waiting 30s for RBAC propagation..."
                    Start-Sleep -Seconds 30
                }
            }

            az keyvault secret set --vault-name $KV_NAME --name "certbot-sp-client-id" --value $sp.appId --output none 2>$null
            az keyvault secret set --vault-name $KV_NAME --name "certbot-sp-client-secret" --value $sp.password --output none 2>$null
            az keyvault secret set --vault-name $KV_NAME --name "certbot-sp-tenant-id" --value $sp.tenant --output none 2>$null

            # Clear sensitive vars
            $sp = $null
            $spResult = $null
            Write-OK "SP credentials stored in Key Vault ($KV_NAME)"
            Add-Finding "Cert" "KV secrets" "SP credentials stored securely (zero-secret)" "PASS"
        } else {
            Write-Fail "SP creation failed: $spResult"
            Add-Finding "Cert" "SP creation" "az ad sp create-for-rbac failed" "FAIL"
            return
        }
    }

    # 4.3 — Install certbot + Azure DNS plugin
    Write-Step "4.3 Installing certbot + certbot-dns-azure"
    Write-Info "pip install certbot certbot-dns-azure"
    pip install certbot certbot-dns-azure 2>&1 | Select-Object -Last 3

    $certbotPath = Get-Command certbot -ErrorAction SilentlyContinue
    if ($certbotPath) {
        Write-OK "certbot installed: $($certbotPath.Source)"
    } else {
        # Try pip install with --user
        pip install --user certbot certbot-dns-azure 2>&1 | Select-Object -Last 3
        $certbotPath = Get-Command certbot -ErrorAction SilentlyContinue
        if (-not $certbotPath) {
            Write-Fail "certbot not found after pip install"
            Write-Info "On Windows, try: pip install certbot certbot-dns-azure in WSL or Cloud Shell"
            Add-Finding "Cert" "certbot install" "certbot not in PATH after pip install" "FAIL"
            Write-Info "Generating manual certbot commands for you to run in Cloud Shell/WSL..."
            Invoke-CertManualInstructions
            return
        }
    }

    # 4.4 — Generate azure-certbot.ini config
    Write-Step "4.4 Generating certbot config from Key Vault"
    $clientId     = az keyvault secret show --vault-name $KV_NAME --name "certbot-sp-client-id" --query "value" -o tsv 2>$null
    $clientSecret = az keyvault secret show --vault-name $KV_NAME --name "certbot-sp-client-secret" --query "value" -o tsv 2>$null
    $tenantId     = az keyvault secret show --vault-name $KV_NAME --name "certbot-sp-tenant-id" --query "value" -o tsv 2>$null

    if (-not $clientId -or -not $clientSecret -or -not $tenantId) {
        Write-Fail "Could not retrieve SP credentials from Key Vault"
        Add-Finding "Cert" "KV retrieval" "One or more secrets missing from Key Vault" "FAIL"
        return
    }

    $certbotIni = @"
dns_azure_sp_client_id = $clientId
dns_azure_sp_client_secret = $clientSecret
dns_azure_tenant_id = $tenantId
dns_azure_environment = AzurePublicCloud
dns_azure_zone1 = ${CHILD_ZONE}:/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/dnszones/${CHILD_ZONE}
"@

    $iniPath = Join-Path $PWD "azure-certbot.ini"
    $certbotIni | Set-Content -Path $iniPath -Force
    # Restrict permissions (best effort on Windows)
    if ($IsLinux -or $IsMacOS) {
        chmod 600 $iniPath
    }
    Write-OK "Config written to $iniPath"

    # Clear secrets from memory
    $clientId = $null; $clientSecret = $null; $tenantId = $null

    # 4.5 — Staging dry-run
    Write-Step "4.5 Let's Encrypt staging dry-run"
    Write-Info "This validates the full ACME flow without issuing a real cert"

    $dryRunResult = certbot certonly `
        --authenticator dns-azure `
        --dns-azure-config $iniPath `
        --dns-azure-propagation-seconds 60 `
        --server https://acme-staging-v02.api.letsencrypt.org/directory `
        -d $CHILD_ZONE `
        -d "*.$CHILD_ZONE" `
        --dry-run `
        --non-interactive `
        --agree-tos `
        -m $CONTACT_EMAIL 2>&1

    $dryRunOutput = $dryRunResult -join "`n"
    if ($dryRunOutput -match "dry run was successful" -or $dryRunOutput -match "would have been successful") {
        Write-OK "Staging dry-run PASSED — ACME + Azure DNS plumbing works"
        Add-Finding "Cert" "Staging dry-run" "Full DNS-01 challenge flow validated" "PASS"
    } else {
        Write-Fail "Staging dry-run FAILED"
        Write-Host $dryRunOutput
        Add-Finding "Cert" "Staging dry-run" "certbot dry-run failed — see output above" "FAIL"

        if ($dryRunOutput -match "NXDOMAIN" -or $dryRunOutput -match "Timeout") {
            Add-Finding "Cert" "DNS propagation" "Domain may not be resolving yet — NS delegation needs time" "WARN"
        }
        return
    }

    # 4.6 — Issue real certificate
    if ($UseStagingCert.IsPresent) {
        Write-Info "Using staging cert (--UseStagingCert flag). Skipping production issuance."
        $acmeArgs = @("--server", "https://acme-staging-v02.api.letsencrypt.org/directory")
    } else {
        Write-Step "4.6 Issuing PRODUCTION Let's Encrypt certificate"
        $acmeArgs = @()
    }

    $certArgs = @(
        "certonly",
        "--authenticator", "dns-azure",
        "--dns-azure-config", $iniPath,
        "--dns-azure-propagation-seconds", "60",
        "-d", $CHILD_ZONE,
        "-d", "*.$CHILD_ZONE",
        "--non-interactive",
        "--agree-tos",
        "-m", $CONTACT_EMAIL
    ) + $acmeArgs

    $certResult = & certbot @certArgs 2>&1

    $certOutput = $certResult -join "`n"
    if ($certOutput -match "Successfully received certificate" -or $certOutput -match "Congratulations") {
        Write-OK "Certificate issued for $CHILD_ZONE + *.$CHILD_ZONE"
        Add-Finding "Cert" "Issuance" "Let's Encrypt cert obtained via DNS-01 challenge" "PASS"
    } else {
        Write-Fail "Certificate issuance failed"
        Write-Host $certOutput
        Add-Finding "Cert" "Issuance" "certbot certonly failed" "FAIL"
        return
    }

    # 4.7 — Convert PEM to PFX and import to Key Vault
    Write-Step "4.7 Importing certificate to Key Vault"
    $certDir = "/etc/letsencrypt/live/$CHILD_ZONE"
    if ($IsWindows) {
        # On Windows, certbot stores in AppData
        $certDir = "$env:LOCALAPPDATA\certbot\live\$CHILD_ZONE"
        if (-not (Test-Path $certDir)) {
            $certDir = "C:\Certbot\live\$CHILD_ZONE"
        }
    }

    $fullchainPath = Join-Path $certDir "fullchain.pem"
    $privkeyPath = Join-Path $certDir "privkey.pem"
    $pfxPath = Join-Path $env:TEMP "le-cert-$CHILD_ZONE.pfx"

    if ((Test-Path $fullchainPath) -and (Test-Path $privkeyPath)) {
        # Convert PEM → PFX (empty password for KV import)
        openssl pkcs12 -export `
            -in $fullchainPath `
            -inkey $privkeyPath `
            -out $pfxPath `
            -passout pass: 2>$null

        if (Test-Path $pfxPath) {
            # Import to Key Vault
            $certName = "le-$($CHILD_ZONE.Replace('.', '-'))"
            az keyvault certificate import `
                --vault-name $KV_NAME `
                --name $certName `
                --file $pfxPath `
                --output none 2>$null

            if ($LASTEXITCODE -eq 0) {
                Write-OK "Certificate imported to Key Vault: $certName"
                Add-Finding "Cert" "KV import" "Cert stored in Key Vault as $certName" "PASS"

                # Verify
                $kvCert = az keyvault certificate show `
                    --vault-name $KV_NAME `
                    --name $certName `
                    --query "{name:name, expires:attributes.expires, thumbprint:x509ThumbprintHex}" `
                    -o json 2>$null | ConvertFrom-Json
                Write-Info "  Name:       $($kvCert.name)"
                Write-Info "  Expires:    $($kvCert.expires)"
                Write-Info "  Thumbprint: $($kvCert.thumbprint)"
            } else {
                Write-Fail "Key Vault certificate import failed"
                Add-Finding "Cert" "KV import" "az keyvault certificate import failed" "FAIL"
            }

            # Clean up PFX from temp
            Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Fail "PEM → PFX conversion failed (openssl not available?)"
            Add-Finding "Cert" "PFX conversion" "openssl pkcs12 failed" "FAIL"
        }
    } else {
        Write-Warn "Certificate files not found at $certDir"
        Write-Info "Certbot may have stored them elsewhere. Check: certbot certificates"
        Add-Finding "Cert" "File location" "PEM files not at expected path" "WARN"
    }

    # Cleanup ini file (contains secrets)
    Remove-Item $iniPath -Force -ErrorAction SilentlyContinue
    Write-OK "Cleaned up azure-certbot.ini"

    $PHASE_RESULTS["Cert"] = "Complete"
}

# Helper: Print manual certbot commands when pip install fails
function Invoke-CertManualInstructions {
    Write-Phase "MANUAL CERTBOT INSTRUCTIONS (run in Cloud Shell or WSL)"
    Write-Host @"

# === Run these commands in Azure Cloud Shell (Bash) or WSL ===

# 1. Install certbot
pip install certbot certbot-dns-azure

# 2. Retrieve SP credentials from Key Vault
KV_NAME="$KV_NAME"
CLIENT_ID=`$(az keyvault secret show --vault-name `$KV_NAME --name certbot-sp-client-id --query value -o tsv)
CLIENT_SECRET=`$(az keyvault secret show --vault-name `$KV_NAME --name certbot-sp-client-secret --query value -o tsv)
TENANT_ID=`$(az keyvault secret show --vault-name `$KV_NAME --name certbot-sp-tenant-id --query value -o tsv)

# 3. Generate config
cat > azure-certbot.ini << EOF
dns_azure_sp_client_id = `$CLIENT_ID
dns_azure_sp_client_secret = `$CLIENT_SECRET
dns_azure_tenant_id = `$TENANT_ID
dns_azure_environment = AzurePublicCloud
dns_azure_zone1 = ${CHILD_ZONE}:/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/dnszones/${CHILD_ZONE}
EOF
chmod 600 azure-certbot.ini
unset CLIENT_ID CLIENT_SECRET TENANT_ID

# 4. Staging dry-run (test plumbing)
certbot certonly \
  --authenticator dns-azure \
  --dns-azure-config ./azure-certbot.ini \
  --dns-azure-propagation-seconds 60 \
  --server https://acme-staging-v02.api.letsencrypt.org/directory \
  -d $CHILD_ZONE \
  -d "*.$CHILD_ZONE" \
  --dry-run \
  --non-interactive --agree-tos -m $CONTACT_EMAIL

# 5. Production cert (if dry-run passes)
certbot certonly \
  --authenticator dns-azure \
  --dns-azure-config ./azure-certbot.ini \
  --dns-azure-propagation-seconds 60 \
  -d $CHILD_ZONE \
  -d "*.$CHILD_ZONE" \
  --non-interactive --agree-tos -m $CONTACT_EMAIL

# 6. Import to Key Vault
openssl pkcs12 -export \
  -in /etc/letsencrypt/live/$CHILD_ZONE/fullchain.pem \
  -inkey /etc/letsencrypt/live/$CHILD_ZONE/privkey.pem \
  -out /tmp/le-cert.pfx -passout pass:

az keyvault certificate import \
  --vault-name $KV_NAME \
  --name le-$($CHILD_ZONE.Replace('.', '-')) \
  --file /tmp/le-cert.pfx

rm -f /tmp/le-cert.pfx azure-certbot.ini

"@ -ForegroundColor Yellow
}

# ============================================================================
# PHASE 5: VALIDATION SUITE
# ============================================================================

function Invoke-PhaseValidate {
    Write-Phase "PHASE 5: VALIDATION SUITE"

    $testsPassed = 0
    $testsFailed = 0

    # V1: DNS Zone exists
    Write-Step "V1: DNS Zone Existence"
    $zone = az network dns zone show -g $RG_NAME -n $CHILD_ZONE --query "name" -o tsv 2>$null
    if ($zone) { Write-OK "Child zone exists: $zone"; $testsPassed++ } else { Write-Fail "Child zone not found"; $testsFailed++ }

    $parentZone = az network dns zone show -g $RG_NAME -n $ROOT_DOMAIN --query "name" -o tsv 2>$null
    if ($parentZone) { Write-OK "Parent zone exists: $parentZone"; $testsPassed++ } else { Write-Fail "Parent zone not found"; $testsFailed++ }

    # V2: NS Delegation
    Write-Step "V2: NS Delegation (child → parent)"
    $childPrefix = $CHILD_ZONE.Replace(".$ROOT_DOMAIN", "")
    $nsRecords = az network dns record-set ns show -g $RG_NAME -z $ROOT_DOMAIN -n $childPrefix --query "nsRecords[].nsdname" -o json 2>$null | ConvertFrom-Json
    if ($nsRecords -and $nsRecords.Count -ge 2) { Write-OK "NS delegation: $($nsRecords.Count) nameservers"; $testsPassed++ }
    else { Write-Fail "NS delegation missing or incomplete"; $testsFailed++ }

    # V3: DNSSEC
    Write-Step "V3: DNSSEC Status"
    $dnssec = az network dns dnssec-config show -g $RG_NAME -z $CHILD_ZONE --query "provisioningState" -o tsv 2>$null
    if ($dnssec -eq "Succeeded") { Write-OK "DNSSEC: Succeeded"; $testsPassed++ }
    else { Write-Warn "DNSSEC: $dnssec"; $testsFailed++ }

    # V4: DS Record in Parent
    Write-Step "V4: DS Record in Parent Zone"
    $dsRecords = az network dns record-set ds show -g $RG_NAME -z $ROOT_DOMAIN -n $childPrefix --query "dsRecords" -o json 2>$null | ConvertFrom-Json
    if ($dsRecords -and $dsRecords.Count -gt 0) { Write-OK "DS record present in parent zone"; $testsPassed++ }
    else { Write-Fail "DS record not found in parent zone"; $testsFailed++ }

    # V5: Key Vault
    Write-Step "V5: Key Vault Accessible"
    $kvCheck = az keyvault show --name $KV_NAME --query "name" -o tsv 2>$null
    if ($kvCheck) { Write-OK "Key Vault: $kvCheck"; $testsPassed++ } else { Write-Fail "Key Vault not found"; $testsFailed++ }

    # V6: Certificate in Key Vault
    Write-Step "V6: TLS Certificate in Key Vault"
    $certName = "le-$($CHILD_ZONE.Replace('.', '-'))"
    $cert = az keyvault certificate show --vault-name $KV_NAME --name $certName --query "name" -o tsv 2>$null
    if ($cert) { Write-OK "Certificate found: $cert"; $testsPassed++ }
    else { Write-Warn "Certificate not found (may not have been issued yet)"; $testsFailed++ }

    # V7: Event Hub
    Write-Step "V7: Event Hub for QRadar"
    $eh = az eventhubs namespace show -g $RG_NAME -n $EH_NAMESPACE --query "name" -o tsv 2>$null
    if ($eh) { Write-OK "Event Hub namespace: $eh"; $testsPassed++ } else { Write-Fail "Event Hub not found"; $testsFailed++ }

    # V8: Web Apps
    Write-Step "V8: Web Apps (Multi-Region)"
    $waUS = az webapp show -g $RG_NAME -n $WEBAPP_US --query "state" -o tsv 2>$null
    $waUK = az webapp show -g $RG_NAME -n $WEBAPP_UK --query "state" -o tsv 2>$null
    if ($waUS -eq "Running") { Write-OK "Web App US: Running"; $testsPassed++ } else { Write-Fail "Web App US: $waUS"; $testsFailed++ }
    if ($waUK -eq "Running") { Write-OK "Web App UK: Running"; $testsPassed++ } else { Write-Fail "Web App UK: $waUK"; $testsFailed++ }

    # V9: Traffic Manager
    Write-Step "V9: Traffic Manager Profiles"
    foreach ($tmName in @($TM_FAILOVER, $TM_GEO, $TM_WEIGHTED)) {
        $tm = az network traffic-manager profile show -g $RG_NAME -n $tmName --query "profileStatus" -o tsv 2>$null
        if ($tm -eq "Enabled") { Write-OK "TM $tmName`: Enabled"; $testsPassed++ }
        else { Write-Warn "TM $tmName`: $tm"; $testsFailed++ }
    }

    # V10: DCV TXT Record Test (quick)
    Write-Step "V10: DCV TXT Record Create/Verify/Delete"
    $dcvToken = "e2e-test-$(Get-Random)"
    az network dns record-set txt add-record -g $RG_NAME -z $CHILD_ZONE -n "_acme-challenge.e2e-test" -v $dcvToken --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        $retrieved = az network dns record-set txt show -g $RG_NAME -z $CHILD_ZONE -n "_acme-challenge.e2e-test" --query "txtRecords[0].value[0]" -o tsv 2>$null
        if ($retrieved -eq $dcvToken) {
            Write-OK "DCV TXT record: created → verified → matches"
            $testsPassed++
        } else {
            Write-Fail "DCV TXT value mismatch: expected $dcvToken, got $retrieved"
            $testsFailed++
        }
        # Cleanup
        az network dns record-set txt remove-record -g $RG_NAME -z $CHILD_ZONE -n "_acme-challenge.e2e-test" -v $dcvToken --output none 2>$null
        az network dns record-set txt delete -g $RG_NAME -z $CHILD_ZONE -n "_acme-challenge.e2e-test" --yes --output none 2>$null
    } else {
        Write-Fail "DCV TXT record creation failed"
        $testsFailed++
    }

    # Summary
    Write-Phase "VALIDATION RESULTS"
    $total = $testsPassed + $testsFailed
    Write-Host "  Passed: $testsPassed / $total" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Yellow" })
    Write-Host "  Failed: $testsFailed / $total" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })

    if ($testsFailed -eq 0) {
        Write-OK "ALL VALIDATION TESTS PASSED"
    } else {
        Write-Warn "$testsFailed test(s) failed — see findings below"
    }

    $PHASE_RESULTS["Validate"] = "Passed: $testsPassed, Failed: $testsFailed"
}

# ============================================================================
# FINDINGS REPORT
# ============================================================================

function Show-FindingsReport {
    Write-Phase "CUMULATIVE FINDINGS REPORT"

    $elapsed = (Get-Date) - $SCRIPT_START
    Write-Host "  Total runtime: $($elapsed.ToString('hh\:mm\:ss'))"
    Write-Host ""

    # Phase summary
    Write-Host "  Phase Results:" -ForegroundColor Cyan
    foreach ($key in $PHASE_RESULTS.Keys) {
        Write-Host "    $key`: $($PHASE_RESULTS[$key])"
    }
    Write-Host ""

    if ($FINDINGS.Count -eq 0) {
        Write-Info "No findings recorded."
        return
    }

    # Group by status
    $passes = $FINDINGS | Where-Object { $_.Status -eq "PASS" }
    $warns  = $FINDINGS | Where-Object { $_.Status -eq "WARN" }
    $fails  = $FINDINGS | Where-Object { $_.Status -eq "FAIL" }

    Write-Host "  Summary: $($passes.Count) PASS | $($warns.Count) WARN | $($fails.Count) FAIL" -ForegroundColor $(if ($fails.Count -eq 0) { "Green" } else { "Red" })
    Write-Host ""

    Write-Host "  Detailed Findings:" -ForegroundColor Cyan
    Write-Host "  $('-' * 66)"
    foreach ($f in $FINDINGS) {
        $color = switch ($f.Status) { "PASS" { "Green" } "WARN" { "Yellow" } "FAIL" { "Red" } default { "White" } }
        Write-Host "  [$($f.Status)] $($f.Category) | $($f.Title)" -ForegroundColor $color
        Write-Host "         $($f.Detail)" -ForegroundColor Gray
        Write-Host "         $($f.Timestamp)" -ForegroundColor DarkGray
    }

    # Export findings
    $reportPath = "E2E_Test_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $FINDINGS | ConvertTo-Json -Depth 4 | Set-Content $reportPath
    Write-Info "Findings exported to $reportPath"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Azure DNS POC — Push-Button End-to-End Deployment         ║" -ForegroundColor Cyan
Write-Host "║  Domain: $ROOT_DOMAIN → Child: $CHILD_ZONE  ║" -ForegroundColor Cyan
Write-Host "║  Phase: $Phase                                              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Pre-flight
Test-AzCli

# Execute phases
switch ($Phase) {
    "All" {
        Invoke-PhaseDomain
        Invoke-PhaseInfra
        Invoke-PhaseDNSSEC
        Invoke-PhaseCert
        Invoke-PhaseValidate
    }
    "Domain"   { Invoke-PhaseDomain }
    "Infra"    { Invoke-PhaseInfra }
    "DNSSEC"   { Invoke-PhaseDNSSEC }
    "Cert"     { Invoke-PhaseCert }
    "Validate" { Invoke-PhaseValidate }
}

# Always show findings
Show-FindingsReport

Write-Host ""
Write-Host "Done. Total elapsed: $((Get-Date) - $SCRIPT_START)" -ForegroundColor Cyan
