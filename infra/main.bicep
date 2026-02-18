// Azure VM deployment for OpenClaw personal AI assistant
// Deploys: VM + VNet + NSG + Public IP + NIC + Key Vault (with managed identity)

@description('Azure region for all resources')
param location string = 'centralus'

@description('VM admin username')
param adminUsername string = 'azureuser'

@description('SSH public key for VM authentication')
@secure()
param sshPublicKey string

@description('VM size')
param vmSize string = 'Standard_B2pls_v2'

@description('Skip cloud-init customData (required for updates to existing VMs)')
param skipCustomData bool = false

@description('Unique DNS label for the public IP')
param dnsLabelPrefix string = 'openclaw-${uniqueString(resourceGroup().id)}'

@description('OpenClaw gateway token (stored in Key Vault)')
@secure()
param openclawGatewayToken string = ''

@description('GitHub PAT for OpenClaw (stored in Key Vault)')
@secure()
param githubToken string = ''

@description('Principal ID of the deploying user (for Key Vault admin access)')
param deployerPrincipalId string = ''

var vmName = 'openclaw-vm'
var vnetName = 'openclaw-vnet'
var subnetName = 'default'
var nsgName = 'openclaw-nsg'
var publicIpName = 'openclaw-pip'
var nicName = 'openclaw-nic'
var keyVaultName = 'kv-oc-${uniqueString(resourceGroup().id)}'

// Key Vault — RBAC authorization, soft delete + purge protection
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Seed secrets into Key Vault (only if values are provided)
resource gatewayTokenSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (!empty(openclawGatewayToken)) {
  parent: keyVault
  name: 'OPENCLAW-GATEWAY-TOKEN'
  properties: {
    value: openclawGatewayToken
  }
}

resource githubTokenSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (!empty(githubToken)) {
  parent: keyVault
  name: 'GITHUB-TOKEN'
  properties: {
    value: githubToken
  }
}

// Role assignment: VM managed identity → Key Vault Secrets User
// Built-in role ID for Key Vault Secrets User: 4633458b-17de-408a-b874-0445c86b69e6
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, vm.id, '4633458b-17de-408a-b874-0445c86b69e6')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role assignment: deployer → Key Vault Administrator (for CLI secret management)
// Built-in role ID for Key Vault Administrator: 00482a5a-887f-4fb3-b363-3b7fe8e74483
resource kvAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: keyVault
  name: guid(keyVault.id, deployerPrincipalId, '00482a5a-887f-4fb3-b363-3b7fe8e74483')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}

// Network Security Group — SSH only; gateway/bridge accessed via Tailscale
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Public IP
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabelPrefix
    }
  }
}

// Network Interface
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Virtual Machine — Ubuntu 24.04 LTS with system-assigned managed identity
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      customData: skipCustomData ? null : loadFileAsBase64('cloud-init.yaml')
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server-arm64'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        diskSizeGB: 30
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output vmPublicIp string = publicIp.properties.ipAddress
output vmFqdn string = publicIp.properties.dnsSettings.fqdn
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.dnsSettings.fqdn}'
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output gatewayNote string = 'Gateway is loopback-only. Access via Tailscale IP or SSH tunnel on port 18789.'
