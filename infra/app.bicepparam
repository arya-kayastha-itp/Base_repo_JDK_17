// Parameters for infra/app.bicep (the API container app). Fixed values are here; the values that change with every
// release are read from environment variables set by the release pipeline:
//   TREBOL_APP_IMAGE            full image reference (required)
//   TREBOL_APP_REVISION_SUFFIX  name suffix of the new revision (default: none)
//   TREBOL_APP_MIN_REPLICAS     minimum replicas, taken from the serving revision (default: 1)
//   TREBOL_APP_TRAFFIC          traffic split as JSON (default: all traffic to the latest revision)
using './app.bicep'

param location = 'southindia'
param appName = 'trebol-api'
param environmentName = 'cae-trebol-poc'
param registryName = 'acrtrebolpocttuu'
param keyVaultName = 'kv-trebol-poc-ttuu'
param appIdentityName = 'id-trebol-app'
param mysqlServerName = 'mysql-trebol-poc-si-ttuu'
param mysqlDatabaseName = 'trebol'

// For now the application uses the server administrator; a restricted application user comes later (hardening)
param dbUser = 'trebol_admin'
param dbPasswordSecretName = 'mysql-admin-password'
param jwtSecretName = 'jwt-secret-key'
// Written into Key Vault by main.bicep (Application Insights module); read by the monitoring agent
param appInsightsSecretName = 'appinsights-connection-string'

// Development envelope: 1 vCPU / 2 GiB, at most 3 replicas (raised for the evaluation through a pull request)
param cpu = '1.0'
param memory = '2Gi'
param maxReplicas = 3
// Scale out at 100 requests in flight per replica or 70% average CPU, whichever comes first
param concurrentRequestsPerReplica = 100
param cpuUtilizationPercent = 70

param containerImage = readEnvironmentVariable('TREBOL_APP_IMAGE', '')
param revisionSuffix = readEnvironmentVariable('TREBOL_APP_REVISION_SUFFIX', '')
param minReplicas = int(readEnvironmentVariable('TREBOL_APP_MIN_REPLICAS', '1'))
param traffic = json(readEnvironmentVariable('TREBOL_APP_TRAFFIC', '[{"latestRevision":true,"weight":100}]'))
