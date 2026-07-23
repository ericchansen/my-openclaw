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
param vmSize string = 'Standard_B2ps_v2'

@description('OS disk size in GiB')
@minValue(30)
param osDiskSizeGB int = 64

@description('Skip cloud-init customData (required for updates to existing VMs)')
param skipCustomData bool = false

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

@description('Tested OpenClaw npm package version')
param openclawVersion string = '2026.7.1'

@description('Tested Node.js version')
param nodeVersion string = '22.23.1'

@description('SHA-256 for the tested Node.js Linux ARM64 tarball')
param nodeArm64Sha256 string = '0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1'

@description('Tested GitHub Copilot CLI npm package version')
param copilotVersion string = '1.0.71-3'

@description('Tested Pondlog eBird MCP npm package version')
param mcpEbirdVersion string = '0.1.5'

@description('Tested Pondlog MCP npm package version')
param mcpPondlogVersion string = '0.4.0'

@description('Canonical Ubuntu 24.04 ARM64 image version. Keep the tested pin for new VMs; pass latest when updating a VM whose model already uses latest.')
param ubuntuImageVersion string = '24.04.202607140'

@description('Private backup blob container name')
param backupContainerName string = 'openclaw-backups'

@description('Email addresses for independent runtime alerts; empty disables email actions')
param monitoringContactEmails array = []

var vmName = 'openclaw-vm'
var vnetName = 'openclaw-vnet'
var subnetName = 'default'
var nsgName = 'openclaw-nsg'
var publicIpName = 'openclaw-pip'
var nicName = 'openclaw-nic'
var keyVaultName = 'kv-oc-${uniqueString(resourceGroup().id)}'
var storageAccountName = 'stoc${uniqueString(resourceGroup().id)}'
var logAnalyticsName = 'log-openclaw-${uniqueString(resourceGroup().id)}'
var dataCollectionRuleName = 'dcr-openclaw-${uniqueString(resourceGroup().id)}'
var alertActionGroupName = 'ag-openclaw-${uniqueString(resourceGroup().id)}'
var cloudInitTemplate = loadTextContent('cloud-init.yaml')
var cloudInit01 = replace(cloudInitTemplate, '__INSTALLER_B64__', base64(loadTextContent('../scripts/install-openclaw-runtime.sh')))
var cloudInit02 = replace(cloudInit01, '__GATEWAY_SERVICE_B64__', base64(loadTextContent('../config/openclaw-gateway.service')))
var cloudInit03 = replace(cloudInit02, '__BACKUP_SERVICE_B64__', base64(loadTextContent('../config/openclaw-backup.service')))
var cloudInit04 = replace(cloudInit03, '__BACKUP_TIMER_B64__', base64(loadTextContent('../config/openclaw-backup.timer')))
var cloudInit05 = replace(cloudInit04, '__HEALTH_SERVICE_B64__', base64(loadTextContent('../config/openclaw-health.service')))
var cloudInit06 = replace(cloudInit05, '__HEALTH_TIMER_B64__', base64(loadTextContent('../config/openclaw-health.timer')))
var cloudInit07 = replace(cloudInit06, '__JOURNALD_CONFIG_B64__', base64(loadTextContent('../config/openclaw-journald.conf')))
var cloudInit08 = replace(cloudInit07, '__BACKUP_SCRIPT_B64__', base64(loadTextContent('../scripts/openclaw-backup.sh')))
var cloudInit09 = replace(cloudInit08, '__RESTORE_VERIFY_SCRIPT_B64__', base64(loadTextContent('../scripts/openclaw-restore-verify.sh')))
var cloudInit10 = replace(cloudInit09, '__HEALTH_SCRIPT_GZIP_B64__', loadTextContent('openclaw-health-check.sh.gz.b64'))
var cloudInit11 = replace(cloudInit10, '__KEYVAULT_RESOLVER_B64__', base64(loadTextContent('../scripts/openclaw-keyvault-resolver.py')))
var cloudInit12 = replace(cloudInit11, '__GATEWAY_LAUNCH_B64__', base64(loadTextContent('../scripts/openclaw-gateway-launch.py')))
var cloudInit13 = replace(cloudInit12, '__GOG_LAUNCH_B64__', base64(loadTextContent('../scripts/openclaw-gog-launch.py')))
var cloudInit14 = replace(cloudInit13, '__MCP_LAUNCH_B64__', base64(loadTextContent('../scripts/openclaw-mcp-launch.py')))
var cloudInit15 = replace(cloudInit14, '__ADMIN_USERNAME__', adminUsername)
var cloudInit16 = replace(cloudInit15, '__KEY_VAULT_NAME__', keyVaultName)
var cloudInit17 = replace(cloudInit16, '__STORAGE_ACCOUNT_NAME__', storageAccountName)
var cloudInit18 = replace(cloudInit17, '__STORAGE_CONTAINER_NAME__', backupContainerName)
var cloudInit19 = replace(cloudInit18, '__OPENCLAW_VERSION__', openclawVersion)
var cloudInit20 = replace(cloudInit19, '__NODE_VERSION__', nodeVersion)
var cloudInit21 = replace(cloudInit20, '__NODE_SHA256__', nodeArm64Sha256)
var cloudInit22 = replace(cloudInit21, '__COPILOT_VERSION__', copilotVersion)
var cloudInit23 = replace(cloudInit22, '__MCP_EBIRD_VERSION__', mcpEbirdVersion)
var renderedCloudInit = replace(cloudInit23, '__MCP_PONDLOG_VERSION__', mcpPondlogVersion)

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
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
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
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
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
// Existing-host deployments reference the NSG without redeploying its rules.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (!skipCustomData) {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      sshSecurityRule
    ]
  }
}

