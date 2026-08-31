// ============================================================
// Key Vault Module
// References an existing Key Vault or creates a new one.
// Uses access policies model (not RBAC).
// ============================================================

@description('Name prefix for new Key Vault (ignored if existingName provided)')
param serviceName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Name for new Key Vault (ignored if existingName provided). Empty = auto-generate.')
param newKeyVaultName string = ''

@description('Managed identity principal ID for access policy. Empty = no identity policy added (deployer-only access). Currently unwired — main.bicep does not pass a workload identity. Kept as a hook for a future Secret Store CSI driver / federated KV access pattern.')
param identityPrincipalId string = ''

@description('Key Vault tenant ID (defaults to current subscription tenant)')
param tenantId string = subscription().tenantId

@description('Name of an existing Key Vault to use (empty = create new)')
param existingName string = ''

@description('Soft-delete retention in days (7-90)')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Enable purge protection. IRREVERSIBLE once set to true.')
param enablePurgeProtection bool = true

@description('Disable public network access (recommended when fronted by a private endpoint)')
param disablePublicNetworkAccess bool = true

@description('Optional AAD objectId of the deploying user/SP. When set, grants get/list/set/delete on secrets so deploy.sh and helm-deploy.sh can manage them. Empty = no deployer policy added.')
param deployerObjectId string = ''

@description('Secrets to create as name/value pairs')
@secure()
param secrets object = {}

var createNew     = empty(existingName)
var generatedName = take('kv-${serviceName}-${uniqueString(resourceGroup().id)}', 24)
var kvName = createNew ? (empty(newKeyVaultName) ? generatedName : newKeyVaultName) : existingName

var hasIdentity = !empty(identityPrincipalId)
var hasDeployer = !empty(deployerObjectId)

var identityAccessPolicy = {
  tenantId: tenantId
  objectId: identityPrincipalId
  permissions: {
    secrets: [
      'get'
      'list'
      'set'
      'delete'
    ]
  }
}

var deployerAccessPolicy = {
  tenantId: tenantId
  objectId: deployerObjectId
  permissions: {
    secrets: [
      'get'
      'list'
      'set'
      'delete'
    ]
  }
}

var initialAccessPolicies = concat(
  hasIdentity ? [identityAccessPolicy] : [],
  hasDeployer ? [deployerAccessPolicy] : []
)

// Reference existing Key Vault
resource kvExisting 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!createNew) {
  name: existingName
}

// Create new Key Vault
resource kvNew 'Microsoft.KeyVault/vaults@2023-07-01' = if (createNew) {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection
    publicNetworkAccess: disablePublicNetworkAccess ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: disablePublicNetworkAccess ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    accessPolicies: initialAccessPolicies
  }
}

// Ensure the managed identity (and deployer, if provided) have access on
// an existing vault too. A single 'add' call covers both — multiple
// access-policy resources on one vault would race.
resource kvAccessPoliciesExisting 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = if (!createNew) {
  parent: kvExisting
  name: 'add'
  properties: {
    accessPolicies: initialAccessPolicies
  }
}

// Pre-populate secrets (new vault)
resource kvSecretsNew 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for secretName in objectKeys(secrets): if (createNew) {
    parent: kvNew
    name: secretName
    properties: {
      value: secrets[secretName]
    }
  }
]

// Pre-populate secrets (existing vault)
// dependsOn ensures the deployer access policy lands before secret writes —
// otherwise kvAccessPoliciesExisting and kvSecretsExisting can race and the
// secret writes fail with 403 because the deployer hasn't been added yet.
resource kvSecretsExisting 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for secretName in objectKeys(secrets): if (!createNew) {
    parent: kvExisting
    name: secretName
    properties: {
      value: secrets[secretName]
    }
    dependsOn: [
      kvAccessPoliciesExisting
    ]
  }
]

// ── Outputs (derive from name to avoid nullable-resource access) ──
output keyVaultName       string = kvName
output keyVaultUri        string = format('https://{0}{1}/', kvName, az.environment().suffixes.keyvaultDns)
output keyVaultResourceId string = resourceId('Microsoft.KeyVault/vaults', kvName)
