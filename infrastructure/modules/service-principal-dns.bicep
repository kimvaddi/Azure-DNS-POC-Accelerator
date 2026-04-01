// ============================================================================
// Service Principal for DNS DCV Automation
// ============================================================================
// Creates a Microsoft Entra ID (Azure AD) service principal with minimal
// privileges scoped to a specific DNS zone. Used for automated Domain
// Control Validation (DCV) without exposing tenant-wide credentials.

targetScope = 'subscription'

@description('Service principal display name (e.g., "DCV-DNS-zava-dnspoc-001")')
param servicePrincipalName string

@description('DNS Zone resource ID (full path)')
param dnsZoneResourceId string

@description('Custom role ID (from custom-role-dns-writer.bicep output)')
param customRoleId string

@description('Tags for tracking and automation')
param tags object = {}

// ============================================================================
// VARIABLES
// ============================================================================

var guidSeed = '${servicePrincipalName}-${dnsZoneResourceId}'
var appRegistrationId = guid(guidSeed) // Stable GUID for idempotency

// ============================================================================
// RESOURCES
// ============================================================================

// Microsoft Entra ID App Registration
// (This is the identity that will authenticate as a service principal)
resource appRegistration 'Microsoft.AAD/applications@2022-12-01' = {
  displayName: servicePrincipalName
  uniqueIdentifier: appRegistrationId
  description: 'Service Principal for automated DNS DCV validation on ${last(split(dnsZoneResourceId, '/'))}' 
  tags: union(tags, {
    'purpose': 'DCV-DNS-automation'
    'dns-zone': last(split(dnsZoneResourceId, '/'))
    'created': utcNow('u')
  })
}

// Service Principal (OAuth2 credential object)
resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  displayName: servicePrincipalName
  appId: appRegistration.appId
  accountEnabled: true
  tags: union(tags, {
    'purpose': 'DCV-DNS-automation'
  })
}

// Role assignment: Assign custom DNS Writer role to the service principal
// Scoped at the DNS zone level for minimal privilege
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, servicePrincipal.id, customRoleId)
  properties: {
    roleDefinitionId: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/${last(split(customRoleId, '/'))}'
    principalId: servicePrincipal.id
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output servicePrincipalId string = servicePrincipal.id
output servicePrincipalName string = servicePrincipal.displayName
output appRegistrationId string = appRegistration.id
output appId string = appRegistration.appId
output roleName string = 'DNS Record Writer'
