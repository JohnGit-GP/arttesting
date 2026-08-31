// ============================================================
// Storage Account Module
// References an existing account or creates a new one.
// Always ensures required blob containers exist.
// Gov Cloud endpoints resolve automatically via environment().
// ============================================================

@description('Name prefix (ignored if existingName provided)')
param serviceName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Storage SKU')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_ZRS'])
param skuName string = 'Standard_LRS'

@description('Blob container names to create')
param blobContainers array = []

@description('Name of an existing Storage Account to use (empty = create new)')
param existingName string = ''

@description('Disable public network access. When true, the account is reachable only through a private endpoint.')
param disablePublicNetworkAccess bool = true

var createNew = empty(existingName)
var storageAccountName = createNew ? take('st${replace(serviceName, '-', '')}${uniqueString(resourceGroup().id)}', 24) : existingName

// Reference existing account
resource existingStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (!createNew) {
  name: existingName
}

// Create new account
resource newStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = if (createNew) {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: skuName
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: disablePublicNetworkAccess ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: disablePublicNetworkAccess ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

// Blob service on whichever account we're using.
// Bicep doesn't allow `parent:` to be a conditional expression (BCP318), so
// we declare two `default` blob services — one per branch — and gate each
// on the createNew flag. Only one runs per deploy. The containers loop
// below is split the same way so its parent is always a direct symbolic
// reference.
resource blobServiceNew 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = if (createNew) {
  parent: newStorageAccount
  name: 'default'
}

resource blobServiceExisting 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = if (!createNew) {
  parent: existingStorageAccount
  name: 'default'
}

// Ensure containers exist — same split as blobService above.
resource containersNew 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for containerName in blobContainers: if (createNew) {
    parent: blobServiceNew
    name: containerName
    properties: {
      publicAccess: 'None'
    }
  }
]

resource containersExisting 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for containerName in blobContainers: if (!createNew) {
    parent: blobServiceExisting
    name: containerName
    properties: {
      publicAccess: 'None'
    }
  }
]

output storageAccountName string = storageAccountName
output storageAccountId string = createNew ? newStorageAccount.id : existingStorageAccount.id
output blobEndpoint string = createNew ? newStorageAccount.properties.primaryEndpoints.blob : existingStorageAccount.properties.primaryEndpoints.blob
output blobEndpointSuffix string = environment().suffixes.storage
