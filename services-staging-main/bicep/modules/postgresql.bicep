// ============================================================
// PostgreSQL Flexible Server Module
// References an existing server or creates a new one.
// Always ensures required databases exist.
// ============================================================

@description('Name prefix (ignored if existingName provided)')
param serviceName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Administrator username')
param adminUser string = 'pgadmin'

@description('Administrator password (required for new server)')
@secure()
param adminPassword string = ''

@description('SKU name (e.g., Standard_B1ms, Standard_D4ds_v5)')
param skuName string = 'Standard_B1ms'

@description('SKU tier')
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier string = 'Burstable'

@description('Storage size in GB')
param storageSizeGB int = 32

@description('PostgreSQL version')
@allowed(['15', '16'])
param version string = '16'

@description('High availability mode')
@allowed(['Disabled', 'ZoneRedundant'])
param highAvailability string = 'Disabled'

@description('Database names to create')
param databaseNames array = []

@description('PostgreSQL extensions to enable (comma-separated)')
param extensions string = ''

@description('Network access mode. private = publicNetworkAccess Disabled (use a private endpoint to reach the server).')
@allowed(['public', 'private'])
param networkAccess string = 'private'

@description('Name of an existing PostgreSQL server to use (empty = create new)')
param existingName string = ''

var createNew = empty(existingName)

// Reference existing server
resource existingPgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' existing = if (!createNew) {
  name: existingName
}

// Create new server
resource newPgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = if (createNew) {
  name: 'pg-${serviceName}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: version
    administratorLogin: adminUser
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: storageSizeGB
    }
    highAvailability: {
      mode: highAvailability
    }
    network: {
      publicNetworkAccess: networkAccess == 'public' ? 'Enabled' : 'Disabled'
    }
  }
}

// Create databases on whichever server we're using.
// Bicep doesn't allow `parent:` to be a conditional expression (BCP318), so
// we declare two parallel collections — one per branch — and gate each on
// the same createNew flag. Only one runs per deploy.
resource databasesNew 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = [
  for dbName in databaseNames: if (createNew) {
    parent: newPgServer
    name: dbName
    properties: {
      charset: 'UTF8'
      collation: 'en_US.utf8'
    }
  }
]

resource databasesExisting 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = [
  for dbName in databaseNames: if (!createNew) {
    parent: existingPgServer
    name: dbName
    properties: {
      charset: 'UTF8'
      collation: 'en_US.utf8'
    }
  }
]

// Enable extensions if specified — same split as databases above.
resource pgExtensionsNew 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = if (createNew && !empty(extensions)) {
  parent: newPgServer
  name: 'azure.extensions'
  properties: {
    value: extensions
    source: 'user-override'
  }
  dependsOn: [
    databasesNew
  ]
}

resource pgExtensionsExisting 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = if (!createNew && !empty(extensions)) {
  parent: existingPgServer
  name: 'azure.extensions'
  properties: {
    value: extensions
    source: 'user-override'
  }
  dependsOn: [
    databasesExisting
  ]
}

output pgServerFqdn string = createNew ? newPgServer.properties.fullyQualifiedDomainName : existingPgServer.properties.fullyQualifiedDomainName
output pgServerName string = createNew ? newPgServer.name : existingPgServer.name
output pgServerResourceId string = createNew ? newPgServer.id : existingPgServer.id
output pgAdminUser string = adminUser
