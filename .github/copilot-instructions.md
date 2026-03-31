# Project Guidelines — Zava Azure DNS POC

## Context

This workspace contains customer-facing engagement materials for **Zava Energy Corporation's Azure DNS POC** — a competitive evaluation to replace aging Bind-based DNS servers with Azure DNS. This is **not a code repository**; it's a collection of plans, runbooks, guides, and agendas supporting a Microsoft account team's customer engagement.

**Customer:** Zava Energy Corporation (HQ: San Antonio, TX)  
**Microsoft Contact:** Kim Vaddi (Account Team)  
**Key Customer Contacts:** Jeremy (Primary Technical), Mike (Technical Stakeholder), Matt Boulder (Engineer), Charles Mylak (PM — requires formal project documentation for go/no-go decision in weeks 3–4 of April), Noel (Coordination)  
**POC Target:** 3-phase engagement, wrap-up weeks 3–4 of April 2026  
**Competitive Context:** Azure DNS is evaluated against at least one other vendor — Azure must be faster, cleaner, and more compelling.  
**SIEM:** IBM QRadar (via Event Hub)  
**Certificate Authority:** DigiCert CertCentral (DCV uses `_dnsauth` TXT records; ACME endpoint also available at `acme.digicert.com`)

## Project Type & AI Agent Guidance

**This is NOT a software development project.** It's a **deployment automation + documentation project** for a time-boxed POC. AI agents should:

- **Prefer reading/analyzing over creating** — Most answers are already in existing docs/scripts
- **When generating scripts:** Follow copy-paste execution pattern (section-by-section with verification)
- **When editing deployment scripts:** Preserve section structure, verification steps, and extensive comments
- **When asked about deployment:** Reference the appropriate method (Bicep vs PowerShell vs Bash) based on context
- **When troubleshooting:** Check the "Known Issues" section in deployment script headers first (14+ findings already documented)
- **When validating deployments:** Cross-check against `AUDIT_REPORT_2026-03-29.md` (46 findings) and `REMEDIATION_PLAN.md`
- **When handling secrets:** Use the Key Vault zero-secret pattern — retrieve DigiCert API keys at runtime via `az keyvault secret show`, never pass as CLI parameters or expose in logs. See `Zava_DCV_Automation.ps1` for reference.
- **When scripting cleanup:** Follow dependency order: DNSSEC config → Resource Locks → Resource Group. See `Zava_DNS_POC_Cleanup.ps1`.

## Three Deployment Options

This POC supports three deployment paths — choose based on customer preference and environment:

| Method | When to Use | Pros | Cons | Time |
|--------|-------------|------|------|------|
| **Bicep (IaC)** | Customer wants repeatable, declarative infrastructure | Fastest, idempotent, version-controlled | Requires Bicep knowledge, less visibility into individual steps | ~15 min |
| **PowerShell** | Customer is Windows-based, wants step-by-step control | Battle-tested (14 issues fixed), extensive inline docs, can pause/resume | Manual execution, requires copy-paste discipline | ~45 min |
| **Bash** | Customer is Linux/Mac-based, wants shell scripting | Includes 9-test DCV proof suite, full-cycle timing | Manual execution, longer than Bicep | ~60 min |

**AI Agent Rule:** When asked "how do I deploy?", recommend Bicep for speed, PowerShell for Windows teams wanting visibility, Bash for Linux teams. See `infrastructure/README.md` (Bicep guide) and `README.md` (all three methods).

## Workspace Structure

