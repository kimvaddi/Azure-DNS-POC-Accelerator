# Zava DNS POC — Complete Deployment Guide

This guide walks through the full deployment process from start to finish, with explanations of what happens at each step.

---

## 📋 Overview: What Gets Deployed

**Total**: 35+ resources across DNS, networking, logging, traffic management, and web hosting.

- ✅ **Public DNS Zone** with CanNotDelete lock
- ✅ **Private DNS Zone** linked to VNet
- ✅ **Azure Key Vault** (RBAC-enabled) for certificate storage
- ✅ **Let's Encrypt Wildcard Certificate** (auto-issued, auto-renewed)
- ✅ **2 Multi-Region Web Apps** (US West 3, UK West Europe) with SNI/TLS bindings
- ✅ **3 Traffic Manager Profiles** (failover, geographic, weighted)
- ✅ **Event Hub** for IBM QRadar SIEM integration
- ✅ **Log Analytics** for Azure Monitor dashboards and diagnostics
- ✅ **Azure Monitor Workbook** for DNS zone monitoring
- ✅ **RBAC** with least-privilege custom roles

**Estimated Time**: ~15–20 minutes (Bicep) + 5 minutes (TLS automation)

---

## 🚀 Step 1: Preparation

### 1.1 Install Prerequisites

```powershell
# Install/upgrade Azure CLI
winget install Microsoft.AzureCLI
az upgrade

# Verify Bicep CLI (bundled with Azure CLI 2.20+)
az bicep version

# Verify PowerShell (7.x recommended)
pwsh --version

# Verify you have Posh-ACME installed (for TLS automation)
Import-Module Posh-ACME -ErrorAction Stop
```

### 1.2 Prepare Azure Subscription

```powershell
# Log in
az login --allow-no-subscriptions

# List available subscriptions
az account list --output table

# Set the correct subscription
az account set --subscription 'your-subscription-id'

# Verify logged-in account and subscription
az account show --output table
```

### 1.3 Check Permissions

You need the following roles:
- **Owner** or **Contributor** (to create resources)
- **User Access Administrator** (to assign RBAC roles)

```powershell
# Check your current permissions
$userId = (az ad signed-in-user show --query id -o tsv)
az role assignment list --assignee $userId --output table
```

### 1.4 Verify Domain Ownership

Ensure you have control over the public domain — you'll need to update NS records at your registrar.

Example: If deploying `zava-dnspoc-002.com`, verify you can modify DNS records with your registrar.

---

## 🛠️ Step 2: Configure Deployment Parameters

Edit `main.bicepparam` to customize your deployment:

```bicep
# Domain to use (required)
param domain = 'zava-dnspoc-002.com'

# Private internal domain (optional)
param privateDomain = 'poc-internal.zava.local'

# Azure regions (default: southcentralus, westus3, westeurope)
param location = 'southcentralus'
param locationPrimary = 'westus3'
param locationSecondary = 'westeurope'

# Web app SKU (default: B1 — Basic tier, ~$10/month)
param appServicePlanSku = 'B1'

# Whether to manage Traffic Manager DNS aliases at deploy time
param deployTrafficManagerDnsAliases = true

# Whether to lock the DNS zone (prevents accidental deletion)
param enableDnsZoneLock = true

# TLS: email for Let's Encrypt account
param letsEncryptContactEmail = 'dnsadmin@zava-dnspoc-002.com'
```

**Key Parameters**:
- `domain`: The public DNS zone name (e.g., `zava-dnspoc-002.com`)
- `location`: The region for core services (southcentralus recommended for Zava)
- `locationPrimary` / `locationSecondary`: US and UK web app regions
- `deployWebApps`: Set to `true` by default (deploy web apps)
- `deployTrafficManagerDnsAliases`: Set to `true` (bind TM profiles to DNS records)

---

## ✅ Step 3: Validate Template (Optional but Recommended)

```powershell
cd infrastructure/

# Validate template syntax and logic
az deployment sub validate `
  --location southcentralus `
  --template-file main.bicep `
  --parameters main.bicepparam

# View what-if preview (shows what will be created/modified)
az deployment sub what-if `
  --location southcentralus `
  --template-file main.bicep `
  --parameters main.bicepparam
```

Expected output: `"provisioningState": "Succeeded"`

---

## 🚀 Step 4: Deploy with Automated TLS

