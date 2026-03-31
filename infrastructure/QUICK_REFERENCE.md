# Zava DNS POC — Quick Reference

## 🚀 Quick Deployment

```powershell
# Option 1: Automated deployment script (recommended)
.\deploy.ps1

# Option 2: Manual deployment with Bicep parameters
az deployment sub create `
  --name Zava-dns-poc `
  --location southcentralus `
  --template-file main.bicep `
  --parameters main.bicepparam

# Option 3: Manual deployment with JSON parameters
az deployment sub create `
  --name Zava-dns-poc `
  --location southcentralus `
  --template-file main.bicep `
  --parameters main.parameters.json
```

---

## 📋 Resource Inventory

| Resource Type | Name | Purpose |
|---------------|------|---------|
| **Resource Group** | `rg-dns-poc` | Container for all POC resources |
| **Public DNS Zone** | `poc.zava-dnspoc.com` | Main POC DNS zone |
| **Private DNS Zone** | `poc-internal.zava-dnspoc.local` | Internal DNS testing |
| **Log Analytics** | `law-dns-poc` | Central logging (30-day retention) |
| **Event Hub Namespace** | `ehns-dns-poc` | QRadar integration |
| **Event Hub** | `dns-logs` | Activity log stream to QRadar |
| **Storage Account** | `stqradarpoc*` | QRadar checkpoints |
| **VNet** | `vnet-dns-poc` | Private DNS zone link |
| **Traffic Manager** | `tm-poc-failover` | Priority/failover routing |
| **Traffic Manager** | `tm-poc-geo` | Geographic routing |
| **Traffic Manager** | `tm-poc-weighted` | Weighted load balancing |
| **App Service Plan** | `asp-poc-us` | US region hosting (westus3) |
| **App Service Plan** | `asp-poc-uk` | UK region hosting (uknorth) |
| **Web App** | `webapp-poc-us` | US endpoint |
| **Web App** | `webapp-poc-uk` | UK endpoint |

---

## 🌐 DNS Records Created

| Record | Type | Target | TTL |
|--------|------|--------|-----|
| `failover.poc.zava-dnspoc.com` | CNAME | `tm-poc-failover.trafficmanager.net` | 30 |
| `geo.poc.zava-dnspoc.com` | CNAME | `tm-poc-geo.trafficmanager.net` | 30 |
| `weighted.poc.zava-dnspoc.com` | CNAME | `tm-poc-weighted.trafficmanager.net` | 30 |
| `db.poc-internal.zava-dnspoc.local` | A | `10.0.1.100` | 300 |
| `app.poc-internal.zava-dnspoc.local` | A | `10.0.1.101` | 300 |
| `cache.poc-internal.zava-dnspoc.local` | A | `10.0.1.102` | 300 |

---

## 🔍 Verification Commands

### Check Deployment Status
```powershell
az deployment sub show --name Zava-dns-poc --query properties.provisioningState
```

### Get All Outputs
```powershell
az deployment sub show --name Zava-dns-poc --query properties.outputs
```

### Verify DNS Zone
```powershell
az network dns zone show --name poc.zava-dnspoc.com --resource-group rg-dns-poc
```

### Check Traffic Manager Health
```powershell
az network traffic-manager endpoint list `
  --profile-name tm-poc-failover `
  --resource-group rg-dns-poc `
  --query "[].{name:name, status:endpointStatus, health:endpointMonitorStatus}"
```

### Test DNS Resolution
```powershell
nslookup failover.poc.zava-dnspoc.com
nslookup geo.poc.zava-dnspoc.com
nslookup weighted.poc.zava-dnspoc.com
```

### Verify Event Hub
```powershell
az eventhubs eventhub show `
  --namespace-name ehns-dns-poc `
  --name dns-logs `
  --resource-group rg-dns-poc
```

### Check Web App Status
```powershell
az webapp show --name webapp-poc-us --resource-group rg-dns-poc --query state
az webapp show --name webapp-poc-uk --resource-group rg-dns-poc --query state
```

---

## 📊 Log Analytics Queries

### Web App HTTP Requests
```kusto
AppServiceHTTPLogs
| where TimeGenerated > ago(1h)
| summarize count() by CsHost, ScStatus, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

### Traffic Manager Health Events
```kusto
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where ResourceId contains "trafficManagerProfiles"
| where MetricName == "ProbeAgentCurrentEndpointStateByProfileResourceId"
| project TimeGenerated, Resource, Average
| order by TimeGenerated desc
```

### Activity Log Events
```kusto
AzureActivity
| where TimeGenerated > ago(24h)
| summarize count() by CategoryValue, ActivityStatusValue
| order by count_ desc
```

### Event Hub Metrics
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.EVENTHUB"
| where TimeGenerated > ago(1h)
| summarize count() by bin(TimeGenerated, 5m)
```

---

## 🧪 Test Scenarios

### Scenario 1: DNS Failover
```powershell
# 1. Baseline
curl https://failover.poc.zava-dnspoc.com

# 2. Stop US web app
az webapp stop --name webapp-poc-us --resource-group rg-dns-poc

# 3. Wait 60 seconds for health probe

# 4. Test failover
curl https://failover.poc.zava-dnspoc.com  # Should return UK app

# 5. Restart US web app
az webapp start --name webapp-poc-us --resource-group rg-dns-poc
```

