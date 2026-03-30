// ============================================================================
// Web App Hostname Bindings Module
// ============================================================================
// Binds multiple custom hostnames to an existing App Service web app.

@description('Web app name')
param appName string

@description('Hostnames to bind to the web app')
param hostNames array

@description('Enable SNI TLS binding for each hostname')
param enableSslBinding bool = false

@description('Certificate thumbprint for SNI binding (required when enableSslBinding=true)')
param certificateThumbprint string = ''

resource webApp 'Microsoft.Web/sites@2022-09-01' existing = {
  name: appName
}

@batchSize(1)
resource hostNameBindings 'Microsoft.Web/sites/hostNameBindings@2022-09-01' = [for hostName in hostNames: {
  parent: webApp
  name: hostName
  properties: union({
    siteName: appName
    hostNameType: 'Verified'
    customHostNameDnsRecordType: 'CName'
  }, enableSslBinding ? {
    sslState: 'SniEnabled'
    thumbprint: certificateThumbprint
  } : {})
}]

output bindingNames array = [for (hostName, i) in hostNames: hostNameBindings[i].name]
