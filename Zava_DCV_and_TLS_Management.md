# DCV & TLS Certificate Management Guide — Zava Energy DNS POC

## Overview

This guide explains how to:
1. **Automate Domain Control Validation (DCV)** for TLS certificate issuance
2. **Create minimal-privilege service principals** for DNS automation
3. **Store certificates securely** in Azure Key Vault
4. **Bind certificates to App Service custom domains** with HTTPS/SNI
5. **Reuse Bicep templates** for additional custom domains

**Target Audience:** Jeremy, Mike, Matt, and cloud operators  
**Estimated Duration:** 30–60 minutes (first domain); 10–15 minutes per additional domain  
**Prerequisites:** Azure CLI, PowerShell 7+, DigiCert CertCentral account (or ACME client)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Azure Subscription                          │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Resource Group: rg-dns-poc                                │  │
│  │                                                            │  │
│  │  ┌──────────────────┐  ┌──────────────────────────────┐  │  │
│  │  │ DNS Zone         │  │ Key Vault (kv-dcv-poc)       │  │  │
│  │  │                  │  │ - Certificates               │  │  │
│  │  │ • Public zone    │  │ - Private keys               │  │  │
│  │  │ • DCV TXT records│  │ - Access policies            │  │  │
│  │  │ • CNAME records  │  │                              │  │  │
│  │  └──────────────────┘  └──────────────────────────────┘  │  │
│  │           △                          △                    │  │
│  │           │ validation              │ certificate         │  │
│  │           └──────────┬───────────────┘                    │  │
│  │                      │                                    │  │
│  │                      ▼                                    │  │
│  │  ┌─────────────────────────────────────────────────────┐ │  │
│  │  │ Service Principal: DCV-Automation-zava-dnspoc-001  │ │  │
│  │  │ - Role: DNS Record Writer (no delete)              │ │  │
│  │  │ - Scope: DNS Zone level (minimal privilege)        │ │  │
│  │  └─────────────────────────────────────────────────────┘ │  │
│  │                      │                                    │  │
│  │                      ▼                                    │  │
│  │  ┌─────────────────────────────────────────────────────┐ │  │
│  │  │ Web Apps (Custom Domains → HTTPS)                 │ │  │
│  │  │ • webapp-poc-us-xxxxx                              │ │  │
│  │  │ • webapp-poc-uk-xxxxx                              │ │  │
│  │  │                                                    │ │  │
│  │  │ Custom Domains:                                    │ │  │
│  │  │ • app.zava-dnspoc-001.com (HTTPS)                │ │  │
│  │  │ • www.zava-dnspoc-001.com (HTTPS)                │ │  │
│  │  │ • api.zava-dnspoc-001.com (HTTPS)                │ │  │
│  │  └─────────────────────────────────────────────────────┘ │  │
│  │                                                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
         │
         │ (External) DigiCert CertCentral or ACME
         │
         ▼
   Certificate Issuer
   • Validates DCV token from DNS
   • Issues TLS certificate
```

---

## Quick Start (First Domain)

### Step 1: Create Service Principal with Minimal Permissions

```powershell
# Run this to create the service principal and custom RBAC role
.\Setup-DCV-ServicePrincipal.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -DnsZoneName "zava-dnspoc-001.com" `
    -ServicePrincipalName "DCV-Automation-zava-dnspoc-001" `
    -GenerateClientSecret

