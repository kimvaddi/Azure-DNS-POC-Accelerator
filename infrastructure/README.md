# Zava DNS POC — Bicep Infrastructure Deployment

Complete Infrastructure-as-Code deployment for Azure DNS POC evaluation, including DNS zones, Event Hub integration for IBM QRadar, multi-region Traffic Manager profiles, and comprehensive diagnostics.

## 📋 What Gets Deployed

### Core DNS Infrastructure
- **Public DNS Zone**: `poc.Zava.com` (with CanNotDelete lock)
- **Private DNS Zone**: `poc-internal.Zava.local` (VNet-linked)
- Private DNS A records: `db.poc-internal.Zava.local`, `app`, `cache`

### Logging & Integration
- **Log Analytics Workspace**: 30-day retention, PerGB2018 pricing
- **Event Hub Namespace**: Standard SKU (required for consumer groups)
- **Event Hub**: `dns-logs` (2 partitions, 1-day retention)
- **Authorization Rules**: `SendPolicy` (Send), `QRadarListenPolicy` (Listen)
- **Consumer Group**: `qradar-consumer` for IBM QRadar
- **Storage Account**: QRadar checkpoint tracking

### Traffic Manager Profiles
- **Priority/Failover**: `tm-poc-failover.trafficmanager.net` (US Primary → UK Secondary)
- **Geographic**: `tm-poc-geo.trafficmanager.net` (US/CA/MX → US, GB/WORLD → UK)
- **Weighted**: `tm-poc-weighted.trafficmanager.net` (70% US, 30% UK)

### Multi-Region Web Apps
- **US Region** (`westus3`): App Service Plan B1 + Web App
- **UK Region** (`eastasia`): App Service Plan B1 + Web App
- Security hardening: `httpsOnly=true`, `ftpsState=Disabled`, `minTlsVersion=1.2`

### DNS Records (TTL=30)
- `webfailover.poc.zava.com` → `tm-poc-failover` Traffic Manager FQDN
- `webgeo.poc.zava.com` → `tm-poc-geo` Traffic Manager FQDN
- `webweighted.poc.zava.com` → `tm-poc-weighted` Traffic Manager FQDN

### Diagnostic Settings
- **Subscription Activity Log**: All 8 categories → Event Hub + Log Analytics
- **Web Apps**: 7 log categories + AllMetrics → Log Analytics
- **Traffic Manager**: ProbeHealthStatusEvents + AllMetrics → Log Analytics

### Azure Monitor Workbook
- **Public DNS Monitoring Workbook**: Shared workbook scoped to the public DNS zone
- Shows recent zone and record changes from `AzureActivity`
- Adds record-set drilldowns for per-record activity, top changed records, and failed changes
- Shows public Azure DNS metrics directly from Azure Monitor metrics (`QueryVolume`, `RecordSetCount`, `RecordSetCapacityUtilization`)
- Deployment outputs include a direct portal URL for the workbook

### Networking
- **VNet**: `vnet-dns-poc` (10.0.0.0/16, subnet 10.0.0.0/24)

---

## 🚀 Deployment Instructions

### Prerequisites
1. **Azure CLI** installed and authenticated
2. **Bicep CLI** (bundled with Azure CLI 2.20+)
3. **Subscription permissions**: Owner or Contributor + User Access Administrator
4. **Verified domain ownership**: Ensure `poc.Zava.com` is registered and you can update NS records at registrar

### Step 1: Review Parameters
Edit `main.bicepparam` to customize:
- Domain names (`domain`, `privateDomain`)
- Resource naming (web app names must be globally unique)
- Regions (default: `southcentralus`, `westus3`, `eastasia`)
- Whether to manage Traffic Manager DNS aliases separately from web app deployment

```bicep
param domain = 'poc.Zava.com'
param privateDomain = 'poc-internal.Zava.local'
param location = 'southcentralus'
param deployTrafficManagerDnsAliases = true
```

### Step 2: Validate Template
```powershell
# Test deployment (no-op validation)
az deployment sub validate `
  --location southcentralus `
  --template-file main.bicep `
  --parameters main.bicepparam
```

### Step 3: Deploy Infrastructure
```powershell
# Deploy to subscription scope
az deployment sub create `
  --name Zava-dns-poc-deployment `
  --location southcentralus `
  --template-file main.bicep `
  --parameters main.bicepparam `
  --confirm-with-what-if
```

