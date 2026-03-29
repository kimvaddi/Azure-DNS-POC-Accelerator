// ============================================================================
// Event Hub Module
// ============================================================================
// Event Hub Namespace and Hub for QRadar integration
// IMPORTANT: Standard SKU required for consumer groups

@description('Event Hub Namespace name')
param namespaceName string

@description('Event Hub name')
param eventHubName string

@description('Azure region')
param location string

@description('SKU name (Standard required for consumer groups)')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param skuName string = 'Standard'

@description('Number of partitions (2-32)')
@minValue(2)
@maxValue(32)
param partitionCount int = 2

@description('Message retention in days (1-7)')
@minValue(1)
@maxValue(7)
param messageRetentionInDays int = 1

@description('Consumer group name for QRadar')
param consumerGroupName string = 'qradar-consumer'

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

// Event Hub Namespace
resource namespace 'Microsoft.EventHub/namespaces@2023-01-01-preview' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuName
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: false
    maximumThroughputUnits: 0
    zoneRedundant: false
  }
}

// Event Hub
resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2023-01-01-preview' = {
  parent: namespace
  name: eventHubName
  properties: {
    messageRetentionInDays: messageRetentionInDays
    partitionCount: partitionCount
    status: 'Active'
    captureDescription: {
      enabled: false
    }
  }
}

// Authorization Rule: Send (for diagnostic settings)
resource sendAuthRule 'Microsoft.EventHub/namespaces/authorizationRules@2023-01-01-preview' = {
  parent: namespace
  name: 'SendPolicy'
  properties: {
    rights: [
      'Send'
    ]
  }
}

// Authorization Rule: Listen (for QRadar)
resource listenAuthRule 'Microsoft.EventHub/namespaces/authorizationRules@2023-01-01-preview' = {
  parent: namespace
  name: 'QRadarListenPolicy'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

// Consumer Group for QRadar
resource consumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2023-01-01-preview' = {
  parent: eventHub
  name: consumerGroupName
  properties: {
    userMetadata: 'QRadar consumer group'
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output namespaceId string = namespace.id
output namespaceName string = namespace.name
output eventHubId string = eventHub.id
output eventHubName string = eventHub.name
output sendAuthRuleId string = sendAuthRule.id
output listenAuthRuleId string = listenAuthRule.id

@description('Connection string for sending events (diagnostic settings)')
@secure()
output sendConnectionString string = sendAuthRule.listKeys().primaryConnectionString

@description('Connection string for QRadar consumer')
@secure()
output listenConnectionString string = listenAuthRule.listKeys().primaryConnectionString

output consumerGroupName string = consumerGroup.name
