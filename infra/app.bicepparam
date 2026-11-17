// Parameters for infra/app.bicep (the API container app). Fixed values are here; the values that change with every
// release are read from environment variables set by the release pipeline:
//   TREBOL_APP_IMAGE            full image reference (required)
//   TREBOL_APP_REVISION_SUFFIX  name suffix of the new revision (default: none)
//   TREBOL_APP_MIN_REPLICAS     minimum replicas, taken from the serving revision (default: 1)
//   TREBOL_APP_TRAFFIC          traffic split as JSON (default: all traffic to the latest revision)
//   TREBOL_EVALUATION           'true' during the evaluation window (GitHub repository variable): larger replicas
using './app.bicep'

var evaluation = readEnvironmentVariable('TREBOL_EVALUATION', 'false') == 'true'

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

// Development envelope: 1 vCPU / 2 GiB, at most 3 replicas. Evaluation: 2 vCPU / 4 GiB, at most 20 replicas
// (40 vCPU; about 8 replicas carry 2,500 browse requests per second at the 70% CPU target, measured 16 Nov)
param cpu = evaluation ? '2.0' : '1.0'
param memory = evaluation ? '4Gi' : '2Gi'
param maxReplicas = evaluation ? 20 : 3
// Scale out at 100 requests in flight per replica or 70% average CPU, whichever comes first
param concurrentRequestsPerReplica = 100
param cpuUtilizationPercent = 70

param containerImage = readEnvironmentVariable('TREBOL_APP_IMAGE', '')
param revisionSuffix = readEnvironmentVariable('TREBOL_APP_REVISION_SUFFIX', '')
param minReplicas = int(readEnvironmentVariable('TREBOL_APP_MIN_REPLICAS', '1'))
param traffic = json(readEnvironmentVariable('TREBOL_APP_TRAFFIC', '[{"latestRevision":true,"weight":100}]'))
