// Application Insights for the API (requests, latency percentiles, failures, database calls), stored in the existing
// Log Analytics workspace (workspace-based), so it shares the workspace's retention and daily cap. The connection
// string is written straight into Key Vault: it never appears in a file, a pipeline or the deployment outputs, and the
// app reads it through a Key Vault reference like its other secrets.

@description('Application Insights resource name.')
param name string

@description('Azure region (the workspace may be in the same region).')
param location string

@description('Tags for policy compliance and cost reporting.')
param tags object

@description('Resource id of the Log Analytics workspace that stores the telemetry.')
param workspaceId string

@description('Key Vault (in this resource group) and the secret name for the connection string.')
param keyVaultName string
param connectionStringSecretName string

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource connectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: connectionStringSecretName
  properties: {
    value: appInsights.properties.ConnectionString
    contentType: 'Application Insights connection string'
  }
}

output id string = appInsights.id
output name string = appInsights.name
