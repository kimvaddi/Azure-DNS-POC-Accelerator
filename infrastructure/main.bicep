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

@description('Public DNS domain for the POC — auto-discovered by deploy.ps1 via App Service Domain availability check (zava-dnspoc-001.com, 002, …). Always override via deploy.ps1 or --parameters domain=<value>.')
param domain string = 'zava-dnspoc-001.com'

@description('Private DNS domain for internal resources')
param privateDomain string = 'poc-internal.zava.local'

@description('Deploy private DNS zone (poc-internal.zava.local) with VNet link. Set false to skip.')
param deployPrivateDnsZone bool = false

@description('Purchase and register the public domain via Azure App Service Domain. Set to false if the domain is already registered or if skipping registration for validation runs.')
param deployAppServiceDomain bool = true

@description('Contact information for App Service Domain registration (WHOIS record). Override email, phone, and address in main.bicepparam.')
param domainContactInfo object = {
  nameFirst: 'DNS'
  nameLast: 'Admin'
  email: 'dnsadmin@zava.com'
  phone: '+1.2105550100'
  organization: 'Zava Energy Corporation'
  address1: '100 Energy Way'
  city: 'San Antonio'
  state: 'TX'
  postalCode: '78201'
  country: 'US'
}

@description('ISO 8601 UTC timestamp when the operator accepted the domain registration terms. Auto-set to deployment time; overridden by deploy.ps1.')
param domainConsentAgreedAt string = utcNow()

@description('Public IP address of the deployment operator for domain registration consent. Overridden by deploy.ps1 at runtime.')
param domainConsentAgreedBy string = '127.0.0.1'

@description('Web app name for US region (globally unique — suffix auto-derived from subscription ID + RG name)')
param webAppNameUS string = 'webapp-poc-us-${uniqueString(subscription().subscriptionId, rgName)}'

@description('Web app name for UK/Asia region (globally unique — suffix auto-derived from subscription ID + RG name)')
param webAppNameUK string = 'webapp-poc-uk-${uniqueString(subscription().subscriptionId, rgName)}'

@description('Storage account name for QRadar checkpoint tracking (globally unique)')
@maxLength(24)
param storageAccountName string = 'stqradarpoc${take(uniqueString(subscription().subscriptionId, rgName), 11)}'

@description('Event Hub namespace name (globally unique — suffix auto-derived from subscription ID + RG name)')
param eventHubNamespaceName string = 'ehns-dns-poc-${uniqueString(subscription().subscriptionId, rgName)}'

@description('Log Analytics workspace name')
param lawName string = 'law-dns-poc'

@description('Deploy App Service + Web Apps + Traffic Manager components (disable if subscription has zero App Service worker quota)')
param deployWebApps bool = false

@description('Deploy DNS aliases for existing Traffic Manager profiles even when web apps are not being deployed in this run')
param deployTrafficManagerDnsAliases bool = false

@description('Bind custom hostnames (e.g. webfailover.<domain>) to App Service. Requires public DNS delegation — set to false during initial deployment until NS records are delegated.')
param deployCustomDomainBindings bool = false

@description('App Service Plan SKU for both web regions (B1, S1, P1v2, etc.)')
param appServicePlanSku string = 'B1'

@description('Enable SNI TLS binding on custom hostnames during deployment')
param enableCustomDomainTls bool = false

@description('Certificate thumbprint used when enableCustomDomainTls=true')
param customDomainCertificateThumbprint string = ''

@description('Enable full Let\'s Encrypt automation (issue/import/bind) during deployment')
param enableLetsEncryptAutomation bool = false

@description('Contact email used for Let\'s Encrypt account registration. Defaults to dnsadmin@<domain>. deploy.ps1 derives this from the discovered domain automatically; override only if a different contact is needed.')
param letsEncryptContactEmail string = 'dnsadmin@${domain}'

@description('Key Vault name for TLS certificate storage (must be globally unique)')
param keyVaultName string = 'kvdns${take(uniqueString(subscription().subscriptionId, rgName), 18)}'

