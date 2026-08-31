// ============================================================
// Main Orchestrator — Azure Infrastructure for AKS Services
// Provisions backing resources only. Helm is handled separately.
// 100% service-agnostic — all service logic lives in config files.
// ============================================================

targetScope = 'resourceGroup'

// ── Service Identity ──
@description('Service identifier used for resource naming and tagging')
param serviceName string

@description('Environment')
@allowed(['dev', 'test', 'prod'])
param environment string = 'dev'

@description('Azure region')
@allowed(['usgovvirginia', 'usgovarizona', 'usgovtexas'])
param location string = 'usgovvirginia'

@description('Resource tags')
param tags object = {}

// ── Existing Infrastructure References ──
@description('AKS cluster name')
param aksClusterName string

@description('AKS cluster resource group')
param aksClusterResourceGroup string

@description('VNet name (for private endpoints)')
param vnetName string

@description('VNet resource group')
param vnetResourceGroup string = aksClusterResourceGroup

@description('Subnet name for private endpoints')
param privateEndpointSubnetName string

@description('ACR name')
param acrName string

@description('ACR resource group')
param acrResourceGroup string = aksClusterResourceGroup

// ── Feature Flags ──
@description('Deploy PostgreSQL Flexible Server')
param deployPostgresql bool = false

@description('Deploy Azure Storage Account')
param deployStorageAccount bool = false

@description('Deploy Key Vault')
param deployKeyVault bool = false

@description('Deploy private endpoints')
param deployPrivateEndpoints bool = false

// ── Existing Resource Names (provide to use existing, leave empty to create new) ──
@description('Existing PostgreSQL server name (empty = create new)')
param existingPgServerName string = ''

@description('Existing Storage Account name (empty = create new)')
param existingStorageAccountName string = ''

@description('Existing Key Vault name (empty = create new)')
param existingKeyVaultName string = ''

// ── Existing Private DNS Zones (centrally-managed zones to reuse) ──
// In environments where privatelink zones are owned by a platform team and
// already linked to the VNet, pass the full ARM resource ID of each zone.
// Bicep will skip zone creation and point the PE's dnsZoneGroup at the
// existing zone for A-record auto-registration. Requires the deployer to
// hold `Private DNS Zone Contributor` on each zone.
@description('Existing privatelink zone resource ID for PostgreSQL (empty = create local zone)')
param existingPrivateDnsZoneIdPg string = ''

@description('Existing privatelink zone resource ID for Blob storage (empty = create local zone)')
param existingPrivateDnsZoneIdBlob string = ''

@description('Existing privatelink zone resource ID for Key Vault (empty = create local zone)')
param existingPrivateDnsZoneIdKv string = ''

// ── Public Network Access (default Disabled — private-only deployments) ──
@description('Disable public network access on Key Vault')
param disableKeyVaultPublicAccess bool = true

@description('Disable public network access on Storage Account')
param disableStoragePublicAccess bool = true

// ── PostgreSQL Config ──
@description('PostgreSQL SKU name')
param pgSkuName string = 'Standard_B1ms'

@description('PostgreSQL SKU tier')
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param pgSkuTier string = 'Burstable'

@description('PostgreSQL storage size in GB')
param pgStorageSizeGB int = 32

@description('PostgreSQL version')
@allowed(['15', '16'])
param pgVersion string = '16'

@description('PostgreSQL HA mode')
@allowed(['Disabled', 'ZoneRedundant'])
param pgHighAvailability string = 'Disabled'

@description('Database names to create')
param pgDatabaseNames array = []

@description('PostgreSQL extensions (comma-separated)')
param pgExtensions string = ''

@description('PostgreSQL admin user')
param pgAdminUser string = 'pgadmin'

@secure()
@description('PostgreSQL admin password')
param pgAdminPassword string = ''

@description('PostgreSQL network access mode (private = publicNetworkAccess Disabled)')
@allowed(['public', 'private'])
param pgNetworkAccess string = 'private'

