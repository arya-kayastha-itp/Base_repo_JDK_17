// The API container app. Deployed by the release pipeline (deploy.yml) for every new image, so every change to the
// app's definition (settings, probes, scale rules) goes through a pull request, the smoke test and the canary like
// code does. Deployed once by hand when the project is set up. The infrastructure is in main.bicep.
// Values that change per release come from environment variables (see app.bicepparam).
targetScope = 'resourceGroup'

@description('Region of the Container Apps environment.')
@allowed([
  'southindia'
])
param location string

@description('Names of the app and of the resources it uses (all in this resource group).')
param appName string
param environmentName string
param registryName string
param keyVaultName string
param appIdentityName string
param mysqlServerName string
param mysqlDatabaseName string

@description('Database user of the application and the Key Vault secret names it reads.')
param dbUser string
param dbPasswordSecretName string
param jwtSecretName string
param appInsightsSecretName string

@description('Full image reference, for example myregistry.azurecr.io/trebol-api:abc1234.')
@minLength(1)
param containerImage string

@description('Name suffix of the new revision (empty when deployed by hand).')
param revisionSuffix string

@description('CPU (string) and memory per replica; memory must be 2 x CPU.')
param cpu string
param memory string

@description('Replica limits. The release keeps the minimum of the serving revision (the schedule sets it).')
param minReplicas int
param maxReplicas int

@description('Traffic split for this deployment.')
param traffic array

// The tags are taken from the resource group, so no private value (such as the owner) is needed here
var tags = {
  project: resourceGroup().tags.project
  owner: resourceGroup().tags.owner
  environment: resourceGroup().tags.environment
  Practice: resourceGroup().tags.Practice
}

module containerApp 'modules/containerapp.bicep' = {
  name: 'containerapp'
  params: {
    name: appName
    location: location
    tags: tags
    environmentId: resourceId('Microsoft.App/managedEnvironments', environmentName)
    image: containerImage
    registryServer: '${registryName}${environment().suffixes.acrLoginServer}'
    identityId: resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', appIdentityName)
    keyVaultUri: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/'
    dbPasswordSecretName: dbPasswordSecretName
    jwtSecretName: jwtSecretName
    appInsightsSecretName: appInsightsSecretName
    dbHost: '${mysqlServerName}.mysql.database.azure.com'
    dbName: mysqlDatabaseName
    dbUser: dbUser
    cpu: cpu
    memory: memory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    revisionSuffix: revisionSuffix
    traffic: traffic
  }
}

output fqdn string = containerApp.outputs.fqdn
output latestRevisionName string = containerApp.outputs.latestRevisionName
