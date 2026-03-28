// ============================================================================
// Zava Azure DNS POC - Main Bicep Template
// ============================================================================
// Deploys complete DNS POC infrastructure including:
// - Public and Private DNS Zones
// - Event Hub for QRadar integration
// - Log Analytics Workspace
// - Traffic Manager profiles (Failover, Geographic, Weighted)
// - Multi-region Web Apps for testing
// - Diagnostic settings and monitoring
// ============================================================================

targetScope = 'subscription'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Primary location for most resources (closest to San Antonio, TX)')
param location string = 'southcentralus'

@description('Primary web app region (US West)')
param locationPrimary string = 'westus3'

@description('Secondary web app region (Asia for geographic routing test)')
param locationSecondary string = 'eastasia'

@description('Resource group name')
param rgName string = 'rg-dns-poc'

@description('Public DNS domain for the POC')
param domain string = 'poc.Zava.com'

@description('Private DNS domain for internal resources')
param privateDomain string = 'poc-internal.Zava.local'

@description('Web app name for US region')
param webAppNameUS string = 'webapp-poc-us'

@description('Web app name for UK/Asia region')
param webAppNameUK string = 'webapp-poc-uk'

@description('Storage account name for QRadar checkpoint tracking (must be globally unique)')
@maxLength(24)
param storageAccountName string = 'stqradarpoc${uniqueString(subscription().subscriptionId)}'

@description('Event Hub namespace name')
param eventHubNamespaceName string = 'ehns-dns-poc'

@description('Log Analytics workspace name')
param lawName string = 'law-dns-poc'

@description('Tags to apply to all resources')
param tags object = {
  project: 'dns-poc'
  customer: 'Zava'
  environment: 'poc'
  managed-by: 'bicep'
}

// ============================================================================
// RESOURCE GROUP
// ============================================================================

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: tags
}

// ============================================================================
// LOG ANALYTICS WORKSPACE
// ============================================================================
// Central logging destination for all diagnostic data

module logAnalytics 'modules/log-analytics.bicep' = {
  scope: rg
  name: 'deploy-log-analytics'
  params: {
    workspaceName: lawName
    location: location
    retentionInDays: 30
    skuName: 'PerGB2018'
    tags: tags
  }
}

// ============================================================================
// EVENT HUB NAMESPACE & HUB
// ============================================================================
// Standard SKU required for consumer groups (QRadar integration)

module eventHub 'modules/event-hub.bicep' = {
  scope: rg
  name: 'deploy-event-hub'
  params: {
    namespaceName: eventHubNamespaceName
    eventHubName: 'dns-logs'
    location: location
    skuName: 'Standard'
    partitionCount: 2
    messageRetentionInDays: 1
    consumerGroupName: 'qradar-consumer'
    tags: tags
  }
}

// ============================================================================
// STORAGE ACCOUNT
// ============================================================================
// For QRadar checkpoint tracking and Event Hub consumer offsets

module storage 'modules/storage-account.bicep' = {
  scope: rg
  name: 'deploy-storage'
  params: {
    storageAccountName: storageAccountName
    location: location
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    tags: tags
  }
}

// ============================================================================
// VIRTUAL NETWORK
// ============================================================================
// VNet for private DNS zone testing

module vnet 'modules/vnet.bicep' = {
  scope: rg
  name: 'deploy-vnet'
  params: {
    vnetName: 'vnet-dns-poc'
    location: location
    addressPrefix: '10.0.0.0/16'
    subnetName: 'default'
    subnetPrefix: '10.0.0.0/24'
    tags: tags
  }
}

// ============================================================================
// PUBLIC DNS ZONE
// ============================================================================
// Primary POC DNS zone (poc.Zava.com)

module publicDnsZone 'modules/public-dns-zone.bicep' = {
  scope: rg
  name: 'deploy-public-dns-zone'
  params: {
    zoneName: domain
    tags: tags
  }
}

// ============================================================================
// PRIVATE DNS ZONE
// ============================================================================
// Internal DNS zone with VNet link and sample A records

