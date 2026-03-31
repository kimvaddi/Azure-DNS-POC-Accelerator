# Zava DNS POC — Bicep Infrastructure Files

## 📁 Project Structure

```
infrastructure/
├── main.bicep                      # Main template (subscription-scope)
├── main.bicepparam                 # Bicep parameters file
├── main.parameters.json            # JSON parameters file (alternative)
├── deploy.ps1                      # Automated deployment script
├── README.md                       # Full deployment guide
├── QUICK_REFERENCE.md              # Quick command reference
├── .gitignore                      # Git ignore rules
│
└── modules/                        # Reusable Bicep modules
    ├── log-analytics.bicep         # Log Analytics Workspace
    ├── event-hub.bicep             # Event Hub Namespace + Hub + Auth Rules
    ├── storage-account.bicep       # Storage Account (QRadar checkpoints)
    ├── vnet.bicep                  # Virtual Network + Subnet
    ├── public-dns-zone.bicep       # Public DNS Zone
    ├── private-dns-zone.bicep      # Private DNS Zone + VNet Link + A Records
    ├── app-service-plan.bicep      # App Service Plan (Linux/Windows)
    ├── web-app.bicep               # Web App + Diagnostic Settings
    ├── traffic-manager.bicep       # Traffic Manager Profile + Endpoints
    ├── dns-cname-records.bicep     # CNAME Records (loop)
    ├── activity-log-diagnostics.bicep  # Subscription-level diagnostics
    └── resource-lock.bicep         # Resource Lock (CanNotDelete/ReadOnly)
```

---

## 📄 File Descriptions

### Core Template Files

#### `main.bicep`
- **Purpose**: Orchestrates complete DNS POC infrastructure deployment
- **Scope**: Subscription-level (creates resource group + resources)
- **Resources**: 25+ resources across DNS, logging, networking, compute
- **Parameters**: 12 configurable parameters (locations, names, domains)
- **Outputs**: 20+ outputs (connection strings, FQDNs, IDs, test URLs)
- **Size**: ~350 lines

#### `main.bicepparam`
- **Purpose**: Type-safe parameters file for Bicep (recommended)
- **Format**: Bicep parameter syntax (`using './main.bicep'`)
- **Contents**: Default POC values with uniqueString for global names
- **Usage**: `az deployment sub create --parameters main.bicepparam`

#### `main.parameters.json`
- **Purpose**: JSON parameters file (alternative to .bicepparam)
- **Format**: ARM template JSON schema
- **Contents**: Same defaults as .bicepparam
- **Usage**: `az deployment sub create --parameters main.parameters.json`

---

### Module Files

#### `log-analytics.bicep`
- **Resources**: Log Analytics Workspace
- **Configuration**: 30-day retention, PerGB2018 SKU
- **Outputs**: Workspace ID, name, customer ID

#### `event-hub.bicep`
- **Resources**: Event Hub Namespace, Event Hub, 2 auth rules, consumer group
- **Configuration**: Standard SKU (required for consumer groups), 2 partitions
- **Outputs**: Namespace/hub IDs, connection strings (Send, Listen)

#### `storage-account.bicep`
- **Resources**: General-purpose v2 storage account
- **Security**: HTTPS-only, TLS 1.2, no public blob access
- **Purpose**: QRadar checkpoint tracking

#### `vnet.bicep`
- **Resources**: Virtual Network + Subnet
- **Configuration**: 10.0.0.0/16 (subnet: 10.0.0.0/24)
- **Purpose**: Private DNS zone VNet link

#### `public-dns-zone.bicep`
- **Resources**: Public DNS zone
- **Configuration**: Auto-generated SOA/NS records
- **Outputs**: Zone ID, name, name servers (for registrar update)

#### `private-dns-zone.bicep`
- **Resources**: Private DNS zone, VNet link, A records (loop)
- **Configuration**: 3 A records (db, app, cache)
- **Purpose**: Internal DNS resolution testing

#### `app-service-plan.bicep`
- **Resources**: App Service Plan
- **Configuration**: B1 tier, Linux or Windows
- **Purpose**: Host multi-region web apps

#### `web-app.bicep`
- **Resources**: Web App + Diagnostic Settings
- **Security**: HTTPS-only, FTPS disabled, TLS 1.2
- **Diagnostics**: 7 log categories + AllMetrics → Log Analytics

