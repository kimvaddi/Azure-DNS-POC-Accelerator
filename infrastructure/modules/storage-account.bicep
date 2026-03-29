// ============================================================================
// Storage Account Module
// ============================================================================
// General-purpose storage for QRadar checkpoint tracking

@description('Storage account name (3-24 chars, lowercase alphanumeric)')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region')
param location string

@description('SKU name')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
  'Premium_LRS'
])
param skuName string = 'Standard_LRS'

@description('Storage account kind')
@allowed([
  'Storage'
  'StorageV2'
  'BlobStorage'
])
param kind string = 'StorageV2'

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: kind
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output primaryEndpoints object = storageAccount.properties.primaryEndpoints

@description('Storage account primary connection string')
@secure()
output connectionString string = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
