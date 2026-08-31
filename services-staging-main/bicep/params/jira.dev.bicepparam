using '../main.bicep'

// Jira Data Center — Dev Environment
// Requires: PostgreSQL 16+, Azure Files NFS (shared home), managed disks (local home)

param serviceName = 'jira'
param environment = 'dev'
param location = 'usgovvirginia'

param aksClusterName = 'placeholder'
param aksClusterResourceGroup = 'placeholder'
param vnetName = 'placeholder'
param vnetResourceGroup = 'placeholder'
param privateEndpointSubnetName = 'placeholder'
param acrName = 'placeholder'
param acrResourceGroup = 'placeholder'

param deployPostgresql = true
param deployStorageAccount = false       // Jira uses Azure Files NFS, not blob
param deployKeyVault = true
param deployPrivateEndpoints = false

param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''

// PostgreSQL 16 required for Jira 11.x
param pgSkuName = 'Standard_B1ms'
param pgSkuTier = 'Burstable'
param pgStorageSizeGB = 32
param pgVersion = '16'
param pgHighAvailability = 'Disabled'
param pgDatabaseNames = ['jira']
param pgExtensions = ''
param pgAdminUser = 'pgadmin'
