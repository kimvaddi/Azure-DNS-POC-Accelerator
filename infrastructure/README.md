# Valero DNS POC — Bicep Infrastructure Deployment

Complete Infrastructure-as-Code deployment for Azure DNS POC evaluation, including DNS zones, Event Hub integration for IBM QRadar, multi-region Traffic Manager profiles, and comprehensive diagnostics.

## 📋 What Gets Deployed

### Core DNS Infrastructure
- **Public DNS Zone**: `poc.valero.com` (with CanNotDelete lock)
- **Private DNS Zone**: `poc-internal.valero.local` (VNet-linked)
- Private DNS A records: `db.poc-internal.valero.local`, `app`, `cache`

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
- `failover.poc.valero.com` → Traffic Manager failover FQDN
- `geo.poc.valero.com` → Traffic Manager geographic FQDN
- `weighted.poc.valero.com` → Traffic Manager weighted FQDN

### Diagnostic Settings
- **Subscription Activity Log**: All 8 categories → Event Hub + Log Analytics
- **Web Apps**: 7 log categories + AllMetrics → Log Analytics
- **Traffic Manager**: ProbeHealthStatusEvents + AllMetrics → Log Analytics

### Networking
- **VNet**: `vnet-dns-poc` (10.0.0.0/16, subnet 10.0.0.0/24)

---

## 🚀 Deployment Instructions

### Prerequisites
1. **Azure CLI** installed and authenticated
2. **Bicep CLI** (bundled with Azure CLI 2.20+)
3. **Subscription permissions**: Owner or Contributor + User Access Administrator
4. **Verified domain ownership**: Ensure `poc.valero.com` is registered and you can update NS records at registrar

### Step 1: Review Parameters
Edit `main.bicepparam` to customize:
- Domain names (`domain`, `privateDomain`)
- Resource naming (web app names must be globally unique)
- Regions (default: `southcentralus`, `westus3`, `eastasia`)

```bicep
param domain = 'poc.valero.com'
param privateDomain = 'poc-internal.valero.local'
param location = 'southcentralus'
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
  --name valero-dns-poc-deployment `
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
  --name valero-dns-poc-deployment `
  --query properties.outputs
```

**Key Outputs**:
- `publicDnsNameServers`: Azure DNS name servers (update registrar NS records)
- `eventHubSendConnectionString`: For diagnostic settings
- `eventHubListenConnectionString`: For QRadar consumer configuration
- `trafficManagerFailoverFqdn`, `trafficManagerGeoFqdn`, `trafficManagerWeightedFqdn`

---

## 🔧 Post-Deployment Configuration

### 1. Update DNS Registrar
Point `poc.valero.com` NS records to Azure DNS name servers (from outputs):
```
ns1-01.azure-dns.com.
ns2-01.azure-dns.net.
ns3-01.azure-dns.org.
ns4-01.azure-dns.info.
```

⚠️ **DO NOT** update registrar during POC if this is a test subdomain — validate with `dig @ns1-01.azure-dns.com poc.valero.com` instead.

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
nslookup failover.poc.valero.com
nslookup geo.poc.valero.com
nslookup weighted.poc.valero.com

# Test private DNS (requires VNet VM)
nslookup db.poc-internal.valero.local 10.0.0.4
```

### 5. Test Web Apps
```powershell
curl https://failover.poc.valero.com
curl https://geo.poc.valero.com
curl https://weighted.poc.valero.com
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
1. **Baseline**: `curl https://failover.poc.valero.com` → returns US web app
2. **Simulate failure**: Stop US web app
3. **Wait 60 seconds**: Traffic Manager health probe detects failure
4. **Verify**: `curl https://failover.poc.valero.com` → returns UK web app

### Scenario 2: Geographic Routing
```powershell
# From US IP: Should route to US web app
curl https://geo.poc.valero.com

# From UK IP (use VPN/proxy): Should route to UK web app
```

### Scenario 3: Weighted Load Balancing
Run 100 requests and verify ~70% hit US, ~30% hit UK:
```powershell
1..100 | ForEach-Object {
    curl -s https://weighted.poc.valero.com | Select-String "webapp-poc"
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

**POC Period (2 weeks):**
| Resource | SKU | Estimated Cost |
|----------|-----|----------------|
| DNS Zone (Public) | Standard | $1.00 |
| Event Hub Namespace | Standard | $10.00 |
| Log Analytics | PerGB2018 (~1GB) | $2.50 |
| App Service Plans (2x B1) | Basic | $10.00 |
| Storage Account | Standard LRS | $0.50 |
| Traffic Manager (3 profiles) | Standard | $2.00 |
| **TOTAL** | | **~$26.00** |

⚠️ Actual costs may vary based on usage (Event Hub ingress, Log Analytics queries, outbound bandwidth).

---

## 📚 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    AZURE SUBSCRIPTION (Valero)                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │           Resource Group: rg-dns-poc                        │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  PUBLIC DNS ZONE: poc.valero.com                      │  │ │
│  │  │  • CNAME: failover → tm-poc-failover.trafficmgr.net  │  │ │
│  │  │  • CNAME: geo → tm-poc-geo.trafficmgr.net            │  │ │
│  │  │  • CNAME: weighted → tm-poc-weighted.trafficmgr.net  │  │ │
│  │  │  • Lock: CanNotDelete                                 │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  PRIVATE DNS ZONE: poc-internal.valero.local          │  │ │
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
