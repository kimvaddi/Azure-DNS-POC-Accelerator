# Zava — Azure DNS POC Scoping Session

**Meeting Type:** POC Scoping & Commitment Session  
**Customer:** Zava Energy Corporation  
**Date:** March 25, 2026 (COMPLETED)  
**Duration:** 60 minutes  
**Format:** Teams / In-Person  
**Status:** COMPLETED — Scope confirmed, scorecard agreed  

---

**Attendees:**

| Name | Role | Organization |
|---|---|---|
| Jeremy | Primary Technical Contact | Zava |
| Mike | Technical Stakeholder | Zava |
| Matt Boulder | Technical Engineer | Zava |
| Charles Mylak | Project Manager (requires project documentation) | Zava |
| Noel | Coordination / Paperwork | Zava |
| Kim Vaddi | Account Team | Microsoft |

---

**Key Decisions from This Session:**

| Decision | Detail |
|---|---|
| SIEM | IBM QRadar (Event Hub → QRadar DSM) |
| Certificate Authority | DigiCert CertCentral (DCV uses `_dnsauth` TXT records) |
| DNSSEC | Optional — not a requirement |
| Timeline | Wrap-up weeks 3–4 of April 2026 |
| Required items | Zone Migration, Audit Logging, Reporting, Zone Snapshots, Certificate Integration (DCV) |
| Optional items | DNS Record Failover, Weighted Load Balancing, Geographic DNS, API Support, DNSSEC |

---

## Meeting Objective

Walk out with **three things agreed:**
1. A defined POC scope (what's in, what's out)
2. Agreed success criteria (the scorecard)
3. A committed start date and pre-POC task owners

This is NOT a demo or deep-dive. Trust-building is done (Jan 28 demo, Feb 12 onsite). Today we convert momentum into a committed POC.

---

## Agenda

### 1. Opening & Context Alignment (5 min)

**Speaker:** Kim  
**Purpose:** Frame the conversation — this is the session where we lock in the plan.

Talking points:
- "We've done the demo, we've done the onsite — today we define the POC so your team can execute."
- Acknowledge the competitive eval: "We know you're finishing another vendor's POC. Our goal is to make the Azure POC fast, low-friction, and conclusive."
- Confirm the landing zone is stood up — "You've already done the hard part. DNS is a natural next step inside that foundation."

**Transition:** _"Let's confirm what we're testing and what success looks like."_

---

### 2. Scope Confirmation — What's In, What's Out (15 min)

**Speaker:** Kim (presenting), Jeremy & Matt (validating)  
**Purpose:** Walk through the proposed scope table and get explicit agreement.

**Present the 3-tier scope model:**

**MUST-TEST (Core — all 6 must pass for POC success):**

| # | Workstream | One-Line Description |
|---|---|---|
| 1 | Bind Parity | Authoritative lookups — all record types (A, AAAA, CNAME, MX, TXT, SRV, NS, SOA) |
| 2 | Zone Import | Import 2–3 Bind zone files into Azure DNS, verify record counts |
| 3 | RBAC & Delegation | Operator role (records only) vs Admin role (full zone control) |
| 4 | Automated Record Creation | Scripted DNS record CRUD via CLI/API/Terraform |
| 5 | DCV TXT Automation (Certs) | Automated _acme-challenge TXT record creation for certificate domain validation — single domain, subdomain, wildcard, and multi-domain SAN certs — with proven resolution and cleanup |
| 6 | DNS Logging → SIEM | Query logs flow to Zava's SIEM via Event Hub |
| 7 | Propagation & Latency | Update latency and propagation timing acceptable |

**SHOULD-TEST (Stretch — at least 1 should pass):**

| # | Workstream | One-Line Description |
|---|---|---|
| 8 | DNSSEC | Zone signing + DS record publication + chain of trust validation |
| 9 | Geo-Based Routing | Traffic Manager geographic routing — UK → UK IP, US → US IP |

**NICE-TO-HAVE (Informational):**

| # | Workstream | One-Line Description |
|---|---|---|
| 10 | Lightweight Load Distribution | Weighted/performance routing via Traffic Manager |
| 11 | Private DNS Coexistence | Document how public + private DNS zones work together in the landing zone |

**OUT OF SCOPE:**
- Production migration, registrar changes, recursive DNS, full GSLB, DDoS stress testing

**Questions to ask:**
- _"Does this match what you had internally? Anything missing from your list?"_
- _"Are we aligned that Bind parity is the minimum bar?"_
- _"Is DNSSEC a must-have or a should-have for this POC?"_ (Confirm priority)
- _"For geo — do you have specific endpoints in UK and US we can test against?"_
- _"For DCV/cert validation — which ACME client or CA are you using today? (certbot, acme.sh, Venafi, DigiCert?)"_
- _"Do you need to prove wildcard certs and multi-domain SAN certs, or just single-domain?"_
- _"Is the cert validation workflow manual today, or already scripted against Bind?"_

**Decision needed:** Confirm scope — thumbs up or adjustments.

---

