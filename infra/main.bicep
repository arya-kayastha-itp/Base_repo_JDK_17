// Trebol POC infrastructure for one resource group (rg-trebol-poc, Central India).
// Deployed in stages; each stage adds resources to this file and is applied with one incremental deployment
// (PowerShell, with $sub holding the subscription id):
//   az deployment group what-if --subscription $sub --resource-group rg-trebol-poc --parameters infra/main.bicepparam
//   az deployment group create  --subscription $sub --resource-group rg-trebol-poc --parameters infra/main.bicepparam
// Stage 1: cost budget + Log Analytics workspace. Stage 2: virtual network, subnets, private DNS zone for MySQL.
// Stage 3: managed identities, container registry, Key Vault. Role assignments: infra/roles.bicep (admin only).
// Stage 4: MySQL Flexible Server (private access) and the application database.
// Stage 5: Container Apps environment (in the network, public ingress). The API container app itself is in
// infra/app.bicep and is deployed by the release pipeline (deploy.yml); this template no longer touches it.
// Two regions: Central India for the registry, Key Vault, Log Analytics and identities; South India for the network,
// MySQL and (later) Container Apps, which must share the region of the network. MySQL Flexible Server is not available
// to this subscription in Central India (deployment failed with ProvisionNotSupportedForRegion, 13 Nov 2026).
targetScope = 'resourceGroup'

@description('Region of the shared services (registry, Key Vault, Log Analytics, identities).')
@allowed([
  'centralindia'
])
param location string

@description('Region of the network and of everything inside it (MySQL, Container Apps).')
@allowed([
  'southindia'
])
param workloadLocation string

@description('Tags on every taggable resource. Policy requires "Practice".')
param tags object

@description('Log Analytics workspace name.')
param logAnalyticsName string

@description('Log Analytics daily ingestion cap in GB (string, for example "0.5").')
param logAnalyticsDailyCapGb string

@description('Budget name.')
param budgetName string

@description('Budget amount for the whole project, in the currency of the billing account.')
param budgetAmount int

@description('Budget start (first day of a month) and end dates, yyyy-MM-dd.')
param budgetStartDate string
param budgetEndDate string

@description('E-mail addresses for the budget alerts.')
param budgetAlertEmails array

@description('Virtual network name and address space.')
param vnetName string
param vnetAddressPrefix string

@description('Container Apps subnet name and address range.')
param acaSubnetName string
param acaSubnetPrefix string

@description('MySQL subnet name and address range.')
param mysqlSubnetName string
param mysqlSubnetPrefix string

@description('Private DNS zone for MySQL (must end with .mysql.database.azure.com).')
param mysqlPrivateDnsZoneName string

@description('Managed identity names (pipeline and app).')
param pipelineIdentityName string
param appIdentityName string

@description('GitHub repository whose workflows may log in as the pipeline identity, as in GitHub\'s OIDC subject: owner@ownerId/name@repoId.')
param githubRepository string

@description('Container registry name (letters and digits, unique across Azure).')
param registryName string

@description('Key Vault name (unique across Azure).')
param keyVaultName string

@description('MySQL server name (unique across Azure), version, administrator and database.')
param mysqlServerName string
param mysqlVersion string
param mysqlAdminLogin string
param mysqlDatabaseName string

@description('MySQL administrator password. Supplied by the parameter file from Key Vault; never logged.')
@secure()
param mysqlAdminPassword string

@description('Container Apps environment name and the name of the resource group Azure manages for it.')
param containerAppsEnvName string
param containerAppsInfraResourceGroupName string

@description('Application Insights name and the Key Vault secret that receives its connection string.')
param appInsightsName string
param appInsightsSecretName string

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    dailyCapGb: logAnalyticsDailyCapGb
  }
}

module budget 'modules/budget.bicep' = {
  name: 'budget'
  params: {
    name: budgetName
    amount: budgetAmount
    startDate: budgetStartDate
    endDate: budgetEndDate
    contactEmails: budgetAlertEmails
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    name: vnetName
    location: workloadLocation
    tags: tags
    addressPrefix: vnetAddressPrefix
    acaSubnetName: acaSubnetName
    acaSubnetPrefix: acaSubnetPrefix
    mysqlSubnetName: mysqlSubnetName
    mysqlSubnetPrefix: mysqlSubnetPrefix
    mysqlPrivateDnsZoneName: mysqlPrivateDnsZoneName
  }
}

module identities 'modules/identities.bicep' = {
  name: 'identities'
  params: {
    pipelineIdentityName: pipelineIdentityName
    appIdentityName: appIdentityName
    location: location
    tags: tags
    githubRepository: githubRepository
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    name: registryName
    location: location
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    tags: tags
  }
}

// The subnet and DNS zone ids are computed from their names (not taken from the network module's outputs), so
// validate and what-if can evaluate this module in advance; dependsOn keeps the order network -> MySQL.
module mysql 'modules/mysql.bicep' = {
  name: 'mysql'
  dependsOn: [
    network
  ]
  params: {
    name: mysqlServerName
    location: workloadLocation
    tags: tags
    version: mysqlVersion
    administratorLogin: mysqlAdminLogin
    administratorPassword: mysqlAdminPassword
    delegatedSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, mysqlSubnetName)
    privateDnsZoneId: resourceId('Microsoft.Network/privateDnsZones', mysqlPrivateDnsZoneName)
    databaseName: mysqlDatabaseName
  }
}

// As for MySQL, the subnet id is computed from names so validate and what-if can evaluate the module in advance;
// dependsOn keeps the order network/monitoring -> environment.
module containerAppsEnv 'modules/containerapps-env.bicep' = {
  name: 'containerapps-env'
  dependsOn: [
    network
    monitoring
  ]
  params: {
    name: containerAppsEnvName
    location: workloadLocation
    tags: tags
    infrastructureSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, acaSubnetName)
    logAnalyticsName: logAnalyticsName
    infrastructureResourceGroupName: containerAppsInfraResourceGroupName
  }
}

// Phase 5: telemetry of the app. Workspace and vault ids are computed from names (validate and what-if can evaluate
// the module in advance); dependsOn keeps the order.
module appInsights 'modules/appinsights.bicep' = {
  name: 'appinsights'
  dependsOn: [
    monitoring
    keyVault
  ]
  params: {
    name: appInsightsName
    location: location
    tags: tags
    workspaceId: resourceId('Microsoft.OperationalInsights/workspaces', logAnalyticsName)
    keyVaultName: keyVaultName
    connectionStringSecretName: appInsightsSecretName
  }
}

output logAnalyticsWorkspaceId string = monitoring.outputs.id
output budgetId string = budget.outputs.id
output vnetId string = network.outputs.vnetId
output acaSubnetId string = network.outputs.acaSubnetId
output mysqlSubnetId string = network.outputs.mysqlSubnetId
output mysqlPrivateDnsZoneId string = network.outputs.mysqlPrivateDnsZoneId
output pipelineIdentityPrincipalId string = identities.outputs.pipelinePrincipalId
output appIdentityPrincipalId string = identities.outputs.appPrincipalId
output registryLoginServer string = registry.outputs.loginServer
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
output mysqlServerFqdn string = mysql.outputs.fqdn
output containerAppsEnvStaticIp string = containerAppsEnv.outputs.staticIp
