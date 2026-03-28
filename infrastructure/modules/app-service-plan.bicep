// ============================================================================
// App Service Plan Module
// ============================================================================
// Linux or Windows app service plan for hosting web apps

@description('App Service Plan name')
param planName string

@description('Azure region')
param location string

@description('SKU name (B1, S1, P1v2, etc.)')
param skuName string = 'B1'

@description('Number of instances')
@minValue(1)
@maxValue(30)
param skuCapacity int = 1

@description('OS type')
@allowed([
  'Linux'
  'Windows'
])
param osType string = 'Linux'

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  kind: osType == 'Linux' ? 'linux' : ''
  properties: {
    reserved: osType == 'Linux'
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output planId string = appServicePlan.id
output planName string = appServicePlan.name
