// Azure VM deployment for OpenClaw personal AI assistant
// New hosts only. Existing hosts use the monitoring-only main-existing.bicep path.

@description('Azure region for all resources')
param location string = 'centralus'

@description('VM admin username')
param adminUsername string = 'azureuser'

@description('SSH public key for VM authentication')
@secure()
param sshPublicKey string

@description('New-VM size; default ARM64 capacity profile has 4 vCPUs, 16 GiB RAM, and no local temporary disk')
param vmSize string = 'Standard_D4ps_v6'

@description('OS disk size in GiB')
@minValue(30)
param osDiskSizeGB int = 64

@description('Unique DNS label for the public IP')
param dnsLabelPrefix string = 'openclaw-${uniqueString(resourceGroup().id)}'

@description('Principal ID of the deploying user (for Key Vault admin access)')
param deployerPrincipalId string = ''

@description('Principal type for the optional Key Vault administrator assignment')
@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string = 'User'

@description('Canonical Ubuntu 24.04 ARM64 image version for new VMs.')
param ubuntuImageVersion string = '24.04.202607140'

@description('Private backup blob container name')
param backupContainerName string = 'openclaw-backups'

@description('Email addresses for independent runtime alerts; empty disables email actions')
param monitoringContactEmails array = []

@description('Platform Percentage CPU average over 15 minutes that triggers saturation alerting; independent of guest logs and CPU credits')
@minValue(80)
@maxValue(99)
param cpuSaturationPercent int = 90

var vmName = 'openclaw-vm'
var vnetName = 'openclaw-vnet'
var subnetName = 'default'
var nsgName = 'openclaw-nsg'
var publicIpName = 'openclaw-pip'
var nicName = 'openclaw-nic'
var keyVaultName = 'kv-oc-${uniqueString(resourceGroup().id)}'
var storageAccountName = 'stoc${uniqueString(resourceGroup().id)}'
var vmSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
var runtimeVersions = loadJsonContent('../config/runtime-versions.json')
var openclawVersion = runtimeVersions.openclaw.version
var openclawIntegrity = runtimeVersions.openclaw.npmIntegrity
var diagnosticsOtelVersion = runtimeVersions.packages['@openclaw/diagnostics-otel'].version
var diagnosticsOtelIntegrity = runtimeVersions.packages['@openclaw/diagnostics-otel'].npmIntegrity
var nodeVersion = runtimeVersions.node.version
var nodeArm64Sha256 = runtimeVersions.node.linuxArm64Sha256
var otelVersion = runtimeVersions.otelCollectorContrib.version
var otelArm64Url = runtimeVersions.otelCollectorContrib.linuxArm64Url
var otelArm64Sha256 = runtimeVersions.otelCollectorContrib.linuxArm64Sha256
var copilotVersion = runtimeVersions.packages['@github/copilot'].version
var copilotIntegrity = runtimeVersions.packages['@github/copilot'].npmIntegrity
var mcpEbirdVersion = runtimeVersions.packages['@pondlog/mcp-ebird'].version
var mcpEbirdIntegrity = runtimeVersions.packages['@pondlog/mcp-ebird'].npmIntegrity
var mcpPondlogVersion = runtimeVersions.packages['@pondlog/mcp-pondlog'].version
var mcpPondlogIntegrity = runtimeVersions.packages['@pondlog/mcp-pondlog'].npmIntegrity
var sandboxSourceCommit = runtimeVersions.upstream.commit
var sandboxArchiveUrl = runtimeVersions.upstream.archiveUrl
var sandboxArchiveSha256 = runtimeVersions.upstream.archiveSha256
var sandboxBrowserContract = runtimeVersions.sandbox.browserContract
var cloudInitTemplate = loadTextContent('cloud-init.yaml')
var cloudInitBundle = replace(
  cloudInitTemplate,
  '__RUNTIME_BUNDLE_XZ_B64__',
  loadTextContent('runtime-assets.tar.xz.b64')
)
var cloudInit24 = replace(cloudInitBundle, '__ADMIN_USERNAME__', adminUsername)
var cloudInit25 = replace(cloudInit24, '__KEY_VAULT_NAME__', keyVaultName)
var cloudInit26 = replace(cloudInit25, '__STORAGE_ACCOUNT_NAME__', storageAccountName)
var cloudInit27 = replace(cloudInit26, '__STORAGE_CONTAINER_NAME__', backupContainerName)
var cloudInit28 = replace(cloudInit27, '__OPENCLAW_VERSION__', openclawVersion)
var cloudInit29 = replace(cloudInit28, '__OPENCLAW_INTEGRITY__', openclawIntegrity)
var cloudInit30 = replace(cloudInit29, '__NODE_VERSION__', nodeVersion)
var cloudInit31 = replace(cloudInit30, '__NODE_SHA256__', nodeArm64Sha256)
var cloudInit32 = replace(cloudInit31, '__OTEL_VERSION__', otelVersion)
var cloudInit33 = replace(cloudInit32, '__OTEL_URL__', otelArm64Url)
var cloudInit34 = replace(cloudInit33, '__OTEL_SHA256__', otelArm64Sha256)
var cloudInit35 = replace(cloudInit34, '__COPILOT_VERSION__', copilotVersion)
var cloudInit36 = replace(cloudInit35, '__COPILOT_INTEGRITY__', copilotIntegrity)
var cloudInit37 = replace(cloudInit36, '__MCP_EBIRD_VERSION__', mcpEbirdVersion)
var cloudInit38 = replace(cloudInit37, '__MCP_EBIRD_INTEGRITY__', mcpEbirdIntegrity)
var cloudInit39 = replace(cloudInit38, '__MCP_PONDLOG_VERSION__', mcpPondlogVersion)
var cloudInit40 = replace(cloudInit39, '__MCP_PONDLOG_INTEGRITY__', mcpPondlogIntegrity)
var cloudInit41 = replace(cloudInit40, '__SANDBOX_SOURCE_COMMIT__', sandboxSourceCommit)
var cloudInit42 = replace(cloudInit41, '__SANDBOX_ARCHIVE_URL__', sandboxArchiveUrl)
var cloudInit43 = replace(cloudInit42, '__SANDBOX_ARCHIVE_SHA256__', sandboxArchiveSha256)
var cloudInit44 = replace(cloudInit43, '__SANDBOX_BROWSER_CONTRACT__', sandboxBrowserContract)
var cloudInit45 = replace(cloudInit44, '__DIAGNOSTICS_OTEL_VERSION__', diagnosticsOtelVersion)
var renderedCloudInit = replace(cloudInit45, '__DIAGNOSTICS_OTEL_INTEGRITY__', diagnosticsOtelIntegrity)

