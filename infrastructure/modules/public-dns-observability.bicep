targetScope = 'resourceGroup'

@description('Public DNS zone name to monitor.')
param zoneName string

@description('Location for workbook resource deployment.')
param location string = resourceGroup().location

@description('Log Analytics workspace resource ID.')
param workspaceId string

@description('Tags to apply to workbook resources.')
param tags object = {}

resource publicDnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: zoneName
}

var workbookDisplayName = 'Public DNS Monitoring - ${zoneName}'
var workbookId = guid(resourceGroup().id, 'Microsoft.Insights/workbooks', workbookDisplayName)
var workbookData = replace(
  replace(
    replace(loadTextContent('../workbooks/public-dns-monitoring.workbook'), '__WORKSPACE_ID__', workspaceId),
    '__ZONE_ID__',
    publicDnsZone.id
  ),
  '__ZONE_NAME__',
  zoneName
)

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: workbookId
  location: location
  kind: 'shared'
  tags: union(tags, {
    'monitoring-scope': 'public-dns'
    'monitoring-zone': zoneName
  })
  properties: {
    category: 'workbook'
    description: 'Public Azure DNS monitoring for ${zoneName}, including zone changes and Azure DNS metrics.'
    displayName: workbookDisplayName
    serializedData: workbookData
    sourceId: publicDnsZone.id
    version: 'Notebook/1.0'
  }
}

output workbookId string = workbook.id
output workbookDisplayName string = workbook.properties.displayName
output workbookResourceName string = workbook.name
output workbookUrl string = '${environment().portal}/#view/AppInsightsExtension/UsageNotebookBlade/ComponentId/Azure%20Monitor/ConfigurationId/${uriComponent(workbook.id)}/Type/${workbook.properties.category}/WorkbookTemplateName/${uriComponent(workbook.properties.displayName)}'
