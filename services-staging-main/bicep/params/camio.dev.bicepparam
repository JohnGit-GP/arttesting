using '../main.bicep'

// Camio — Dev Environment (PLACEHOLDER)
// Pending Gov Cloud distribution from vendor. Config TBD.

param serviceName = 'camio'
param environment = 'dev'
param location = 'usgovvirginia'

param aksClusterName = 'placeholder'
param aksClusterResourceGroup = 'placeholder'
param vnetName = 'placeholder'
param vnetResourceGroup = 'placeholder'
param privateEndpointSubnetName = 'placeholder'
param acrName = 'placeholder'
param acrResourceGroup = 'placeholder'

param deployPostgresql = false
param deployStorageAccount = false
param deployKeyVault = false
param deployPrivateEndpoints = false

param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''