// Key Vault — RBAC authorization, soft delete + purge protection
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  properties: {
    accessPolicies: []
    createMode: 'default'
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource backupStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

resource backupBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: backupStorage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 7
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    restorePolicy: {
      enabled: true
      days: 6
    }
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: backupBlobService
  name: backupContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource backupLifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: backupStorage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'delete-daily-after-35-days'
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 35
                }
              }
              version: {
                delete: {
                  daysAfterCreationGreaterThan: 35
                }
              }
            }
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${backupContainerName}/daily/'
              ]
            }
          }
        }
        {
          enabled: true
          name: 'delete-monthly-after-365-days'
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 365
                }
              }
              version: {
                delete: {
                  daysAfterCreationGreaterThan: 365
                }
              }
            }
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${backupContainerName}/monthly/'
              ]
            }
          }
        }
      ]
    }
  }
}

// Role assignment: VM managed identity → Key Vault Secrets User
// Built-in role ID for Key Vault Secrets User: 4633458b-17de-408a-b874-0445c86b69e6
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, vm.id, '4633458b-17de-408a-b874-0445c86b69e6')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Built-in role ID for Storage Blob Data Contributor:
// ba92f5b4-2d11-453d-a403-e96b0029c9fe
resource backupStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: backupContainer
  name: guid(backupContainer.id, vm.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
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
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '00482a5a-887f-4fb3-b363-3b7fe8e74483'
    )
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

var sshSecurityRule = {
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
// Existing hosts use main-existing.bicep; this bootstrap rule is new-host only.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      sshSecurityRule
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
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vmSubnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
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
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
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
      customData: base64(renderedCloudInit)
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server-arm64'
        version: ubuntuImageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        diskSizeGB: osDiskSizeGB
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

module monitoring 'monitoring.bicep' = {
  name: 'openclaw-monitoring'
  params: {
    location: location
    vmName: vm.name
    monitoringContactEmails: monitoringContactEmails
    cpuSaturationPercent: cpuSaturationPercent
  }
}
output outboundPublicIp string = publicIp.properties.ipAddress
output vmFqdn string = publicIp.properties.dnsSettings.fqdn
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.dnsSettings.fqdn}'
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output backupStorageAccountName string = backupStorage.name
output backupContainerName string = backupContainer.name
output logAnalyticsWorkspaceName string = monitoring.outputs.workspaceName
output openClawContentTableName string = monitoring.outputs.contentTable
output gatewayNote string = 'Gateway and OTLP remain loopback-only. Use an authenticated tunnel; private-network cutover is separate.'
output vmPrincipalId string = vm.identity.principalId
