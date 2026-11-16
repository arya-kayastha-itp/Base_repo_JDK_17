// Operations dashboard (Azure Monitor workbook): traffic, latency and errors from Application Insights; replicas, CPU,
// memory, restarts and status codes from the Container Apps platform metrics; CPU and connections of MySQL.
// Shown in the portal under Monitor, Workbooks.

@description('Region of the workbook resource.')
param location string

@description('Tags for policy compliance and cost reporting.')
param tags object

@description('Resource ids of the Log Analytics workspace (Application Insights data), the container app and MySQL.')
param workspaceId string
param appId string
param mysqlId string

@description('Name of the app in Application Insights (APPLICATIONINSIGHTS_ROLE_NAME).')
param appRoleName string

@description('Display name of the workbook.')
param displayName string = 'Trebol API operations'

var requestsFilter = 'AppRequests | where AppRoleName == "${appRoleName}"'

// One Application Insights (log query) tile
var logTiles = [
  {
    name: 'requests-per-minute'
    title: 'Requests per minute'
    query: '${requestsFilter} | summarize Requests = sum(ItemCount) by bin(TimeGenerated, 1m)'
    visualization: 'timechart'
  }
  {
    name: 'latency'
    title: 'Response time percentiles (ms)'
    query: '${requestsFilter} | summarize P50 = percentile(DurationMs, 50), P95 = percentile(DurationMs, 95), P99 = percentile(DurationMs, 99) by bin(TimeGenerated, 1m)'
    visualization: 'timechart'
  }
  {
    name: 'error-rate'
    title: 'Server error rate (5xx, %)'
    query: '${requestsFilter} | summarize Total = sum(ItemCount), Errors = sumif(ItemCount, toint(ResultCode) >= 500) by bin(TimeGenerated, 1m) | project TimeGenerated, ErrorRatePercent = round(100.0 * Errors / Total, 2)'
    visualization: 'timechart'
  }
  {
    name: 'status-codes'
    title: 'Responses by status code'
    query: '${requestsFilter} | summarize Responses = sum(ItemCount) by ResultCode, bin(TimeGenerated, 1m)'
    visualization: 'timechart'
  }
  {
    name: 'operations'
    title: 'Operations: volume, P95 and server errors'
    query: '${requestsFilter} | summarize Requests = sum(ItemCount), P95ms = round(percentile(DurationMs, 95), 1), ServerErrors = sumif(ItemCount, toint(ResultCode) >= 500) by Name | order by Requests desc'
    visualization: 'table'
  }
  {
    name: 'database-calls'
    title: 'Database calls: per minute and P95 (ms)'
    query: 'AppDependencies | where AppRoleName == "${appRoleName}" | summarize Calls = sum(ItemCount), P95ms = percentile(DurationMs, 95) by bin(TimeGenerated, 1m)'
    visualization: 'timechart'
  }
  {
    name: 'platform-events'
    title: 'Platform events (probes, restarts, scaling)'
    query: 'ContainerAppSystemLogs_CL | where ContainerAppName_s == "trebol-api" | project TimeGenerated, Revision = RevisionName_s, Replica = ReplicaName_s, Reason = Reason_s, Message = Log_s | order by TimeGenerated desc | take 100'
    visualization: 'table'
  }
]