### Option A: Full Automated Deployment (Recommended)

```powershell
cd infrastructure/

# Deploy everything with automatic TLS setup
.\deploy.ps1
```

**What happens**:
1. Pre-flight checks (Azure CLI, domain, permissions)
2. Discovers or reuses existing public DNS zone
3. Validates Bicep template
4. Asks for confirmation
5. **Deploys all 35+ resources** (~12–15 minutes)
6. **Automatically runs TLS automation**:
   - Issues Let's Encrypt wildcard cert
   - Stores in Key Vault
   - Imports and binds SNI on both web apps
7. Outputs deployment summary and test URLs

### Option B: Staged Deployment (Infrastructure First)

```powershell
# Deploy infrastructure only, skip TLS (to debug/test)
.\deploy.ps1 -AdditionalParameters 'postDeployTlsMode=Skip'

# Later, run TLS setup manually
pwsh -ExecutionPolicy Bypass -File .\Invoke-LetsEncryptKeyVaultTls.ps1 `
  -SubscriptionId 'your-sub-id' `
  -ResourceGroup 'rg-dns-poc' `
  -DnsZoneName 'zava-dnspoc-002.com' `
  -KeyVaultName 'kvdnsg7vqz5xal6jqs' `
  -WebAppNames 'webapp-poc-us-xxx,webapp-poc-uk-xxx' `
  -CustomDomains 'webfailover.zava-dnspoc-002.com,webgeo.zava-dnspoc-002.com,webweighted.zava-dnspoc-002.com' `
  -ContactEmail 'dnsadmin@zava-dnspoc-002.com'
```

### Option C: Full Redeploy (Clean Slate)

```powershell
# Deletes existing RG, soft-deleted Key Vaults, and redeploys from scratch
.\deploy.ps1 -Redeploy

# This will:
# 1. Remove all resource locks in rg-dns-poc
# 2. Delete the resource group entirely
# 3. Purge or recover soft-deleted Key Vaults
# 4. Deploy fresh infrastructure
# 5. Run TLS automation
```

---

## 📦 Step 5: Capture Deployment Outputs

After deployment succeeds, save the outputs:

```powershell
# Get all outputs and save to JSON
az deployment sub show --name 'Zava-dns-poc-*' `
  --query properties.outputs `
  --output json | Out-File deployment-outputs.json

# View key outputs
az deployment sub show --name 'Zava-dns-poc-*' `
  --query properties.outputs `
  --output table
```

**Key Outputs to Note**:
- `publicDnsNameServers`: Azure DNS name servers (update registrar NS records)
- `publicDnsZoneName`: Your public DNS zone (e.g., `zava-dnspoc-002.com`)
- `eventHubSendConnectionString`: For QRadar configuration
- `trafficManagerFailoverFqdn`: Failover routing endpoint
- `tlsKeyVaultName`: Key Vault containing the LE certificate
- `webAppUSUrl` / `webAppUKUrl`: Direct web app URLs (not for HTTPS custom domains)

---

## 🔗 Step 6: Update DNS Registrar (If Using New Domain)

If you purchased a new domain via App Service Domain, you must update the registrar's NS records to point to Azure DNS.

**⚠️ IMPORTANT**: This only applies if `deployAppServiceDomain=true` in main.bicepparam.

### Update NS Records at Registrar

Get the Azure DNS name servers:

```powershell
# Option 1: From deployment outputs
az deployment sub show --name 'Zava-dns-poc-*' `
  --query 'properties.outputs.publicDnsNameServers.value' -o tsv

# Option 2: From the DNS zone directly
az network dns zone show --name zava-dnspoc-002.com --resource-group rg-dns-poc `
  --query nameServers -o tsv
```

You'll see something like:
```
ns1-01.azure-dns.com.
ns2-01.azure-dns.net.
ns3-01.azure-dns.org.
ns4-01.azure-dns.info.
```

**Log into your domain registrar** (GoDaddy, Namecheap, etc.) and:
1. Go to **DNS Settings** for `zava-dnspoc-002.com`
2. **Replace the NS records** with the 4 Azure nameservers above
3. **Save changes**
4. **Wait 5–30 minutes** for DNS propagation

### Verify DNS Propagation

```powershell
# Test name resolution via Azure DNS
nslookup zava-dnspoc-002.com ns1-01.azure-dns.com

