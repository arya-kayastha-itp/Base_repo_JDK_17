// Parameters for infra/main.bicep. Private values (e-mail addresses, subscription id) are NOT in this public file:
// they are read from environment variables of the shell that runs the deployment. In PowerShell, before any
// az deployment command:
//   $env:TREBOL_OWNER_TAG       = 'value of the owner tag'
//   $env:TREBOL_BUDGET_EMAIL    = 'address that receives the budget alerts'
//   $env:TREBOL_SUBSCRIPTION_ID = 'subscription id (used to locate the Key Vault secret)'
//   $env:TREBOL_GITHUB_REPO     = 'owner@ownerId/name@repoId of the GitHub repository allowed to deploy'
//     (the form GitHub uses in its OIDC token subject; the ids come from https://api.github.com/repos/OWNER/NAME)
// Evaluation window (load test by the evaluators): $env:TREBOL_EVALUATION = 'true' switches the values marked
// "evaluation" below; remove it (or set 'false') and deploy again afterwards. The GitHub repository variable of the
// same name switches the app's size in infra/app.bicepparam: set both, so the alerts match the app.
using './main.bicep'

var evaluation = readEnvironmentVariable('TREBOL_EVALUATION', 'false') == 'true'

param location = 'centralindia'
// The network, MySQL and Container Apps run in South India: MySQL Flexible Server is not available to this
// subscription in Central India (nor in East US, East US 2, Central US; checked 13 Nov 2026).
param workloadLocation = 'southindia'

param tags = {
  project: 'trebol-poc'
  owner: readEnvironmentVariable('TREBOL_OWNER_TAG')
  environment: 'poc'
  Practice: 'MLOps'
}

param logAnalyticsName = 'log-trebol-poc'
// 0.1 GB/day keeps the worst case at about 3 GB/month inside the 50 USD project total.
// Evaluation: 1 GB for the day, so the dashboard and the log alerts keep working during the load test.
param logAnalyticsDailyCapGb = evaluation ? '1' : '0.1'

// Project limit: 50 USD in total (1 Nov 2026 - 31 Oct 2027). Budget amounts are in the billing currency, and this
// subscription is billed in INR: 4,000 INR stays below 50 USD at any realistic exchange rate, so the alerts
// (50% = 2,000, 80% = 3,200, 100% = 4,000 INR) fire slightly early rather than late.
param budgetName = 'budget-trebol-poc'
param budgetAmount = 4000
// Full ISO format, as Azure stores it, so later what-if previews show no difference
param budgetStartDate = '2026-11-01T00:00:00Z'
param budgetEndDate = '2027-10-31T00:00:00Z'
param budgetAlertEmails = [
  readEnvironmentVariable('TREBOL_BUDGET_EMAIL')
]

// Stage 2: private network. 10.20.0.0/16 leaves room for later subnets.
// '-si' = South India. The first network (vnet-trebol-poc, Central India, 12 Nov) is no longer used: a network
// cannot change region, so it was replaced; it is left for the engineer to remove.
param vnetName = 'vnet-trebol-poc-si'
param vnetAddressPrefix = '10.20.0.0/16'
// /23 = 512 addresses: room for 25 replicas plus old and new revisions side by side; cannot be resized later
param acaSubnetName = 'snet-aca'
param acaSubnetPrefix = '10.20.0.0/23'
param mysqlSubnetName = 'snet-mysql'
param mysqlSubnetPrefix = '10.20.2.0/24'
param mysqlPrivateDnsZoneName = 'trebol-poc.private.mysql.database.azure.com'

// Stage 3: identities (created on 2 Nov, now managed here), registry and Key Vault.
// Registry and vault names must be unique across Azure: fixed random suffix 'ttuu', chosen once, so the names stay
// the same if the resource group is moved to another subscription.
param pipelineIdentityName = 'id-trebol-github'
param appIdentityName = 'id-trebol-app'
// Phase 4: GitHub Actions of this repository log in as id-trebol-github through OIDC (federated credentials)
param githubRepository = readEnvironmentVariable('TREBOL_GITHUB_REPO')
param registryName = 'acrtrebolpocttuu'
param keyVaultName = 'kv-trebol-poc-ttuu'

// Stage 4: MySQL Flexible Server, private access only. Development: Burstable B1ms (1 vCore, 2 GiB, 171 connections,
// fixed 360 IOPS). Evaluation: General Purpose D4ads_v5 (4 vCores at full speed, 16 GiB, 1,365 connections) with
// Autoscale IOPS. Changing the compute restarts the server (usually 60-120 s): deploy only while MySQL is running.
param mysqlSkuName = evaluation ? 'Standard_D4ads_v5' : 'Standard_B1ms'
param mysqlSkuTier = evaluation ? 'GeneralPurpose' : 'Burstable'
param mysqlAutoIoScaling = evaluation ? 'Enabled' : 'Disabled'
// The administrator password is read by Azure Resource Manager directly from Key Vault during the deployment
// (the vault is enabled for template deployment): it never appears in a shell, a file or the deployment history.
// '-si' = South India: Azure Resource Manager keeps the first name (failed create in Central India, 13 Nov) tied to
// Central India, so the South India server needs its own name.
param mysqlServerName = 'mysql-trebol-poc-si-ttuu'
param mysqlVersion = '8.4'
param mysqlAdminLogin = 'trebol_admin'
param mysqlDatabaseName = 'trebol'
param mysqlAdminPassword = az.getSecret(readEnvironmentVariable('TREBOL_SUBSCRIPTION_ID'), 'rg-trebol-poc', 'kv-trebol-poc-ttuu', 'mysql-admin-password')

// Stage 5: Container Apps environment (South India, inside vnet-trebol-poc-si). Azure creates and manages the
// infrastructure resource group (load balancer and public IP for the public HTTPS endpoint). The app itself:
// infra/app.bicep + infra/app.bicepparam, deployed by the release pipeline.
param containerAppsEnvName = 'cae-trebol-poc'
param containerAppsInfraResourceGroupName = 'rg-trebol-poc-aca-infra'

// Phase 5: Application Insights (stored in log-trebol-poc); its connection string goes straight into Key Vault
param appInsightsName = 'appi-trebol-poc'
param appInsightsSecretName = 'appinsights-connection-string'

// Phase 5: alerts (e-mail to the same address as the budget alerts) and the operations workbook
param appName = 'trebol-api'
param appRoleName = 'trebol-api'
param actionGroupName = 'ag-trebol-poc'
param alertEmails = [
  readEnvironmentVariable('TREBOL_BUDGET_EMAIL')
]
// Must match maxReplicas in app.bicepparam (both follow TREBOL_EVALUATION)
param alertMaxReplicas = evaluation ? 20 : 3
// max_connections default of the MySQL size (B1ms 171, D4ads_v5 1,365; Microsoft Learn, server parameters);
// the connections alert fires above 80% of it
param mysqlMaxConnections = evaluation ? 1365 : 171
