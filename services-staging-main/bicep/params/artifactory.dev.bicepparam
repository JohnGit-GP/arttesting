using '../main.bicep'

// ══════════════════════════════════════════════════════════════
// Artifactory — Dev Environment (Azure infra only)
// ══════════════════════════════════════════════════════════════
// Helm config, secrets, and K8s resources are in packages/artifactory.json.
// Shared resource names come from azure.env via deploy.sh.
// ══════════════════════════════════════════════════════════════

// ── Service Identity ──
param serviceName = 'artifactory'
param environment = 'dev'
param location = 'usgovvirginia'

// ── Existing Infrastructure (overridden by deploy.sh from azure.env) ──
param aksClusterName = 'placeholder'
param aksClusterResourceGroup = 'placeholder'
param vnetName = 'placeholder'
param vnetResourceGroup = 'placeholder'
param privateEndpointSubnetName = 'placeholder'
param acrName = 'placeholder'
param acrResourceGroup = 'placeholder'

// ── Feature Flags ──
param deployPostgresql = true
param deployStorageAccount = true
param deployKeyVault = true
param deployPrivateEndpoints = true

// ── Existing Resources (overridden by deploy.sh from azure.env) ──
param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''

// ── Network Access (private-only — central privatelink zones provide DNS) ──
param disableKeyVaultPublicAccess = true
param disableStoragePublicAccess = true
param pgNetworkAccess = 'private'

// ── PostgreSQL (dev sizing) ──
param pgSkuName = 'Standard_B1ms'
param pgSkuTier = 'Burstable'
param pgStorageSizeGB = 32
param pgVersion = '16'
param pgHighAvailability = 'Disabled'
param pgDatabaseNames = ['artifactory', 'xraydb', 'distribution']
param pgExtensions = 'pg_trgm'
param pgAdminUser = 'pgadmin'

// ── Storage ──
param storageSkuName = 'Standard_LRS'
param storageBlobContainers = ['artifactory-data']
