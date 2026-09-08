targetScope = 'resourceGroup'

param location string
param vmName string = 'openclaw-vm'
param monitoringContactEmails array = []
@minValue(80)
@maxValue(99)
param cpuSaturationPercent int = 90

var logAnalyticsName = 'log-openclaw-${uniqueString(resourceGroup().id)}'
var dataCollectionRuleName = 'dcr-openclaw-${uniqueString(resourceGroup().id)}'
var alertActionGroupName = 'ag-openclaw-${uniqueString(resourceGroup().id)}'
var contentTableName = 'OpenClawContent_CL'

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource openClawContentTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  parent: logAnalytics
  name: contentTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 7
    totalRetentionInDays: 7
    schema: {
      name: contentTableName
      columns: [
        {
          name: 'TimeGenerated'
          type: 'dateTime'
        }
        {
          name: 'RawData'
          type: 'string'
        }
        {
          name: 'Computer'
          type: 'string'
        }
        {
          name: 'FilePath'
          type: 'string'
        }
        {
          name: 'TelemetryClass'
          type: 'string'
        }
      ]
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  properties: {
    streamDeclarations: {
      'Custom-OpenClawContent_CL': {
        columns: [
          {
            name: 'TimeGenerated'
            type: 'datetime'
          }
          {
            name: 'RawData'
            type: 'string'
          }
          {
            name: 'Computer'
            type: 'string'
          }
          {
            name: 'FilePath'
            type: 'string'
          }
        ]
      }
    }
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
      logFiles: [
        {
          name: 'openclaw-sanitized-otel'
          streams: [
            'Custom-OpenClawContent_CL'
          ]
          filePatterns: [
            '/var/log/openclaw-telemetry/metadata.jsonl'
            '/var/log/openclaw-telemetry/content.jsonl'
          ]
          format: 'text'
          settings: {
            text: {
              recordStartTimestampFormat: 'ISO 8601'
            }
          }
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
      {
        streams: [
          'Custom-OpenClawContent_CL'
        ]
        destinations: [
          'openclaw-log-analytics'
        ]
        transformKql: 'source | extend TelemetryClass = case(FilePath == "/var/log/openclaw-telemetry/content.jsonl", "sampled-redacted-content", FilePath == "/var/log/openclaw-telemetry/metadata.jsonl", "metadata", "invalid") | where TelemetryClass != "invalid" | project TimeGenerated, RawData, Computer, FilePath, TelemetryClass'
        outputStream: 'Custom-OpenClawContent_CL'
      }
    ]
  }
  dependsOn: [
    openClawContentTable
  ]
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
    description: 'Collect bounded local6 health plus locally sanitized OpenTelemetry JSONL.'
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
var metricAlertActions = empty(monitoringContactEmails)
  ? []
  : [
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

resource capacityPressureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-capacity-pressure'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw guest capacity pressure'
    description: 'The latest fresh early sample reports memory/swap headroom pressure or CPU/memory PSI stalls; does not wait for application canaries.'
    enabled: true
    severity: 2
    scopes: [
      logAnalytics.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where d.event == "capacity" and toint(d.capacitySchemaVersion) == 1 | extend SampledAt = todatetime(d.capacity.sampledAt) | where SampledAt between (ago(20m) .. now()) | summarize arg_max(SampledAt, *) by Computer | where tobool(d.capacity.pressure) == true'
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
    description: 'The same actionable failure occurred across separated records and remains present in the latest schema-v2 health record.'
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
          query: 'let Health = Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where toint(d.schemaVersion) >= 2 | project TimeGenerated, Failures = todynamic(d.actionableFailures); let LatestHealth = toscalar(Health | summarize max(TimeGenerated)); Health | mv-expand Failure = Failures | extend Failure = tostring(Failure) | where isnotempty(Failure) | summarize FailureSamples = count(), FirstFailure = min(TimeGenerated), LastFailure = max(TimeGenerated) by Failure | where FailureSamples >= 2 and LastFailure - FirstFailure >= 10m and LastFailure == LatestHealth'
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
    description: 'No complete schema-v2 OpenClaw health record has arrived for 50 minutes.'
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
          query: 'print LastHealth=toscalar(Syslog | where Facility == "local6" and ProcessName == "openclaw-health" | extend d = parse_json(SyslogMessage) | where toint(d.schemaVersion) >= 2 | summarize max(TimeGenerated)) | where isnull(LastHealth) or LastHealth < ago(50m)'
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

resource cpuSaturationAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'openclaw-cpu-saturation'
  location: 'global'
  properties: {
    description: 'Sustained platform CPU saturation, even when guest health logs and VM Agent stop responding.'
    severity: 1
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CpuSaturation'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThanOrEqual'
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
          threshold: cpuSaturationPercent
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

output workspaceName string = logAnalytics.name
output contentTable string = contentTableName
