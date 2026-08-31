using '../main.bicep'

// ══════════════════════════════════════════════════════════════
// GitLab — Dev Environment (Azure infra only)
// ══════════════════════════════════════════════════════════════
// Heaviest service: needs PostgreSQL 16, Redis (Azure Cache),
// and Blob Storage (~12 containers). All bundled subcharts
// disabled — using external Azure services.
// ══════════════════════════════════════════════════════════════

// ── Service Identity ──
param serviceName = 'gitlab'
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
param deployPrivateEndpoints = false

// ── Existing Resources (overridden by deploy.sh from azure.env) ──
param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''

// ── PostgreSQL (dev sizing — GitLab is heavier than Artifactory) ──
param pgSkuName = 'Standard_B2s'
param pgSkuTier = 'Burstable'
param pgStorageSizeGB = 64
param pgVersion = '16'
param pgHighAvailability = 'Disabled'
param pgDatabaseNames = ['gitlabhq_production']
param pgExtensions = 'pg_trgm,btree_gist'
param pgAdminUser = 'pgadmin'

// ── Storage (12 containers for GitLab object storage) ──
param storageSkuName = 'Standard_LRS'
param storageBlobContainers = [
  'gitlab-artifacts'
  'git-lfs'
  'gitlab-uploads'
  'gitlab-packages'
  'gitlab-mr-diffs'
  'gitlab-terraform-state'
  'gitlab-ci-secure-files'
  'gitlab-dependency-proxy'
  'registry'
  'gitlab-pages'
  'gitlab-backups'
  'gitlab-backups-tmp'
]
