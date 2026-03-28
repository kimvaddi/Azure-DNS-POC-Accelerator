# Zava — Azure DNS POC Plan

**Document Type:** POC Scope & Execution Plan  
**Customer:** Zava Energy Corporation  
**Microsoft Contacts:** Kim Vaddi (Account Team)  
**Customer Contacts:** Jeremy (Primary Technical), Mike (Technical Stakeholder), Matt Boulder (Technical Engineer), Charles Mylak (PM — requires project documentation), Noel (Coordination/Paperwork)  
**Date Created:** March 24, 2026  
**Last Updated:** March 25, 2026 — Post-scoping session updates  
**POC Target Start:** Week of April 7, 2026  
**POC Wrap-Up:** Weeks 3–4 of April 2026 (documentation + go/no-go)  
**POC Duration:** 2 weeks execution + 1 week documentation/wrap-up  
**SIEM:** IBM QRadar  
**Certificate Authority:** DigiCert CertCentral  
**Status:** CONFIRMED — Scope agreed in scoping session March 25, 2026  

---

## 1. Executive Summary

Zava is replacing aging Bind-based DNS servers in their DMZ with a cloud-hosted authoritative DNS service. Azure DNS is being evaluated in a competitive POC against at least one other vendor. Zava recently stood up their Azure Enterprise Landing Zone, which positions this POC well — the foundational networking, identity, and governance guardrails are already in place.

**The goal:** Validate that Azure DNS can fully replace Bind while improving security posture, operational scalability, and enabling future capabilities (geo-routing, automation, certificate integration).

**Why this POC matters competitively:**  
- Zava is finishing another vendor's POC first — Azure DNS needs to be *faster, cleaner, and more compelling* to win.  
- The enterprise landing zone is already Azure — this is a natural extension, not a new platform bet.  
- If DNS moves to Azure, it deepens Azure footprint and opens the door for broader network services adoption.

**Key findings from scoping session (March 25, 2026):**  
- SIEM confirmed: **IBM QRadar** — Event Hub → QRadar DSM integration  
- Certificate provider confirmed: **DigiCert CertCentral** — DCV uses `_dnsauth` TXT records (not ACME `_acme-challenge`)  
- DNSSEC moved to **optional/nice-to-have** — not a requirement for this POC  
- New required items: **Zone Snapshots** (point-in-time export) and **Reporting** (operational dashboards)  
- Charles Mylak requires **formal project documentation** for the POC  
- Mike confirmed as additional technical stakeholder alongside Jeremy and Matt

---

## 2. POC Scope — What's In / What's Out

### 2.1 REQUIRED (Must-Pass for POC Success)

| # | Workstream | What We're Validating | Azure Service / Feature | Pass Criteria |
|---|---|---|---|---|
| 1 | **Zone Migration** | Import existing Bind zone files into Azure DNS; validate record parity across all types (A, AAAA, CNAME, MX, TXT, SRV, NS, SOA) | `az network dns zone import` + Azure Public DNS Zones | Zones imported; record counts match source; all types resolve via dig/nslookup |
| 2 | **Audit Logging** | Full audit trail — who changed what record, when, from where | Azure Activity Log (management plane) + Diagnostic Settings → DnsDiagnosticEvents (query plane) | Activity Log shows record create/modify/delete with user identity + timestamp; query logs flowing |
| 3 | **Reporting** | Operational visibility into DNS zone health, query volumes, and change history | Azure Monitor Workbooks + Log Analytics + Activity Log queries | Dashboard shows query volume trends, top queried records, change history, and error rates |
| 4 | **Zone Snapshots** | Point-in-time zone backup and restore capability | `az network dns zone export` + scheduled Azure Automation or cron | On-demand and scheduled zone exports produce valid RFC 1035 files; re-import verified |
| 5 | **Certificate Integration (DCV)** | Automated DigiCert DNS-01 domain validation — `_dnsauth` TXT record lifecycle for single domain, subdomain, wildcard, and multi-domain SAN certs | Azure DNS API + DigiCert CertCentral | Automated create → verify → cleanup of `_dnsauth` TXT records; propagation under 60s; all cert types proven |

### 2.2 OPTIONAL (Nice-to-Have)

