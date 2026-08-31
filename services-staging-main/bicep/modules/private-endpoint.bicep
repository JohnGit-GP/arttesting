// ============================================================
// Private Endpoint Module (generic)
// Creates a private endpoint with DNS zone group registration
// Called once per backing service that needs a PE
// ============================================================

@description('Private endpoint name')
param name string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Target resource ID (PG server, storage account, etc.)')
param targetResourceId string

@description('Group ID for the private link (e.g., postgresqlServer, blob, vault)')
param groupId string

@description('Subnet resource ID for the private endpoint')
param subnetId string

@description('Private DNS zone resource ID for auto-registration')
param privateDnsZoneId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: replace(last(split(privateDnsZoneId, '/')), '.', '-')
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}
