// ============================================================================
// DNS TXT Records Module
// ============================================================================
// Creates multiple TXT record sets in a DNS zone

@description('DNS zone name')
param zoneName string

@description('Array of TXT records to create')
param txtRecords array

// Reference existing DNS zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: zoneName
}

// TXT Records (loop through array)
resource txtRecord 'Microsoft.Network/dnsZones/TXT@2018-05-01' = [for record in txtRecords: {
  parent: dnsZone
  name: record.name
  properties: {
    TTL: record.ttl
    TXTRecords: [for value in record.values: {
      value: [value]
    }]
  }
}]

output recordNames array = [for (record, i) in txtRecords: txtRecord[i].name]
