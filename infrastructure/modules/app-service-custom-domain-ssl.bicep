// ============================================================================
// App Service Custom Domain SSL/TLS Module
// ============================================================================
// Binds a custom domain to a web app and associates with a Key Vault certificate.
// Supports both managed certificates and BYOC (bring your own certificate).

targetScope = 'resourceGroup'

@description('Web App resource ID')
param webAppResourceId string

@description('Custom domain name (e.g., app.zava-dnspoc-001.com)')
param customDomainName string

@description('Key Vault resource ID containing the certificate')
param keyVaultId string

@description('Certificate name in Key Vault')
param certificateName string

@description('Thumbprint of the certificate (required for binding)')
param certificateThumbprint string

@description('Enable Server Name Indication (SNI) - recommended for Azure App Service')
param useSni bool = true

// ============================================================================
// VARIABLES
// ============================================================================

var webAppName = last(split(webAppResourceId, '/'))
var resourceGroupName = split(webAppResourceId, '/')[4]

// ============================================================================
// RESOURCES
// ============================================================================

// Reference the existing web app
resource webApp 'Microsoft.Web/sites@2022-09-01' existing = {
  name: webAppName
}

// Bind the custom domain to the web app (creates CNAME record binding)
resource customDomainBinding 'Microsoft.Web/sites/hostNameBindings@2022-09-01' = {
  parent: webApp
  name: customDomainName
  properties: {
    siteName: webAppName
    hostNameType: 'Verified'
    customHostNameDnsRecordType: 'CName'
    sslState: 'SniEnabled'
    thumbprint: certificateThumbprint
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output customDomainBindingId string = customDomainBinding.id
output customDomainBindingName string = customDomainBinding.name
output sslState string = customDomainBinding.properties.sslState