# Test via public resolvers
nslookup webfailover.zava-dnspoc-002.com
nslookup webgeo.zava-dnspoc-002.com
nslookup webweighted.zava-dnspoc-002.com

# Or use dig for detailed output
dig @ns1-01.azure-dns.com zava-dnspoc-002.com +short
```

---

## 🔐 Step 7: Verify TLS Setup

### Check HTTPS Bindings

```powershell
# US Web App
az webapp config hostname list --resource-group rg-dns-poc --webapp-name webapp-poc-us-pyikahhqyplni `
  --query "[?sslState=='SniEnabled']" --output table

# UK Web App
az webapp config hostname list --resource-group rg-dns-poc --webapp-name webapp-poc-uk-pyikahhqyplni `
  --query "[?sslState=='SniEnabled']" --output table
```

Expected output:
```
Domain                              SslState    Thumbprint
----------------------------------  ----------  ----------------------------------------
webfailover.zava-dnspoc-002.com     SniEnabled  9453592F75488D1016412D1AA97CBE8149C51F98
webgeo.zava-dnspoc-002.com          SniEnabled  9453592F75488D1016412D1AA97CBE8149C51F98
webweighted.zava-dnspoc-002.com     SniEnabled  9453592F75488D1016412D1AA97CBE8149C51F98
```

### Check Certificate in Key Vault

```powershell
az keyvault certificate show --vault-name kvdnsg7vqz5xal6jqs --name le-wildcard-zava `
  --query "{name:id, expires:attributes.expires, thumbprint:x509ThumbprintHex}" -o json
```

Example output:
```json
{
  "name": "https://kvdnsg7vqz5xal6jqs.vault.azure.net/certificates/le-wildcard-zava/...",
  "expires": 1719705600,
  "thumbprint": "9453592F75488D1016412D1AA97CBE8149C51F98"
}
```

---

## 🧪 Step 8: Test Deployment

### Test HTTPS Connectivity

```powershell
# Test from PowerShell
Invoke-RestMethod -Uri https://webfailover.zava-dnspoc-002.com -Method Get

Invoke-RestMethod -Uri https://webgeo.zava-dnspoc-002.com -Method Get

Invoke-RestMethod -Uri https://webweighted.zava-dnspoc-002.com -Method Get

# Or use curl
curl -I https://webfailover.zava-dnspoc-002.com
curl -I https://webgeo.zava-dnspoc-002.com
curl -I https://webweighted.zava-dnspoc-002.com
```

Expected: HTTP 200 OK with valid SSL certificate

### Check Traffic Manager Health

```powershell
# Failover profiles
az network traffic-manager endpoint list --profile-name tm-poc-failover `
  --resource-group rg-dns-poc `
  --query "[].{name:name, status:endpointStatus, monitor:endpointMonitorStatus}" --output table

# Geographic profile
az network traffic-manager endpoint list --profile-name tm-poc-geo `
  --resource-group rg-dns-poc `
  --query "[].{name:name, status:endpointStatus, monitor:endpointMonitorStatus}" --output table

# Weighted profile
az network traffic-manager endpoint list --profile-name tm-poc-weighted `
  --resource-group rg-dns-poc `
  --query "[].{name:name, status:endpointStatus, monitor:endpointMonitorStatus}" --output table
```

Expected: All endpoints show `Online` status

### Verify Event Hub Connection

```powershell
# Check Event Hub metrics
az monitor metrics list `
  --resource /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-dns-poc/providers/Microsoft.EventHub/namespaces/ehns-dns-poc-pyikahhqyplni `
  --metric IncomingMessages --start-time 2026-03-31T00:00:00 --interval PT5M `
  --query "[0].timeseries[*].[timeStamp, data.average]" -o table
```

Expected: Metrics show incoming messages (Activity Log events being streamed)

### Test Log Analytics Queries

```kusto
// Query: DNS zone changes in last 24 hours
AzureActivity
| where TimeGenerated > ago(24h)
| where ResourceType == "Microsoft.Network/dnsZones"
| project TimeGenerated, OperationName, Caller, ActivityStatus