### Scenario 2: Geographic Routing
```powershell
# Test from different geographic locations
curl -H "X-Forwarded-For: 1.1.1.1" https://geo.poc.zava-dnspoc.com  # US IP
curl -H "X-Forwarded-For: 194.0.0.1" https://geo.poc.zava-dnspoc.com  # UK IP
```

### Scenario 3: Weighted Distribution
```powershell
# Run 100 requests and check distribution
1..100 | ForEach-Object {
    $response = curl -s https://weighted.poc.zava-dnspoc.com
    if ($response -match "webapp-poc-us") { "US" } else { "UK" }
} | Group-Object | Select-Object Name, Count
```

---

## 🔐 Security Configuration

### HTTPS Only
All web apps deployed with:
- `httpsOnly: true`
- `minTlsVersion: 1.2`
- `ftpsState: Disabled`

### Network Security
- Storage account: `allowBlobPublicAccess: false`
- Event Hub: Standard SKU with authorization rules (least privilege)
- Private DNS zone: VNet-linked (not publicly resolvable)

### Resource Lock
- DNS zone protected with `CanNotDelete` lock
- Remove before zone modifications:
  ```powershell
  az lock delete --name lock-dns-zone --resource-group rg-dns-poc
  ```

---

## 📦 Event Hub Configuration for QRadar

### Connection Details
```plaintext
Event Hub Namespace: ehns-dns-poc.servicebus.windows.net
Event Hub Name: dns-logs
Consumer Group: qradar-consumer
Partition Count: 2
Retention: 1 day
```

### QRadar DSM Configuration
1. Open QRadar Console
2. Navigate to **Admin** → **Data Sources**
3. Add new log source: **Microsoft Azure Event Hub**
4. Configure:
   - **Event Hub Name**: `dns-logs`
   - **Consumer Group**: `qradar-consumer`
   - **Connection String**: (from deployment outputs)
   - **Storage Account**: `stqradarpoc*` (for checkpoints)

### Test Event Hub Flow
```powershell
# Generate test activity log event
az group update --name rg-dns-poc --tags test=event-hub-validation

# Wait 2-3 minutes, then check metrics
az monitor metrics list `
  --resource /subscriptions/<sub-id>/resourceGroups/rg-dns-poc/providers/Microsoft.EventHub/namespaces/ehns-dns-poc `
  --metric IncomingMessages `
  --start-time (Get-Date).AddMinutes(-10) `
  --interval PT1M
```

---

## 🧹 Cleanup Commands

### Delete All Resources
```powershell
# Remove DNS zone lock first
az lock delete --name lock-dns-zone --resource-group rg-dns-poc

# Delete resource group
az group delete --name rg-dns-poc --yes --no-wait

# Remove subscription-level diagnostic settings
az monitor diagnostic-settings subscription delete `
  --name activity-log-to-eventhub
```

### Selective Cleanup (Keep DNS Zone)
```powershell
# Remove only compute resources
az webapp delete --name webapp-poc-us --resource-group rg-dns-poc
az webapp delete --name webapp-poc-uk --resource-group rg-dns-poc
az appservice plan delete --name asp-poc-us --resource-group rg-dns-poc --yes
az appservice plan delete --name asp-poc-uk --resource-group rg-dns-poc --yes

# Remove Traffic Manager
az network traffic-manager profile delete --name tm-poc-failover --resource-group rg-dns-poc
az network traffic-manager profile delete --name tm-poc-geo --resource-group rg-dns-poc
az network traffic-manager profile delete --name tm-poc-weighted --resource-group rg-dns-poc
```

---

## 💰 Cost Tracking

### Get Current Costs
```powershell
# Requires Microsoft.CostManagement
az costmanagement query `
  --type ActualCost `
  --dataset-filter "{\"and\":[{\"dimensions\":{\"name\":\"ResourceGroupName\",\"operator\":\"In\",\"values\":[\"rg-dns-poc\"]}}]}" `
  --timeframe MonthToDate `
  --query "rows[]"
```

### Estimated Daily Cost: ~$1.85
- Event Hub Standard: ~$0.50/day
- App Service Plans (2x B1): ~$0.50/day
- Log Analytics: ~$0.15/day (assuming 1GB ingestion)
- DNS Zone: ~$0.05/day
- Traffic Manager: ~$0.10/day
- Storage: ~$0.03/day
- VNet: Free
- Data Transfer: Minimal during POC

---

## 🔗 Useful Links

- [POC Plan](../Zava_Azure_DNS_POC_Plan.md)
- [Runbook Scripts](../Zava_DNS_POC_Runbook.sh)
- [DCV Walkthrough](../Zava_DCV_Walkthrough_Guide.md)
- [Scoping Session Agenda](../Zava_DNS_POC_Scoping_Session_Agenda.md)

---

## 📞 Contacts

**Microsoft**: Kim Vaddi (Account Team)  
**Zava**: Jeremy (Primary), Matt Boulder (Engineer), Mike (Technical), Charles Mylak (PM), Noel (Coordination)

---

**Last Updated**: March 27, 2026  
**Version**: 1.0
