// ============================================================================
// App Service Domain Registration Module
// ============================================================================
// Purchases a custom domain via Azure App Service Domain (GoDaddy-backed).
// Binds the domain to an existing Azure DNS Zone so NS records are
// automatically configured at the registrar — no manual delegation needed.
//
// Cost:    ~$11–15/year for a .com domain (billed to the subscription).
// Note:    autoRenew defaults to false — enable before expiry if the domain
//          should persist beyond the POC period.

@description('Domain name to purchase and register (e.g., zava-dnspoc-001.com)')
param domainName string

@description('Resource ID of the existing Azure DNS Zone to bind this domain to')
param dnsZoneId string

@description('''Contact information for domain WHOIS registration.
Required fields: nameFirst, nameLast, email, phone (+1.XXXXXXXXXX),
address1, city, state, postalCode, country (ISO 3166-1 alpha-2, e.g. "US").
Optional: organization.''')
param contactInfo object

@description('ISO 8601 UTC timestamp when the operator agreed to the domain registration terms of service')
param consentAgreedAt string

@description('Public IP address of the deployment operator for domain registration consent record')
param consentAgreedBy string

@description('Disable auto-renewal — recommended for short-lived POC environments')
param autoRenew bool = false

@description('Enable WHOIS privacy protection to hide contact details from the public WHOIS database')
param privacy bool = true

@description('Resource tags')
param tags object = {}

// ============================================================================
// LOCALS
// ============================================================================

// Flatten the contactInfo object into the ARM contact schema
var contact = {
  addressMailing: {
    address1: contactInfo.address1
    city: contactInfo.city
    country: contactInfo.country
    postalCode: contactInfo.postalCode
    state: contactInfo.state
  }
  email: contactInfo.email
  nameFirst: contactInfo.nameFirst
  nameLast: contactInfo.nameLast
  organization: contactInfo.?organization ?? ''
  phone: contactInfo.phone
}

// ============================================================================
// RESOURCES
// ============================================================================

resource appDomain 'Microsoft.DomainRegistration/domains@2022-09-01' = {
  name: domainName
  location: 'global'
  tags: tags
  properties: {
    contactAdmin: contact
    contactBilling: contact
    contactRegistrant: contact
    contactTech: contact
    privacy: privacy
    autoRenew: autoRenew
          consent: {
            agreementKeys: ['DNRA', 'DNPA']
      agreedAt: consentAgreedAt
      agreedBy: consentAgreedBy
    }
    // AzureDns: binds to an existing Azure DNS Zone (dnsZoneId required)
    // NS records at the GoDaddy registrar are automatically updated to
    // point to Azure DNS — fully automated end-to-end.
    dnsType: 'AzureDns'
    dnsZoneId: dnsZoneId
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output domainId string = appDomain.id
output domainName string = appDomain.name
output registrationStatus string = appDomain.properties.?registrationStatus ?? 'Pending'