# Output:
# - Service Principal ID (object ID)
# - Application ID (client ID)
# - Client Secret (save immediately!)
# - Custom Role ID
```

**What this does:**
- ✓ Creates a custom RBAC role: **"DNS Record Writer"**
  - Allows: Create, read, update DNS records
  - Denies: Delete DNS records (safety feature)
  - Scope: DNS zone level only (not tenant-wide)
- ✓ Creates a service principal with this role
- ✓ Generates client secret for automation

**Security notes:**
- The service principal **cannot delete** DNS records (explicit deny)
- Access is **scoped to the DNS zone only** (not entire subscription)
- Client secret expires in 12 months (configurable)
- Credentials should be stored in **Azure Key Vault** (not in scripts)

---

### Step 2: Configure DCV and Deploy Infrastructure

```powershell
# Run the main DCV setup script
.\Zava_DCV_TLS_Setup.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -DnsZoneName "zava-dnspoc-001.com" `
    -CustomDomains @("app.zava-dnspoc-001.com", "www.zava-dnspoc-001.com") `
    -KeyVaultName "kv-dcv-poc" `
    -SkipDigiCertValidation  # For testing; remove for production

# Output:
# ✓ Key Vault created
# ✓ DCV DNS records created (_dnsauth.app.zava-dnspoc-001.com, etc.)
# ✓ Custom domain bindings established
# ✓ DNS propagation verified
```

**What this does:**
- ✓ Creates Azure Key Vault (`kv-dcv-poc`)
- ✓ Creates `_dnsauth` TXT records for each subdomain (DigiCert DCV convention)
- ✓ Verifies DNS propagation (retries for 5 minutes)
- ✓ Binds custom domains to web apps (CNAME records created)
- ✓ Logs all operations to `dcv-YYYYMMDD-HHmmss.log`

---

### Step 3: Request Certificate from CA

#### **Option A: DigiCert CertCentral (Recommended)**

