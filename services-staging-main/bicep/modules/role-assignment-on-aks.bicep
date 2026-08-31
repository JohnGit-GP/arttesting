// ============================================================
// Role Assignment on an AKS cluster
// Deploys into the AKS cluster's resource group (pass via scope
// on the module call from the parent).
// ============================================================

targetScope = 'resourceGroup'

@description('AKS cluster name in this resource group')
param aksClusterName string

@description('Principal ID to grant the role to')
param principalId string

@description('Built-in role definition ID (guid only)')
param roleDefinitionId string

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-01-01' existing = {
  name: aksClusterName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, principalId, roleDefinitionId)
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