// ── Storage Config ──
@description('Storage SKU')
param storageSkuName string = 'Standard_LRS'

@description('Blob container names')
param storageBlobContainers array = []

// ── Key Vault Config ──
@description('Pre-generated Key Vault name (empty = auto-generate). KV names cap at 24 chars.')
param newKeyVaultName string = ''

@description('AAD objectId of the deploying user/SP. Granted get/list/set/delete on secrets so deploy.sh and helm-deploy.sh can manage them.')
param deployerObjectId string = ''

@secure()
@description('Secrets to store in Key Vault as {name: value} object')
param keyVaultSecrets object = {}

// ════════════════════════════════════════
// Computed values
// ════════════════════════════════════════

var defaultTags = union(tags, {
  service: serviceName
  environment: environment
  managedBy: 'bicep'
})

// Reference existing resources
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
  scope: resourceGroup(acrResourceGroup)
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

var peSubnetId = '${vnet.id}/subnets/${privateEndpointSubnetName}'

// Helper: is this resource active (either existing or being created)?
var hasPg = deployPostgresql || !empty(existingPgServerName)
var hasStorage = deployStorageAccount || !empty(existingStorageAccountName)
var hasKv = deployKeyVault || !empty(existingKeyVaultName)

// Helper: should we create a local privatelink zone, or reuse an existing one?
var useExistingDnsPg = !empty(existingPrivateDnsZoneIdPg)
var useExistingDnsBlob = !empty(existingPrivateDnsZoneIdBlob)
var useExistingDnsKv = !empty(existingPrivateDnsZoneIdKv)

// ════════════════════════════════════════
// 1. Key Vault
// ════════════════════════════════════════

module keyVault 'modules/keyvault.bicep' = if (hasKv) {
  name: 'deploy-keyvault-${serviceName}'
  params: {
    serviceName: serviceName
    location: location
    tags: defaultTags
    newKeyVaultName: newKeyVaultName
    deployerObjectId: deployerObjectId
    secrets: keyVaultSecrets
    existingName: existingKeyVaultName
    disablePublicNetworkAccess: disableKeyVaultPublicAccess
  }
}

// ════════════════════════════════════════
// 2. PostgreSQL + Storage (parallel)
// ════════════════════════════════════════

module postgresql 'modules/postgresql.bicep' = if (hasPg) {
  name: 'deploy-postgresql-${serviceName}'
  params: {
    serviceName: serviceName
    location: location
    tags: defaultTags
    adminUser: pgAdminUser
    adminPassword: pgAdminPassword
    skuName: pgSkuName
    skuTier: pgSkuTier
    storageSizeGB: pgStorageSizeGB
    version: pgVersion
    highAvailability: pgHighAvailability
    databaseNames: pgDatabaseNames
    extensions: pgExtensions
    existingName: existingPgServerName
    networkAccess: pgNetworkAccess
  }
}

module storageAccount 'modules/storage-account.bicep' = if (hasStorage) {
  name: 'deploy-storage-${serviceName}'
  params: {
    serviceName: serviceName
    location: location
    tags: defaultTags
    skuName: storageSkuName
    blobContainers: storageBlobContainers
    existingName: existingStorageAccountName
    disablePublicNetworkAccess: disableStoragePublicAccess
  }
}

// ════════════════════════════════════════
// 3. Private DNS Zones — local creation path
// Skipped when an existingPrivateDnsZoneId* is provided (reuse central zone).
// Zone names are GOV-CLOUD-ONLY in this template — KV uses 'vaultcore' (not
// 'vault'), and PG/blob use the ...usgovcloudapi.net suffix to match the
// CNAMEs that Gov Cloud services emit. To support public Azure as well,
// hoist these to a cloud-aware ternary keyed off az.environment().name.
// ════════════════════════════════════════

module dnsZonePg 'modules/private-dns-zone.bicep' = if (deployPrivateEndpoints && hasPg && !useExistingDnsPg) {
  name: 'deploy-dns-pg-${serviceName}'
  params: {
    zoneName: 'privatelink.postgres.database.usgovcloudapi.net'
    tags: defaultTags
    vnetResourceId: vnet.id
  }
}

