// ============================================================================
// Resource Lock Module
// ============================================================================
// Applies CanNotDelete or ReadOnly lock to a DNS zone

@description('Name of the DNS zone to lock')
param resourceName string

@description('Lock name')
param lockName string

@description('Lock level')
@allowed([
  'CanNotDelete'
  'ReadOnly'
])
param lockLevel string

@description('Lock notes')
param lockNotes string = ''

// ============================================================================
// RESOURCES
// ============================================================================

// Reference existing DNS zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: resourceName
}

// Apply lock to DNS zone
resource lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: dnsZone
  name: lockName
  properties: {
    level: lockLevel
    notes: lockNotes
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output lockId string = lock.id
output lockName string = lock.name
