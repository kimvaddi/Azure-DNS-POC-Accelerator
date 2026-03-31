// ============================================================================
// Private DNS Zone Module
// ============================================================================
// Private DNS zone with VNet link and sample A records

@description('Private DNS zone name (e.g., poc-internal.zava-dnspoc.local)')
param zoneName string

@description('VNet ID to link for DNS resolution')
param vnetId string

@description('VNet link name')
param vnetLinkName string

@description('Array of A records to create')
param aRecords array = []

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

// Private DNS Zone
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
  properties: {}
}

// VNet Link (enables DNS resolution from VNet)
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: vnetLinkName
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// A Records (loop through array)
resource aRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = [for record in aRecords: {
  parent: privateDnsZone
  name: record.name
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: record.ipAddress
      }
    ]
  }
}]

// ============================================================================
// OUTPUTS
// ============================================================================

output zoneId string = privateDnsZone.id
output zoneName string = privateDnsZone.name
output vnetLinkId string = vnetLink.id