resource existingNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = if (skipCustomData) {
  name: nsgName
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
            id: skipCustomData ? existingNsg.id : nsg.id
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
      customData: skipCustomData ? null : base64(renderedCloudInit)
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

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
      name: logAnalyticsName
      location: location
      properties: {
        retentionInDays: 30
        features: {
          enableLogAccessUsingOnlyResourcePermissions: true
        }
        publicNetworkAccessForIngestion: 'Enabled'
        publicNetworkAccessForQuery: 'Enabled'
      }
    }

    resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
      name: dataCollectionRuleName
      location: location
      properties: {
        dataSources: {
          syslog: [
            {
              name: 'openclaw-runtime-health'
              facilityNames: [
                'local6'
              ]
              logLevels: [
                'Notice'
                'Warning'
                'Error'
                'Critical'
                'Alert'
                'Emergency'
              ]
              streams: [
                'Microsoft-Syslog'
              ]
            }
          ]
        }
        destinations: {
          logAnalytics: [
            {
              name: 'openclaw-log-analytics'
              workspaceResourceId: logAnalytics.id
            }
          ]
        }
        dataFlows: [
          {
            streams: [
              'Microsoft-Syslog'
            ]
            destinations: [
              'openclaw-log-analytics'
            ]
          }
        ]
      }
    }

    resource monitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
      parent: vm
      name: 'AzureMonitorLinuxAgent'
      location: location
      properties: {
        publisher: 'Microsoft.Azure.Monitor'
        type: 'AzureMonitorLinuxAgent'
        typeHandlerVersion: '1.0'
        autoUpgradeMinorVersion: true
        enableAutomaticUpgrade: true
      }
    }

    resource dataCollectionAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
      scope: vm
      name: 'openclaw-runtime-health'
      properties: {
        dataCollectionRuleId: dataCollectionRule.id
        description: 'Collect only structured local6 OpenClaw health and backup events.'
      }
      dependsOn: [
        monitorAgent
      ]
    }

    resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(monitoringContactEmails)) {
      name: alertActionGroupName
      location: 'global'
      properties: {
        groupShortName: 'openclaw'
        enabled: true
        emailReceivers: [
          for (email, index) in monitoringContactEmails: {
            name: 'contact-${index}'
            emailAddress: email
            useCommonAlertSchema: true
          }
        ]
      }
    }

