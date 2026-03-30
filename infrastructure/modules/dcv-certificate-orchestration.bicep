// ============================================================================
// Complete DCV & Certificate Management Orchestration
// ============================================================================
// This module orchestrates the full workflow:
// 1. Create DNS records for DCV validation
// 2. Deploy custom domain bindings with SSL/TLS
// 3. Manage Key Vault certificates
//
// Call this module for each custom domain that needs TLS certificates.
// It's designed to be reusable and idempotent.

targetScope = 'resourceGroup'

@description('DNS Zone name (public zone, e.g., zava-dnspoc-001.com)')
param dnsZoneName string

@description('Web app names to bind custom domains (array)')
param webAppNames array

@description('Custom domain names (e.g., ["app.zava-dnspoc-001.com", "www.zava-dnspoc-001.com"])')
param customDomainNames array

@description('Key Vault name for storing certificates')
param keyVaultName string = 'kvdns${take(uniqueString(subscription().subscriptionId, resourceGroup().id), 18)}'

@description('Azure region')
param location string = resourceGroup().location

@description('Custom RBAC role ID for DNS record writer')
param customRoleId string

@description('Service principal ID (object ID) to assign the custom DNS role')
param servicePrincipalId string

@description('DCV records to create (array of { subdomain, recordName, token, comment })')
@metadata({
  example: [
    {
      subdomain: 'app'
      recordName: '_dnsauth'
      token: 'digicert-dcv-value'
      comment: 'DigiCert DCV'
    }
  ]
})
param dcvRecords array = []

@description('Tags for all resources')
param tags object = {}

// ============================================================================
// VARIABLES
// ============================================================================

var keyVaultDefaultAccessPolicy = {
  tenantId: subscription().tenantId
  permissions: {
    certificates: ['get', 'list']
    secrets: ['get', 'list']
    keys: ['get', 'list']
  }
}

// ============================================================================
// RESOURCES
// ============================================================================

// Get reference to DNS Zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
}

// Create or update Key Vault for certificate storage
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: union(tags, {
    'purpose': 'certificate-storage'
    'dcv-automation': 'enabled'
  })
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: [
      union(keyVaultDefaultAccessPolicy, { objectId: servicePrincipalId })
    ]
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
  }
}

// Create DCV TXT records
module dcvRecordsModule 'dcv-txt-records.bicep' = if (length(dcvRecords) > 0) {
  name: 'deploy-dcv-records'
  params: {
    dnsZoneName: dnsZoneName
    dcvRecords: dcvRecords
  }
}

// Create custom domain bindings for each web app
module customDomainBindings 'web-app-hostname-bindings.bicep' = [for (webAppName, i) in webAppNames: {
  name: 'deploy-custom-domains-${webAppName}'
  params: {
    appName: webAppName
    hostNames: customDomainNames
  }
}]

// ============================================================================
// OUTPUTS
// ============================================================================

output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultName string = keyVault.name
output dnsZoneId string = dnsZone.id
output dcvRecordDetails array = length(dcvRecords) > 0 ? dcvRecordsModule.outputs.dcvRecordNames : []
output customDomainBindings array = [for (binding, i) in customDomainBindings: {
  webApp: webAppNames[i]
  bindingNames: binding.outputs.bindingNames
}]
