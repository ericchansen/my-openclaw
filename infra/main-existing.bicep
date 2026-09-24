// Existing-host changes are monitoring plus the declared VM snapshot RBAC prerequisites;
// compute, networking and data stores are read-only.
targetScope = 'resourceGroup'

param location string = 'centralus'
param diagnosticsContactEmails array
param escalationContactEmails array
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: 'openclaw-vm'
}
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: 'kv-oc-${uniqueString(resourceGroup().id)}'
}
resource snapshotContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, vm.id, '7efff54f-a5b4-42b5-a1c5-5411624893ce')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7efff54f-a5b4-42b5-a1c5-5411624893ce'
    )
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource snapshotReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, vm.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    )
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
module monitoring 'monitoring.bicep' = {
  name: 'openclaw-monitoring'
  params: {
    location: location
    vmName: vm.name
    diagnosticsContactEmails: diagnosticsContactEmails
    escalationContactEmails: escalationContactEmails
  }
}

output keyVaultName string = keyVault.name
output logAnalyticsWorkspaceName string = monitoring.outputs.workspaceName
output gatewayNote string = 'Monitoring and snapshot prerequisites updated; VM, network, data stores and runtime were not changed.'
