# Zava DNS POC — DCV and Certificate Management Walkthrough

**Audience:** Jeremy, Mike, Matt, and anyone new to Azure DNS + certificate workflows  
**Purpose:** Explain where certs live, how ACME DNS-01 DCV works with Let's Encrypt, and how to validate end to end behavior  
**Prerequisite:** Azure enterprise landing zone is set up, `rg-dns-poc` resource group exists  
**Certificate Authority:** Let's Encrypt (ACME DNS-01 via Azure DNS plugin)  

---

## 1. What Is DCV (Domain Control Validation)?

Before a Certificate Authority (CA) like Let's Encrypt, DigiCert, or GlobalSign will issue you an SSL/TLS certificate, they need **proof that you control the domain**. That proof is DCV.

There are 3 methods:

| Method | How It Works | Automatable? |
|---|---|---|
| **HTTP-01** | Place a file at `http://yourdomain/.well-known/acme-challenge/TOKEN` | Yes, but requires a running web server |
| **DNS-01** | Create a TXT record: `_acme-challenge.yourdomain` with a specific token value | **Yes — this is what we're testing** |
| **Email** | CA sends email to admin@yourdomain, you click a link | No (manual) |

**DNS-01 is the most important for kimvaddi** because:
- It works for **wildcard certificates** (HTTP-01 doesn't)
- It doesn't require a running web server
- It can be fully automated with Azure DNS APIs
- It works even if the server isn't publicly accessible
- **DigiCert CertCentral supports DNS-01 validation** using `_dnsauth` TXT records

### The DCV Flow — DigiCert CertCentral (kimvaddi's Workflow)

DigiCert uses `_dnsauth` as the TXT record name (not `_acme-challenge`):

```
1. You order a cert for "app.kimvaddi.com" in DigiCert CertCentral
2. DigiCert says: "Prove you own this domain. Create a TXT record:
   _dnsauth.app.kimvaddi.com = '<digicert-dcv-random-value>'"
3. You create that TXT record in Azure DNS
4. DigiCert queries DNS, finds the TXT record, confirms the token matches
5. DigiCert issues the certificate
6. You clean up the TXT record (good hygiene)
```

**That's it.** The POC runbook automates steps 3, 4 (verification), and 6 for both DigiCert (`_dnsauth`) and ACME (`_acme-challenge`) conventions.

### ACME Flow (Alternative — certbot / acme.sh)

DigiCert also offers an ACME-compatible endpoint for automation. The flow is the same but uses `_acme-challenge`:

```
1. You request a cert using certbot/acme.sh pointed at DigiCert's ACME endpoint
2. The ACME client creates: _acme-challenge.app.kimvaddi.com = 'token'
3. DigiCert validates, issues the certificate
4. Cleanup happens automatically
```

DigiCert ACME endpoint: `https://acme.digicert.com/v2/acme/directory/`  
Requires EAB (External Account Binding) credentials from CertCentral → Automation → ACME.

---

## 2. Where Do the Certificates End Up?

This is the key question. The answer depends on which tool you use:

### Option A: Local File System (certbot / acme.sh)

When you use **certbot** or **acme.sh** (free ACME clients), the certificates are saved **on the machine where you ran the command**.

| Tool | Default Cert Location | What's Stored |
|---|---|---|
| **certbot** (Linux) | `/etc/letsencrypt/live/yourdomain/` | `fullchain.pem`, `privkey.pem`, `cert.pem`, `chain.pem` |
| **certbot** (Windows) | `C:\Certbot\live\yourdomain\` | Same as above |
| **acme.sh** | `~/.acme.sh/yourdomain/` | `yourdomain.cer`, `yourdomain.key`, `ca.cer`, `fullchain.cer` |

**For the POC:** This is fine — you'll see the cert files on disk and can verify they're valid.

**For production:** You wouldn't leave certs on disk. You'd store them in **Azure Key Vault** (see Option B).

### Option B: Azure Key Vault (Recommended for Production)

**Azure Key Vault** is a managed secret/key/certificate store. This is where kimvaddi should store production certificates.

```
┌──────────────────────────────────────────────┐
│  Azure Key Vault                              │
│  ┌──────────────┐  ┌──────────────┐          │
│  │  Secrets      │  │  Keys        │          │
│  │  (passwords,  │  │  (encryption │          │
│  │   conn strings)│  │   keys)      │          │
│  └──────────────┘  └──────────────┘          │
│  ┌──────────────────────────────────┐        │
│  │  Certificates                     │        │
│  │  ┌────────────────────────────┐  │        │
│  │  │  app.kimvaddi.com            │  │        │
│  │  │  - Certificate (public)    │  │        │
│  │  │  - Private key             │  │        │
│  │  │  - CA chain                │  │        │
│  │  │  - Expiration tracking     │  │        │
│  │  │  - Auto-renewal (optional) │  │        │
│  │  └────────────────────────────┘  │        │
│  └──────────────────────────────────┘        │
└──────────────────────────────────────────────┘
         │
         │  Referenced by:
         ▼
  ┌─────────────────────┐
  │  App Service         │  ← Custom domain SSL
  │  Application Gateway │  ← HTTPS listener
  │  Azure Front Door    │  ← Edge TLS
  │  VM / Container      │  ← App pulls cert
  └─────────────────────┘
```

**Key Vault benefits for kimvaddi:**
- Centralized certificate storage (not scattered on servers)
- Automatic expiration alerts
- RBAC-controlled access (who can see the private key?)
- Azure services can reference certs directly (no file copies)
- Audit logging (who accessed which cert and when)

### Option C: Azure App Service Managed Certificates (Free, Automatic)

If kimvaddi runs web apps on Azure App Service, Azure can issue and renew certificates **automatically** — no ACME client needed. The DCV happens behind the scenes using a CNAME record.

This is nice-to-know for the future but not the POC focus.

---

## 3. Step-by-Step: Walk Jeremy & Matt Through DCV Testing

### Prerequisites (Do These First)

```powershell
# 1. Install Azure CLI (if not already installed)
# Download from: https://aka.ms/installazurecliwindows
# Or via winget:
winget install Microsoft.AzureCLI

# 2. Log in to Azure
az login

# 3. Set the correct subscription
az account set --subscription "<subscription-id>"

# 4. Verify you're in the right subscription
az account show --output table
```

### Step 1: Understand What You're Working With

```powershell
# List your DNS zones — you should see poc.kimvaddi.com
az network dns zone list --resource-group rg-dns-poc --output table

# See the nameservers Azure assigned to your zone
az network dns zone show `
  --resource-group rg-dns-poc `
  --name poc.kimvaddi.com `
  --query "nameServers" `
  --output tsv
```

**What you'll see:** 4 Azure DNS nameservers like `ns1-01.azure-dns.com`, `ns2-01.azure-dns.net`, etc. These are the servers that answer DNS queries for your zone.

### Step 2: Simulate a DigiCert DCV Challenge (Manual Walkthrough)

Let's do this manually first so the team understands what's happening, before running the automated tests.

```powershell
# Pretend you're DigiCert CertCentral. You've generated this DCV random value:
$token = "digicert-manual-test-12345"

# Step A: Create the _dnsauth TXT record
# This is what your automation would do when DigiCert issues a DCV challenge
az network dns record-set txt add-record `
  --resource-group rg-dns-poc `
  --zone-name poc.kimvaddi.com `
  --record-set-name "_dnsauth" `
  --value $token `
  --output table
```

**What happened:** You just created a DNS TXT record. Anyone querying `_dnsauth.poc.kimvaddi.com` will now get the token value back. This is how DigiCert proves you control the domain.

```powershell
# Step B: Verify it — pretend you're DigiCert checking the record
$ns = (az network dns zone show `
  --resource-group rg-dns-poc `
  --name poc.kimvaddi.com `
  --query "nameServers[0]" `
  --output tsv)

# Query the record (this is what DigiCert does)
nslookup -type=TXT _dnsauth.poc.kimvaddi.com $ns
```

**What you should see:**
```
_dnsauth.poc.kimvaddi.com  text = "digicert-manual-test-12345"
```

That's the proof. DigiCert sees the token, confirms it matches what they issued, and gives you the certificate.

```powershell
# Step C: Clean up (delete the challenge record)
az network dns record-set txt remove-record `
  --resource-group rg-dns-poc `
  --zone-name poc.kimvaddi.com `
  --record-set-name "_dnsauth" `
  --value $token

# Step D: Verify it's gone
nslookup -type=TXT _dnsauth.poc.kimvaddi.com $ns
# Should return "Non-existent domain" or empty
```

**Congratulations — you just did DigiCert DCV manually.** The automated scripts do this exact thing, but faster, with timing, and with pass/fail verdicts.

### Step 3: See It in the Azure Portal (Visual Confirmation)

For a team new to Azure, seeing it in the portal builds confidence:

1. Go to **portal.azure.com**
2. Search for **"DNS zones"** in the top search bar
3. Click on **poc.kimvaddi.com**
4. You'll see all your DNS records listed in a table
5. When a `_acme-challenge` TXT record exists, you'll see it here
6. You can also **add/edit/delete records** from this UI (but CLI is better for automation)

**Key things to point out in the portal:**
- The **Record sets** list shows every record in the zone
- Click any record to see its value, TTL, and metadata
- The **Activity log** (left sidebar) shows who changed what and when
- **Access control (IAM)** shows current RBAC role assignments

### Step 4: Run the Automated DCV Proof Suite

Now that the team understands what DCV is, run the full automated test suite from the runbook:

```bash
# On a Linux/Mac machine or WSL:
# Edit Section 0 of the runbook with your values, then run Section 5
bash kimvaddi_DNS_POC_Runbook.sh
```

Or run the DCV tests individually from PowerShell:

```powershell
# === TEST: Standard DCV ===
$zone = "poc.kimvaddi.com"
$rg = "rg-dns-poc"
$token = "dcv-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
$ns = (az network dns zone show -g $rg -n $zone --query "nameServers[0]" -o tsv)

# Create
Write-Host "Creating _acme-challenge TXT record with token: $token"
az network dns record-set txt add-record -g $rg -z $zone -n "_acme-challenge" -v $token --output none

# Verify (poll until resolvable)
$maxWait = 60
$elapsed = 0
do {
    Start-Sleep -Seconds 5
    $elapsed += 5
    $result = (nslookup -type=TXT "_acme-challenge.$zone" $ns 2>$null | Select-String "text =")
    Write-Host "  ${elapsed}s: $result"
} while (-not ($result -match $token) -and ($elapsed -lt $maxWait))

if ($result -match $token) {
    Write-Host "`n  PASS: TXT record verified in ${elapsed}s" -ForegroundColor Green
} else {
    Write-Host "`n  FAIL: TXT record not found after ${maxWait}s" -ForegroundColor Red
}