**Deployment time**: ~15-20 minutes

### Step 4: Capture Outputs
```powershell
# Get all deployment outputs
az deployment sub show `
  --name Zava-dns-poc-deployment `
  --query properties.outputs
```

**Key Outputs**:
- `publicDnsNameServers`: Azure DNS name servers (update registrar NS records)
- `eventHubSendConnectionString`: For diagnostic settings
- `eventHubListenConnectionString`: For QRadar consumer configuration
- `trafficManagerFailoverFqdn`, `trafficManagerGeoFqdn`, `trafficManagerWeightedFqdn`

---

## � TLS Certificate Management (Let's Encrypt + Key Vault)

### Overview

After Bicep deployment, the `deploy.ps1` script automatically:
1. **Issues** a Let's Encrypt wildcard certificate via Azure DNS ACME challenge
2. **Stores** the certificate in Azure Key Vault with RBAC protection
3. **Imports** the certificate into each App Service webspace
4. **Binds** SNI (Server Name Indication) TLS on all custom domains

**Why this approach:**
- ✅ **Zero management**: Let's Encrypt auto-renews 30 days before expiration
- ✅ **Least privilege**: App Service RP gets only `Key Vault Secrets User` (read-only)
- ✅ **Repeatable**: Post-deployment script is idempotent — safe to re-run
- ✅ **No expensive managed certs**: Avoids App Service Managed Certificate licensing

### Automatic TLS Flow (Part of `deploy.ps1`)

```
Bicep Deployment
       ↓
   [Infrastructure Created: RG, DNS Zone, Web Apps, Key Vault]
       ↓
Post-Deployment TLS Setup (`Invoke-LetsEncryptKeyVaultTls.ps1`)
       ↓
   1. Check if KV soft-deleted; recover if needed
   2. Issue LE wildcard cert via Azure DNS challenge
   3. Store in Key Vault
   4. Grant RBAC: App Service RP → Key Vault Secrets User
   5. Import cert into US web app webspace
   6. Bind SNI on all 3 custom domains (US app)
   7. Import cert into UK web app webspace
   8. Bind SNI on all 3 custom domains (UK app)
   9. Remove any stale managed cert resources
       ↓
   ✅ All domains ready for HTTPS
```

### Manual Certificate Operations

If needed, you can run the TLS script directly:

```powershell
cd infrastructure/

pwsh -ExecutionPolicy Bypass -File .\Invoke-LetsEncryptKeyVaultTls.ps1 `
  -SubscriptionId 'your-sub-id' `
  -ResourceGroup 'rg-dns-poc' `
  -DnsZoneName 'zava-dnspoc-002.com' `
  -KeyVaultName 'kvdnsg7vqz5xal6jqs' `
  -WebAppNames 'webapp-poc-us-xxx,webapp-poc-uk-xxx' `
  -CustomDomains 'webfailover.zava-dnspoc-002.com,webgeo.zava-dnspoc-002.com,webweighted.zava-dnspoc-002.com' `
  -ContactEmail 'dnsadmin@zava-dnspoc-002.com'
```

### Verify TLS Bindings

```powershell
# Check US app HTTPS bindings
az webapp config hostname list --resource-group rg-dns-poc --webapp-name webapp-poc-us-xxx `
  --query "[?sslState=='SniEnabled'].{domain:name,sslState:sslState,thumbprint:thumbprint}" --output table

# Check UK app HTTPS bindings
az webapp config hostname list --resource-group rg-dns-poc --webapp-name webapp-poc-uk-xxx `
  --query "[?sslState=='SniEnabled'].{domain:name,sslState:sslState,thumbprint:thumbprint}" --output table

# Check Key Vault certificate
az keyvault certificate show --vault-name kvdnsg7vqz5xal6jqs --name le-wildcard-zava `
  --query "{name:id, expires:attributes.expires, thumbprint:x509ThumbprintHex}" -o json
```

### Troubleshooting TLS

#### Certificate Not Binding to Custom Domains
**Symptom**: Hostname binding shows `IPBased` or empty `sslState` instead of `SniEnabled`

**Cause**: Certificate not imported to webspace, or DNS lock prevents ACME challenge cleanup

