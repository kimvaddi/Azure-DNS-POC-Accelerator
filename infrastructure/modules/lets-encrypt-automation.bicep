// ============================================================================
// Let's Encrypt Automation Module
// ============================================================================
// Uses a deployment script and managed identity to:
// 1) Issue/renew a wildcard certificate via ACME DNS-01 (Azure DNS)
// 2) Import certificate into Key Vault
// 3) Import certificate into App Service for each web app
// 4) Bind SNI TLS to each custom hostname

@description('Azure location for automation resources')
param location string = resourceGroup().location

@description('Public DNS zone name used for ACME DNS-01 challenge')
param dnsZoneName string

@description('Key Vault name that stores certificate')
param keyVaultName string

@description('Web App names that receive the certificate')
param webAppNames array

@description('Custom domains to bind on each web app')
param customDomains array

@description('Contact email for Let\'s Encrypt account registration')
param letsEncryptContactEmail string

@description('Certificate name in Key Vault')
param certificateName string = 'le-wildcard-zava'

@description('Wildcard domain to request from Let\'s Encrypt (e.g. *.example.com)')
param wildcardDomain string

@description('Force rerun token for deployment script')
param forceUpdateTag string

@description('Tags to apply to automation resources')
param tags object = {}

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: union(tags, {
    purpose: 'certificate-storage'
    'acme-automation': 'enabled'
  })
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
    enableRbacAuthorization: true
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

resource automationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-le-acme-${uniqueString(resourceGroup().id, dnsZoneName)}'
  location: location
  tags: tags
}

var contributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
var dnsZoneContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'befefa01-2a29-4197-83a8-272ff33ce314')
var keyVaultCertificatesOfficerRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a4417e6f-fecd-4de8-b567-7b0420556985')
var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

resource rgContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationIdentity.id, contributorRoleDefinitionId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: contributorRoleDefinitionId
    principalId: automationIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource dnsZoneContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dnsZone.id, automationIdentity.id, dnsZoneContributorRoleDefinitionId)
  scope: dnsZone
  properties: {
    roleDefinitionId: dnsZoneContributorRoleDefinitionId
    principalId: automationIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource kvCertificatesOfficerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, automationIdentity.id, keyVaultCertificatesOfficerRoleDefinitionId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultCertificatesOfficerRoleDefinitionId
    principalId: automationIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource kvSecretsOfficerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, automationIdentity.id, keyVaultSecretsOfficerRoleDefinitionId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
    principalId: automationIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource letsEncryptScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'deploy-letsencrypt-${uniqueString(resourceGroup().id, wildcardDomain)}'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${automationIdentity.id}': {}
    }
  }
  properties: {
    azPowerShellVersion: '11.6'
    timeout: 'PT1H'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    forceUpdateTag: forceUpdateTag
    environmentVariables: [
      {
        name: 'RG_NAME'
        value: resourceGroup().name
      }
      {
        name: 'SUBSCRIPTION_ID'
        value: subscription().subscriptionId
      }
      {
        name: 'DNS_ZONE_NAME'
        value: dnsZoneName
      }
      {
        name: 'KV_NAME'
        value: keyVaultName
      }
      {
        name: 'WEB_APP_NAMES'
        value: join(webAppNames, ',')
      }
      {
        name: 'CUSTOM_DOMAINS'
        value: join(customDomains, ',')
      }
      {
        name: 'LE_CONTACT'
        value: letsEncryptContactEmail
      }
      {
        name: 'CERT_NAME'
        value: certificateName
      }
      {
        name: 'WILDCARD_DOMAIN'
        value: wildcardDomain
      }
      {
        name: 'ARM_RESOURCE_MANAGER_ENDPOINT'
        value: environment().resourceManager
      }
    ]
    scriptContent: '''
      $ErrorActionPreference = 'Stop'

      Connect-AzAccount -Identity | Out-Null
      Set-AzContext -Subscription $env:SUBSCRIPTION_ID | Out-Null

      # Allow role assignments to propagate before data-plane and DNS operations.
      Start-Sleep -Seconds 30

      Install-Module Posh-ACME -Scope CurrentUser -Force -AllowClobber
      Import-Module Posh-ACME
      Set-PAServer LE_PROD

      $paAccount = Get-PAAccount -ErrorAction SilentlyContinue
      if (-not $paAccount) {
        New-PAAccount -Contact $env:LE_CONTACT -AcceptTOS | Out-Null
      }

      $token = (Get-AzAccessToken -ResourceUrl $env:ARM_RESOURCE_MANAGER_ENDPOINT).Token
      if (-not $token) {
        throw 'Unable to acquire ARM token for Posh-ACME Azure DNS plugin.'
      }

      $pluginArgs = @{
        AZSubscriptionId = $env:SUBSCRIPTION_ID
        AZAccessToken    = $token
      }

      $cert = $null
      for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
          $cert = New-PACertificate -Domain $env:WILDCARD_DOMAIN -Plugin Azure -PluginArgs $pluginArgs -ErrorAction Stop
          break
        } catch {
          if ($attempt -eq 5) { throw }
          Start-Sleep -Seconds 30
        }
      }

      if (-not $cert -or -not $cert.PfxFile) {
        throw 'Let''s Encrypt certificate issuance did not produce a PFX file.'
      }

      Import-AzKeyVaultCertificate -VaultName $env:KV_NAME -Name $env:CERT_NAME -FilePath $cert.PfxFile -Password $cert.PfxPass | Out-Null

      $kvCert = Get-AzKeyVaultCertificate -VaultName $env:KV_NAME -Name $env:CERT_NAME
      $thumbprint = $kvCert.Certificate.Thumbprint

      if (-not $thumbprint) {
        throw 'Unable to determine certificate thumbprint from Key Vault certificate.'
      }

      $apps = $env:WEB_APP_NAMES.Split(',') | Where-Object { $_ -and $_.Trim() -ne '' }
      $domains = $env:CUSTOM_DOMAINS.Split(',') | Where-Object { $_ -and $_.Trim() -ne '' }

      foreach ($app in $apps) {
        Import-AzWebAppKeyVaultCertificate -ResourceGroupName $env:RG_NAME -WebAppName $app -KeyVaultName $env:KV_NAME -CertName $env:CERT_NAME | Out-Null

        foreach ($domain in $domains) {
          New-AzWebAppSSLBinding -ResourceGroupName $env:RG_NAME -WebAppName $app -Name $domain -Thumbprint $thumbprint -SslState SniEnabled | Out-Null
        }
      }

      $DeploymentScriptOutputs = @{}
      $DeploymentScriptOutputs['certificateThumbprint'] = $thumbprint
      $DeploymentScriptOutputs['certificateName'] = $env:CERT_NAME
      $DeploymentScriptOutputs['keyVaultName'] = $env:KV_NAME
      $DeploymentScriptOutputs['wildcardDomain'] = $env:WILDCARD_DOMAIN
    '''
  }
  dependsOn: [
    keyVault
    rgContributorAssignment
    dnsZoneContributorAssignment
    kvCertificatesOfficerAssignment
    kvSecretsOfficerAssignment
  ]
}

output certificateThumbprint string = string(letsEncryptScript.properties.outputs.certificateThumbprint)
output certificateName string = string(letsEncryptScript.properties.outputs.certificateName)
output keyVaultName string = string(letsEncryptScript.properties.outputs.keyVaultName)