@description('Certificate name in Key Vault for Let\'s Encrypt wildcard cert')
param letsEncryptCertificateName string = 'le-wildcard-zava'

@description('Force-run token for Let\'s Encrypt deployment script')
param letsEncryptRunTag string = newGuid()

@description('Apply CanNotDelete lock to public DNS zone')
param enableDnsZoneLock bool = true

@description('TTL in seconds for Traffic Manager profiles and DNS CNAME records. Default 10 for fast POC testing; increase to 60+ for production.')
@minValue(10)
param trafficManagerTtl int = 10

@description('Traffic Manager endpoint health probe interval in seconds. 10 is the minimum (Fast Endpoint Monitoring) and best for POC testing.')
@allowed([10, 30])
param trafficManagerMonitorIntervalSeconds int = 10

var regionDisplayNames = {
  eastasia: 'East Asia'
  northeurope: 'North Europe'
  southcentralus: 'South Central US'
  uksouth: 'UK South'
  westus3: 'West US 3'
  westeurope: 'West Europe'
}

// Shared unique suffix derived from subscription ID + RG name — unique per deployment target RG
var uniqueSuffix = uniqueString(subscription().subscriptionId, rgName)
// Include location so subscription-scope nested deployments don't collide across regions.
var subDeploymentSuffix = uniqueString(subscription().subscriptionId, rgName, location)
var locationPrimaryDisplayName = regionDisplayNames[?locationPrimary] ?? locationPrimary
var locationSecondaryDisplayName = regionDisplayNames[?locationSecondary] ?? locationSecondary
var trafficManagerFailoverProfileName = 'tm-poc-failover'
var trafficManagerGeoProfileName = 'tm-poc-geo'
var trafficManagerWeightedProfileName = 'tm-poc-weighted'
var customerCnameLabels = [
  'webfailover'
  'webgeo'
  'webweighted'
]
var customerSubdomainHostNames = [for label in customerCnameLabels: '${label}.${domain}']
var customerVerificationSubdomainTxtNames = [for label in customerCnameLabels: 'asuid.${label}']
var customerHostNames = customerSubdomainHostNames
var customerVerificationTxtNames = customerVerificationSubdomainTxtNames
var applyImmediateCustomDomainTls = enableCustomDomainTls && !enableLetsEncryptAutomation
var customDomainVerificationValue = deployWebApps ? (webAppUS.?outputs.?customDomainVerificationId ?? '') : ''

