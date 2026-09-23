// Existing-host changes are monitoring-only; compute, networking and data stores are read-only.
targetScope = 'resourceGroup'

param location string = 'centralus'
param monitoringContactEmails array = []
@minValue(80)
@maxValue(99)
param cpuSaturationPercent int = 90
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: 'openclaw-vm'
}
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: 'kv-oc-${uniqueString(resourceGroup().id)}'
}
module monitoring 'monitoring.bicep' = {
  name: 'openclaw-monitoring'
  params: {
    location: location
    vmName: vm.name
    monitoringContactEmails: monitoringContactEmails
    cpuSaturationPercent: cpuSaturationPercent
  }
}

output keyVaultName string = keyVault.name
output logAnalyticsWorkspaceName string = monitoring.outputs.workspaceName
output gatewayNote string = 'Monitoring updated; VM, network, data stores and runtime were not changed.'
