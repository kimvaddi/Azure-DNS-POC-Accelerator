// ============================================================================
// Web App Module
// ============================================================================
// App Service with diagnostic settings and security hardening

@description('Web app name (must be globally unique)')
param appName string

@description('Azure region')
param location string

@description('App Service Plan resource ID')
param appServicePlanId string

@description('Log Analytics Workspace ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('.NET Framework version')
param netFrameworkVersion string = 'v8.0'

@description('App settings to stamp onto the web app')
param appSettings object = {}

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

// Web App
resource webApp 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'app'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      netFrameworkVersion: netFrameworkVersion
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
  }
}

resource webAppAppSettings 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  parent: webApp
  properties: appSettings
}

// Diagnostic Settings
// Use categoryGroup to avoid region/SKU-specific category mismatches.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: webApp
  name: 'diag-${appName}'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output appId string = webApp.id
output appName string = webApp.name
output defaultHostName string = webApp.properties.defaultHostName
output outboundIpAddresses string = webApp.properties.outboundIpAddresses
output customDomainVerificationId string = webApp.properties.customDomainVerificationId
