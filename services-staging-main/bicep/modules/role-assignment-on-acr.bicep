// ============================================================
// Role Assignment on a Container Registry
// Deploys into the ACR's resource group (pass via scope on the
// module call from the parent).
// ============================================================

targetScope = 'resourceGroup'

@description('ACR name in this resource group')
param acrName string

@description('Principal ID to grant the role to')
param principalId string

@description('Built-in role definition ID (guid only)')
param roleDefinitionId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, principalId, roleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
