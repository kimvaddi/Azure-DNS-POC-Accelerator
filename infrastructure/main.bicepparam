// ============================================================================
// Parameters file for Zava DNS POC Deployment
// ============================================================================
// Use this file with: az deployment sub create --template-file main.bicep --parameters main.bicepparam

using './main.bicep'

// ============================================================================
// LOCATION PARAMETERS
// ============================================================================

param location = 'southcentralus'
param locationPrimary = 'westus3'
param locationSecondary = 'westeurope'

// ============================================================================
// RESOURCE GROUP
// ============================================================================

param rgName = 'rg-dns-poc'

// ============================================================================
// DNS DOMAINS
// ============================================================================
// NOTE: 'domain' (public zone name) is NOT set here.
// deploy.ps1 auto-discovers the first available zava-dnspoc-001.com / 002 / ...
// and passes it as a --parameters override at deployment time.
// For direct az CLI runs: --parameters domain=zava-dnspoc-001.com

param privateDomain = 'poc-internal.zava.local'

// App Service worker quota is currently restricted in this subscription.
// Keep disabled for core DNS/Event Hub deployment success.
param deployWebApps = true

// Preserve current ACME/Let's Encrypt custom-domain TLS bindings during redeployments.
param enableCustomDomainTls = true
param customDomainCertificateThumbprint = '8652E6320D9C23BD85AB6FC2450C918A1AA5DCA6'

// End-to-end Let's Encrypt automation (issue + import to Key Vault + bind to both web apps).
param enableLetsEncryptAutomation = true
param letsEncryptContactEmail = 'dmauser@hotmail.com'
param keyVaultName = 'kv-dcv-poc'
param letsEncryptCertificateName = 'le-wildcard-zava'

// After a fresh deployment (deployWebApps=false) there are no Traffic Manager
// profiles yet, so aliases cannot be created. Set to true only after web apps
// are deployed and TM profiles exist.
param deployTrafficManagerDnsAliases = true

// ============================================================================
// APP SERVICE DOMAIN REGISTRATION
// ============================================================================
// Purchases the auto-discovered domain and binds it to the Azure DNS Zone.
// Set to false to skip registration (e.g., if domain already purchased).
param deployAppServiceDomain = true

// Contact information used for domain WHOIS registration.
// Update email, phone, and address to reflect actual Zava team contact.
param domainContactInfo = {
  nameFirst: 'DNS'
  nameLast: 'Admin'
  email: 'dnsadmin@zava.com'
  phone: '+1.2105550100'
  organization: 'Zava Energy Corporation'
  address1: '100 Energy Way'
  city: 'San Antonio'
  state: 'TX'
  postalCode: '78201'
  country: 'US'
}
// domainConsentAgreedBy and domainConsentAgreedAt are set dynamically by
// deploy.ps1 using the operator's public IP and current timestamp.

// ============================================================================
// WEB APP NAMES
// ============================================================================
// Note: defaults in main.bicep use uniqueString(subscription().subscriptionId)
// Override here only if you need a specific name (must be globally unique)

// ============================================================================
// INFRASTRUCTURE NAMES
// ============================================================================
// Note: storageAccountName and eventHubNamespaceName defaults in main.bicep
// are auto-unique via uniqueString(). Override here only if needed.
param lawName = 'law-dns-poc'

// ============================================================================
// TAGS
// ============================================================================

param tags = {
  project: 'dns-poc'
  customer: 'Zava'
  environment: 'poc'
  'managed-by': 'bicep'
  'created-date': '2026-03-27'
  contact: 'kim-vaddi'
}
