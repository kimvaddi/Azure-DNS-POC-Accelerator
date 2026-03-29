// ============================================================================
// Web App Hostname Bindings Module
// ============================================================================
// Binds multiple custom hostnames to an existing App Service web app.

@description('Web app name')
param appName string

@description('Hostnames to bind to the web app')
param hostNames array

resource webApp 'Microsoft.Web/sites@2022-09-01' existing = {
  name: appName
}

@batchSize(1)
resource hostNameBindings 'Microsoft.Web/sites/hostNameBindings@2022-09-01' = [for hostName in hostNames: {
  parent: webApp
  name: hostName
  properties: {
    siteName: appName
    hostNameType: 'Verified'
    customHostNameDnsRecordType: 'CName'
  }
}]

output bindingNames array = [for (hostName, i) in hostNames: hostNameBindings[i].name]