| # | Workstream | What We're Validating | Azure Service / Feature | Pass Criteria |
|---|---|---|---|---|
| 6 | **DNS Record Failover** | Automatic DNS failover when primary endpoint is unhealthy | Traffic Manager with Priority routing + health probes | Primary down → DNS resolves to secondary automatically |
| 7 | **Weighted Load Balancing** | Distribute DNS traffic across endpoints by weight | Traffic Manager with Weighted routing | Requests distribute per configured weights (e.g., 70/30) |
| 8 | **Geographic DNS** | Return different IPs based on client geography | Traffic Manager with Geographic routing | US clients → US IP, UK clients → UK IP |
| 9 | **API Support** | Full programmatic DNS management via multiple interfaces | Azure REST API, CLI, PowerShell, Terraform, Bicep, SDKs | Record CRUD demonstrated via CLI, REST API, and Terraform |
| 10 | **DNSSEC** | Zone signing and chain of trust validation | Azure DNS DNSSEC (`az network dns dnssec-config create`) | Zone signed, RRSIG present in dig output |

### 2.3 OUT OF SCOPE

- Full production migration (this is validation only)  
- Recursive/resolver DNS (Zava's use case is authoritative; recursive resolvers remain separate)  
- Full GSLB / application-layer load balancing (Azure Front Door, Application Gateway — can be discussed as future phase)  
- DNS-based DDoS testing (Azure DNS has built-in DDoS protection via Azure's global network, but stress testing is not in POC scope)  
- Registrar transfer or NS delegation changes to production domains  

---

## 3. Architecture — POC Environment

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Zava ENTERPRISE LANDING ZONE                     │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  POC Resource Group: rg-dns-poc                                  │ │
│  │                                                                   │ │
│  │  ┌──────────────────┐    ┌──────────────────────┐               │ │
│  │  │  Azure DNS Zone   │    │  Azure DNS Zone       │               │ │
│  │  │  poc.Zava.com   │    │  poc-internal.Zava   │               │ │
│  │  │  (Public)         │    │  (Private DNS Zone)    │               │ │
│  │  └────────┬─────────┘    └──────────┬───────────┘               │ │
│  │           │                          │                            │ │
│  │           │  Diagnostic Settings     │  VNet Link                 │ │
│  │           ▼                          ▼                            │ │
│  │  ┌──────────────────┐    ┌──────────────────────┐               │ │
│  │  │  Event Hub        │    │  Landing Zone VNet    │               │ │
│  │  │  (→ SIEM)         │    │                       │               │ │
│  │  └──────────────────┘    └──────────────────────┘               │ │
│  │                                                                   │ │
│  │  ┌──────────────────┐    ┌──────────────────────┐               │ │
│  │  │  Traffic Manager  │    │  RBAC Assignments     │               │ │
│  │  │  (Geo Routing)    │    │  (Zone-scoped)        │               │ │
│  │  └──────────────────┘    └──────────────────────┘               │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
                          │
               ┌──────────┴──────────┐
               │   Internet / Clients │
               │   (dig, nslookup)    │
               └─────────────────────┘
```

**Key design decisions:**
- Use a **dedicated POC resource group** (`rg-dns-poc`) inside the existing landing zone — easy to provision, easy to tear down.
- Use a **subdomain or non-production domain** for testing (e.g., `poc.Zava.com`) — no risk to production DNS.
- Landing zone RBAC and policies already apply — POC inherits governance automatically.
- Event Hub namespace for log streaming to existing SIEM pipeline.

---

## 4. POC Phases & Timeline (3 Phases — Wrap-Up Weeks 3–4 of April)

### Pre-POC (Before Day 1)

| Task | Owner | Target |
|---|---|---|
| Confirm POC domain/subdomain (e.g., `poc.Zava.com`) | Jeremy / Zava DNS team | Before POC start |
| Export 2–3 representative Bind zone files (RFC 1035 format) | Jeremy / Matt / Mike | Before POC start |
| Confirm QRadar Event Hub DSM connector is available | Zava Security team | Before POC start |
| Provision POC resource group `rg-dns-poc` in landing zone | Zava Platform team | Before POC start |
| Identify 2 test users: 1 "Operator" + 1 "Admin" for RBAC testing | Jeremy | Before POC start |
| Share DigiCert CertCentral workflow details (API access, current DCV process) | Jeremy / Matt | Before POC start |

### Phase 1: Core Required Validation (Days 1–5)

| Day | Focus | Activities | Exit Criteria |
|---|---|---|---|
| **Day 1** | **Environment Setup + Zone Migration** | Create DNS zones in Azure; import Bind zone files using `az network dns zone import`; verify record counts and types match source | Zones created, records imported, all types verified via dig |
| **Day 2** | **Zone Migration Validation + Zone Snapshots** | Run dig/nslookup battery against all imported record types; test zone export/snapshot capability; schedule automated snapshot | 100% record parity; zone export produces valid RFC 1035 file; re-import verified |
| **Day 3** | **Audit Logging + QRadar SIEM Integration** | Enable Diagnostic Settings; route query logs to Event Hub; configure QRadar DSM connector; validate log ingestion; verify Activity Log change tracking | DNS query logs visible and queryable in QRadar; management changes tracked in Activity Log |
| **Day 4** | **Certificate Integration — DigiCert DCV** | Run DigiCert DCV proof suite: `_dnsauth` TXT records for single domain, subdomain, wildcard, multi-domain SAN; measure propagation; cleanup | All 5 DCV tests pass; propagation under 60s; cleanup confirmed |
| **Day 5** | **Reporting + Mid-POC Review** | Build Azure Monitor Workbook dashboards; create operational reports (query volumes, change history, top queried records); present Phase 1 results to stakeholders | Dashboards operational; Phase 1 scorecard reviewed with Jeremy, Mike, Matt, Kim |

### Phase 2: Optional Features (Days 6–8)

| Day | Focus | Activities | Exit Criteria |
|---|---|---|---|
| **Day 6** | **DNS Record Failover + Weighted Load Balancing** | Configure Traffic Manager Priority routing (failover); test automatic DNS failover on endpoint failure; configure Weighted routing; verify distribution | Failover works automatically; weighted distribution confirmed |
| **Day 7** | **Geographic DNS + API Support** | Set up Traffic Manager Geographic routing; test from multiple geo vantage points; demonstrate record CRUD via REST API, CLI, PowerShell, and Terraform | Geo-routing returns correct IPs; API management workflows demonstrated |
| **Day 8** | **Edge Cases + DNSSEC (if time)** | Test TTL behavior, propagation speed, NXDOMAIN, large zones; optionally test DNSSEC zone signing | No blocking issues; propagation within SLAs; DNSSEC optional results documented |

### Phase 3: Documentation + Wrap-Up (Days 9–10, extending into Weeks 3–4 April)

| Day | Focus | Activities | Exit Criteria |
|---|---|---|---|
| **Day 9** | **Documentation + Project Report** | Compile POC results against scorecard; document all test results with evidence; prepare formal project documentation for Charles | Draft report complete with all Required items scored |
| **Day 10** | **Final Review + Go/No-Go** | Present scorecard and project documentation to all stakeholders; review Optional test results; discuss production migration path | POC scorecard signed off; go/no-go recommendation; next steps agreed |

---

## 5. Success Criteria Matrix (Customer Scorecard)

This scorecard was confirmed with Zava during the scoping session (March 25, 2026). Charles Mylak requires formal project documentation including these results.

### Required — All Must Pass

| # | Criterion | Pass Condition | Pass/Fail | Notes |
|---|---|---|---|---|
| 1 | **Zone Migration** | Bind zones imported into Azure DNS; record counts match; all types (A, AAAA, CNAME, MX, TXT, SRV, NS, SOA) resolve correctly | ☐ | |
| 2 | **Audit Logging** | Activity Log captures all record changes with user identity + timestamp; DNS query logs flow to QRadar via Event Hub | ☐ | |
| 3 | **Reporting** | Azure Monitor Workbook dashboards show query volumes, top records, change history, and error rates | ☐ | |
| 4 | **Zone Snapshots** | On-demand zone export produces valid RFC 1035 file; scheduled export works via automation; re-import verified | ☐ | |
| 5 | **Certificate Integration (DCV)** | DigiCert `_dnsauth` TXT records automated for: single domain, subdomain, wildcard, multi-domain SAN; propagation under 60s; cleanup confirmed | ☐ | DigiCert CertCentral |

### Optional — Nice-to-Have

| # | Criterion | Pass Condition | Pass/Fail | Notes |
|---|---|---|---|---|
| 6 | **DNS Record Failover** | Traffic Manager Priority routing — primary down → automatic failover to secondary | ☐ | |
| 7 | **Weighted Load Balancing** | Traffic Manager Weighted routing — requests distribute per configured weights | ☐ | |
| 8 | **Geographic DNS** | Traffic Manager Geographic routing — US → US IP, UK → UK IP | ☐ | |
| 9 | **API Support** | Record CRUD demonstrated via Azure CLI, REST API, PowerShell, and Terraform | ☐ | |
| 10 | **DNSSEC** | Zone signed; `dig +dnssec` shows RRSIG records | ☐ | Not a requirement |

**POC Pass Threshold:** All 5 Required items pass. Optional items are informational — no impact on go/no-go.

---

## 6. Key Technical Details for the POC Team

### 6.1 Zone Import from Bind

```bash
# Export zone from Bind (on existing server)
named-checkzone Zava.com /etc/bind/zones/db.Zava.com > Zava.com.zone

# Import into Azure DNS
az network dns zone create -g rg-dns-poc -n poc.Zava.com
az network dns zone import -g rg-dns-poc -n poc.Zava.com -f Zava.com.zone
```

**Caveats:**  
- Azure DNS zone import expects RFC 1035 format. Most Bind exports are compliant, but test with `named-checkzone` first.
- SOA and NS records are auto-generated by Azure DNS — imported SOA/NS values are overwritten. This is expected.
- Max 10,000 record sets per zone (can increase via support request).

### 6.2 RBAC Roles

| Role | Scope | What It Allows |
|---|---|---|
| `DNS Zone Contributor` | Resource group or zone | Full zone management (create/delete zones + records) |
| `DNS Zone Record Set Contributor` (custom) | Individual zone | Manage record sets only; cannot create/delete zones |
| `Reader` | Resource group | View-only access to zones and records |

**Custom Role Definition (Operator):**
```json
{
  "Name": "DNS Record Operator",
  "Description": "Can manage DNS record sets but not zones",
  "Actions": [
    "Microsoft.Network/dnsZones/read",
    "Microsoft.Network/dnsZones/recordsets/*"
  ],
  "NotActions": [
    "Microsoft.Network/dnsZones/write",
    "Microsoft.Network/dnsZones/delete"
  ],
  "AssignableScopes": ["/subscriptions/{subscription-id}/resourceGroups/rg-dns-poc"]
}
```

### 6.3 Logging to QRadar SIEM

```
Azure DNS Zone
  → Diagnostic Settings
    → Category: DnsDiagnosticEvents (query logs)
    → Destination: Event Hub Namespace
      → Event Hub → IBM QRadar DSM (Microsoft Azure Event Hub protocol)
```

**Log fields available:** Query name, query type, client IP, response code, response time, zone name, timestamp.

**QRadar-specific setup:**
1. Create Event Hub namespace + hub in Azure (runbook Section 6)
2. Get Event Hub connection string (`RootManageSharedAccessKey`)
3. In QRadar: Admin → Log Sources → Add → Microsoft Azure Event Hub protocol
4. Configure: connection string, consumer group (`$Default`), Event Hub name
5. QRadar auto-parses Azure DNS diagnostic events into its event taxonomy
6. Create custom dashboards/reports in QRadar Pulse for DNS operational visibility

### 6.4 DNSSEC

```bash
# Enable DNSSEC signing on a zone
az network dns dnssec-config create -g rg-dns-poc -z poc.Zava.com

# Get the DS record to publish at the parent/registrar
az network dns dnssec-config show -g rg-dns-poc -z poc.Zava.com

# Validate
dig +dnssec poc.Zava.com @ns1-01.azure-dns.com
```

### 6.5 Geo-Based Routing (Traffic Manager)

```bash
# Create Traffic Manager profile with Geographic routing
az network traffic-manager profile create \
  -g rg-dns-poc \
  -n tm-Zava-geo \
  --routing-method Geographic \
  --unique-dns-name Zava-geo-poc

# Add endpoints with geo mappings
az network traffic-manager endpoint create \
  -g rg-dns-poc \
  --profile-name tm-Zava-geo \
  -n us-endpoint --type externalEndpoints \
  --target 1.2.3.4 \
  --geo-mapping "US"

az network traffic-manager endpoint create \
  -g rg-dns-poc \
  --profile-name tm-Zava-geo \
  -n uk-endpoint --type externalEndpoints \
  --target 5.6.7.8 \
  --geo-mapping "GB"
```

### 6.6 DigiCert DCV — Certificate Domain Validation

Zava uses **DigiCert CertCentral** for certificate management. DigiCert uses `_dnsauth` TXT records (not `_acme-challenge`).

```bash
# DigiCert DCV Flow:
# 1. Order cert in DigiCert CertCentral → get DCV random value (token)
# 2. Create _dnsauth TXT record in Azure DNS with that token
# 3. DigiCert validates → issues certificate
# 4. Clean up TXT record

DOMAIN="poc.Zava.com"
DCV_TOKEN="<digicert-dcv-random-value>"  # From DigiCert CertCentral order

# Create the _dnsauth TXT record
az network dns record-set txt add-record \
  -g rg-dns-poc -z $DOMAIN \
  -n "_dnsauth" \
  -v "$DCV_TOKEN"

# Verify it resolves (this is what DigiCert checks)
dig @ns1-01.azure-dns.com _dnsauth.$DOMAIN TXT +short

# After DigiCert validates, cleanup
az network dns record-set txt remove-record \
  -g rg-dns-poc -z $DOMAIN \
  -n "_dnsauth" \
  -v "$DCV_TOKEN"
```

**DigiCert ACME option:** DigiCert also offers an ACME endpoint (`https://acme.digicert.com/v2/acme/directory/`) for customers who want certbot/acme.sh compatibility with EAB credentials.

### 6.7 Zone Snapshots (Point-in-Time Export)

```bash
# On-demand zone snapshot
az network dns zone export \
  -g rg-dns-poc -n poc.Zava.com \
  -f "snapshot-poc-Zava-com-$(date +%Y%m%d-%H%M%S).zone"

# Verify snapshot is valid (re-import to a test zone)
az network dns zone create -g rg-dns-poc -n snapshot-test.poc.Zava.com
az network dns zone import -g rg-dns-poc -n snapshot-test.poc.Zava.com \
  -f snapshot-poc-Zava-com-*.zone

# Cleanup test zone
az network dns zone delete -g rg-dns-poc -n snapshot-test.poc.Zava.com --yes
```

**Scheduled snapshots:** Use Azure Automation (runbook on a schedule) or a cron job on an admin workstation to export zones daily/weekly.

### 6.8 Reporting — Azure Monitor Workbooks

```bash
# Enable Log Analytics workspace for richer reporting
az monitor log-analytics workspace create \
  -g rg-dns-poc -n la-dns-poc --location southcentralus

# Add Log Analytics as a second diagnostic destination
LA_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -g rg-dns-poc -n la-dns-poc --query id -o tsv)

az monitor diagnostic-settings create \
  --name "dns-logs-to-loganalytics" \
  --resource "$DNS_ZONE_ID" \
  --workspace "$LA_WORKSPACE_ID" \
  --logs '[{"category": "DnsDiagnosticEvents", "enabled": true}]'
```

Once logs flow to Log Analytics, build dashboards in Azure Monitor Workbooks:
- Query volume over time
- Top 10 queried record names
- Error rates (NXDOMAIN, SERVFAIL)
- Change history (Activity Log)
- Zone record count trends

---

## 7. Azure Services & Estimated POC Cost

| Service | Purpose | Estimated POC Cost |
|---|---|---|
| Azure DNS (Public Zones) | Authoritative DNS hosting | ~$0.50/zone/month + $0.40/M queries |
| Azure Traffic Manager | Geo-routing & load distribution | ~$0.75/M queries |
| Event Hub (Basic) | Log streaming to SIEM | ~$11/month (1 TU) |
| Azure Monitor / Diagnostic Settings | Query log capture | Included |
| RBAC / Entra ID | Role assignments | Included (no additional cost) |

**Total estimated POC cost: < $25 for the 2-week period** (assuming moderate query volumes)

---

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Bind zone file format incompatibility on import | Medium | Medium | Pre-validate with `named-checkzone`; manually fix any non-RFC records |
| SIEM connector not available for Event Hub | Low | High | Confirm SIEM vendor supports Event Hub ingestion before POC; fallback to Log Analytics + export |
| DNSSEC DS record publication blocked by registrar | Medium | Low | Use test domain if registrar doesn't support DS updates via API; document process for production |
| Geo-routing accuracy not meeting expectations | Low | Medium | Traffic Manager uses EDNS client subnet; accuracy depends on resolver behavior — set expectations |
| Competitive vendor POC delays push Azure POC timeline | Medium | Medium | Keep pre-POC tasks moving; be ready to start the day their other POC concludes |
| Limited Zava staff availability (only 2–3 DNS people) | Medium | Medium | Provide runbooks and scripts so POC can proceed even with limited hands-on time |

---

## 9. Competitive Positioning — Why Azure DNS Wins

Use these points throughout the POC engagement:

| Advantage | Detail |
|---|---|
| **Already in the ecosystem** | Zava has an enterprise landing zone — Azure DNS is a natural extension, not a new platform |
| **100% SLA** | Azure DNS offers a 100% availability SLA — the highest in the industry for managed DNS |
| **Global anycast network** | Queries answered from the nearest Azure edge node worldwide — no infrastructure to manage |
| **Native Azure integration** | RBAC, Azure Policy, Diagnostic Settings, Event Hub, Terraform, ARM/Bicep — all first-party |
| **Cost** | Dramatically cheaper than running Bind servers in a DMZ (hardware, patching, personnel) |
| **DNSSEC built-in** | Managed DNSSEC — no key rotation complexity |
| **Infrastructure as Code** | Full Terraform/Bicep/CLI support for zone and record lifecycle — fits DevOps workflows |
| **Zero maintenance** | No OS patching, no Bind upgrades, no DMZ firewall rules to maintain |

---

## 10. Action Items — Post-Scoping Session (March 25, 2026)

| # | Action | Owner | Due | Status |
|---|---|---|---|---|
| 1 | Confirm POC start date (target: week of April 7) | Charles Mylak / Noel | March 28 | Pending |
| 2 | Select POC domain/subdomain | Jeremy | March 28 | Pending |
| 3 | Export 2–3 Bind zone files (RFC 1035 format) | Jeremy / Matt / Mike | Before Day 1 | Pending |
| 4 | Confirm QRadar Event Hub DSM connector availability | Zava Security team | Before Day 1 | Pending |
| 5 | Provision `rg-dns-poc` resource group in landing zone | Zava Platform team | Before Day 1 | Pending |
| 6 | Identify Operator + Admin test accounts for RBAC | Jeremy | Before Day 1 | Pending |
| 7 | Share DigiCert CertCentral workflow details (API access, current DCV process) | Jeremy / Matt | Before Day 1 | Pending |
| 8 | Schedule Phase 1/2/3 checkpoint calls | Kim / Charles | March 28 | Pending |
| 9 | Deliver updated POC runbook and documentation to Zava team | Kim / Microsoft | 2 days before Day 1 | Pending |
| 10 | Define project documentation format requirements | Charles Mylak | Before Day 1 | Pending |

---

## 11. Meeting Cadence During POC

| Touchpoint | When | Who | Purpose |
|---|---|---|---|
| **Kickoff** | Day 1 | All (Jeremy, Mike, Matt, Kim) | Environment walkthrough + zone import |
| **Mid-POC Check** | Day 5 | Jeremy, Mike, Matt, Kim | Phase 1 results review; Phase 2 planning |
| **Final Review** | Day 10 | All + Charles, Noel | POC scorecard review; project documentation review; go/no-go |
| **Async Support** | Daily | Kim + Jeremy (Teams) | Unblock issues in real-time |

---

## 12. Post-POC — If It's a Go

If the POC passes:

1. **Migration Planning Workshop** — Map all production zones; build cutover sequence  
2. **NS Delegation Cutover** — Gradual cutover (zone by zone) by updating NS records at registrar  
3. **Parallel Run** — Run Azure DNS alongside Bind for a validation window before decommissioning  
4. **Decommission Bind** — Remove Bind servers from DMZ after validation period  
5. **Operational Handoff** —  RBAC finalization, runbooks, and SOP documentation for Zava's broader team  

---

*This document is a living artifact — update after each POC checkpoint.*