### 3. Success Criteria Scorecard (10 min)

**Speaker:** Kim (presenting), Charles (confirming on PM side)  
**Purpose:** Agree on the exact scorecard that determines pass/fail.

**Present the scorecard:**

| # | Criterion | Priority | Pass Condition |
|---|---|---|---|
| 1 | Bind-equivalent lookups (all record types) | **MUST** | 100% record type parity via dig/nslookup |
| 2 | Zone import (2+ zones) | **MUST** | Record counts match source; no data loss |
| 3 | RBAC separation (Operator vs Admin) | **MUST** | Operator cannot create/delete zones; Admin can |
| 4 | Automated record CRUD (CLI/API/Terraform) | **MUST** | Scripted create/read/update/delete lifecycle works |
| 5 | **DCV TXT automation for certificates** | **MUST** | Automated _acme-challenge TXT creation + dig proof for: (a) single domain, (b) subdomain, (c) wildcard, (d) multi-domain SAN, (e) cleanup confirmed — with measured propagation time |
| 6 | DNS query logs in SIEM | **MUST** | Logs visible and queryable in existing SIEM |
| 7 | Propagation latency acceptable | **MUST** | Updates propagate within documented Azure DNS SLAs |
| 8 | DNSSEC signing and validation | **SHOULD** | dig +dnssec validates chain of trust |
| 9 | Geo-based routing works | **SHOULD** | Different geos resolve to correct endpoints |
| 10 | Weighted load distribution | **NICE** | Requests distribute per configured weights |
| 11 | Private DNS model documented | **NICE** | Team understands public/private coexistence |
| 12 | API/CLI management experience | **MUST** | Team finds management workflow acceptable |

**Pass threshold:** All MUSTs pass + at least 1 SHOULD passes.

**Questions to ask:**
- _"Is this the list your team has internally, or do you have additional criteria?"_
- _"Who signs off on the go/no-go at the end — Charles? Jeremy? Someone else?"_
- _"Is there a formal report format you need, or does a filled-in scorecard work?"_

**Decision needed:** Scorecard agreed — this is the contract for what "success" means.

---

### 4. Timeline, Logistics & Pre-POC Tasks (15 min)

**Speaker:** Kim (leading), Charles & Jeremy (committing)  
**Purpose:** Lock in dates and assign pre-POC homework.

#### Proposed Timeline

```
NOW ──────────────────── POC START ─────────────────── POC END
│                           │                            │
│  Pre-POC Tasks            │  Week 1: Core              │  
│  (1–2 weeks)              │  Week 2: Advanced          │
│                           │                            │
│  Zone exports              Day 1: Setup + Import       Day 10: Scorecard
│  SIEM details              Day 2: Bind Parity           + Go/No-Go
│  RG provisioned            Day 3: RBAC
│  Test accounts             Day 4: Automation
│  Domain confirmed          Day 5: Logging/SIEM ← MID-CHECK
│                            Day 6: DNSSEC
│                            Day 7: Geo Routing
│                            Day 8: Load + Private DNS
│                            Day 9: Edge Cases
│                            Day 10: Wrap-Up
```

#### Pre-POC Tasks (Must Complete Before Day 1)

| # | Task | Owner | Due |
|---|---|---|---|
| 1 | Confirm POC domain/subdomain (e.g., `poc.zava-dnspoc.com` or a test domain) | Jeremy | 1 week before start |
| 2 | Export 2–3 representative Bind zone files (RFC 1035 format) | Jeremy / Matt | 1 week before start |
| 3 | Confirm SIEM type and Event Hub compatibility (Splunk? Sentinel? QRadar?) | Zava Security team | 1 week before start |
| 4 | Provision resource group `rg-dns-poc` in the enterprise landing zone | Zava Platform team | 3 days before start |
| 5 | Identify 2 Entra ID test accounts: 1 "Operator" + 1 "Admin" for RBAC | Jeremy | 3 days before start |
| 6 | Share ACME/cert validation workflow details (provider, flow, expectations) | Jeremy / Matt | 1 week before start |
| 7 | Confirm geo-routing test endpoints (UK IP, US IP) if testing geo | Jeremy | 1 week before start |

**Questions to ask:**
- _"When does your other vendor's POC wrap up?"_
- _"Can we target [specific date] for Day 1?"_
- _"Jeremy — can you have the zone files and domain confirmed by [date]?"_
- _"Who on your platform team provisions the resource group? Do they need a ticket?"_

**Decision needed:** Start date committed. Pre-POC task owners assigned with dates.

---

### 5. Meeting Cadence & Support Model (5 min)

**Speaker:** Kim  
**Purpose:** Set expectations for how we'll work together during the POC.

| Touchpoint | When | Who | Purpose |
|---|---|---|---|
| **Kickoff** | Day 1 morning | All | Environment walkthrough, zone import, first validation |
| **Mid-POC Check** | Day 5 afternoon | Jeremy, Matt, Kim | Week 1 results review; adjust Week 2 plan if needed |
| **Final Review** | Day 10 | All + Charles, Noel | Scorecard review, go/no-go discussion |
| **Async Support** | Daily (Teams chat) | Kim ↔ Jeremy | Real-time unblocking, Q&A |