# Cleanup
az network dns record-set txt remove-record -g $rg -z $zone -n "_acme-challenge" -v $token --output none
Write-Host "Cleanup complete.`n"
```

### Step 5: Test with a Real ACME Client (Optional but Impressive)

If the team wants to see an **actual certificate** issued:

```powershell
# Install certbot (on Ubuntu/WSL)
# sudo apt install certbot python3-pip
# pip install certbot-dns-azure

# Or use acme.sh (simpler, works everywhere)
# curl https://get.acme.sh | sh

# Using acme.sh with Azure DNS (staging = free, no rate limits):
$env:AZUREDNS_SUBSCRIPTIONID = "<subscription-id>"
$env:AZUREDNS_TENANTID = "<tenant-id>"
$env:AZUREDNS_APPID = "<service-principal-client-id>"
$env:AZUREDNS_CLIENTSECRET = "<service-principal-secret>"

# Issue a test cert (staging CA — doesn't count against rate limits)
# acme.sh --issue --dns dns_azure -d poc.kimvaddi.com --staging

# If successful, the cert is stored at:
# ~/.acme.sh/poc.kimvaddi.com_ecc/
#   ├── poc.kimvaddi.com.cer      ← Your certificate
#   ├── poc.kimvaddi.com.key      ← Your private key
#   ├── ca.cer                  ← CA chain
#   └── fullchain.cer           ← Cert + chain (use this)
```

### Step 6: (Optional) Store the Cert in Azure Key Vault

This shows the production pattern — cert in Key Vault instead of on disk:

```powershell
# Create a Key Vault (if one doesn't exist in the landing zone)
az keyvault create `
  --name "kv-kimvaddi-dns-poc" `
  --resource-group rg-dns-poc `
  --location southcentralus `
  --output table