module privateDnsZone 'modules/private-dns-zone.bicep' = {
  scope: rg
  name: 'deploy-private-dns-zone'
  params: {
    zoneName: privateDomain
    vnetId: vnet.outputs.vnetId
    vnetLinkName: 'link-vnet-dns-poc'
    aRecords: [
      { name: 'db', ipAddress: '10.0.1.100' }
      { name: 'app', ipAddress: '10.0.1.101' }
      { name: 'cache', ipAddress: '10.0.1.102' }
    ]
    tags: tags
  }
}

// ============================================================================
// APP SERVICE PLANS (MULTI-REGION)
// ============================================================================
// B1 tier for cost-effective POC testing

module appServicePlanUS 'modules/app-service-plan.bicep' = {
  scope: rg
  name: 'deploy-asp-us'
  params: {
    planName: 'asp-poc-us'
    location: locationPrimary
    skuName: 'B1'
    skuCapacity: 1
    tags: tags
  }
}

module appServicePlanUK 'modules/app-service-plan.bicep' = {
  scope: rg
  name: 'deploy-asp-uk'
  params: {
    planName: 'asp-poc-uk'
    location: locationSecondary
    skuName: 'B1'
    skuCapacity: 1
    tags: tags
  }
}

// ============================================================================
// WEB APPS (MULTI-REGION)
// ============================================================================
// .NET 8 web apps with security hardening

module webAppUS 'modules/web-app.bicep' = {
  scope: rg
  name: 'deploy-webapp-us'
  params: {
    appName: webAppNameUS
    location: locationPrimary
    appServicePlanId: appServicePlanUS.outputs.planId
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    netFrameworkVersion: 'v8.0'
    tags: tags
  }
}

module webAppUK 'modules/web-app.bicep' = {
  scope: rg
  name: 'deploy-webapp-uk'
  params: {
    appName: webAppNameUK
    location: locationSecondary
    appServicePlanId: appServicePlanUK.outputs.planId
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    netFrameworkVersion: 'v8.0'
    tags: tags
  }
}

// ============================================================================
// TRAFFIC MANAGER PROFILES
// ============================================================================
// Three profiles: Priority (failover), Geographic, Weighted

