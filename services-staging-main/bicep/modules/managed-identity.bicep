// ============================================================
// Managed Identity Module
// Creates a User-Assigned Managed Identity and grants:
//   - AKS Cluster User Role on the AKS cluster (listClusterUserCredential)
//   - AcrPull on the container registry
// AKS and ACR may live in resource groups other than this template's
// deploy RG; role assignments are applied via sub-modules scoped to
// each target's RG.
//
// TODO: Wire up commented-out role assignments below.
// Requires creating role-assignment-on-aks.bicep and
// role-assignment-on-acr.bicep submodules first.
// ============================================================

@description('Name prefix for the managed identity')
param serviceName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('AKS cluster name')
#disable-next-line no-unused-params
param aksClusterName string

@description('AKS cluster resource group')
#disable-next-line no-unused-params
param aksClusterResourceGroup string

@description('ACR name')
#disable-next-line no-unused-params
param acrName string

@description('ACR resource group')
#disable-next-line no-unused-params
param acrResourceGroup string

// Role definition IDs (built-in Azure roles)
#disable-next-line no-unused-vars
var aksClusterUserRoleId = '4abbcc35-e782-43d8-92c5-2d3f1bd2253f' // Azure Kubernetes Service Cluster User Role
#disable-next-line no-unused-vars
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'         // AcrPull

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${serviceName}-deployer'
  location: location
  tags: tags
}

// module aksRoleAssignment 'role-assignment-on-aks.bicep' = {
//   name: 'ra-aks-${serviceName}'
//   scope: resourceGroup(aksClusterResourceGroup)
//   params: {
//     aksClusterName: aksClusterName
//     principalId: identity.properties.principalId
//     roleDefinitionId: aksClusterUserRoleId
//   }
// }
//
// module acrRoleAssignment 'role-assignment-on-acr.bicep' = {
//   name: 'ra-acr-${serviceName}'
//   scope: resourceGroup(acrResourceGroup)
//   params: {
//     acrName: acrName
//     principalId: identity.properties.principalId
//     roleDefinitionId: acrPullRoleId
//   }
// }

output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