**Offer:** _"We'll provide a runbook with copy-paste scripts for every workstream so your team can move fast without waiting on us."_

**Question to ask:**
- _"Does this cadence work? Do you want more touchpoints or fewer?"_

---

### 6. Competitive Framing — Why Azure DNS (5 min)

**Speaker:** Kim  
**Purpose:** Reinforce Azure's advantages without being salesy. Subtle, factual, confident.

Key points (weave into conversation, don't present as a slide):

| Point | What to Say |
|---|---|
| **Already in the platform** | "Your landing zone is Azure. DNS is a config change, not a new platform decision." |
| **100% SLA** | "Azure DNS is the only major cloud DNS with a 100% availability SLA." |
| **Global anycast** | "Queries are answered from the nearest edge — 60+ regions, no infra to manage." |
| **Native integration** | "RBAC, Policy, Terraform, Bicep, Event Hub logging — all first-party. No glue code." |
| **Zero maintenance** | "No Bind upgrades, no OS patches, no DMZ firewall rules. That's the operational win." |
| **Cost** | "The entire POC will cost under $25. Production will be pennies per zone." |

**Don't say:**
- Don't trash the other vendor — stay above it
- Don't promise features that aren't GA (check DNSSEC GA status before the call)
- Don't oversell geo-routing — Traffic Manager is DNS-level, not application-level

---

### 7. Wrap-Up & Commitments (5 min)

**Speaker:** Kim  
**Purpose:** Summarize decisions, confirm action items, lock in next step.

**Recap template:**

> "To confirm what we agreed today:
> - **Scope:** [6 must-test + 2 should-test + 2 nice-to-have] — is that right?
> - **Success criteria:** The scorecard we walked through — all MUSTs pass, at least 1 SHOULD.
> - **Start date:** [confirmed date]
> - **Pre-POC tasks:** [owner assignments confirmed]
> - **Next touchpoint:** [kickoff date/time]"

**Action items to capture:**

| # | Action | Owner | Due |
|---|---|---|---|
| 1 | Send POC plan document to Zava team | Kim | Same day |
| 2 | Send runbook with scripts to Jeremy & Matt | Kim | 2 days before Day 1 |
| 3 | Complete all pre-POC tasks | Zava team | Per dates above |
| 4 | Send calendar invites for Kickoff, Mid-Check, Final Review | Kim / Charles | Within 2 days |
| 5 | Confirm any additional Zava success criteria not covered | Jeremy / Charles | Within 1 week |

**Closing line:**  
_"We'll make this the fastest, cleanest POC you've run. The landing zone is ready, the scripts are ready — let's lock in the date and go."_

---

## Appendix: Scoping Session Prep Checklist (For Kim)

Before the meeting, confirm:

- [ ] POC plan document is polished and ready to share
- [ ] Runbook with scripts is drafted (can refine after scoping)
- [ ] DNSSEC GA status confirmed for Azure DNS
- [ ] Traffic Manager geographic routing capability confirmed (it is GA)
- [ ] Azure DNS diagnostic settings → Event Hub flow confirmed
- [ ] Know Zava's SIEM vendor (ask Noel/Jeremy before if possible)
- [ ] Know when the other vendor's POC ends (ask Charles/Noel)
- [ ] Have pricing estimate ready ($0.50/zone/month, $0.40/M queries)
- [ ] Calendar holds are placed for proposed kickoff, mid-check, final review

---

## Slide Deck Skeleton (If Presenting Visually)

If you want to build a short slide deck from this agenda:

| Slide # | Title | Content |
|---|---|---|
| 1 | **Title** | "Zava Azure DNS POC — Scoping Session" + date, attendees |
| 2 | **Objective** | "Walk out with: Scope, Success Criteria, Start Date" |
| 3 | **Context** | One-liner: Bind replacement → Azure DNS POC. Landing zone ready. |
| 4 | **Scope — Must-Test** | Table of 6 must-test workstreams |
| 5 | **Scope — Should/Nice** | Table of 4 should/nice workstreams + out-of-scope list |
| 6 | **Success Scorecard** | Full 11-item scorecard with MUST/SHOULD/NICE |
| 7 | **Timeline** | 2-week visual (ASCII or Gantt-style) |
| 8 | **Pre-POC Tasks** | Task table with owners and dates |
| 9 | **Meeting Cadence** | Kickoff → Mid-Check → Final Review |
| 10 | **Why Azure DNS** | 4-5 bullet points — 100% SLA, native integration, zero maint, cost |
| 11 | **Next Steps** | Action items + "Let's lock in the date" |

Keep it to 11 slides max. No animations. No filler. Every slide earns its place.

---

*This agenda is designed to run tight at 60 minutes. If the conversation runs long on scope (section 2), borrow time from competitive framing (section 6) — they already know why Azure; today is about commitment.*