@description('Tags to apply to all resources')
param tags object = {
  project: 'dns-poc'
  environment: 'poc'
  'managed-by': 'bicep'
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
// Primary POC DNS zone — name is auto-discovered by deploy.ps1

module publicDnsZone 'modules/public-dns-zone.bicep' = {
  scope: rg
  name: 'deploy-public-dns-zone'
  params: {
    zoneName: domain
    tags: tags
  }
}

// ============================================================================
// APP SERVICE DOMAIN REGISTRATION
// ============================================================================
// Purchases the domain and binds it to the Azure DNS Zone above.
// NS records are automatically updated at the GoDaddy registrar — no manual
// delegation required. Cost: ~$11–15/year for .com.

module appServiceDomain 'modules/app-service-domain.bicep' = if (deployAppServiceDomain) {
  scope: rg
  name: 'deploy-app-service-domain'
  params: {
    domainName: domain
    dnsZoneId: publicDnsZone.outputs.zoneId
    contactInfo: domainContactInfo
    consentAgreedAt: domainConsentAgreedAt
    consentAgreedBy: domainConsentAgreedBy
    autoRenew: false
    privacy: false
    tags: tags
  }
}

module publicDnsObservability 'modules/public-dns-observability.bicep' = {
  scope: rg
  name: 'deploy-public-dns-observability'
  params: {
    zoneName: domain
    location: location
    workspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
  dependsOn: [
    appServiceDomain
  ]
}

resource existingTrafficManagerFailover 'Microsoft.Network/trafficmanagerprofiles@2022-04-01' existing = if (deployTrafficManagerDnsAliases && !deployWebApps) {
  scope: rg
  name: trafficManagerFailoverProfileName
}

resource existingTrafficManagerGeo 'Microsoft.Network/trafficmanagerprofiles@2022-04-01' existing = if (deployTrafficManagerDnsAliases && !deployWebApps) {
  scope: rg
  name: trafficManagerGeoProfileName
}

resource existingTrafficManagerWeighted 'Microsoft.Network/trafficmanagerprofiles@2022-04-01' existing = if (deployTrafficManagerDnsAliases && !deployWebApps) {
  scope: rg
  name: trafficManagerWeightedProfileName
}

// ============================================================================
// PRIVATE DNS ZONE
// ============================================================================
// Internal DNS zone with VNet link and sample A records

module privateDnsZone 'modules/private-dns-zone.bicep' = if (deployPrivateDnsZone) {
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
  dependsOn: [
    appServiceDomain
  ]
}

// ============================================================================
// APP SERVICE PLANS (MULTI-REGION)
// ============================================================================
// App Service plan tier for web workload

module appServicePlanUS 'modules/app-service-plan.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-asp-us'
  params: {
    planName: 'asp-poc-us'
    location: locationPrimary
    skuName: appServicePlanSku
    skuCapacity: 1
    osType: 'Windows'
    tags: tags
  }
  dependsOn: [
    appServiceDomain
  ]
}

module appServicePlanUK 'modules/app-service-plan.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-asp-uk'
  params: {
    planName: 'asp-poc-uk'
    location: locationSecondary
    skuName: appServicePlanSku
    skuCapacity: 1
    osType: 'Windows'
    tags: tags
  }
  dependsOn: [
    appServiceDomain
  ]
}

// ============================================================================
// WEB APPS (MULTI-REGION)
// ============================================================================
// .NET 8 web apps with security hardening

module webAppUS 'modules/web-app.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-webapp-us'
  params: {
    appName: webAppNameUS
    location: locationPrimary
    appServicePlanId: appServicePlanUS.?outputs.?planId ?? ''
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    netFrameworkVersion: 'v8.0'
    appSettings: {
      POC_METADATA_ENDPOINT: '/metadata.json'
      POC_PRIVATE_DNS_ZONE: privateDomain
      POC_PUBLIC_DNS_ZONE: domain
      POC_REGION_DISPLAY_NAME: locationPrimaryDisplayName
      POC_REGION_ENDPOINT: '/region.txt'
      POC_REGION_NAME: locationPrimary
      POC_REGION_ROLE: 'primary'
      POC_SITE_TITLE: 'Zava Azure DNS POC'
      POC_APP_NAME: webAppNameUS
    }
    tags: tags
  }
}

module webAppUK 'modules/web-app.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-webapp-uk'
  params: {
    appName: webAppNameUK
    location: locationSecondary
    appServicePlanId: appServicePlanUK.?outputs.?planId ?? ''
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    netFrameworkVersion: 'v8.0'
    appSettings: {
      POC_METADATA_ENDPOINT: '/metadata.json'
      POC_PRIVATE_DNS_ZONE: privateDomain
      POC_PUBLIC_DNS_ZONE: domain
      POC_REGION_DISPLAY_NAME: locationSecondaryDisplayName
      POC_REGION_ENDPOINT: '/region.txt'
      POC_REGION_NAME: locationSecondary
      POC_REGION_ROLE: 'secondary'
      POC_SITE_TITLE: 'Zava Azure DNS POC'
      POC_APP_NAME: webAppNameUK
    }
    tags: tags
  }
}

// ============================================================================
// TRAFFIC MANAGER PROFILES
// ============================================================================
// Three profiles: Priority (failover), Geographic, Weighted

