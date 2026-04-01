---
description: "Deploy the Azure DNS POC — interactive guide that checks Azure login, selects deployment method, runs pre-flight checks, deploys, and validates."
agent: "agent"
argument-hint: "Which deployment method? (e2e, bicep, powershell, bash)"
---
# Deploy Azure DNS POC

## Steps

1. **Pre-flight**: Verify Azure CLI login, subscription, and region availability
2. **Select method**: Based on input or recommend based on environment
3. **Deploy**: Run the selected deployment script
4. **Validate**: Check all resources deployed correctly

## Deployment Methods

| Input | Script | Command |
|-------|--------|---------|
| `e2e` | [Zava_DNS_POC_E2E.ps1](../Zava_DNS_POC_E2E.ps1) | `.\Zava_DNS_POC_E2E.ps1 -Phase All` |
| `bicep` | [infrastructure/deploy.ps1](../infrastructure/deploy.ps1) | `cd infrastructure; .\deploy.ps1` |
| `powershell` | [Zava_DNS_POC_Deployment.ps1](../Zava_DNS_POC_Deployment.ps1) | Copy-paste section by section |
| `bash` | [Zava_DNS_POC_Runbook.sh](../Zava_DNS_POC_Runbook.sh) | Copy-paste section by section |

## Pre-flight Checklist

- [ ] `az account show` — correct subscription?
- [ ] `az group exists --name rg-dns-poc` — clean slate? (should be `false`)
- [ ] `domain-contact-info.json` exists (if buying domain)
- [ ] No stale subscription-level diagnostic settings

## After Deployment

Verify with: `az resource list -g rg-dns-poc -o table`
Expected: 12+ resources (DNS zones, Event Hub, KV, Web Apps, TM profiles)