module trafficManagerFailover 'modules/traffic-manager.bicep' = {
  scope: rg
  name: 'deploy-tm-failover'
  params: {
    profileName: 'tm-poc-failover'
    routingMethod: 'Priority'
    dnsConfig: {
      relativeName: 'tm-poc-failover'
      ttl: 30
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/'
      intervalInSeconds: 30
      toleratedNumberOfFailures: 3
      timeoutInSeconds: 10
    }
    endpoints: [
      {
        name: 'us-primary'
        targetResourceId: webAppUS.outputs.appId
        priority: 1
        endpointLocation: locationPrimary
      }
      {
        name: 'uk-secondary'
        targetResourceId: webAppUK.outputs.appId
        priority: 2
        endpointLocation: locationSecondary
      }
    ]
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
}

module trafficManagerGeo 'modules/traffic-manager.bicep' = {
  scope: rg
  name: 'deploy-tm-geo'
  params: {
    profileName: 'tm-poc-geo'
    routingMethod: 'Geographic'
    dnsConfig: {
      relativeName: 'tm-poc-geo'
      ttl: 30
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/'
      intervalInSeconds: 30
      toleratedNumberOfFailures: 3
      timeoutInSeconds: 10
    }
    endpoints: [
      {
        name: 'us-endpoint'
        targetResourceId: webAppUS.outputs.appId
        geoMapping: [ 'US', 'CA', 'MX' ]
        endpointLocation: locationPrimary
      }
      {
        name: 'uk-endpoint'
        targetResourceId: webAppUK.outputs.appId
        geoMapping: [ 'GB', 'WORLD' ]
        endpointLocation: locationSecondary
      }
    ]
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
}

module trafficManagerWeighted 'modules/traffic-manager.bicep' = {
  scope: rg
  name: 'deploy-tm-weighted'
  params: {
    profileName: 'tm-poc-weighted'
    routingMethod: 'Weighted'
    dnsConfig: {
      relativeName: 'tm-poc-weighted'
      ttl: 30
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/'
      intervalInSeconds: 30
      toleratedNumberOfFailures: 3
      timeoutInSeconds: 10
    }
    endpoints: [
      {
        name: 'us-70pct'
        targetResourceId: webAppUS.outputs.appId
        weight: 70
        endpointLocation: locationPrimary
      }
      {
        name: 'uk-30pct'
        targetResourceId: webAppUK.outputs.appId
        weight: 30
        endpointLocation: locationSecondary
      }
    ]
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
}

// ============================================================================
// DNS CNAME RECORDS FOR TRAFFIC MANAGER
// ============================================================================
// Wire up DNS to Traffic Manager endpoints (TTL=30 for fast failover)

module dnsRecords 'modules/dns-cname-records.bicep' = {
  scope: rg
  name: 'deploy-dns-cnames'
  params: {
    zoneName: domain
    cnameRecords: [
      {
        name: 'failover'
        targetFqdn: trafficManagerFailover.outputs.tmFqdn
        ttl: 30
      }
      {
        name: 'geo'
        targetFqdn: trafficManagerGeo.outputs.tmFqdn
        ttl: 30
      }
      {
        name: 'weighted'
        targetFqdn: trafficManagerWeighted.outputs.tmFqdn
        ttl: 30
      }
    ]
  }
  dependsOn: [
    publicDnsZone
  ]
}

// ============================================================================
// SUBSCRIPTION-LEVEL DIAGNOSTIC SETTINGS
// ============================================================================
// Activity Log → Event Hub + Log Analytics (all 8 categories)

module activityLogDiagnostics 'modules/activity-log-diagnostics.bicep' = {
  scope: subscription()
  name: 'deploy-activity-log-diagnostics'
  params: {
    diagnosticSettingName: 'activity-log-to-eventhub'
    eventHubAuthorizationRuleId: eventHub.outputs.sendAuthRuleId
    eventHubName: 'dns-logs'
    workspaceId: logAnalytics.outputs.workspaceId
  }
}

// ============================================================================
// RESOURCE LOCK
// ============================================================================
// CanNotDelete lock on public DNS zone (prevent accidental deletion)

module dnsZoneLock 'modules/resource-lock.bicep' = {
  scope: rg
  name: 'deploy-dns-zone-lock'
  params: {
    resourceName: domain
    resourceType: 'Microsoft.Network/dnsZones'
    lockName: 'lock-dns-zone'
    lockLevel: 'CanNotDelete'
    lockNotes: 'Prevent accidental deletion of POC DNS zone'
  }
  dependsOn: [
    publicDnsZone
  ]
}

// ============================================================================
// OUTPUTS
// ============================================================================

output resourceGroupName string = rg.name
output resourceGroupId string = rg.id

output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
output logAnalyticsWorkspaceName string = logAnalytics.outputs.workspaceName

output eventHubNamespaceId string = eventHub.outputs.namespaceId
output eventHubName string = eventHub.outputs.eventHubName
output eventHubSendConnectionString string = eventHub.outputs.sendConnectionString
output eventHubListenConnectionString string = eventHub.outputs.listenConnectionString

output storageAccountId string = storage.outputs.storageAccountId
output storageAccountName string = storage.outputs.storageAccountName

output vnetId string = vnet.outputs.vnetId
output vnetName string = vnet.outputs.vnetName

output publicDnsZoneId string = publicDnsZone.outputs.zoneId
output publicDnsZoneName string = publicDnsZone.outputs.zoneName
output publicDnsNameServers array = publicDnsZone.outputs.nameServers

output privateDnsZoneId string = privateDnsZone.outputs.zoneId
output privateDnsZoneName string = privateDnsZone.outputs.zoneName

output webAppUSId string = webAppUS.outputs.appId
output webAppUSHostName string = webAppUS.outputs.defaultHostName
output webAppUSUrl string = 'https://${webAppUS.outputs.defaultHostName}'

output webAppUKId string = webAppUK.outputs.appId
output webAppUKHostName string = webAppUK.outputs.defaultHostName
output webAppUKUrl string = 'https://${webAppUK.outputs.defaultHostName}'

output trafficManagerFailoverFqdn string = trafficManagerFailover.outputs.tmFqdn
output trafficManagerGeoFqdn string = trafficManagerGeo.outputs.tmFqdn
output trafficManagerWeightedFqdn string = trafficManagerWeighted.outputs.tmFqdn

output dnsTestUrls object = {
  failover: 'https://failover.${domain}'
  geo: 'https://geo.${domain}'
  weighted: 'https://weighted.${domain}'
}
