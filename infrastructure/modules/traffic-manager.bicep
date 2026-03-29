// ============================================================================
// Traffic Manager Profile Module
// ============================================================================
// Supports Priority, Geographic, and Weighted routing methods

@description('Traffic Manager profile name')
param profileName string

@description('Routing method')
@allowed([
  'Priority'
  'Weighted'
  'Performance'
  'Geographic'
  'MultiValue'
  'Subnet'
])
param routingMethod string

@description('DNS configuration')
param dnsConfig object

@description('Monitor configuration')
param monitorConfig object

@description('Array of endpoints')
param endpoints array

@description('Log Analytics Workspace ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object = {}

// ============================================================================
// RESOURCES
// ============================================================================

// Traffic Manager Profile
resource profile 'Microsoft.Network/trafficmanagerprofiles@2022-04-01' = {
  name: profileName
  location: 'global'
  tags: tags
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: routingMethod
    dnsConfig: {
      relativeName: dnsConfig.relativeName
      ttl: dnsConfig.ttl
    }
    monitorConfig: {
      protocol: monitorConfig.protocol
      port: monitorConfig.port
      path: monitorConfig.path
      intervalInSeconds: monitorConfig.intervalInSeconds
      toleratedNumberOfFailures: monitorConfig.toleratedNumberOfFailures
      timeoutInSeconds: monitorConfig.timeoutInSeconds
    }
  }
}

// Endpoints (loop through array)
resource endpoint 'Microsoft.Network/trafficManagerProfiles/azureEndpoints@2022-04-01' = [for ep in endpoints: {
  parent: profile
  name: ep.name
  properties: {
    targetResourceId: ep.targetResourceId
    endpointStatus: 'Enabled'
    priority: ep.?priority
    weight: ep.?weight
    endpointLocation: ep.endpointLocation
    geoMapping: ep.?geoMapping
  }
}]

// Diagnostic Settings
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: profile
  name: 'diag-${profileName}'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'ProbeHealthStatusEvents'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
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

output profileId string = profile.id
output profileName string = profile.name
output tmFqdn string = profile.properties.dnsConfig.fqdn
