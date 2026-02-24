// Subscription-scoped deployment: budget alerts + RBAC for OpenClaw VM managed identity
// Usage: az deployment sub create --location centralus --template-file infra/main-subscription.bicep --parameters vmPrincipalId=<id> budgetStartDate=<date>

targetScope = 'subscription'

@description('Principal ID of the OpenClaw VM system-assigned managed identity')
param vmPrincipalId string

@description('Budget start date (first of current month, YYYY-MM-DDT00:00:00Z)')
param budgetStartDate string

@description('Monthly budget amount in USD')
param budgetAmount int = 150

@description('Email addresses for budget notifications')
param contactEmails array = [
  'ericchansen@gmail.com'
]

// --- Budget ---

module budget 'budget.bicep' = {
  name: 'openclaw-budget'
  params: {
    amount: budgetAmount
    contactEmails: contactEmails
    startDate: budgetStartDate
  }
}

// --- RBAC: Cost Management Contributor (subscription scope) ---
// Lets OpenClaw query costs, manage budgets/exports, view consumption data
// Built-in role ID: 434105ed-43f6-45c7-a02f-909b2ba83430

resource costMgmtRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, vmPrincipalId, '434105ed-43f6-45c7-a02f-909b2ba83430')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '434105ed-43f6-45c7-a02f-909b2ba83430')
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// --- RBAC: Contributor (subscription scope) ---
// Lets OpenClaw deploy resources (App Service, databases, etc.) across the subscription
// Built-in role ID: b24988ac-6180-42a0-ab88-20f7382dd24c

resource contributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, vmPrincipalId, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output budgetName string = budget.outputs.budgetName
output costMgmtRoleAssignmentId string = costMgmtRole.id
output contributorRoleAssignmentId string = contributorRole.id
