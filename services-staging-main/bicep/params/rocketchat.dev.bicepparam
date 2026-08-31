using '../main.bicep'

// Rocket.Chat — Dev Environment
// Requires: Self-managed MongoDB 8.0 on AKS (Cosmos DB vCore unavailable in Gov Cloud)
// No PostgreSQL. Optional blob storage for file uploads via MinIO or GridFS.

param serviceName = 'rocketchat'
param environment = 'dev'
param location = 'usgovvirginia'

param aksClusterName = 'placeholder'
param aksClusterResourceGroup = 'placeholder'
param vnetName = 'placeholder'
param vnetResourceGroup = 'placeholder'
param privateEndpointSubnetName = 'placeholder'
param acrName = 'placeholder'
param acrResourceGroup = 'placeholder'

param deployPostgresql = false           // Uses MongoDB, not PostgreSQL
param deployStorageAccount = false       // File uploads via GridFS (in MongoDB) for dev
param deployKeyVault = true
param deployPrivateEndpoints = false

param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''
