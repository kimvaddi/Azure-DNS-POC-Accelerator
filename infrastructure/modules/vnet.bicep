// ============================================================================
// Virtual Network Module
// ============================================================================
// VNet with single subnet for private DNS zone testing

@description('Virtual network name')
param vnetName string

@description('Azure region')
param location string

@description('VNet address prefix (CIDR)')
param addressPrefix string = '10.0.0.0/16'

@description('Subnet name')
param subnetName string = 'default'

@description('Subnet address prefix (CIDR)')
param subnetPrefix string = '10.0.0.0/24'

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetId string = vnet.properties.subnets[0].id
output subnetName string = vnet.properties.subnets[0].name