// One platform metric tile; aggregation: 1 total, 3 maximum, 4 average
var metricTiles = [
  {
    name: 'replicas'
    title: 'Replicas (by revision)'
    resourceType: 'microsoft.app/containerapps'
    resourceId: appId
    metric: 'Replicas'
    aggregation: 3
    splitBy: 'revisionName'
  }
  {
    name: 'cpu'
    title: 'CPU usage (%)'
    resourceType: 'microsoft.app/containerapps'
    resourceId: appId
    metric: 'CpuPercentage'
    aggregation: 4
    splitBy: null
  }
  {
    name: 'memory'
    title: 'Memory usage (%)'
    resourceType: 'microsoft.app/containerapps'
    resourceId: appId
    metric: 'MemoryPercentage'
    aggregation: 4
    splitBy: null
  }
  {
    name: 'restarts'
    title: 'Replica restarts'
    resourceType: 'microsoft.app/containerapps'
    resourceId: appId
    metric: 'RestartCount'
    aggregation: 3
    splitBy: null
  }
  {
    name: 'platform-requests'
    title: 'Requests by status class (platform)'
    resourceType: 'microsoft.app/containerapps'
    resourceId: appId
    metric: 'Requests'
    aggregation: 1
    splitBy: 'statusCodeCategory'
  }
  {
    name: 'mysql-cpu'
    title: 'MySQL CPU (%)'
    resourceType: 'microsoft.dbformysql/flexibleservers'
    resourceId: mysqlId
    metric: 'cpu_percent'
    aggregation: 3
    splitBy: null
  }
  {
    name: 'mysql-connections'
    title: 'MySQL active connections'
    resourceType: 'microsoft.dbformysql/flexibleservers'
    resourceId: mysqlId
    metric: 'active_connections'
    aggregation: 3
    splitBy: null
  }
]

var header = [
  {
    type: 1
    name: 'title'
    content: {
      json: '## Trebol API operations\nTraffic, latency and errors come from Application Insights (sampled; counts are corrected with ItemCount). Replicas, CPU, memory, restarts and status classes come from the Container Apps platform metrics; the last two tiles from MySQL. Server errors are 5xx only: the API returns 4xx on purpose.'
    }
  }
  {
    type: 9
    name: 'parameters'
    content: {
      version: 'KqlParameterItem/1.0'
      parameters: [
        {
          id: '7f1d8f8e-5d0b-4e8a-9a55-1b2c3d4e5f60'
          version: 'KqlParameterItem/1.0'
          name: 'TimeRange'
          label: 'Time range'
          type: 4
          isRequired: true
          value: {
            durationMs: 3600000
          }
          typeSettings: {
            selectableValues: [
              {
                durationMs: 900000
              }
              {
                durationMs: 3600000
              }
              {
                durationMs: 14400000
              }
              {
                durationMs: 86400000
              }
            ]
            allowCustom: true
          }
        }
      ]
      style: 'pills'
      queryType: 0
      resourceType: 'microsoft.operationalinsights/workspaces'
    }
  }
]

var logItems = [for t in logTiles: {
  type: 3
  name: t.name
  customWidth: t.visualization == 'table' ? '100' : '50'
  content: {
    version: 'KqlItem/1.0'
    title: t.title
    query: t.query
    size: 0
    timeContextFromParameter: 'TimeRange'
    queryType: 0
    resourceType: 'microsoft.operationalinsights/workspaces'
    crossComponentResources: [
      workspaceId
    ]
    visualization: t.visualization
  }
}]

var metricItems = [for t in metricTiles: {
  type: 10
  name: t.name
  customWidth: '50'
  content: {
    chartId: 'workbook-${t.name}'
    version: 'MetricsItem/2.0'
    title: t.title
    size: 0
    chartType: 2
    resourceType: t.resourceType
    metricScope: 0
    resourceIds: [
      t.resourceId
    ]
    timeContextFromParameter: 'TimeRange'
    timeContext: {
      durationMs: 3600000
    }
    metrics: [
      union({
        namespace: t.resourceType
        metric: '${t.resourceType}--${t.metric}'
        aggregation: t.aggregation
      }, t.splitBy == null ? {} : {
        splitBy: t.splitBy
      })
    ]
  }
}]

var content = {
  version: 'Notebook/1.0'
  items: concat(header, logItems, metricItems)
  fallbackResourceIds: [
    workspaceId
  ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  // A workbook's resource name must be a GUID; derived from the resource group, so redeploys update the same one
  name: guid(resourceGroup().id, 'trebol-api-operations')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: displayName
    category: 'workbook'
    sourceId: 'azure monitor'
    serializedData: string(content)
    version: 'Notebook/1.0'
  }
}

output id string = workbook.id
