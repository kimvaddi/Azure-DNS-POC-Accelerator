// ============================================================================
// Activity Log Diagnostic Settings Module
// ============================================================================
// Subscription-level diagnostic settings for Azure Activity Log
// Sends all 8 categories to Event Hub and Log Analytics

targetScope = 'subscription'

@description('Diagnostic setting name')
param diagnosticSettingName string

@description('Event Hub authorization rule ID')
param eventHubAuthorizationRuleId string

@description('Event Hub name')
param eventHubName string

@description('Log Analytics Workspace ID')
param workspaceId string

// ============================================================================
// RESOURCES
// ============================================================================

resource activityLogDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  properties: {
    eventHubAuthorizationRuleId: eventHubAuthorizationRuleId
    eventHubName: eventHubName
    workspaceId: workspaceId
    logs: [
      {
        category: 'Administrative'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'Security'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'ServiceHealth'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'Alert'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'Recommendation'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'Policy'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'Autoscale'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'ResourceHealth'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output diagnosticSettingId string = activityLogDiagnostics.id
output diagnosticSettingName string = activityLogDiagnostics.name
