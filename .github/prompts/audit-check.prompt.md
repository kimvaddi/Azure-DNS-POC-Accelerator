---
description: "Audit the current Azure deployment against the 46-finding audit report and 26 live testing findings. Reports which are resolved vs outstanding."
agent: "agent"
argument-hint: "Check deployment against audit findings"
---
# Audit Check

Compare the current deployment state against known findings.

## Data Sources

1. [AUDIT_REPORT_2026-03-29.md](../AUDIT_REPORT_2026-03-29.md) — 46 findings (14 critical)
2. [REMEDIATION_PLAN.md](../REMEDIATION_PLAN.md) — 4-phase remediation roadmap
3. Live testing findings (documented in script headers):
   - [Zava_DNS_POC_E2E.ps1](../Zava_DNS_POC_E2E.ps1) header — E2E findings
   - [Zava_DNS_POC_Deployment.ps1](../Zava_DNS_POC_Deployment.ps1) header — 14 original findings

## What to Check

1. List deployed resources: `az resource list -g rg-dns-poc -o table`
2. For each audit finding, check if the resource/config exists and meets the requirement
3. Report: RESOLVED / OUTSTANDING / NOT APPLICABLE for each finding
4. Highlight any new issues discovered

## Output Format

Table with: Finding ID | Severity | Description | Status | Evidence
