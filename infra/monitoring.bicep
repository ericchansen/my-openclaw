targetScope = 'resourceGroup'

param location string
param vmName string = 'openclaw-vm'
param diagnosticsContactEmails array = []
param escalationContactEmails array = []

var logAnalyticsName = 'log-openclaw-${uniqueString(resourceGroup().id)}'
var dataCollectionRuleName = 'dcr-openclaw-${uniqueString(resourceGroup().id)}'
var diagnosticsActionGroupName = 'ag-openclaw-diagnostics'
var escalationActionGroupName = 'ag-openclaw-escalation'
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

resource diagnosticsActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(diagnosticsContactEmails)) {
  name: diagnosticsActionGroupName
  location: 'global'
  properties: {
    groupShortName: 'ocdiag'
    enabled: true
    emailReceivers: [for (email, index) in diagnosticsContactEmails: { name: 'diagnostic-${index}', emailAddress: email, useCommonAlertSchema: true }]
  }
}

resource escalationActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(escalationContactEmails)) {
  name: escalationActionGroupName
  location: 'global'
  properties: {
    groupShortName: 'ocescal'
    enabled: true
    emailReceivers: [for (email, index) in escalationContactEmails: { name: 'escalation-${index}', emailAddress: email, useCommonAlertSchema: true }]
  }
}

var diagnosticAlertActions = empty(diagnosticsContactEmails) ? { actionGroups: [] } : { actionGroups: [diagnosticsActionGroup.id] }
var ownerMetricAlertActions = empty(escalationContactEmails)
  ? []
  : [
      {
        actionGroupId: escalationActionGroup.id
      }
    ]

resource diskPressureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-disk-pressure'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw disk pressure'
    description: 'The latest runtime probe reports disk usage at or above 85 percent.'
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
          query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-runtime-health-probe" | extend d = parse_json(SyslogMessage) | where d.event == "runtime_health_probe" | summarize arg_max(TimeGenerated, *) by Computer | where tobool(d.disk.pressure) == true'
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
    actions: diagnosticAlertActions
  }
}

resource capacityPressureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-capacity-pressure'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw host capacity pressure'
    description: 'The latest runtime probe reports memory or load pressure.'
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
          query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-runtime-health-probe" | extend d = parse_json(SyslogMessage) | where d.event == "runtime_health_probe" | summarize arg_max(TimeGenerated, *) by Computer | where tobool(d.capacity.pressure) == true'
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
    actions: diagnosticAlertActions
  }
}

resource runtimeHealthProbeAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-runtime-health-probe-failed'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw runtime health probe unhealthy'
    description: 'The latest runtime probe reports an unhealthy Gateway or host-capacity state.'
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
          query: 'Syslog | where Facility == "local6" and ProcessName == "openclaw-runtime-health-probe" | extend d = parse_json(SyslogMessage) | where d.event == "runtime_health_probe" | summarize arg_max(TimeGenerated, *) by Computer | where tobool(d.probeOk) == false'
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
    actions: diagnosticAlertActions
  }
}

resource missingHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'openclaw-runtime-health-probe-missing'
  kind: 'LogAlert'
  location: location
  properties: {
    displayName: 'OpenClaw runtime health probe missing'
    description: 'No runtime health probe record has arrived for 50 minutes.'
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
          query: 'let LastProbe=toscalar(Syslog | where Facility == "local6" and ProcessName == "openclaw-runtime-health-probe" | extend d = parse_json(SyslogMessage) | where d.event == "runtime_health_probe" | summarize max(TimeGenerated)); print Missing=toint(iif(isnull(LastProbe) or LastProbe < ago(50m), 1, 0))'
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'Missing'
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
    actions: diagnosticAlertActions
  }
}

resource vmAvailabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'openclaw-vm-availability'
  location: 'global'
  properties: {
    description: 'Azure reports the VM unavailable for the five-minute evaluation window.'
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
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
          threshold: 1
          skipMetricValidation: false
        }
      ]
    }
    autoMitigate: true
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    actions: ownerMetricAlertActions
  }
}

output workspaceName string = logAnalytics.name
output contentTable string = contentTableName