// Query: Web app HTTP requests
AppServiceHTTPLogs
| where TimeGenerated > ago(1h)
| summarize count() by CsHost, ScStatus, bin(TimeGenerated, 5m)
```

---

## 🔄 Step 9: Set Up Continuous Monitoring

### Create Log Analytics Alert (Optional)

```powershell
# Alert when DNS zone creation fails
az monitor metrics alert create `
  --name zava-dns-zone-alerts `
  --resource-group rg-dns-poc `
  --scopes /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-dns-poc/providers/Microsoft.Network/dnsZones/zava-dnspoc-002.com `
  --condition "avg QueryCount < 10 in the last 1h" `
  --severity 2
```

### Configure QRadar Integration

Use the deployment outputs to configure your QRadar instance:

```powershell
# Get Event Hub connection string
az deployment sub show --name 'Zava-dns-poc-*' `
  --query 'properties.outputs.eventHubListenConnectionString.value' -o tsv

# Get Event Hub name and consumer group
az eventhubs eventhub show --namespace-name ehns-dns-poc-pyikahhqyplni `
  --name dns-logs --resource-group rg-dns-poc --query "name"
```

In QRadar DSM connector configuration:
- **Connection String**: (from above)
- **Event Hub Name**: `dns-logs`
- **Consumer Group**: `qradar-consumer`
- **Partition Count**: 2

---

## 🧹 Step 10: Cleanup (When POC Ends)

### Option A: Soft Delete (Keep for Grace Period)

```powershell
# Delete resource group (keeps soft-deleted resources for 14 days)
az group delete --name rg-dns-poc --yes

# Key Vaults can be recovered for up to 14 days
az keyvault list-deleted --query "[?name=='kvdnsg7vqz5xal6jqs']"
```

### Option B: Hard Delete (Immediate Cleanup)

```powershell
# Purge Key Vault (only if purge protection is disabled)
az keyvault purge --name kvdnsg7vqz5xal6jqs --location southcentralus

# Delete resource group
az group delete --name rg-dns-poc --yes

# Delete subscription-level diagnostics
az monitor diagnostic-settings subscription delete --name activity-log-to-eventhub --yes
```

### Option C: Redeploy from Scratch

```powershell
# Next time you run deploy.ps1, use -Redeploy to cleanly restart
.\deploy.ps1 -Redeploy
```

---

## 🔧 Troubleshooting

### Deployment Fails with "Conflict" Error on App Service Domain

**Cause**: App Service Domain already exists and can't be recreated.

**Fix**:
```powershell
# Set deployAppServiceDomain to false in main.bicepparam
param deployAppServiceDomain = false

# Then redeploy
.\deploy.ps1
```

### TLS Certificate Won't Bind to Custom Domains

**Cause**: Key Vault RBAC role not assigned to App Service RP.

**Fix**:
```powershell
# Grant App Service RP Key Vault Secrets User role
$kvScope = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-dns-poc/providers/Microsoft.KeyVault/vaults/kvdnsg7vqz5xal6jqs"

az role assignment create `
  --scope $kvScope `
  --assignee-object-id fd4afe00-f7d0-4f8b-809f-8767c14805cd `
  --assignee-principal-type ServicePrincipal `
  --role "Key Vault Secrets User"

# Re-run TLS setup
.\Invoke-LetsEncryptKeyVaultTls.ps1 ...
```

### Soft-Deleted Key Vault Blocks Redeployment

**Cause**: KV with the same name exists in soft-delete state with purge protection enabled.

**Fix**:
```powershell
# Recover soft-deleted vault
az keyvault recover --name kvdnsg7vqz5xal6jqs

# Enable RBAC
az keyvault update --name kvdnsg7vqz5xal6jqs --enable-rbac-authorization true

# Then redeploy
.\deploy.ps1
```

---

## 📚 Next Steps

1. ✅ **Verify deployment** — Test HTTPS endpoints and DNS resolution
2. ✅ **Configure QRadar** — Connect Event Hub for SIEM integration
3. ✅ **Set up monitoring** — Create Log Analytics dashboards and alerts
4. ✅ **Run POC tests** — Execute DNS failover, geo-routing, and load-balancing scenarios
5. ✅ **Document findings** — Record competitive comparison with other DNS solutions

---

## 📞 Support & Documentation

- **README.md**: Architecture overview and resource descriptions
- **QUICK_REFERENCE.md**: Command cheat sheet
- **Zava_Azure_DNS_POC_Plan.md**: Full POC scope and timeline
- **Zava_DCV_Walkthrough_Guide.md**: Certificate management deep-dive