var alertActions = empty(monitoringContactEmails) ? { actionGroups: [] } : { actionGroups: [alertActionGroup.id] }
var metricAlertActions = empty(monitoringContactEmails) ? [] : [
  {
    actionGroupId: alertActionGroup.id
  }
]

    resource diskWarningAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
      name: 'openclaw-disk-75'
      kind: 'LogAlert'
      location: location
      properties: {
        displayName: 'OpenClaw disk usage at or above 75 percent'
        description: 'Structured runtime health reports disk usage at or above 75 percent.'
        enabled: true
        severity: 2
        scopes: [
          logAnalytics.id
        ]
        evaluationFrequency: 'PT5M'
        windowSize: 'PT10M'
        criteria: {
          allOf: [
            {
              query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where toint(d.diskPercent) >= 75'
              timeAggregation: 'Count'
              operator: 'GreaterThan'
              threshold: 0
              failingPeriods: {
                numberOfEvaluationPeriods: 1
                minFailingPeriodsToAlert: 1
              }
            }
          ]
        }
        autoMitigate: true
        actions: alertActions
      }
    }

    resource diskHighAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
      name: 'openclaw-disk-85'
      kind: 'LogAlert'
      location: location
      properties: {
        displayName: 'OpenClaw disk usage at or above 85 percent'
        description: 'Structured runtime health reports disk usage at or above 85 percent.'
        enabled: true
        severity: 1
        scopes: [
          logAnalytics.id
        ]
        evaluationFrequency: 'PT5M'
        windowSize: 'PT10M'
        criteria: {
          allOf: [
            {
              query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where toint(d.diskPercent) >= 85'
              timeAggregation: 'Count'
              operator: 'GreaterThan'
              threshold: 0
              failingPeriods: {
                numberOfEvaluationPeriods: 1
                minFailingPeriodsToAlert: 1
              }
            }
          ]
        }
        autoMitigate: true
        actions: alertActions
      }
    }

    resource diskCriticalAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
      name: 'openclaw-disk-92'
      kind: 'LogAlert'
      location: location
      properties: {
        displayName: 'OpenClaw disk usage at or above 92 percent'
        description: 'Structured runtime health reports disk usage at or above 92 percent.'
        enabled: true
        severity: 0
        scopes: [
          logAnalytics.id
        ]
        evaluationFrequency: 'PT5M'
        windowSize: 'PT10M'
        criteria: {
          allOf: [
            {
              query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where toint(d.diskPercent) >= 92'
              timeAggregation: 'Count'
              operator: 'GreaterThan'
              threshold: 0
              failingPeriods: {
                numberOfEvaluationPeriods: 1
                minFailingPeriodsToAlert: 1
              }
            }
          ]
        }
        autoMitigate: true
        actions: alertActions
      }
    }

    resource backupHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
      name: 'openclaw-backup-health'
      kind: 'LogAlert'
      location: location
      properties: {
        displayName: 'OpenClaw backup failed or is stale'
        description: 'Structured runtime health reports a failed backup or age over 36 hours.'
        enabled: true
        severity: 1
        scopes: [
          logAnalytics.id
        ]
        evaluationFrequency: 'PT5M'
        windowSize: 'PT10M'
        criteria: {
          allOf: [
            {
              query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where tobool(d.backupOk) == false or tolong(d.backupAgeSeconds) > 129600'
              timeAggregation: 'Count'
              operator: 'GreaterThan'
              threshold: 0
              failingPeriods: {
                numberOfEvaluationPeriods: 1
                minFailingPeriodsToAlert: 1
              }
            }
          ]
        }
        autoMitigate: true
        actions: alertActions
      }
    }

resource runtimeHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-runtime-health'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw runtime health check failed'
    description: 'The same actionable gateway, channel, security, secrets, cron, or task failure persisted across separated health records.'
    enabled: true
    severity: 1
    scopes: [
      logAnalytics.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where toint(d.schemaVersion) >= 2 | mv-expand Failure = todynamic(d.actionableFailures) | extend Failure = tostring(Failure) | where isnotempty(Failure) | summarize FailureSamples = count(), FirstFailure = min(TimeGenerated), LastFailure = max(TimeGenerated) by Failure | where FailureSamples >= 2 and LastFailure - FirstFailure >= 10m'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource missingHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-health-missing'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw runtime health records missing'
    description: 'No structured OpenClaw health record has arrived for 50 minutes.'
    enabled: true
    severity: 1
    scopes: [
      logAnalytics.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: 'print LastHealth=toscalar(Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | summarize max(TimeGenerated)) | where isnull(LastHealth) or LastHealth < ago(50m)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource vmAvailabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'openclaw-vm-availability'
  location: 'global'
  properties: {
    description: 'Azure VM availability metric is below healthy.'
    severity: 0
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'VmAvailability'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'VmAvailabilityMetric'
          operator: 'LessThan'
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
          threshold: 1
          skipMetricValidation: false
        }
      ]
    }
    autoMitigate: true
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    actions: metricAlertActions
  }
}
output vmPublicIp string = publicIp.properties.ipAddress
output vmFqdn string = publicIp.properties.dnsSettings.fqdn
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.dnsSettings.fqdn}'
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output backupStorageAccountName string = backupStorage.name
output backupContainerName string = backupContainer.name
output logAnalyticsWorkspaceName string = logAnalytics.name
output gatewayNote string = 'Gateway is loopback-only. Access via Tailscale IP or SSH tunnel on port 18789.'
output vmPrincipalId string = vm.identity.principalId