### Core Documentation
| File | Purpose |
|------|---------|
| `README.md` | Solution accelerator overview — deployment options, cost estimate, what gets deployed |
| `DNS_POC_Core Ask from the Customer.txt` | Raw customer requirements and success criteria (source of truth for what Zava needs) |
| `Zava DNS POC Scope _3_25_2026.txt` | Workstream catalog, pre-POC task matrix with owners/dates, and prep checklist (output of March 25 scoping session) |
| `Zava_Azure_DNS_POC_Plan.md` | Full POC scope, architecture, 3-phase timeline, success scorecard, risks, and competitive positioning |
| `Zava_DCV_Walkthrough_Guide.md` | Beginner-friendly guide explaining DCV (Domain Control Validation), certificate workflows, and step-by-step instructions for Jeremy & Matt |
| `Zava_DNS_POC_Scoping_Session_Agenda.md` | 60-minute scoping session agenda with talking points, questions to ask, and decision templates |
| `DCV_Gap_Analysis.md` | Gap analysis and automation opportunities for DigiCert DCV workflows |
| `DNS_POC_Solution_Accelerator_Discovery.md` | Discovery document — kimvaddi.com reference analysis + gap mapping |

### Audit & Remediation (Post-Kickoff)
| File | Purpose |
|------|---------||
| `AUDIT_REPORT_2026-03-29.md` | Security & WAF audit — **46 findings** (14 critical). Organized by Security, Network, Ops, Reliability, Docs, Code Quality |
| `REMEDIATION_PLAN.md` | 4-phase implementation roadmap for all 46 findings with line numbers, testing, and rollback steps |

### Deployment Scripts
| File | Lines | Status |
|------|-------|--------|
| `Zava_DNS_POC_E2E.ps1` | 900+ | ✅ **Push-button E2E** — Domain purchase → Bicep → DNSSEC → Let's Encrypt → Validation |
| `letsencrypt-cert.sh` | 280+ | ✅ Standalone Let's Encrypt cert automation (staging → prod → KV import) |
| `Zava_DNS_POC_Deployment.ps1` | 2,000+ | ✅ **Battle-tested** — PowerShell (16 sections + feature flags for LE/DNSSEC/private DNS) |
| `Zava_DNS_POC_Runbook.sh` | 2,100+ | ✅ Bash/az CLI runbook (13 sections + feature flags + 9-test DCV suite) |
| `Zava_DCV_Automation.ps1` | — | 🔧 DigiCert DCV automation (Key Vault + cert lifecycle) |
| `cert-renewal-runbook.ps1` | — | 🔧 Generated scaffold — scheduled cert renewal via Key Vault + DigiCert (awaits customer credentials) |
| `Zava_DNS_POC_Cleanup.ps1` | 182 | 🔧 Dependency-ordered cleanup (must remove: DNSSEC → Locks → RG in that order) |

### Infrastructure-as-Code (Bicep)
| Path | Purpose |
|------|---------|
| `infrastructure/main.bicep` | Subscription-scope template — deploys all 35 resources declaratively |
| `infrastructure/main.bicepparam` | Parameters file (Bicep native format — **preferred**) |
| `infrastructure/main.parameters.json` | Parameters file (JSON alternative) |
| `infrastructure/deploy.ps1` | Automated Bicep deployment script (validate / what-if / deploy) |
| `infrastructure/modules/` | 12 reusable Bicep modules (DNS, Event Hub, TM, Web Apps, RBAC, etc.) |
| `infrastructure/README.md` | Bicep deployment guide — see this for IaC approach |
| `infrastructure/QUICK_REFERENCE.md` | Operator command cheat sheet |
| `infrastructure/PROJECT_STRUCTURE.md` | Detailed IaC file descriptions |

### Reference Files
| File | Purpose |
|------|---------|
| `sample-bind-zone.txt` | Sample Bind zone file (RFC 1035) with all record types |
| `dns-operator-role.json` | Custom RBAC role definition for DNS record operators |
| `DNS_POC_Architecture.drawio` | Architecture diagram (open in draw.io or VS Code extension) || `HighLevelASD.drawio` | 3-page high-level architecture (Resource Group, DNS, Compute, TM, Security, Observability layers) |
| `infrastructure/main.json` | Compiled ARM template — auto-generated from `main.bicep` via `az bicep build` (**do not edit manually**) |
## Conventions

