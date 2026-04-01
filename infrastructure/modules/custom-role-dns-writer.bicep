// ============================================================================
// Custom RBAC Role: DNS Record Writer (No Delete)
// ============================================================================
// Allows creation and modification of DNS records but NOT deletion.
// Used for DCV (Domain Control Validation) automation with minimal privileges.
// Scope: DNS Zone level

targetScope = 'subscription'

@description('Subscription ID where this role definition will be created')
param subscriptionId string = subscription().subscriptionId

@description('Role display name')
param roleName string = 'DNS Record Writer'

@description('Role description')
param roleDescription string = 'Create, read, and update DNS records. Cannot delete records. Used for DCV automation.'

// ============================================================================
// RESOURCES
// ============================================================================

resource customRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscriptionId, roleName) // Stable GUID based on subscription + role name
  properties: {
    roleName: roleName
    description: roleDescription
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Network/dnsZones/read'
          'Microsoft.Network/dnsZones/recordSets/read'
          'Microsoft.Network/dnsZones/recordSets/A/read'
          'Microsoft.Network/dnsZones/recordSets/AAAA/read'
          'Microsoft.Network/dnsZones/recordSets/CNAME/read'
          'Microsoft.Network/dnsZones/recordSets/MX/read'
          'Microsoft.Network/dnsZones/recordSets/NS/read'
          'Microsoft.Network/dnsZones/recordSets/PTR/read'
          'Microsoft.Network/dnsZones/recordSets/SRV/read'
          'Microsoft.Network/dnsZones/recordSets/TXT/read'
          'Microsoft.Network/dnsZones/recordSets/SOA/read'
          'Microsoft.Network/dnsZones/recordSets/CAA/read'
          'Microsoft.Network/dnsZones/recordSets/A/write'
          'Microsoft.Network/dnsZones/recordSets/AAAA/write'
          'Microsoft.Network/dnsZones/recordSets/CNAME/write'
          'Microsoft.Network/dnsZones/recordSets/MX/write'
          'Microsoft.Network/dnsZones/recordSets/NS/write'
          'Microsoft.Network/dnsZones/recordSets/PTR/write'
          'Microsoft.Network/dnsZones/recordSets/SRV/write'
          'Microsoft.Network/dnsZones/recordSets/TXT/write'
          'Microsoft.Network/dnsZones/recordSets/CAA/write'
          'Microsoft.Network/dnsZones/*/read'
          'Microsoft.Authorization/*/read'
        ]
        notActions: [
          'Microsoft.Network/dnsZones/recordSets/delete'
          'Microsoft.Network/dnsZones/recordSets/*/delete'
        ]
      }
    ]
    assignableScopes: [
      '/subscriptions/${subscriptionId}'
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output roleId string = customRole.id
output roleName string = customRole.properties.roleName
output roleDefinitionId string = customRole.name