#### `traffic-manager.bicep`
- **Resources**: Traffic Manager Profile + Endpoints (loop) + Diagnostics
- **Routing**: Supports Priority, Geographic, Weighted
- **Health Probes**: HTTPS/443, 30s interval, path=/

#### `dns-cname-records.bicep`
- **Resources**: CNAME records (loop)
- **Configuration**: TTL=30 for fast failover
- **Purpose**: Wire DNS to Traffic Manager FQDNs

#### `activity-log-diagnostics.bicep`
- **Scope**: Subscription-level
- **Resources**: Diagnostic settings for Activity Log
- **Configuration**: All 8 categories → Event Hub + Log Analytics

#### `resource-lock.bicep`
- **Resources**: Resource lock (CanNotDelete/ReadOnly)
- **Scope**: DNS zone level
- **Purpose**: Prevent accidental deletion

---

### Deployment & Documentation

#### `deploy.ps1`
- **Purpose**: Automated deployment script with validation and outputs
- **Features**:
  - Pre-flight checks (Azure CLI, Bicep, authentication)
  - Template compilation and validation
  - What-if analysis support
  - Progress tracking and timing
  - Full output capture and formatting
  - Post-deployment action list
  - Save outputs to JSON file
- **Flags**: `-ValidateOnly`, `-WhatIf`
- **Usage**: `.\deploy.ps1`

#### `README.md`
- **Purpose**: Comprehensive deployment guide
- **Sections**:
  - What gets deployed (full resource list)
  - Deployment instructions (step-by-step)
  - Post-deployment configuration
  - Verification commands
  - Logging pipeline validation
  - POC test scenarios (3 scenarios)
  - Troubleshooting guide
  - Cleanup commands
  - Cost estimate (~$26 for 2 weeks)
  - Architecture diagram (ASCII art)
  - Success criteria scorecard
- **Length**: ~650 lines

#### `QUICK_REFERENCE.md`
- **Purpose**: Command cheat sheet for operators
- **Sections**:
  - Quick deployment commands
  - Resource inventory table
  - DNS records list
  - Verification commands
  - Log Analytics queries (KQL)
  - Test scenarios (copy-paste ready)
  - Security configuration summary
  - QRadar configuration steps
  - Cleanup commands
  - Cost tracking commands
  - Contact information
- **Length**: ~350 lines

#### `.gitignore`
- **Purpose**: Exclude build artifacts and sensitive data from git
- **Patterns**:
  - Compiled ARM JSON templates
  - Deployment outputs
  - Logs and temporary files
  - Connection strings and secrets
  - VS Code workspace files

---

## 🎯 Deployment Options

### Option 1: Automated Script (Recommended)
```powershell
.\deploy.ps1
```
**Features**: Validation, confirmation, progress tracking, formatted outputs

### Option 2: Azure CLI + Bicep Parameters
```powershell
az deployment sub create \
  --name Zava-dns-poc \
  --location southcentralus \
  --template-file main.bicep \
  --parameters main.bicepparam
```

### Option 3: Azure CLI + JSON Parameters
```powershell
az deployment sub create \
  --name Zava-dns-poc \
  --location southcentralus \
  --template-file main.bicep \
  --parameters main.parameters.json
```

### Option 4: Validate Only (No Deployment)
```powershell
.\deploy.ps1 -ValidateOnly
```

### Option 5: What-If Analysis
```powershell
.\deploy.ps1 -WhatIf
```

---

## ✅ Validation Checklist

Before deploying, ensure:
- [ ] Azure CLI installed and authenticated (`az login`)
- [ ] Bicep CLI installed (`az bicep install`)
- [ ] Subscription permissions (Owner or Contributor + User Access Administrator)
- [ ] Domain `poc.zava-dnspoc.com` registered (or ready to use subdomain)
- [ ] Resource names are globally unique (especially web apps, storage account)
- [ ] Parameters reviewed in `main.bicepparam` or `main.parameters.json`
- [ ] Cost estimate approved (~$26 for 2 weeks)

