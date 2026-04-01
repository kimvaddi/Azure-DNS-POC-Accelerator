// ============================================================================
// DCV TXT Records Module for Domain Control Validation
// ============================================================================
// Creates and manages TXT records in Azure DNS for DCV (Domain Control Validation).
// Supports both DigiCert `_dnsauth` and ACME `_acme-challenge` conventions.
// 
// Usage:
// 1. Get DCV token from your CA (DigiCert CertCentral or ACME client)
// 2. Deploy this module to create the TXT record
// 3. Verify DNS propagation
// 4. CA validates the token
// 5. Redeploy with empty 'dcvRecords' to clean up

targetScope = 'resourceGroup'

@description('DNS Zone name (e.g., zava-dnspoc-001.com)')
param dnsZoneName string

@description('Array of DCV records to create. Each object has: { subdomain: string, recordName: string, token: string }')
@metadata({
  example: [
    {
      subdomain: 'app'
      recordName: '_dnsauth'
      token: 'digicert-dcv-value-12345'
      comment: 'DigiCert DCV for app.zava-dnspoc-001.com'
    }
    {
      subdomain: 'www'
      recordName: '_acme-challenge'
      token: 'acme-challenge-value-abcde'
      comment: 'ACME DCV for www.zava-dnspoc-001.com'
    }
  ]
})
param dcvRecords array = []

@description('TTL for DCV TXT records (in seconds, typically 300 for validation)')
param dcvTtl int = 300

// ============================================================================
// RESOURCES
// ============================================================================

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
}

// Create TXT records for DCV validation
@batchSize(1) // Process one at a time to avoid conflicts
resource dcvTxtRecords 'Microsoft.Network/dnsZones/TXT@2018-05-01' = [for record in dcvRecords: {
  parent: dnsZone
  name: '${record.subdomain}.${record.recordName}'
  properties: {
    TTL: dcvTtl
    TXTRecords: [
      {
        value: [
          record.token
        ]
      }
    ]
  }
}]

// ============================================================================
// OUTPUTS
// ============================================================================

output dcvRecordNames array = [for (record, i) in dcvRecords: {
  fqdn: '${record.subdomain}.${record.recordName}.${dnsZoneName}'
  recordName: dcvTxtRecords[i].name
  recordId: dcvTxtRecords[i].id
  comment: record.comment
}]