1. Log in to [DigiCert CertCentral](https://www.digicert.com/secure/orders/dashboard)
2. **Order → SSL/TLS Certificate**
3. **Domain:** `app.zava-dnspoc-001.com` (single domain or multi-domain SAN)
4. **Validation Method:** DNS (_dnsauth)
5. After order creation, the portal will show:
   ```
   _dnsauth.app.zava-dnspoc-001.com = "digicert_dcv_token_value_12345"
   ```
6. **Verify DNS:** DigiCert queries the TXT record and validates
7. **Download:** Certificate issued (PFX format recommended)

#### **Option B: ACME Client (certbot, acme.sh)**

```bash
# Using certbot with DigiCert ACME endpoint
certbot certonly \
  --manual \
  --preferred-challenges=dns \
  --server "https://acme.digicert.com/v2/acme/directory/" \
  -d "app.zava-dnspoc-001.com" \
  -d "www.zava-dnspoc-001.com"

# certbot creates: _acme-challenge.app = "token"
# Create this record in your DNS zone manually (or via API)
# Once validated and cert issued, convert to PFX:
openssl pkcs12 -export \
  -in /etc/letsencrypt/live/app.zava-dnspoc-001.com/fullchain.pem \
  -inkey /etc/letsencrypt/live/app.zava-dnspoc-001.com/privkey.pem \
  -out app.zava-dnspoc-001.com.pfx \
  -password pass:YOUR_CERT_PASSWORD
```

---

### Step 4: Import Certificate to Key Vault & Bind to Web Apps

```powershell
# Import certificate and bind to web apps
.\Import-Certificate-and-Bind.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -KeyVaultName "kv-dcv-poc" `
    -CertificateFile "C:\certs\app.zava-dnspoc-001.com.pfx" `
    -CertificatePassword (ConvertTo-SecureString "cert-password" -AsPlainText -Force) `
    -WebAppNames @("webapp-poc-us-yjpkzjlqt4dou", "webapp-poc-uk-yjpkzjlqt4dou") `
    -CustomDomains @("app.zava-dnspoc-001.com", "www.zava-dnspoc-001.com")

# Output:
# ✓ Certificate imported to Key Vault
# ✓ SSL bindings created for both web apps
# ✓ HTTPS available on custom domains
```

**What this does:**
- ✓ Imports PFX certificate to Key Vault (encrypted at rest)
- ✓ Extracts certificate thumbprint
- ✓ Creates SNI SSL bindings on web app custom domains
- ✓ Enables HTTPS on custom domains

---

### Step 5: Verify HTTPS

```powershell
# Test HTTPS on custom domain
$uri = "https://app.zava-dnspoc-001.com"
$response = Invoke-WebRequest -Uri $uri -SkipCertificateCheck -Verbose

Write-Host "Status: $($response.StatusCode)"
Write-Host "Certificate Valid: $(($null -ne $response.Headers['Content-Type']))"

# Or use curl:
curl -I https://app.zava-dnspoc-001.com/

# Browser test:
# Open https://app.zava-dnspoc-001.com in your browser
# Verify: no certificate warning, valid certificate shown
```

---

## Adding Additional Custom Domains (Reusable Bicep)

For each new custom domain, you can redeploy the Bicep templates with new parameters:

### Option 1: PowerShell Script (Quickest)

```powershell
# Re-run with additional domains
.\Zava_DCV_TLS_Setup.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -DnsZoneName "zava-dnspoc-001.com" `
    -CustomDomains @("api.zava-dnspoc-001.com", "admin.zava-dnspoc-001.com") `
    -KeyVaultName "kv-dcv-poc"

# Then request certificate and import as before
.\Import-Certificate-and-Bind.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -KeyVaultName "kv-dcv-poc" `
    -CertificateFile "C:\certs\api.zava-dnspoc-001.com.pfx" `
    -CertificatePassword (ConvertTo-SecureString "cert-password" -AsPlainText -Force) `
    -CustomDomains @("api.zava-dnspoc-001.com", "admin.zava-dnspoc-001.com")
```

### Option 2: Bicep Deployment (IaC Approach)

```powershell
# Use the dcv-certificate-orchestration.bicep module
az deployment group create `
    --resource-group rg-dns-poc `
    --template-file infrastructure/modules/dcv-certificate-orchestration.bicep `
    --parameters `
      dnsZoneName=zava-dnspoc-001.com `
      webAppNames='["webapp-poc-us-yjpkzjlqt4dou", "webapp-poc-uk-yjpkzjlqt4dou"]' `
      customDomainNames='["api.zava-dnspoc-001.com"]' `
      keyVaultName=kv-dcv-poc `
      customRoleId="/subscriptions/43d55e51-58fe-486f-9e2a-ba56b8dd15de/providers/Microsoft.Authorization/roleDefinitions/..." `
      servicePrincipalId="<spn-object-id>"

# Then import certificate as before
.\Import-Certificate-and-Bind.ps1 ...
```

---

## File Structure

```
Azure-DNS-POC-Accelerator/
├── infrastructure/
│   ├── modules/
│   │   ├── custom-role-dns-writer.bicep          # RBAC role definition
│   │   ├── service-principal-dns.bicep           # Service principal + role assignment
│   │   ├── key-vault-certificates.bicep          # Key Vault for certs
│   │   ├── dcv-txt-records.bicep                 # DCV TXT record creation
│   │   ├── app-service-custom-domain-ssl.bicep   # HTTPS binding
│   │   └── dcv-certificate-orchestration.bicep   # Complete workflow
│   └── main.bicep                                # (existing main template)
│
├── Zava_DCV_TLS_Setup.ps1                        # Main setup script
├── Setup-DCV-ServicePrincipal.ps1                # Service principal creation
├── Import-Certificate-and-Bind.ps1               # Certificate import & binding
├── Zava_DCV_and_TLS_Management.md               # This guide
│
└── logs/
    └── dcv-20260329-120000.log                  # Operations log
```

---

## Troubleshooting

### Issue: "DNS record not propagating"
**Solution:**
- Wait 2-3 minutes (DNS TTL is 300 seconds)
- Verify DNS zone ownership in Azure Portal
- Check DNS record manually: `nslookup _dnsauth.app.zava-dnspoc-001.com`
- Increase `$dnsPropagationMaxAttempts` in script if needed

### Issue: "Service principal cannot write DNS records"
**Solution:**
- Verify role assignment: `Get-AzRoleAssignment -ObjectId <spn-id>`
- Check if custom RBAC role was created: `Get-AzRoleDefinition -Name "DNS Record Writer"`
- Ensure role scope is set to DNS zone, not resource group
- Rerun `Setup-DCV-ServicePrincipal.ps1`

### Issue: "Certificate import fails: 'Invalid certificate format'"
**Solution:**
- Ensure certificate is in PFX (PKCS#12) format
- Verify password is correct (try escaping special chars)
- Test locally: `openssl pkcs12 -in <cert.pfx> -password pass:<pwd>`

### Issue: "HTTPS still shows certificate warning"
**Solution:**
- Verify CNAME record points to `azurewebsites.net`
- Check custom domain binding is in "Verified" state
- Verify certificate thumbprint matches binding
- Allow 5-10 minutes for HTTPS to fully propagate
- Clear browser cache or test in incognito window

### Issue: "Service principal accidental delete"
**Solution (prevention):**
- The custom role explicitly denies delete operations
- If app registration/SP deleted, recreate via `Setup-DCV-ServicePrincipal.ps1`
- Ensure client secret stored in Key Vault for easy rotation

---

## Security Best Practices

### ✓ **Do:**
- Store client secrets in Azure Key Vault (reference in scripts, not hardcoded)
- Limit service principal scope to specific DNS zone (no tenant-wide role)
- Use explicit deny on delete operations (minimal privilege)
- Rotate service principal client secrets every 12 months
- Enable Key Vault audit logging
- Use SNI (Server Name Indication) for HTTPS bindings
- Monitor certificate expiration dates

### ✗ **Don't:**
- Hardcode client secrets in PowerShell scripts
- Use subscription-level scope for service principal role
- Use a single service principal for multiple unrelated tasks
- Store certificates locally unencrypted
- Ignore certificate expiration warnings

---

## Frequently Asked Questions

**Q: Can I automate this entire workflow?**  
A: Yes. The PowerShell scripts support full automation. At production scale, integrate with:
- Azure DevOps Pipeline (for scheduled certificate renewal)
- GitOps (Bicep templates versioned in Git)
- HashiCorp Vault (for credential rotation)
- Prometheus/AlertManager (for certificate expiration alerts)

**Q: How do I renew certificates before they expire?**  
A: Request a new certificate from your CA (DigiCert, Let's Encrypt, etc.) 30 days before expiration. Run `Import-Certificate-and-Bind.ps1` again with the new PFX file. The binding automatically uses the newest certificate.

**Q: What's the difference between HTTP-01 and DNS-01 DCV?**  
A: 
- **HTTP-01:** Requires a running web server and public accessibility
- **DNS-01:** Works for wildcard certs, offline servers, and internal-only services
- We recommend **DNS-01** for flexibility

**Q: Can I use Azure's built-in managed certificates instead?**  
A: Yes, Azure App Service has free managed certificates, but they don't support wildcards and have auto-renewal limitations. Our approach gives you full control and is better for multi-domain/SAN scenarios.

**Q: How do I bind the same certificate to multiple domains?**  
A: Use a SAN (Subject Alternative Name) certificate, which covers multiple domains. Once imported to Key Vault, you can bind it to multiple custom domain hostnames on the same web app (or across web apps).

---

## Next Steps

1. ✓ Run `Setup-DCV-ServicePrincipal.ps1`
2. ✓ Run `Zava_DCV_TLS_Setup.ps1`
3. ✓ Request certificate from DigiCert or ACME
4. ✓ Run `Import-Certificate-and-Bind.ps1`
5. ✓ Verify HTTPS on custom domains
6. ✓ Document certificate renewal process
7. ✓ Set up certificate expiration alerts in Key Vault

---

## Support & Questions

For issues or clarifications:
- Review logs in `dcv-*.log` files
- Check Azure Portal > Key Vault > Certificates for import status
- Review Service Principal permissions in IAM blade
- Contact your DNS provider or CA (DigiCert) support if DCV fails

---

**Last Updated:** 2026-03-29  
**Maintained by:** Zava Energy Corporation, Microsoft DNS POC Team
