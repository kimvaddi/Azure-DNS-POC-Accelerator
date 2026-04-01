# Azure DNS POC — Portal Setup Guide (Step-by-Step)

> **Audience:** Jeremy, Matt (Zava Energy) — DNS practitioners new to Azure  
> **Time estimate:** ~90 minutes (portal clicks)  
> **Domain:** `poc.zava-dnspoc.com` | **RG:** `rg-dns-poc` | **Region:** South Central US

---

## Pre-Requisites

- Azure subscription with Owner or Contributor role
- Sign in to [portal.azure.com](https://portal.azure.com)
- Non-Microsoft email for domain registration (e.g., Gmail)

---

## Step 1: Create Resource Group

1. Search **"Resource groups"** in the top search bar
2. Click **+ Create**
3. Fill in:
   - **Subscription:** (your subscription)
   - **Resource group:** `rg-dns-poc`
   - **Region:** `South Central US`
4. Click **Review + create** → **Create**

---

## Step 2: Purchase Domain (App Service Domain)

1. Search **"App Service Domains"** in the top search bar
2. Click **+ Create**
3. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Domain name:** `zava-dnspoc.com`
   - **Contact information:** Fill all fields (use non-Microsoft email)
   - **Privacy protection:** Enabled
   - **Auto-renew:** Enabled
4. Click **Review + create** → **Create**
5. **Wait 2-3 minutes** for GoDaddy registration to complete

> **What this does:** Purchases the domain via GoDaddy, auto-creates a DNS zone `zava-dnspoc.com` in Azure DNS, and sets NS delegation automatically.

**Verify:** Search "DNS zones" → you should see `zava-dnspoc.com` with NS records pointing to `ns1-XX.azure-dns.com`

---

## Step 3: Create Log Analytics Workspace

1. Search **"Log Analytics workspaces"**
2. Click **+ Create**
3. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Name:** `law-dns-poc`
   - **Region:** `South Central US`
4. Click **Review + create** → **Create**

---

## Step 4: Create Event Hub (for QRadar SIEM)

### 4a: Event Hub Namespace
1. Search **"Event Hubs"**
2. Click **+ Create**
3. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Namespace name:** `ehns-dnspoc-<unique>` (e.g., `ehns-dnspoc-zava2026`)
   - **Location:** `South Central US`
   - **Pricing tier:** `Standard`
4. Click **Review + create** → **Create**

### 4b: Event Hub (inside the namespace)
1. Open the namespace you just created
2. Click **+ Event Hub**
3. Fill in:
   - **Name:** `dns-logs`
   - **Partition Count:** `2`
   - **Retention:** `1` day
4. Click **Create**

### 4c: SAS Policies (on the Event Hub)
1. Inside the Event Hub `dns-logs`, go to **Shared access policies**
2. Click **+ Add**
   - **Name:** `SendPolicy` → Check **Send** only → **Create**
3. Click **+ Add** again
   - **Name:** `QRadarListenPolicy` → Check **Listen** only → **Create**

### 4d: Consumer Group
1. In the Event Hub `dns-logs`, go to **Consumer groups**
2. Click **+ Consumer group**
   - **Name:** `qradar-consumer` → **Create**

---

## Step 5: Create Key Vault

1. Search **"Key vaults"**
2. Click **+ Create**
3. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Key vault name:** `kv-dnspoc-zava2026` (must be globally unique)
   - **Region:** `South Central US`
   - **Pricing tier:** `Standard`
   - **Permission model:** Select **Azure role-based access control (RBAC)**
4. Click **Review + create** → **Create**

### 5b: Grant yourself Key Vault Administrator
1. Open the Key Vault → **Access control (IAM)**
2. Click **+ Add** → **Add role assignment**
3. Search: `Key Vault Administrator` → Select it → **Next**
4. **Members:** Select your user account → **Review + assign**

### 5c: Grant App Service RP access (for cert import later)
1. Still in **Access control (IAM)** → **+ Add role assignment**
2. Search: `Key Vault Certificate User` → Select it → **Next**
3. **Members:** Select **User, group, or service principal** → search `Microsoft.Azure.WebSites` (App ID: `abfa0a7c-a6b6-4736-8310-5855508787cd`)
4. **Review + assign**

---

## Step 6: Create Virtual Network

1. Search **"Virtual networks"**
2. Click **+ Create**
3. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Name:** `vnet-dns-poc`
   - **Region:** `South Central US`
   - **IPv4 address space:** `10.0.0.0/16`
4. **Subnets tab:** Add default subnet `10.0.0.0/24`
5. Click **Review + create** → **Create**

---

## Step 7: Create DNS Zones

### 7a: POC Public Zone
1. Search **"DNS zones"**
2. Click **+ Create**
3. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Name:** `poc.zava-dnspoc.com`
4. Click **Review + create** → **Create**

### 7b: Delegate POC zone from parent
1. Go to the `zava-dnspoc.com` zone
2. Click **+ Record set**
   - **Name:** `poc`
   - **Type:** `NS`
   - **Value:** Copy all 4 NS values from the `poc.zava-dnspoc.com` zone (e.g., `ns1-08.azure-dns.com.`)
3. Click **OK** — repeat for all 4 NS records

### 7c: Child Zone for DNSSEC
1. Create another DNS zone: `demo.zava-dnspoc.com`
2. Delegate from parent: add NS records for `demo` in `zava-dnspoc.com` zone

### 7d: Zone Import (optional)
1. Open the `poc.zava-dnspoc.com` zone
2. Click **Import** (top toolbar) → Upload your Bind zone file
3. Review parsed records → **Import**

> **Note:** SOA and NS records are auto-generated by Azure — imported values are overwritten (expected).

**Verify:** Open zone → You should see NS + SOA records auto-created

---

## Step 8: Create DNS Records (CRUD Demo)

In the `poc.zava-dnspoc.com` zone, click **+ Record set** for each:

| Name | Type | TTL | Value |
|------|------|-----|-------|
| `www` | A | 3600 | `10.0.1.10` |
| `www` | AAAA | 3600 | `2001:db8::1` |
| `mail` | MX | 3600 | Priority `10`, Mail exchange `mail.poc.zava-dnspoc.com` |
| `@` | TXT | 3600 | `v=spf1 include:_spf.google.com ~all` |
| `_sip._tcp` | SRV | 3600 | Priority `10`, Weight `60`, Port `5060`, Target `sip.poc.zava-dnspoc.com` |

---

## Step 9: Configure Audit Logging

### 9a: Activity Log → Event Hub + Log Analytics
1. Search **"Monitor"** → **Activity log** → **Export Activity Logs**
2. Click **+ Add diagnostic setting**
   - **Name:** `activity-log-to-eh-and-law`
   - Check ALL 8 log categories (Administrative, Security, ServiceHealth, etc.)
   - **Destination:** Check both:
     - ✅ **Send to Log Analytics workspace** → `law-dns-poc`
     - ✅ **Stream to an event hub** → Namespace: `ehns-dnspoc-*`, Hub: `dns-logs`, Policy: `SendPolicy`
3. Click **Save**

### 9b: Storage Account for QRadar Checkpoints
1. Search **"Storage accounts"** → **+ Create**
   - **Resource group:** `rg-dns-poc`
   - **Name:** `stqradarpoc<random>` (e.g., `stqradarpoc2026`)
   - **Region:** `South Central US`
   - **Performance:** `Standard`
   - **Redundancy:** `LRS`
2. Click **Review + create** → **Create**

---

## Step 10: Configure RBAC

### 10a: Built-in DNS Zone Contributor
1. Go to the `poc.zava-dnspoc.com` DNS zone → **Access control (IAM)**
2. **+ Add role assignment** → `DNS Zone Contributor` → Assign to admin user

### 10b: Custom Role (DNS Record Operator)
> Custom roles cannot be created in the portal UI from scratch. Use Cloud Shell:
```bash
# In the portal, click the Cloud Shell icon (top-right) →
az role definition create --role-definition '{
  "Name": "DNS Record Operator",
  "Description": "Can manage DNS records but not zones",
  "Actions": [
    "Microsoft.Network/dnsZones/read",
    "Microsoft.Network/dnsZones/*/read",
    "Microsoft.Network/dnsZones/*/write",
    "Microsoft.Network/dnsZones/*/delete"
  ],
  "NotActions": [
    "Microsoft.Network/dnsZones/write",
    "Microsoft.Network/dnsZones/delete"
  ],
  "AssignableScopes": ["/subscriptions/<your-subscription-id>"]
}'
```

---

## Step 11: DCV Certificate Validation Tests

In the `poc.zava-dnspoc.com` zone, add these TXT records:

| Name | Type | Value | Purpose |
|------|------|-------|---------|
| `_dnsauth` | TXT | `test-dcv-token-single-domain` | DigiCert single-domain DCV |
| `_dnsauth.www` | TXT | `test-dcv-token-subdomain` | DigiCert subdomain DCV |
| `_acme-challenge` | TXT | `test-acme-token-single` | Let's Encrypt single-domain |
| `_acme-challenge.www` | TXT | `test-acme-token-subdomain` | Let's Encrypt subdomain |

**Verify:** Use **nslookup** or the portal "Query" feature to confirm records resolve.

---

## Step 12: Traffic Manager Profiles

Create 3 profiles:

### 12a: Failover (Priority)
1. Search **"Traffic Manager profiles"** → **+ Create**
   - **Name:** `tm-poc-failover-<unique>`
   - **Routing method:** `Priority`
   - **Resource group:** `rg-dns-poc`
   - **TTL:** `30`
2. Click **Create**

### 12b: Geographic
1. **+ Create** another profile
   - **Name:** `tm-poc-geo-<unique>`
   - **Routing method:** `Geographic`
   - **TTL:** `30`
2. Click **Create**

### 12c: Weighted
1. **+ Create** another profile
   - **Name:** `tm-poc-weighted-<unique>`
   - **Routing method:** `Weighted`
   - **TTL:** `30`
2. Click **Create**

---

## Step 13: Web Apps (2 Regions)

### 13a: US Web App
1. Search **"App Services"** → **+ Create** → **Web App**
2. Fill in:
   - **Resource group:** `rg-dns-poc`
   - **Name:** `webapp-poc-us-<unique>`
   - **Runtime stack:** `Node 20 LTS`
   - **Region:** `West US 3`
   - **App Service Plan:** Create new `asp-poc-us`, SKU `B1`
3. Click **Review + create** → **Create**

### 13b: UK Web App
1. **+ Create** another Web App
   - **Name:** `webapp-poc-uk-<unique>`
   - **Region:** `West Europe`
   - **App Service Plan:** Create new `asp-poc-uk`, SKU `B1`
2. Click **Review + create** → **Create**

### 13c: Add TM Endpoints
1. Open each Traffic Manager profile → **Endpoints** → **+ Add**
   - **Type:** `Azure endpoint`
   - **Target resource:** Select the US and UK web apps
   - For **Priority** profile: US = Priority 1, UK = Priority 2
   - For **Weighted**: US = Weight 70, UK = Weight 30
   - For **Geographic**: US = `North America`, UK = `Europe`

### 13d: DNS CNAME Records
In the `poc.zava-dnspoc.com` zone, add:

| Name | Type | TTL | Value |
|------|------|-----|-------|
| `failover` | CNAME | 30 | `tm-poc-failover-<unique>.trafficmanager.net` |
| `geo` | CNAME | 30 | `tm-poc-geo-<unique>.trafficmanager.net` |
| `weighted` | CNAME | 30 | `tm-poc-weighted-<unique>.trafficmanager.net` |

---

## Step 14: Let's Encrypt Certificate (Posh-ACME)

> This step requires PowerShell — open **Cloud Shell** (top-right icon, select PowerShell):

```powershell
# Install Posh-ACME
Install-Module Posh-ACME -Scope CurrentUser -Force
Import-Module Posh-ACME

# Set production LE server
Set-PAServer LE_PROD

# Create ACME account
New-PAAccount -AcceptTOS -Contact "your-email@example.com"

# Get ARM token from current session
$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)

# Request wildcard cert
$cert = New-PACertificate -Domain "poc.zava-dnspoc.com","*.poc.zava-dnspoc.com" `
  -Plugin Azure -PluginArgs @{
    AZSubscriptionId = "<your-subscription-id>"
    AZAccessToken = $token
  }

# Import to Key Vault
az keyvault certificate import --vault-name "kv-dnspoc-zava2026" --name "le-cert" --file $cert.PfxFile
```

**Verify:** Key Vaults → your vault → **Certificates** → `le-cert` should appear

---

## Step 15: Custom Domain + TLS Binding

For **each** hostname (`failover`, `geo`, `weighted`) × **each** web app:

### 15a: Domain Verification
1. Open the US web app → **Custom domains**
2. Copy the **Custom Domain Verification ID** (long string)
3. In the `poc.zava-dnspoc.com` DNS zone, add:
   - **Name:** `asuid.failover` | **Type:** TXT | **Value:** (paste verification ID)
4. Repeat for `asuid.geo` and `asuid.weighted`

### 15b: Add Custom Domain
1. Open the US web app → **Custom domains** → **+ Add custom domain**
2. Enter: `failover.poc.zava-dnspoc.com` → **Validate** → **Add**
3. Repeat for `geo.poc.zava-dnspoc.com` and `weighted.poc.zava-dnspoc.com`
4. Repeat all 3 for the UK web app

### 15c: Bind Certificate
1. Open the US web app → **Certificates** → **Bring your own certificates (.pfx)**
2. Click **+ Add certificate** → **Import from Key Vault**
3. Select your Key Vault → Select `le-cert` → **Add**
4. Go back to **Custom domains** → Click **Add binding** next to each hostname
5. Select the imported certificate → **TLS/SSL type:** `SNI SSL` → **Add**
6. Repeat for the UK web app

**Verify:** Browse to `https://failover.poc.zava-dnspoc.com` — should show a valid Let's Encrypt certificate (padlock icon).

---

## Step 16: DNSSEC

1. Open the `demo.zava-dnspoc.com` zone → **DNSSEC** (left sidebar)
2. Click **Enable DNSSEC signing**
3. Copy the **DS record** details (Key Tag, Algorithm, Digest Type, Digest)
4. Go to the parent zone `zava-dnspoc.com` → **+ Record set**
   - **Name:** `demo`
   - **Type:** `DS`
   - **Key tag / Algorithm / Digest type / Digest:** (paste from step 3)
5. Click **OK**

**Verify:** In Cloud Shell: `az network dns dnssec-config show -g rg-dns-poc -z demo.zava-dnspoc.com`

---

## Step 17: Zone Snapshots

1. Open Cloud Shell
2. Run:
```bash
az network dns zone export -g rg-dns-poc -z poc.zava-dnspoc.com -f snapshot-poc-$(date +%Y%m%d).zone
```
3. Download the file for offline backup

---

## Step 18: Resource Diagnostic Settings

For each web app and TM profile:
1. Open the resource → **Diagnostic settings** → **+ Add diagnostic setting**
2. **Name:** `to-law`
3. Check all available log categories
4. **Destination:** Send to Log Analytics workspace → `law-dns-poc`
5. Click **Save**

---

## Verification Checklist

| # | Check | How to Verify |
|---|-------|---------------|
| 1 | DNS zone resolves | `nslookup poc.zava-dnspoc.com` from any internet connection |
| 2 | Records exist | Portal → DNS zone → Record count > 5 |
| 3 | Activity log flowing | Monitor → Activity log → Filter by `rg-dns-poc` |
| 4 | Event Hub receiving | Event Hub → `dns-logs` → Metrics → Incoming Messages > 0 |
| 5 | RBAC works | Assign DNS Record Operator to test user → verify they can add records but not delete zones |
| 6 | TM failover | Stop US web app → `nslookup failover.poc.zava-dnspoc.com` should return UK app |
| 7 | TLS valid | Browse `https://failover.poc.zava-dnspoc.com` → padlock shows Let's Encrypt cert |
| 8 | DNSSEC signed | `dig demo.zava-dnspoc.com +dnssec` shows RRSIG records |
| 9 | Zone snapshot | Downloaded `.zone` file is valid RFC 1035 format |

---

*Generated from `Zava_DNS_POC_Deployment.ps1` (main branch) — April 1, 2026*
