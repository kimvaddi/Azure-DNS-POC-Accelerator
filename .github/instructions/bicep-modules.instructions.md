---
description: "Use when editing Bicep files for Azure DNS POC. Enforces parameter decorators, subscription-scope patterns, naming conventions, and known deployment fixes."
applyTo: "infrastructure/**/*.bicep"
---
# Bicep Module Guidelines

## Parameters
- Every parameter MUST have `@description()` decorator
- Use `@maxLength()`, `@minValue()`, `@maxValue()`, `@allowed()` where appropriate
- Globally unique names: use `uniqueString(subscription().subscriptionId)` or deterministic suffix (e.g., `zava2026`)
- Key Vault name: `kv-dns-poc-zava2026` (single instance, shared across all methods)

## Subscription-Scope Templates
- Set `targetScope = 'subscription'` at top
- Create resource group as a resource, then scope modules to it
- Conditional modules use `= if (param)` syntax with `!` non-null assertion on outputs

## Known Deployment Fixes (from live FDPO testing)
- Do NOT set `enablePurgeProtection: false` on Key Vault — omit the property entirely
- Do NOT include empty `captureDescription` on Event Hub — remove the block
- Do NOT include `AppServiceFileAuditLogs` in web app diagnostics — not supported on Linux B1
- CNAME TTL for Traffic Manager: always set to 30 (not default 3600)
- `@secure()` decorator required on all connection string outputs

## Naming Convention
- Resources: `<service>-<environment>` kebab-case (e.g., `law-dns-poc`, `ehns-dns-poc`)
- Tags: always include `project`, `customer`, `environment`, `managed-by`

## References
- Bicep best practices: https://learn.microsoft.com/azure/azure-resource-manager/bicep/best-practices
- DNSSEC: https://learn.microsoft.com/azure/dns/dnssec-how-to
