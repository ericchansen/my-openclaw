// Subscription-scoped monthly budget with email notifications
// Deployed at subscription scope — alerts when spend crosses configured thresholds

targetScope = 'subscription'

@description('Name of the budget')
param budgetName string = 'openclaw-monthly-budget'

@description('Monthly budget amount in USD')
param amount int = 150

@description('Email addresses for budget notifications')
param contactEmails array = [
  'ericchansen@gmail.com'
]

@description('Budget start date (first of current month)')
param startDate string // e.g. '2026-02-01T00:00:00Z'

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    timePeriod: {
      startDate: startDate
      endDate: '2036-01-01T00:00:00Z'
    }
    timeGrain: 'Monthly'
    amount: amount
    category: 'Cost'
    notifications: {
      ApproachingLimit: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 67
        contactEmails: contactEmails
        thresholdType: 'Actual'
      }
      NearLimit: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 90
        contactEmails: contactEmails
        thresholdType: 'Actual'
      }
      BudgetExceeded: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: contactEmails
        thresholdType: 'Actual'
      }
      ForecastedOverage: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: contactEmails
        thresholdType: 'Forecasted'
      }
    }
  }
}

output budgetName string = budget.name
output budgetId string = budget.id
