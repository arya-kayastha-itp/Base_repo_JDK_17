// Alerts for the API and its database, sent by e-mail through one action group.
// Metric alerts (cheap, near real time) watch platform signals: replicas at the limit, restarts, CPU, database
// connections. Two log alerts query the Application Insights data for what metrics cannot express: the share of
// server errors (5xx) and the 95th percentile of the response time. 4xx responses are not errors here: the API returns
// them on purpose (wrong password, missing permission, invalid input).

@description('Region of the Log Analytics workspace (for the log alerts).')
param location string

@description('Tags for policy compliance and cost reporting.')
param tags object

@description('Action group name and the e-mail addresses it notifies.')
param actionGroupName string
param alertEmails array

@description('Resource ids of the Log Analytics workspace, the container app and the MySQL server.')
param workspaceId string
param appId string
param mysqlId string

@description('Name of the app in Application Insights (APPLICATIONINSIGHTS_ROLE_NAME).')
param appRoleName string

@description('Maximum replicas of the app (the "replicas at the limit" alert compares with it).')
param maxReplicas int

@description('MySQL max_connections (the connections alert fires above 80% of it).')
param mysqlMaxConnections int

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'trebolpoc'
    enabled: true
    emailReceivers: [for (email, i) in alertEmails: {
      name: 'email-${i}'
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}

var metricAlertDefinitions = [
  {
    name: 'alert-trebol-replicas-at-max'
    description: 'The app has run at its maximum replica count for 10 minutes: it cannot scale out any further.'
    severity: 2
    scope: appId
    namespace: 'Microsoft.App/containerApps'
    metric: 'Replicas'
    // The minimum over the window reaches the limit only if the app stayed at the limit the whole time
    aggregation: 'Minimum'
    operator: 'GreaterThanOrEqual'
    threshold: maxReplicas
    window: 'PT10M'
  }
  {
    name: 'alert-trebol-restarts'
    description: 'A replica has restarted more than 3 times (crash loop or failing liveness probe).'
    severity: 2
    scope: appId
    namespace: 'Microsoft.App/containerApps'
    metric: 'RestartCount'
    aggregation: 'Maximum'
    operator: 'GreaterThan'
    threshold: 3
    window: 'PT10M'
  }
  {
    name: 'alert-trebol-cpu-high'
    description: 'Average CPU of the replicas above 85% for 10 minutes (scaling does not keep up, or the maximum is reached).'
    severity: 3
    scope: appId
    namespace: 'Microsoft.App/containerApps'
    metric: 'CpuPercentage'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 85
    window: 'PT10M'
  }
  {
    name: 'alert-trebol-db-connections'
    description: 'MySQL active connections above 80% of max_connections (replicas x connection pool size too large).'
    severity: 2
    scope: mysqlId
    namespace: 'Microsoft.DBforMySQL/flexibleServers'
    metric: 'active_connections'
    aggregation: 'Maximum'
    operator: 'GreaterThan'
    threshold: mysqlMaxConnections * 80 / 100
    window: 'PT5M'
  }
]

resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for a in metricAlertDefinitions: {
  name: a.name
  location: 'global'
  tags: tags
  properties: {
    description: a.description
    severity: a.severity
    enabled: true
    scopes: [
      a.scope
    ]
    evaluationFrequency: 'PT5M'
    windowSize: a.window
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'condition'
          metricNamespace: a.namespace
          metricName: a.metric
          timeAggregation: a.aggregation
          operator: a.operator
          threshold: a.threshold
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}]

// Each query returns a row only when the condition is met; the alert fires when there is at least one row.
// Requests are sampled by the agent: ItemCount restores the real counts. At least 20 requests in the window, so a
// single slow or failed request at night does not page anyone.
var logAlertDefinitions = [
  {
    name: 'alert-trebol-error-rate'
    description: 'More than 1% of the requests in 5 minutes failed with a server error (5xx), with at least 20 requests.'
    severity: 1
    query: 'AppRequests | where AppRoleName == "${appRoleName}" | summarize total = sum(ItemCount), errors = sumif(ItemCount, toint(ResultCode) >= 500) | where total >= 20 | extend errorRatePercent = round(100.0 * errors / total, 2) | where errorRatePercent > 1'
  }
  {
    name: 'alert-trebol-p95-latency'
    description: '95th percentile of the response time above 500 ms over 5 minutes, with at least 20 requests.'
    severity: 2
    query: 'AppRequests | where AppRoleName == "${appRoleName}" | summarize p95 = percentile(DurationMs, 95), total = sum(ItemCount) | where total >= 20 and p95 > 500'
  }
]

resource logAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for a in logAlertDefinitions: {
  name: a.name
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: a.name
    description: a.description
    severity: a.severity
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: a.query
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
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}]

output actionGroupId string = actionGroup.id
