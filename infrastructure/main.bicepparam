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
// WEB APP NAMES (must be globally unique - update these values)
// ============================================================================

param webAppNameUS = 'webapp-poc-us-zava2026'
param webAppNameUK = 'webapp-poc-uk-zava2026'

// ============================================================================
// INFRASTRUCTURE NAMES (storage account must be globally unique)
// ============================================================================

param storageAccountName = 'stqradarpoczava2026'
param eventHubNamespaceName = 'ehns-dns-poc'
param lawName = 'law-dns-poc'
param keyVaultName = 'kv-dns-poc-zava2026'

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
