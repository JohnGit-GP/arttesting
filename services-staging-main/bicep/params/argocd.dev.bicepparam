using '../main.bicep'

// ══════════════════════════════════════════════════════════════
// ArgoCD — Dev Environment (Azure infra only)
// ══════════════════════════════════════════════════════════════
// ArgoCD is self-contained — no PostgreSQL, no storage, no
// external backing services. Only needs Key Vault for secrets.
// ══════════════════════════════════════════════════════════════

// ── Service Identity ──
param serviceName = 'argocd'
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
param deployPostgresql = false
param deployStorageAccount = false
param deployKeyVault = true
param deployPrivateEndpoints = false

// ── Existing Resources (overridden by deploy.sh from azure.env) ──
param existingPgServerName = ''
param existingStorageAccountName = ''
param existingKeyVaultName = ''
