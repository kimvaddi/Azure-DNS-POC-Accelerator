---
description: "Use when editing DCV automation, certificate renewal, or Let's Encrypt scripts. Enforces Key Vault zero-secret pattern, credential cleanup, and certbot-dns-azure configuration."
applyTo: "**/Zava_DCV*.ps1,**/cert-renewal*.ps1,**/letsencrypt*.sh"
---
# DCV & Certificate Script Guidelines

## Zero-Secret Pattern (MANDATORY)
- NEVER pass credentials as CLI parameters
- NEVER display secrets in console output (Write-Host, echo)
- ALWAYS retrieve from Key Vault at runtime: `az keyvault secret show --vault-name $KV --name <name> --query value -o tsv`
- ALWAYS clear variables after use: `$secret = $null` (PS) or `unset SECRET` (Bash)
- ALWAYS delete temp credential files (azure-certbot.ini) in cleanup/trap

## Key Vault Secret Names (standard across all scripts)
- `certbot-sp-client-id` — Service Principal app ID
- `certbot-sp-client-secret` — SP password (or cert if using --create-cert)
- `certbot-sp-tenant-id` — Entra tenant ID
- `digicert-api-key` — DigiCert CertCentral API key (customer provides)
- `digicert-org-id` — DigiCert Organization ID (customer provides)
- `eventhub-connection-string` — Event Hub connection string

## certbot-dns-azure Configuration
- Config file: temp file with `chmod 600`, deleted after use
- Plugin: `certbot-dns-azure` (pip install certbot certbot-dns-azure)
- Propagation wait: 60 seconds (`--dns-azure-propagation-seconds 60`)
- Always run staging dry-run before production cert
- Ref: https://docs.certbot-dns-azure.co.uk/en/latest/

## FDPO Tenant Limitation
- Password credentials blocked by policy — use `--create-cert --keyvault` for SP creation
- Certificate credential stored in Key Vault automatically