- **Audience is the customer team** (Jeremy, Matt) and internal Microsoft stakeholders (Kim). Write for DNS practitioners who are new to Azure, not Azure experts.
- **Azure region:** `southcentralus` (closest to Zava HQ in San Antonio).
- **Resource group:** `rg-dns-poc` inside Zava's existing Enterprise Landing Zone.
- **POC domain:** `poc.zava-dnspoc.com` (public), `poc-internal.zava-dnspoc.local` (private).
- **Scripts use Azure CLI** (`az` commands). PowerShell alternatives are provided where noted.
- Variables in the runbook use `UPPER_SNAKE_CASE` and must be set in Section 0 before execution.
- Placeholders use angle brackets: `<subscription-id>`, `<tenant-id>`, etc.

## Writing Style

- Direct, confident, no filler — every sentence should be actionable or informative.
- Use tables for structured data (scope items, success criteria, role definitions).
- Use ASCII diagrams for architecture (no image dependencies).
- Scripts must be **copy-paste ready** with clear section headers and comments.
- Include `echo` statements in scripts so the operator can follow progress.
- Always pair a "create" operation with a "verify" step (e.g., create DNS record → dig/nslookup to confirm).

## Azure DNS Technical Notes

- Azure DNS zone import expects **RFC 1035** format — validate Bind exports with `named-checkzone` first.
- SOA and NS records are auto-generated by Azure; imported values are overwritten (expected behavior).
- RBAC uses `DNS Zone Contributor` (admin) and a custom `DNS Record Operator` role (operator).
- DCV testing covers **9 proof tests**: DigiCert `_dnsauth` and ACME `_acme-challenge` conventions — single domain, subdomain, wildcard (RFC 8555), multi-domain SAN (parallel challenges), full-cycle timing (create → propagate → cleanup), and certbot dry-run integration. Each test produces a PASS/FAIL verdict with timing data.
- Logging path: DNS Zone → Diagnostic Settings → Event Hub → IBM QRadar (DSM connector).
- Reporting: Azure Monitor Workbooks + Log Analytics for operational dashboards.
- Zone Snapshots: `az network dns zone export` for point-in-time backups.
- DNSSEC: Optional. `az network dns dnssec-config create` to sign, then publish DS record at registrar.
- Geo-routing uses **Traffic Manager** with Geographic routing method (DNS-level, not application-level).
- DNS Failover uses **Traffic Manager** with Priority routing method. **Set CNAME TTL to 30s** for failover scenarios (default 3600s is too slow).
- POC deploys **3 Traffic Manager profiles** (Priority, Geographic, Weighted) — each independently testable.
- QRadar integration requires **4 resources**: Event Hub namespace + Send/Listen SAS policies + consumer group + storage account.
- Bicep parameter format: prefer `.bicepparam` (native) over `.parameters.json`. Both are provided.
- Pre-flight checks: Both deployment scripts validate Azure CLI version, login state, subscription, and region availability before executing. Agents should do the same.
- Bash runbook includes **9-test DCV proof suite** (more rigorous than PowerShell DCV section) — prefer Bash for cert automation testing.

## Success Criteria Tiers

- **Required (all must pass):** Zone Migration, Audit Logging, Reporting, Zone Snapshots, Certificate Integration (DCV)
- **Optional (at least 1 must pass):** DNS Record Failover, Weighted Load Balancing, Geographic DNS, API/Automation Support, DNSSEC

## Engagement Cadence

- **Kickoff:** Day 1 — align on scope, confirm pre-POC readiness
- **Mid-POC Check:** Day 5 — review Required workstream progress, address blockers
- **Final Review:** Day 10 — demo results, present scorecard, discuss go/no-go
- **Async support:** Daily via Teams channel

## Key Constraints

- **No production domains in POC** — use `poc.zava-dnspoc.com` subdomain only.
- **No registrar NS delegation changes** during POC.
- **POC cost target:** ~$27 for the 2-week period (API-verified: App Service B1 x2 = $13.44, Event Hub Standard = $10.08, everything else < $3).
- **Competitive sensitivity:** Don't disparage other vendors. Lead with Azure's strengths (100% SLA, native integration, zero maintenance, global anycast).