module dnsZoneBlob 'modules/private-dns-zone.bicep' = if (deployPrivateEndpoints && hasStorage && !useExistingDnsBlob) {
  name: 'deploy-dns-blob-${serviceName}'
  params: {
    zoneName: 'privatelink.blob.core.usgovcloudapi.net'
    tags: defaultTags
    vnetResourceId: vnet.id
  }
}

module dnsZoneKv 'modules/private-dns-zone.bicep' = if (deployPrivateEndpoints && hasKv && !useExistingDnsKv) {
  name: 'deploy-dns-kv-${serviceName}'
  params: {
    zoneName: 'privatelink.vaultcore.usgovcloudapi.net'
    tags: defaultTags
    vnetResourceId: vnet.id
  }
}

// ════════════════════════════════════════
// 4. Private Endpoints
// privateDnsZoneId resolves in order: existingPrivateDnsZoneId<x> param first,
// otherwise the locally-created zone module output. The dnsZoneGroup child
// of private-endpoint.bicep registers the A-record in that zone — requires
// `Private DNS Zone Contributor` on the zone.
// ════════════════════════════════════════

module pePg 'modules/private-endpoint.bicep' = if (deployPrivateEndpoints && hasPg) {
  name: 'deploy-pe-pg-${serviceName}'
  params: {
    name: 'pe-pg-${serviceName}'
    location: location
    tags: defaultTags
    targetResourceId: hasPg ? postgresql.outputs.pgServerResourceId : ''
    groupId: 'postgresqlServer'
    subnetId: peSubnetId
    privateDnsZoneId: useExistingDnsPg ? existingPrivateDnsZoneIdPg : ((deployPrivateEndpoints && hasPg) ? dnsZonePg.outputs.zoneId : '')
  }
}

module peBlob 'modules/private-endpoint.bicep' = if (deployPrivateEndpoints && hasStorage) {
  name: 'deploy-pe-blob-${serviceName}'
  params: {
    name: 'pe-blob-${serviceName}'
    location: location
    tags: defaultTags
    targetResourceId: hasStorage ? storageAccount.outputs.storageAccountId : ''
    groupId: 'blob'
    subnetId: peSubnetId
    privateDnsZoneId: useExistingDnsBlob ? existingPrivateDnsZoneIdBlob : ((deployPrivateEndpoints && hasStorage) ? dnsZoneBlob.outputs.zoneId : '')
  }
}

module peKv 'modules/private-endpoint.bicep' = if (deployPrivateEndpoints && hasKv) {
  name: 'deploy-pe-kv-${serviceName}'
  params: {
    name: 'pe-kv-${serviceName}'
    location: location
    tags: defaultTags
    targetResourceId: hasKv ? keyVault.outputs.keyVaultResourceId : ''
    groupId: 'vault'
    subnetId: peSubnetId
    privateDnsZoneId: useExistingDnsKv ? existingPrivateDnsZoneIdKv : ((deployPrivateEndpoints && hasKv) ? dnsZoneKv.outputs.zoneId : '')
  }
}

// ════════════════════════════════════════
// Outputs
// ════════════════════════════════════════

output keyVaultName string = hasKv ? keyVault.outputs.keyVaultName : 'not deployed'
output keyVaultUri string = hasKv ? keyVault.outputs.keyVaultUri : 'not deployed'
output pgServerFqdn string = hasPg ? postgresql.outputs.pgServerFqdn : 'not deployed'
output pgServerName string = hasPg ? postgresql.outputs.pgServerName : 'not deployed'
output storageAccountName string = hasStorage ? storageAccount.outputs.storageAccountName : 'not deployed'
output blobEndpointSuffix string = hasStorage ? storageAccount.outputs.blobEndpointSuffix : 'not deployed'
output acrLoginServer string = acr.properties.loginServer