module trafficManagerFailover 'modules/traffic-manager.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-tm-failover'
  params: {
    profileName: trafficManagerFailoverProfileName
    routingMethod: 'Priority'
    dnsConfig: {
      relativeName: 'tm-poc-failover-${uniqueSuffix}'
      ttl: trafficManagerTtl
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/health.json'
      intervalInSeconds: trafficManagerMonitorIntervalSeconds
      toleratedNumberOfFailures: 3
      timeoutInSeconds: 9
    }
    endpoints: [
      {
        name: 'us-primary'
        targetResourceId: webAppUS.?outputs.?appId ?? ''
        priority: 1
        endpointLocation: locationPrimary
      }
      {
        name: 'uk-secondary'
        targetResourceId: webAppUK.?outputs.?appId ?? ''
        priority: 2
        endpointLocation: locationSecondary
      }
    ]
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
}

module trafficManagerGeo 'modules/traffic-manager.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-tm-geo'
  params: {
    profileName: trafficManagerGeoProfileName
    routingMethod: 'Geographic'
    dnsConfig: {
      relativeName: 'tm-poc-geo-${uniqueSuffix}'
      ttl: trafficManagerTtl
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/health.json'
      intervalInSeconds: trafficManagerMonitorIntervalSeconds
      toleratedNumberOfFailures: 3
      timeoutInSeconds: 9
    }
    endpoints: [
      {
        name: 'us-endpoint'
        targetResourceId: webAppUS.?outputs.?appId ?? ''
        geoMapping: [ 'US', 'CA', 'MX' ]
        endpointLocation: locationPrimary
      }
      {
        name: 'uk-endpoint'
        targetResourceId: webAppUK.?outputs.?appId ?? ''
        geoMapping: [ 'GB', 'WORLD' ]
        endpointLocation: locationSecondary
      }
    ]
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
}

