// ============================================================
// Private DNS Zone Module
// Creates a private DNS zone and links it to a VNet
// ============================================================

@description('DNS zone name (e.g., privatelink.postgres.database.azure.com)')
param zoneName string

@description('Resource tags')
param tags object = {}

@description('VNet resource ID to link')
param vnetResourceId string

resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: 'link-${last(split(vnetResourceId, '/'))}'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetResourceId
    }
    registrationEnabled: false
  }
}

output zoneId string = dnsZone.id