**Fix**:
```powershell
# Verify KV cert exists
az keyvault certificate show --vault-name kvdnsg7vqz5xal6jqs --name le-wildcard-zava

# Verify App Service RP has Key Vault Secrets User role
az role assignment list --scope /subscriptions/<sub>/resourceGroups/rg-dns-poc/providers/Microsoft.KeyVault/vaults/kvdnsg7vqz5xal6jqs `
  --query "[?principalName=='Microsoft.Web'].roleDefinitionName"

# If role missing, grant it manually
az role assignment create --scope /subscriptions/<sub>/resourceGroups/rg-dns-poc/providers/Microsoft.KeyVault/vaults/kvdnsg7vqz5xal6jqs `
  --assignee-object-id fd4afe00-f7d0-4f8b-809f-8767c14805cd `
  --assignee-principal-type ServicePrincipal `
  --role "Key Vault Secrets User"

# Re-run TLS setup
pwsh -ExecutionPolicy Bypass -File .\Invoke-LetsEncryptKeyVaultTls.ps1 ...
```

#### "Soft-Deleted Key Vault" Error
**Cause**: KV was deleted in previous deployment and is in soft-delete state with purge protection enabled

**Fix**: The script auto-recovers soft-deleted vaults. If you need to manually recover:
```powershell
az keyvault recover --name kvdnsg7vqz5xal6jqs
az keyvault update --name kvdnsg7vqz5xal6jqs --enable-rbac-authorization true
```

#### DNS Zone Lock Prevents ACME Challenge Cleanup
**Cause**: The `CanNotDelete` lock on the DNS zone blocks TXT record deletion after ACME validation

**Fix**: Script automatically removes and restores the lock. If manual fix needed:
```powershell
# List locks
az lock list --resource-group rg-dns-poc --query "[].name"

# Temporarily remove
az lock delete --name lock-dns-zone --resource-group rg-dns-poc --resource-name zava-dnspoc-002.com --resource-type Microsoft.Network/dnsZones

# Re-run TLS setup

# Restore lock
az lock create --name lock-dns-zone --resource-group rg-dns-poc --lock-type CanNotDelete --resource-name zava-dnspoc-002.com --resource-type Microsoft.Network/dnsZones
```

---

## �🔧 Post-Deployment Configuration

### 1. Update DNS Registrar
Point `poc.Zava.com` NS records to Azure DNS name servers (from outputs):
```
ns1-01.azure-dns.com.
ns2-01.azure-dns.net.
ns3-01.azure-dns.org.
ns4-01.azure-dns.info.
```

⚠️ **DO NOT** update registrar during POC if this is a test subdomain — validate with `dig @ns1-01.azure-dns.com poc.Zava.com` instead.

### 2. Configure IBM QRadar Event Hub Consumer
Use `eventHubListenConnectionString` output to configure QRadar DSM connector:
- **Event Hub Name**: `dns-logs`
- **Consumer Group**: `qradar-consumer`
- **Connection String**: (from outputs)
- **Partition Count**: 2

### 3. Verify Traffic Manager Health Probes
Check endpoint health:
```powershell
$tmProfiles = @('tm-poc-failover', 'tm-poc-geo', 'tm-poc-weighted')
foreach ($tm in $tmProfiles) {
    az network traffic-manager endpoint list `
        --profile-name $tm `
        --resource-group rg-dns-poc `
        --query "[].{name:name, status:endpointStatus, monitor:endpointMonitorStatus}"
}
```

Expected: All endpoints show `Online` within 2 minutes of deployment.

### 4. Test DNS Resolution
```powershell
# Test public DNS records
nslookup webfailover.poc.zava.com
nslookup webgeo.poc.zava.com
nslookup webweighted.poc.zava.com

# Test private DNS (requires VNet VM)
nslookup db.poc-internal.Zava.local 10.0.0.4
```

### 5. Test Web Apps
```powershell
curl https://webfailover.poc.zava.com
curl https://webgeo.poc.zava.com
curl https://webweighted.poc.zava.com
```

---

## 📊 Verify Logging Pipeline

### Check Activity Log Flow
```powershell
# Verify Activity Log → Event Hub
az monitor diagnostic-settings subscription list `
  --query "[?name=='activity-log-to-eventhub']"

# Check Event Hub metrics
az monitor metrics list `
  --resource /subscriptions/<subscription-id>/resourceGroups/rg-dns-poc/providers/Microsoft.EventHub/namespaces/ehns-dns-poc `
  --metric IncomingMessages
```

