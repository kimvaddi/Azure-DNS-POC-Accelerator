// ============================================================================
// Key Vault Module for Certificate Storage
// ============================================================================
// Creates a managed Azure Key Vault instance for storing TLS certificates,
// private keys, and DCV-related secrets. Enforces security best practices.

targetScope = 'resourceGroup'

@description('Key Vault name (must be globally unique, 3-24 alphanumeric characters)')
@minLength(3)
@maxLength(24)
param keyVaultName string = 'kvdns${take(uniqueString(subscription().subscriptionId, resourceGroup().id), 18)}'

@description('Azure region')
param location string = resourceGroup().location

@description('Object IDs of principals (users, service principals, applications) that can read certificates and secrets. Format: array of AAD object IDs')
param allowedPrincipalIds array = []

@description('Object IDs of principals that can manage (write, delete) certificates. Should be minimized — usually just administrators.')
param adminPrincipalIds array = []

@description('Enable purge protection (prevents accidental deletion of deleted objects)')
param enablePurgeProtection bool = true

@description('Enable soft delete (keeps deleted objects for 90 days)')
param enableSoftDelete bool = true

@description('Resource tags')
param tags object = {}

// ============================================================================
// VARIABLES
// ============================================================================

var tenantId = subscription().tenantId
var keyVaultDefaultAccessPolicy = {
  tenantId: tenantId
  permissions: {
    certificates: ['get', 'list', 'getissuers', 'listissuers']
    secrets: ['get', 'list']
    keys: ['get', 'list']
  }
}

var keyVaultAdminAccessPolicy = {
  tenantId: tenantId
  permissions: {
    certificates: ['create', 'delete', 'deletIssuers', 'get', 'getissuers', 'import', 'list', 'listissuers', 'purge', 'recover', 'setissuers', 'update']
    secrets: ['backup', 'delete', 'get', 'list', 'purge', 'recover', 'restore', 'set']
    keys: ['backup', 'create', 'decrypt', 'delete', 'encrypt', 'get', 'import', 'list', 'purge', 'recover', 'restore', 'sign', 'unwrapKey', 'update', 'verify', 'wrapKey']
  }
}

// ============================================================================
// RESOURCES
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: union(tags, {
    'purpose': 'certificate-storage'
    'dcv-automation': 'enabled'
  })
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard' // Use 'premium' for HSM-backed keys if needed
    }
    accessPolicies: concat(
      [for principalId in allowedPrincipalIds: union(keyVaultDefaultAccessPolicy, { objectId: principalId })],
      [for adminId in adminPrincipalIds: union(keyVaultAdminAccessPolicy, { objectId: adminId })]
    )
    enabledForDeployment: true // Allow ARM templates to retrieve secrets
    enabledForTemplateDeployment: true // Allow Bicep/ARM to access during deployment
    enabledForDiskEncryption: false // Not needed for certificates
    enableSoftDelete: enableSoftDelete
    softDeleteRetentionInDays: 7 // Minimum allowed value
    enablePurgeProtection: enablePurgeProtection
    publicNetworkAccess: 'Enabled' // For POC; should be 'Disabled' + Private Endpoint in prod
  }
}

// Key Vault diagnostics
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'diag-${keyVaultName}'
  properties: {
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output tenantId string = tenantId