module trafficManagerWeighted 'modules/traffic-manager.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-tm-weighted'
  params: {
    profileName: trafficManagerWeightedProfileName
    routingMethod: 'Weighted'
    dnsConfig: {
      relativeName: 'tm-poc-weighted-${uniqueSuffix}'
      ttl: trafficManagerTtl
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/health.json'
      intervalInSeconds: trafficManagerMonitorIntervalSeconds
      toleratedNumberOfFailures: 3
      timeoutInSeconds: 9
    }
    endpoints: [
      {
        name: 'us-70pct'
        targetResourceId: webAppUS.?outputs.?appId ?? ''
        weight: 70
        endpointLocation: locationPrimary
      }
      {
        name: 'uk-30pct'
        targetResourceId: webAppUK.?outputs.?appId ?? ''
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

var trafficManagerFailoverFqdnValue = deployWebApps
  ? (trafficManagerFailover.?outputs.?tmFqdn ?? '')
  : (existingTrafficManagerFailover.?properties.?dnsConfig.?fqdn ?? '')
var trafficManagerGeoFqdnValue = deployWebApps
  ? (trafficManagerGeo.?outputs.?tmFqdn ?? '')
  : (existingTrafficManagerGeo.?properties.?dnsConfig.?fqdn ?? '')
var trafficManagerWeightedFqdnValue = deployWebApps
  ? (trafficManagerWeighted.?outputs.?tmFqdn ?? '')
  : (existingTrafficManagerWeighted.?properties.?dnsConfig.?fqdn ?? '')

module dnsRecords 'modules/dns-cname-records.bicep' = if (deployWebApps || deployTrafficManagerDnsAliases) {
  scope: rg
  name: 'deploy-dns-cnames'
  params: {
    zoneName: domain
    cnameRecords: [
      {
        name: 'webfailover'
        targetFqdn: trafficManagerFailoverFqdnValue
        ttl: trafficManagerTtl
      }
      {
        name: 'webgeo'
        targetFqdn: trafficManagerGeoFqdnValue
        ttl: trafficManagerTtl
      }
      {
        name: 'webweighted'
        targetFqdn: trafficManagerWeightedFqdnValue
        ttl: trafficManagerTtl
      }
    ]
  }
  dependsOn: [
    publicDnsZone
    appServiceDomain
  ]
}

module dnsVerificationTxtRecords 'modules/dns-txt-records.bicep' = if (deployWebApps) {
  scope: rg
  name: 'deploy-dns-txt-asuid'
  params: {
    zoneName: domain
    txtRecords: [for txtName in customerVerificationTxtNames: {
      name: txtName
      ttl: 300
      values: [customDomainVerificationValue]
    }]
  }
  dependsOn: [
    publicDnsZone
    appServiceDomain
  ]
}

module webAppUSCustomerDomainBindings 'modules/web-app-hostname-bindings.bicep' = if (deployWebApps && deployCustomDomainBindings) {
  scope: rg
  name: 'deploy-webapp-us-hostname-bindings'
  params: {
    appName: webAppNameUS
    hostNames: customerHostNames
    enableSslBinding: applyImmediateCustomDomainTls
    certificateThumbprint: customDomainCertificateThumbprint
  }
  dependsOn: [
    webAppUS
    dnsRecords
    dnsVerificationTxtRecords
  ]
}

module webAppUKCustomerDomainBindings 'modules/web-app-hostname-bindings.bicep' = if (deployWebApps && deployCustomDomainBindings) {
  scope: rg
  name: 'deploy-webapp-uk-hostname-bindings'
  params: {
    appName: webAppNameUK
    hostNames: customerHostNames
    enableSslBinding: applyImmediateCustomDomainTls
    certificateThumbprint: customDomainCertificateThumbprint
  }
  dependsOn: [
    webAppUK
    dnsRecords
    dnsVerificationTxtRecords
  ]
}

module letsEncryptAutomation 'modules/lets-encrypt-automation.bicep' = if (deployWebApps && enableLetsEncryptAutomation) {
  scope: rg
  name: 'deploy-letsencrypt-automation'
  params: {
    location: location
    dnsZoneName: domain
    keyVaultName: keyVaultName
    webAppNames: [
      webAppNameUS
      webAppNameUK
    ]
    customDomains: customerHostNames
    letsEncryptContactEmail: letsEncryptContactEmail
    certificateName: letsEncryptCertificateName
    wildcardDomain: '*.${domain}'
    forceUpdateTag: letsEncryptRunTag
    tags: tags
  }
  dependsOn: [
    publicDnsZone
    appServiceDomain
    webAppUSCustomerDomainBindings
    webAppUKCustomerDomainBindings
  ]
}

// ============================================================================
// SUBSCRIPTION-LEVEL DIAGNOSTIC SETTINGS
// ============================================================================
// Activity Log → Event Hub + Log Analytics (all 8 categories)

module activityLogDiagnostics 'modules/activity-log-diagnostics.bicep' = {
  scope: subscription()
  name: 'deploy-activity-log-diagnostics-${subDeploymentSuffix}'
  params: {
    diagnosticSettingName: 'activity-log-to-eventhub'
    eventHubAuthorizationRuleId: eventHub.outputs.sendAuthRuleId
    eventHubName: 'dns-logs'
    workspaceId: logAnalytics.outputs.workspaceId
  }
  dependsOn: [
    appServiceDomain
  ]
}

// ============================================================================
// RESOURCE LOCK
// ============================================================================
// CanNotDelete lock on public DNS zone (prevent accidental deletion)

module dnsZoneLockNoAcme 'modules/resource-lock.bicep' = if (enableDnsZoneLock && !enableLetsEncryptAutomation) {
  scope: rg
  name: 'deploy-dns-zone-lock'
  params: {
    resourceName: domain
    lockName: 'lock-dns-zone'
    lockLevel: 'CanNotDelete'
    lockNotes: 'Prevent accidental deletion of POC DNS zone'
  }
  dependsOn: [
    publicDnsZone
    appServiceDomain
  ]
}

module dnsZoneLockAfterAcme'modules/resource-lock.bicep' = if (enableDnsZoneLock && enableLetsEncryptAutomation) {
  scope: rg
  name: 'deploy-dns-zone-lock-after-acme'
  params: {
    resourceName: domain
    lockName: 'lock-dns-zone'
    lockLevel: 'CanNotDelete'
    lockNotes: 'Prevent accidental deletion of POC DNS zone'
  }
  dependsOn: [
    publicDnsZone
    letsEncryptAutomation
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
@secure()
output eventHubSendConnectionString string = eventHub.outputs.sendConnectionString
@secure()
output eventHubListenConnectionString string = eventHub.outputs.listenConnectionString

output storageAccountId string = storage.outputs.storageAccountId
output storageAccountName string = storage.outputs.storageAccountName

output vnetId string = vnet.outputs.vnetId
output vnetName string = vnet.outputs.vnetName

output publicDnsZoneId string = publicDnsZone.outputs.zoneId
output publicDnsZoneName string = publicDnsZone.outputs.zoneName
output publicDnsNameServers array = publicDnsZone.outputs.nameServers
output publicDnsWorkbookId string = publicDnsObservability.outputs.workbookId
output publicDnsWorkbookName string = publicDnsObservability.outputs.workbookDisplayName
output publicDnsWorkbookUrl string = publicDnsObservability.outputs.workbookUrl

output appServiceDomainId string = deployAppServiceDomain ? (appServiceDomain.?outputs.?domainId ?? '') : ''
output appServiceDomainName string = deployAppServiceDomain ? (appServiceDomain.?outputs.?domainName ?? '') : ''
output appServiceDomainStatus string = deployAppServiceDomain ? (appServiceDomain.?outputs.?registrationStatus ?? '') : ''

output privateDnsZoneId string = deployPrivateDnsZone ? (privateDnsZone.?outputs.?zoneId ?? '') : ''
output privateDnsZoneName string = deployPrivateDnsZone ? (privateDnsZone.?outputs.?zoneName ?? '') : privateDomain

output webAppUSName string = webAppUS.?outputs.?appName ?? ''
output webAppUSId string = webAppUS.?outputs.?appId ?? ''
output webAppUSHostName string = webAppUS.?outputs.?defaultHostName ?? ''
output webAppUSUrl string = webAppUS.?outputs.?defaultHostName != null ? 'https://${webAppUS.?outputs.?defaultHostName}' : ''
output webAppUSRegionUrl string = webAppUS.?outputs.?defaultHostName != null ? 'https://${webAppUS.?outputs.?defaultHostName}/region.txt' : ''

output webAppUKName string = webAppUK.?outputs.?appName ?? ''
output webAppUKId string = webAppUK.?outputs.?appId ?? ''
output webAppUKHostName string = webAppUK.?outputs.?defaultHostName ?? ''
output webAppUKUrl string = webAppUK.?outputs.?defaultHostName != null ? 'https://${webAppUK.?outputs.?defaultHostName}' : ''
output webAppUKRegionUrl string = webAppUK.?outputs.?defaultHostName != null ? 'https://${webAppUK.?outputs.?defaultHostName}/region.txt' : ''

output trafficManagerFailoverFqdn string = trafficManagerFailoverFqdnValue
output trafficManagerGeoFqdn string = trafficManagerGeoFqdnValue
output trafficManagerWeightedFqdn string = trafficManagerWeightedFqdnValue

output letsEncryptCertificateThumbprint string = (deployWebApps && enableLetsEncryptAutomation) ? (letsEncryptAutomation.?outputs.?certificateThumbprint ?? '') : ''
output tlsKeyVaultName string = keyVaultName

output dnsTestUrls object = (deployWebApps || deployTrafficManagerDnsAliases) ? {
  webfailover: 'https://webfailover.${domain}'
  webgeo: 'https://webgeo.${domain}'
  webweighted: 'https://webweighted.${domain}'
} : {
  status: 'traffic-manager-dns-aliases-disabled'
}