# Import a PFX certificate into Key Vault
# First, convert PEM to PFX (if you used certbot/acme.sh):
# openssl pkcs12 -export -out cert.pfx -inkey privkey.pem -in fullchain.pem

az keyvault certificate import `
  --vault-name "kv-kimvaddi-dns-poc" `
  --name "poc-kimvaddi-com-cert" `
  --file cert.pfx `
  --password "" `
  --output table

# View the certificate in Key Vault
az keyvault certificate show `
  --vault-name "kv-kimvaddi-dns-poc" `
  --name "poc-kimvaddi-com-cert" `
  --output table

# See expiration date
az keyvault certificate show `
  --vault-name "kv-kimvaddi-dns-poc" `
  --name "poc-kimvaddi-com-cert" `
  --query "attributes.expires" `
  --output tsv
```

**In the portal:**
1. Go to **portal.azure.com** → search **"Key vaults"**
2. Click your vault → **Certificates** (left sidebar)
3. You'll see the cert with its expiration date, thumbprint, and status

---

## 4. How It All Fits Together (The Big Picture)

```
                     TODAY (Bind)                          AFTER MIGRATION (Azure)
                     ============                          =======================

  ┌──────────────┐                              ┌──────────────────────────────┐
  │  Bind Server  │                              │  Azure DNS Zone              │
  │  (in DMZ)     │                              │  poc.kimvaddi.com              │
  │               │                              │  - Managed by Azure          │
  │  Zone files   │  ──── Migrate ────────────▶  │  - 100% SLA                  │
  │  on disk      │                              │  - RBAC controlled           │
  │               │                              │  - API/CLI/Terraform managed │
  └──────┬───────┘                              └──────────┬───────────────────┘
         │                                                  │
         │                                                  │ DCV (DNS-01)
         │                                                  │
  ┌──────┴───────┐                              ┌──────────┴───────────────────┐
  │  Manual cert  │                              │  Automated cert workflow     │
  │  management   │                              │                              │
  │  - SSH to     │  ──── Replace ────────────▶  │  1. ACME client calls Azure  │
  │    Bind box   │                              │     DNS API                  │
  │  - Edit zone  │                              │  2. TXT record created       │
  │  - Run certbot│                              │  3. CA validates             │
  │  - Copy cert  │                              │  4. Cert issued              │
  │    manually   │                              │  5. Stored in Key Vault      │
  └──────────────┘                              │  6. Auto-renewed on schedule │
                                                 └──────────────────────────────┘
