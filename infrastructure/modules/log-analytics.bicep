// ============================================================================
// Log Analytics Workspace Module
// ============================================================================
// Central logging and monitoring workspace for all diagnostic data

@description('Log Analytics Workspace name')
param workspaceName string

@description('Azure region for the workspace')
param location string

@description('Data retention in days (30-730)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Pricing tier')
@allowed([
  'PerGB2018'
  'CapacityReservation'
  'Free'
])
param skuName string = 'PerGB2018'

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: skuName
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output customerId string = workspace.properties.customerId
