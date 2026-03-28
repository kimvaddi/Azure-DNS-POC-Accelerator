// ============================================================================
// DNS CNAME Records Module
// ============================================================================
// Creates multiple CNAME records in a DNS zone

@description('DNS zone name')
param zoneName string

@description('Array of CNAME records to create')
param cnameRecords array

// ============================================================================
// RESOURCES
// ============================================================================

// Reference existing DNS zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: zoneName
}

// CNAME Records (loop through array)
resource cnameRecord 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = [for record in cnameRecords: {
  parent: dnsZone
  name: record.name
  properties: {
    TTL: record.ttl
    CNAMERecord: {
      cname: record.targetFqdn
    }
  }
}]

// ============================================================================
// OUTPUTS
// ============================================================================

output recordNames array = [for (record, i) in cnameRecords: cnameRecord[i].name]
