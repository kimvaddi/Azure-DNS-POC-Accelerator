@description('Deployment template for DCV service principal with minimal DNS permissions')
targetScope = 'subscription'

@description('Tenant ID for the Azure subscription')
param tenantId string = '7a3c7f0f-98cc-4c61-94ad-4e25c8c5a27f'

@description('Resource group where DNS zone is located')
param resourceGroupName string = 'rg-dns-poc'

@description('DNS zone name (e.g., zava-dnspoc-001.com)')
param dnsZoneName string = 'zava-dnspoc-001.com'

@description('Service principal display name')
param servicePrincipalName string = 'DCV-Automation-zava-dnspoc-001'

// Get existing resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  name: resourceGroupName
}

// Get existing DNS zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
  scope: rg
}

// Deploy custom RBAC role at subscription scope
module customRole 'modules/custom-role-dns-writer.bicep' = {
  name: 'customRoleDeployment'
  scope: subscription()
}

// Deploy service principal at subscription scope
module servicePrincipal 'modules/service-principal-dns.bicep' = {
  name: 'servicePrincipalDeployment'
  scope: subscription()
  params: {
    tenantId: tenantId
    customRoleId: customRole.outputs.roleDefinitionId
    dnsZoneId: dnsZone.id
    servicePrincipalName: servicePrincipalName
  }
}

@description('Output service principal details')
output servicePrincipalId string = servicePrincipal.outputs.servicePrincipalId
output applicationId string = servicePrincipal.outputs.applicationId
output customRoleId string = customRole.outputs.roleDefinitionId
output dnsZoneId string = dnsZone.id
output dnsZoneName string = dnsZone.name
