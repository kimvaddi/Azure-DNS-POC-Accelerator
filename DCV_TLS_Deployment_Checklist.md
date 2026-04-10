# DCV and TLS Deployment Checklist (Let's Encrypt ACME)

This checklist reflects the current implementation in this repository.

## Scope

The main deployment now supports the full flow:

1. Create or reuse ACME account with Let's Encrypt.
2. Perform DNS-01 DCV in Azure DNS.
3. Issue wildcard certificate for `*.zava-dnspoc-001.com`.
4. Import certificate into Key Vault (`kv-dcv-poc` by default in this environment).
5. Import certificate to both App Services.
6. Bind SNI TLS to all three custom hostnames on both apps.

This automation is implemented through `deploymentScripts` in the main Bicep deployment.

## Files That Implement the Flow

- `infrastructure/main.bicep`
- `infrastructure/main.bicepparam`
- `infrastructure/modules/lets-encrypt-automation.bicep`
- `infrastructure/modules/web-app-hostname-bindings.bicep`

## Required Parameters

In `infrastructure/main.bicepparam` ensure these are set:

```bicep
param deployWebApps = true
param enableLetsEncryptAutomation = true
param letsEncryptContactEmail = 'dmauser@hotmail.com'
param keyVaultName = 'kv-dcv-poc'
param letsEncryptCertificateName = 'le-wildcard-zava'
```

Optional behavior controls:

```bicep
param enableCustomDomainTls = true
param customDomainCertificateThumbprint = '<existing-thumbprint-or-empty>'
param enableDnsZoneLock = true
```

Notes:
- `enableLetsEncryptAutomation=true` runs the full ACME issuance/import/bind flow.
- `enableCustomDomainTls=true` plus thumbprint preserves explicit SNI bindings through normal host binding module behavior.
- DNS zone lock is applied after ACME when ACME automation is enabled, so challenge record cleanup is not blocked.

## Deployment Steps

1. Authenticate and select subscription.

```powershell
az login
az account set --subscription 43d55e51-58fe-486f-9e2a-ba56b8dd15de
```

2. Validate template build.

```powershell
az bicep build --file infrastructure/main.bicep
```

3. Run what-if (recommended).

```powershell
az deployment sub what-if \
  --name dns-poc-le-whatif \
  --location <deployment-location> \
  --template-file infrastructure/main.bicep \
  --parameters infrastructure/main.bicepparam
```

4. Deploy.

```powershell
az deployment sub create \
  --name dns-poc-le-deploy \
  --location <deployment-location> \
  --template-file infrastructure/main.bicep \
  --parameters infrastructure/main.bicepparam
```

## DCV Behavior (How DNS-01 Works Here)

The deployment script in `infrastructure/modules/lets-encrypt-automation.bicep`:

1. Installs `Posh-ACME`.
2. Sets ACME server to Let's Encrypt production (`LE_PROD`).
3. Uses managed identity and ARM token with Posh-ACME Azure plugin.
4. Calls `New-PACertificate -Domain '*.zava-dnspoc-001.com' -Plugin Azure`.
5. Plugin creates `_acme-challenge` TXT record in Azure DNS.
6. Let's Encrypt validates the TXT token (DCV success).
7. Plugin removes `_acme-challenge` TXT record.
8. Certificate issuance completes and PFX is produced.

## Post-Deployment Verification

1. Confirm certificate in Key Vault.

```powershell
az keyvault certificate list \
  --vault-name kv-dcv-poc \
  --query "[].{name:name,thumb:x509ThumbprintHex,exp:attributes.expires}" \
  -o table
```

Expected certificate name: `le-wildcard-zava`.

2. Confirm SNI bindings on US app.

```powershell
az webapp config hostname list \
  -g rg-dns-poc \
  --webapp-name webapp-poc-us-yjpkzjlqt4dou \
  --query "[?contains(name,'zava-dnspoc-001.com')].{hostname:name,ssl:sslState,thumbprint:thumbprint}" \
  -o table
```

3. Confirm SNI bindings on UK app.

```powershell
az webapp config hostname list \
  -g rg-dns-poc \
  --webapp-name webapp-poc-uk-yjpkzjlqt4dou \
  --query "[?contains(name,'zava-dnspoc-001.com')].{hostname:name,ssl:sslState,thumbprint:thumbprint}" \
  -o table
```

4. Confirm HTTPS response for all three domains.

```powershell
$domains=@('webfailover.zava-dnspoc-001.com','webgeo.zava-dnspoc-001.com','webweighted.zava-dnspoc-001.com')
foreach($h in $domains){
  try { $r=Invoke-WebRequest -Uri ('https://'+$h) -Method Head -TimeoutSec 20 -UseBasicParsing; "$h -> HTTP $($r.StatusCode)" }
  catch { "$h -> FAILED: $($_.Exception.Message)" }
}
```

## Troubleshooting

1. ACME challenge cleanup fails with lock error.
- Cause: DNS zone lock applied too early.
- Fix: keep `enableDnsZoneLock=true`; current `main.bicep` already applies lock after ACME when ACME is enabled.

2. Certificate imports to Key Vault but not to App Service.
- Cause: role propagation delay or missing permissions.
- Fix: rerun deployment with new `letsEncryptRunTag` value to force script rerun.

3. Binding exists on one app only.
- Cause: transient import/bind failure.
- Fix: rerun deployment with new `letsEncryptRunTag` value.

4. No certificate created.
- Cause: ACME or DNS API transient failure.
- Fix: module retries ACME call up to 5 times; rerun deployment if all retries fail.

## Operational Notes

- Cert renewal can be handled by rerunning deployment periodically (for example monthly).
- Use a changing `letsEncryptRunTag` to force ACME script execution.
- Key Vault name should remain stable for the environment once chosen.
- Avoid manually deleting ACME-related role assignments unless decommissioning automation.