After deploying, verify:
- [ ] All resources created successfully (`az deployment sub show`)
- [ ] Traffic Manager endpoints show "Online" status
- [ ] Event Hub receiving Activity Log events
- [ ] Web apps accessible via HTTPS
- [ ] DNS CNAME records created with TTL=30
- [ ] Private DNS zone linked to VNet
- [ ] Log Analytics receiving diagnostic data
- [ ] Resource lock applied to DNS zone

---

## 📊 Resource Counts by Type

| Resource Type | Count | Module |
|---------------|-------|--------|
| Resource Groups | 1 | main.bicep |
| DNS Zones (Public) | 1 | public-dns-zone |
| DNS Zones (Private) | 1 | private-dns-zone |
| DNS CNAME Records | 3 | dns-cname-records |
| DNS A Records | 3 | private-dns-zone |
| Virtual Networks | 1 | vnet |
| Subnets | 1 | vnet |
| Log Analytics Workspaces | 1 | log-analytics |
| Event Hub Namespaces | 1 | event-hub |
| Event Hubs | 1 | event-hub |
| Event Hub Auth Rules | 2 | event-hub |
| Event Hub Consumer Groups | 1 | event-hub |
| Storage Accounts | 1 | storage-account |
| App Service Plans | 2 | app-service-plan |
| Web Apps | 2 | web-app |
| Traffic Manager Profiles | 3 | traffic-manager |
| Traffic Manager Endpoints | 6 | traffic-manager |
| Diagnostic Settings (Resource) | 5 | web-app, traffic-manager |
| Diagnostic Settings (Subscription) | 1 | activity-log-diagnostics |
| Resource Locks | 1 | resource-lock |
| **TOTAL** | **35** | |

---

## 🔐 Security Features

### Network Security
- ✅ All web apps: HTTPS-only (`httpsOnly: true`)
- ✅ TLS 1.2 minimum (`minTlsVersion: '1.2'`)
- ✅ FTPS disabled (`ftpsState: 'Disabled'`)
- ✅ Storage: No public blob access (`allowBlobPublicAccess: false`)
- ✅ Private DNS zone: VNet-linked (not publicly resolvable)

### Identity & Access
- ✅ Event Hub: Least-privilege auth rules (Send, Listen)
- ✅ Resource lock: CanNotDelete on DNS zone

### Monitoring & Compliance
- ✅ Subscription Activity Log: All 8 categories logged
- ✅ Web Apps: 7 log categories + metrics
- ✅ Traffic Manager: Probe health events logged
- ✅ Log retention: 30 days in Log Analytics

---

## 💡 Best Practices Applied

### Bicep Coding Standards
- ✅ **Module-first architecture**: 12 reusable modules
- ✅ **Strong typing**: All parameters typed and validated
- ✅ **Parameterization**: All names, locations, SKUs configurable
- ✅ **Descriptive names**: Clear resource naming (no cryptic abbreviations)
- ✅ **Comments**: Section headers and inline documentation
- ✅ **Outputs**: Comprehensive outputs for post-deployment automation
- ✅ **Idempotent**: Safe to re-run deployments

### Azure Naming Conventions
- ✅ **Prefixes**: `rg-`, `law-`, `ehns-`, `vnet-`, `asp-`, `webapp-`, `tm-`
- ✅ **Hierarchy**: `{type}-{workload}-{environment}` pattern
- ✅ **Global uniqueness**: Storage account and web apps use `uniqueString()`
- ✅ **Tag strategy**: project, customer, environment, managed-by

### Infrastructure Design
- ✅ **Multi-region**: US (westus3) + UK (westeurope)
- ✅ **High availability**: Traffic Manager failover + health probes
- ✅ **Observability**: Full diagnostic settings on all resources
- ✅ **Cost-optimized**: B1 App Service Plans for POC
- ✅ **Security-first**: HTTPS, TLS 1.2, least privilege
- ✅ **Modular**: Easy to extend or remove components

---

## 📞 Support & Feedback

**Issues?** Check [README.md](README.md) Troubleshooting section  
**Questions?** Contact Kim Vaddi (Microsoft Account Team)  
**POC Duration**: 2 weeks (March 27 - April 10, 2026)

---

**Generated**: March 27, 2026  
**Total Files**: 18 (1 main + 12 modules + 5 docs)  
**Total Resources**: 35 Azure resources  
**Estimated Deployment Time**: 15-20 minutes  
**Estimated Cost**: ~$26 for 2-week POC
