// ============================================================================
// Parameters file for Zava DNS POC Deployment
// ============================================================================
// Use this file with: az deployment sub create --template-file main.bicep --parameters main.bicepparam

using './main.bicep'

// ============================================================================
// LOCATION PARAMETERS
// ============================================================================

param location = 'southcentralus'
param locationPrimary = 'westus3'
param locationSecondary = 'eastasia'

// ============================================================================
// RESOURCE GROUP
// ============================================================================

param rgName = 'rg-dns-poc'

// ============================================================================
// DNS DOMAINS
// ============================================================================

param domain = 'poc.Zava.com'
param privateDomain = 'poc-internal.Zava.local'

// ============================================================================
// WEB APP NAMES
// ============================================================================

param webAppNameUS = 'webapp-poc-us-${uniqueString(subscription().subscriptionId)}'
param webAppNameUK = 'webapp-poc-uk-${uniqueString(subscription().subscriptionId)}'

// ============================================================================
// INFRASTRUCTURE NAMES
// ============================================================================

param storageAccountName = 'stqradarpoc${uniqueString(subscription().subscriptionId)}'
param eventHubNamespaceName = 'ehns-dns-poc'
param lawName = 'law-dns-poc'

// ============================================================================
// TAGS
// ============================================================================

param tags = {
  project: 'dns-poc'
  customer: 'Zava'
  environment: 'poc'
  'managed-by': 'bicep'
  'created-date': '2026-03-27'
  contact: 'kim-vaddi'
}
