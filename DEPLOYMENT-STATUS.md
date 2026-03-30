# DCV & TLS Certificate Deployment - Status Report
**Date:** March 29, 2026  
**Status:** Step 1 Complete ✓

---

## COMPLETED

### Step 1: Service Principal with Minimal DNS Permissions ✓
- **Status:** COMPLETE
- **Custom RBAC Role:** DNS Record Writer - zava-dnspoc-001
  - Role ID: `35bef08e-cfa8-4f32-b5eb-b6dfdde6c473`
  - Permissions: Create/Read/Update DNS records (NO DELETE)
  
- **App Registration & Service Principal Created**
  - App ID: `ef781fcb-6036-4fd4-9d1a-f1b8cadca74d`
  - Service Principal: Created and RBAC role assigned to DNS zone scope
  
- **Credentials File:** `DCV-ServicePrincipal-Credentials.json`

---

## NEXT STEPS

### Step 2: Deploy DCV Infrastructure  
Run this command to create Key Vault, DNS records, and custom domain bindings:

```powershell
.\Zava_DCV_TLS_Setup.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -DnsZoneName "zava-dnspoc-001.com" `
    -CustomDomains @("webfailover.zava-dnspoc-001.com", "webgeo.zava-dnspoc-001.com", "webweighted.zava-dnspoc-001.com") `
    -KeyVaultName "kv-dcv-poc" `
    -Verbose
```

**What it does:**
- Creates Azure Key Vault (kv-dcv-poc)
- Creates DCV validation TXT records (_dnsauth format for DigiCert)
- Tests DNS propagation
- Sets up custom domain bindings

**Expected Duration:** 3-5 minutes

---

### Step 3: Request Certificate from DigiCert
Once Step 2 completes, log into **DigiCert CertCentral** and:
1. Order SSL certificate for `webfailover.zava-dnspoc-001.com`
2. Select validation method: **DNS (_dnsauth)**
3. DigiCert will query the TXT record created in Step 2
4. Download certificate as PFX file

**No client secret needed yet** - The service principal is only used for DNS automation, not certificate ordering.

---

### Step 4: Import Certificate & Bind to Web Apps
Once you have the PFX certificate:

```powershell
.\Import-Certificate-and-Bind.ps1 `
    -SubscriptionId "43d55e51-58fe-486f-9e2a-ba56b8dd15de" `
    -ResourceGroup "rg-dns-poc" `
    -KeyVaultName "kv-dcv-poc" `
    -CertificateFile "C:\path\to\webfailover.zava-dnspoc-001.com.pfx" `
    -CertificatePassword (ConvertTo-SecureString "your-pfx-password" -AsPlainText -Force) `
    -WebAppNames @("webapp-poc-us-yjpkzjlqt4dou", "webapp-poc-uk-yjpkzjlqt4dou") `
    -CustomDomains @("webfailover.zava-dnspoc-001.com")
```

---

### Step 5: Verify HTTPS
Test HTTPS on custom domains:
```powershell
Invoke-WebRequest -Uri "https://webfailover.zava-dnspoc-001.com/" -UseBasicParsing
# Should return status 200 (or appropriate code, NOT SSL error)
```

---

## Generated Files Summary

| File | Purpose |
|------|---------|
| `DCV-ServicePrincipal-Credentials.json` | Service Principal credentials |
| `Create-DCV-ServicePrincipal-Simple.ps1` | Script to create service principal (used in Step 1) |
| `Zava_DCV_TLS_Setup.ps1` | Script to deploy DCV infrastructure (Step 2) |
| `Import-Certificate-and-Bind.ps1` | Script to import cert and bind to web apps (Step 4) |
| `Zava_DCV_and_TLS_Management.md` | Comprehensive user guide |
| `DCV_TLS_Deployment_Checklist.md` | Complete deployment checklist |

---

## Key Information

**Subscription ID:** `43d55e51-58fe-486f-9e2a-ba56b8dd15de`  
**Resource Group:** `rg-dns-poc`  
**DNS Zone:** `zava-dnspoc-001.com`  
**Tenant ID:** `ebf541ac-cacf-4a40-b46e-1accc3810ef8`  
**Key Vault:** `kv-dcv-poc` (to be created in Step 2)  

**Custom Domains:**
- webfailover.zava-dnspoc-001.com
- webgeo.zava-dnspoc-001.com
- webweighted.zava-dnspoc-001.com

**Web Apps:**
- webapp-poc-us-yjpkzjlqt4dou (US West 3)
- webapp-poc-uk-yjpkzjlqt4dou (West Europe)

---

## Security Notes

✓ **Minimal Privilege:** Service principal cannot delete DNS records (explicit RBAC deny)  
✓ **Zone Scoped:** Service principal access limited to zava-dnspoc-001.com zone only  
✓ **No Hardcoded Secrets:** All credentials stored in Key Vault or config files  
✓ **Audit Logging:** All operations logged in Azure Activity Log  

---

## Support

For detailed information, see:
- `Zava_DCV_and_TLS_Management.md` - Architecture & troubleshooting
- `DCV_TLS_Deployment_Checklist.md` - Step-by-step instructions
- `Zava_DCV_Walkthrough_Guide.md` - DCV concepts & examples

---

**Generated:** March 29, 2026  
**Status:** Ready for Step 2 Deployment