```

---

## 5. Common Questions from Teams New to Azure

**Q: Do I need to install anything on a server?**  
A: Not for DNS management. Azure DNS is fully managed — no servers to maintain. For the ACME client (certbot/acme.sh), you run it from any machine with Azure CLI access — your laptop, a CI/CD pipeline, or a VM.

**Q: What if I mess up a DNS record?**  
A: Azure DNS has an **Activity Log** that records every change with timestamp and user identity. You can see exactly who changed what. To undo, just delete or modify the record via CLI or portal.

**Q: How fast do DNS changes take effect?**  
A: Azure DNS updates are typically visible within **seconds** (demonstrated in the POC timing tests). The actual propagation to end users depends on TTL values — shorter TTL = faster propagation.

**Q: Can multiple people manage DNS at the same time?**  
A: Yes. Azure DNS supports concurrent access, and RBAC controls who can do what. Unlike Bind, there's no single-server lock — it's a managed service with built-in concurrency.

**Q: What happens if Azure DNS goes down?**  
A: Azure DNS has a **100% availability SLA**. The service runs on Azure's global anycast network across all Azure regions. There has never been a full Azure DNS outage.

**Q: Can I see a history of all DNS changes?**  
A: Yes — Azure Activity Log and Azure Monitor capture all management plane operations. You can see who created, modified, or deleted records, with timestamps.

**Q: How do I handle certificate renewals?**  
A: Set up automated renewal. Both certbot and acme.sh support cron jobs that run every 60-90 days, automatically performing DCV and renewing the cert. With Azure DNS as the backend, the DCV step is fully automated.

**Q: What's the cost?**  
A: Azure DNS: ~$0.50/zone/month + $0.40 per million queries. Key Vault: ~$0.03 per 10,000 operations. For kimvaddi's use case, total cost will be minimal compared to running Bind servers.

---

## 6. Suggested Demo Flow for the Walkthrough Session

Use this as a talking track when walking Jeremy and Matt through DCV:

| # | Duration | What You Do | What You Say |
|---|---|---|---|
| 1 | 2 min | Open portal, show DNS zone | "Here's your zone in Azure. Every record is visible, searchable, and auditable." |
| 2 | 2 min | Show the empty _acme-challenge | "Right now there's no challenge record. Let's create one like a CA would." |
| 3 | 3 min | Run the CLI command to create TXT | "One command. No SSH, no editing zone files, no restarting Bind." |
| 4 | 1 min | Refresh portal — show record appeared | "There it is in the portal. The CA would query this exact record." |
| 5 | 2 min | Run nslookup/dig to verify | "This is what the CA sees. Token matches — cert would be issued." |
| 6 | 1 min | Delete the record | "Cleanup. One command. Record is gone." |
| 7 | 3 min | Run full automated suite (Tests 1-5) | "Now let's run the full proof suite — single domain, subdomain, wildcard, multi-SAN, and timing." |
| 8 | 2 min | Show the PASS/FAIL summary | "5/5 passed. This is your evidence that DCV automation works with Azure DNS." |
| 9 | 2 min | Show Key Vault (cert storage) | "In production, the cert lands here. RBAC controls who can see the private key. Expiration alerts built in." |
| 10 | 2 min | Q&A | "Questions? This replaces the SSH-to-Bind-and-manually-edit-zone workflow." |

**Total: ~20 minutes.** Fast enough to fit in a lunch slot.

---

*This document is designed to be shared with kimvaddi's team before or during the POC.*
