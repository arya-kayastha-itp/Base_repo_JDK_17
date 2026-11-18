// Azure Database for MySQL Flexible Server with private access only: it lives in the delegated MySQL subnet,
// registers its name in the private DNS zone and has no public endpoint. Plus the application database.

@description('Server name: unique across Azure, part of its DNS name.')
param name string

@description('Azure region (must be the region of the virtual network).')
param location string

@description('Tags for policy compliance and cost reporting.')
param tags object

@description('MySQL version, for example "8.4" or "8.0.21".')
param version string

@description('Compute size and tier (development: Burstable B1ms; evaluation: General Purpose D4ads_v5).')
param skuName string = 'Standard_B1ms'
@allowed([
  'Burstable'
  'GeneralPurpose'
])
param skuTier string = 'Burstable'

@description('Storage IOPS: Disabled = fixed IOPS from the storage size (360 for 20 GiB); Enabled = Autoscale IOPS, up to the compute size maximum, billed per million I/O operations. Can be switched back.')
@allowed([
  'Disabled'
  'Enabled'
])
param autoIoScaling string = 'Disabled'

@description('Storage in GiB. Auto-grow is off so the cost stays fixed.')
param storageSizeGB int = 20

@description('Days of automatic backups (locally redundant).')
param backupRetentionDays int = 7

@description('Administrator user name.')
param administratorLogin string

@description('Administrator password, supplied from Key Vault by the parameter file.')
@secure()
param administratorPassword string

@description('Resource id of the subnet delegated to MySQL Flexible Server.')
param delegatedSubnetId string

@description('Resource id of the private DNS zone for MySQL.')
param privateDnsZoneId string

@description('Name of the application database.')
param databaseName string

resource server 'Microsoft.DBforMySQL/flexibleServers@2023-12-30' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: version
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Disabled'
      autoIoScaling: autoIoScaling
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    // Private access: the server gets an address in the delegated subnet and an A record in the private zone
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneResourceId: privateDnsZoneId
    }
  }
}

resource database 'Microsoft.DBforMySQL/flexibleServers/databases@2023-12-30' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'utf8mb4'
    collation: 'utf8mb4_0900_ai_ci'
  }
}

output id string = server.id
output name string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