### Query Log Analytics
```kusto
// Web app HTTP requests (last 1 hour)
AppServiceHTTPLogs
| where TimeGenerated > ago(1h)
| summarize count() by CsHost, ScStatus

// Traffic Manager probe health
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where ResourceId contains "trafficManagerProfiles"
| project TimeGenerated, MetricName, Average
```

---

## 🧪 POC Test Scenarios

### Scenario 1: DNS Failover Test
1. **Baseline**: `curl https://webfailover.poc.zava.com` → returns US web app
2. **Simulate failure**: Stop US web app
3. **Wait 60 seconds**: Traffic Manager health probe detects failure
4. **Verify**: `curl https://webfailover.poc.zava.com` → returns UK web app

### Scenario 2: Geographic Routing
```powershell
# From US IP: Should route to US web app
curl https://webgeo.poc.zava.com

# From UK IP (use VPN/proxy): Should route to UK web app
```

### Scenario 3: Weighted Load Balancing
Run 100 requests and verify ~70% hit US, ~30% hit UK:
```powershell
1..100 | ForEach-Object {
  curl -s https://webweighted.poc.zava.com | Select-String "webapp-poc"
} | Group-Object
```

---

## 🛠️ Troubleshooting

### Issue: Traffic Manager endpoints show "Degraded"
**Cause**: Health probe failing (web apps not responding on HTTPS)  
**Fix**: Verify web apps are running and accessible:
```powershell
az webapp show --name webapp-poc-us --resource-group rg-dns-poc --query state
```

### Issue: Event Hub not receiving Activity Log events
**Cause**: Diagnostic settings not applied at subscription level  
**Fix**: Verify diagnostic setting exists:
```powershell
az monitor diagnostic-settings subscription show --name activity-log-to-eventhub
```

### Issue: DNS zone locked but deployment tries to modify it
**Cause**: CanNotDelete lock prevents updates  
**Fix**: Temporarily remove lock:
```powershell
az lock delete --name lock-dns-zone --resource-group rg-dns-poc
```

---

## 🧹 Cleanup

### Delete All Resources
```powershell
# Remove resource lock first
az lock delete --name lock-dns-zone --resource-group rg-dns-poc

# Delete entire resource group
az group delete --name rg-dns-poc --yes --no-wait

# Remove subscription-level diagnostic settings
az monitor diagnostic-settings subscription delete `
  --name activity-log-to-eventhub
