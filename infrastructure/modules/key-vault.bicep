// ============================================================================
// Key Vault Module — Certificate Storage for DCV Automation
// ============================================================================
// Purpose: Store TLS certificates issued via DigiCert/ACME DCV workflow
// RBAC: Key Vault Administrator (deployer) + Certificates Officer (SP)
// ============================================================================

@description('Key Vault name')
param kvName string

@description('Location for the Key Vault')
param location string

@description('Tags to apply')
param tags object = {}

@description('Enable RBAC authorization (recommended over access policies)')
param enableRbacAuthorization bool = true

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: enableRbacAuthorization
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: false // POC only — enable in production
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
