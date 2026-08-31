using '../main.bicep'

// Confluence Data Center — Dev Environment
// Requires: PostgreSQL 16, Azure Files NFS (shared home), managed disks (local home)

param serviceName = 'confluence'
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
param deployStorageAccount = false       // Confluence uses Azure Files NFS, not blob
param deployKeyVault = true
param deployPrivateEndpoints = false

param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''

param pgSkuName = 'Standard_B1ms'
param pgSkuTier = 'Burstable'
param pgStorageSizeGB = 32
param pgVersion = '16'
param pgHighAvailability = 'Disabled'
param pgDatabaseNames = ['confluencedb']
param pgExtensions = ''
param pgAdminUser = 'pgadmin'