```

---

## 💰 Cost Estimate

**POC Period (14 days) — Prices from Azure Retail Prices API (March 2026):**

| Resource | SKU | API Unit Price | 14-Day Cost |
|----------|-----|---------------|-------------|
| Public DNS Zone (1) | Public | $0.50/zone/mo | $0.23 |
| Private DNS Zone (1) | Private | $0.50/zone/mo | $0.23 |
| DNS Queries (public + private) | — | $0.40/1M queries | $0.00 |
| Event Hub Namespace (1 TU) | Standard | $0.03/hr | $10.08 |
| Event Hub Ingress | Standard | $0.028/1M events | $0.00 |
| Log Analytics (~0.5 GB ingested) | PerGB2018 | $2.76/GB | $1.38 |
| Storage Account | Standard LRS | $0.018/GB/mo | $0.00 |
| App Service Plan US | B1 | $0.02/hr | $6.72 |
| App Service Plan UK | B1 | $0.02/hr | $6.72 |
| Traffic Manager (3 profiles) | — | $0.36/endpoint/mo | $1.01 |
| VNet, RBAC, Locks, Diagnostics | — | Free | $0.00 |
| **TOTAL** | | | **~$26.37** |

**Cost drivers:** App Service Plans (51%) + Event Hub Standard (38%) = 89% of total cost.

⚠️ Prices sourced from `prices.azure.com` API. Actual costs may vary based on Event Hub ingress volume, Log Analytics query volume, and outbound bandwidth.

---

## 📚 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    AZURE SUBSCRIPTION (Zava)                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │           Resource Group: rg-dns-poc                        │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  PUBLIC DNS ZONE: poc.Zava.com                      │  │ │
│  │  │  • CNAME: failover → tm-poc-failover.trafficmgr.net  │  │ │
│  │  │  • CNAME: geo → tm-poc-geo.trafficmgr.net            │  │ │
│  │  │  • CNAME: weighted → tm-poc-weighted.trafficmgr.net  │  │ │
│  │  │  • Lock: CanNotDelete                                 │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  PRIVATE DNS ZONE: poc-internal.Zava.local          │  │ │
│  │  │  • A: db → 10.0.1.100                                 │  │ │
│  │  │  • A: app → 10.0.1.101                                │  │ │
│  │  │  • A: cache → 10.0.1.102                              │  │ │
│  │  │  • VNet Link: vnet-dns-poc                            │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  TRAFFIC MANAGER PROFILES (Global)                    │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  Priority: tm-poc-failover                      │  │  │ │
│  │  │  │  • US (Priority 1) → webapp-poc-us             │  │  │ │
│  │  │  │  • UK (Priority 2) → webapp-poc-uk             │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  Geographic: tm-poc-geo                         │  │  │ │
│  │  │  │  • US/CA/MX → webapp-poc-us                    │  │  │ │
│  │  │  │  • GB/WORLD → webapp-poc-uk                    │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  Weighted: tm-poc-weighted                      │  │  │ │
│  │  │  │  • 70% → webapp-poc-us                         │  │  │ │
│  │  │  │  • 30% → webapp-poc-uk                         │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  WEB APPS (Multi-Region)                              │  │ │
│  │  │  • webapp-poc-us (westus3) → App Service Plan B1    │  │ │
│  │  │  • webapp-poc-uk (eastasia) → App Service Plan B1   │  │ │
│  │  │  Security: HTTPS Only, FTPS Disabled, TLS 1.2       │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  LOGGING INFRASTRUCTURE                               │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  Log Analytics: law-dns-poc (30-day retention) │  │  │ │
│  │  │  │  • Web App logs (7 categories)                 │  │  │ │
│  │  │  │  • Traffic Manager probe health                │  │  │ │
│  │  │  │  • Activity Log (8 categories)                 │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  Event Hub: ehns-dns-poc/dns-logs              │  │  │ │
│  │  │  │  • Standard SKU, 2 partitions, 1-day retention │  │  │ │
│  │  │  │  • Consumer Group: qradar-consumer             │  │  │ │
│  │  │  │  • SendPolicy (Send), QRadarListenPolicy       │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  NETWORKING: vnet-dns-poc (10.0.0.0/16)              │  │ │
│  │  │  • Subnet: default (10.0.0.0/24)                     │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  STORAGE: stqradarpoc (QRadar checkpoints)           │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  SUBSCRIPTION-LEVEL DIAGNOSTICS                           │  │
│  │  Activity Log → Event Hub + Log Analytics                │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  IBM QRadar (On-Prem) │
                   │  Consumes: dns-logs   │
                   └──────────────────────┘
```

---

## 📞 Contact & Support

**Microsoft Contact**: Kim Vaddi (Account Team)  
**Customer Contacts**: Jeremy (Primary Technical), Matt Boulder (Engineer), Mike (Technical Stakeholder)  
**POC Timeline**: 3-phase engagement, wrap-up weeks 3–4 of April 2026  
**Competitive Context**: Azure DNS vs. alternative vendor evaluation

---

## ✅ Success Criteria Scorecard

| Workstream | Status | Notes |
|------------|--------|-------|
| ✅ Zone Migration | Pass | Automated via Bicep |
| ✅ Audit Logging | Pass | Activity Log → Event Hub + Log Analytics |
| ✅ Reporting | Pass | Log Analytics dashboards |
| ✅ Zone Snapshots | Manual | Use `az network dns zone export` |
| ✅ Certificate Integration (DCV) | Manual | DigiCert `_dnsauth` TXT records (post-deployment) |
| ✅ DNS Record Failover | Pass | Priority routing + health probes |
| ✅ Weighted Load Balancing | Pass | 70/30 split |
| ✅ Geographic DNS | Pass | US/CA/MX vs GB/WORLD |
| ✅ API/Automation Support | Pass | Full Bicep IaC |

---

## 📖 References

- [Azure DNS Documentation](https://learn.microsoft.com/en-us/azure/dns/)
- [Traffic Manager Routing Methods](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-routing-methods)
- [Event Hub Integration with QRadar](https://www.ibm.com/docs/en/qradar-common?topic=apps-microsoft-azure-event-hub-dsm)
- [DigiCert DCV Methods](https://docs.digicert.com/en/certcentral/certificate-management/domain-control-validation.html)

---

**Generated**: March 27, 2026  
**Version**: 1.0  
**Managed-by**: Bicep IaC
