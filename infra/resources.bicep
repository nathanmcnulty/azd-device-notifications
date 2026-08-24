param location string
param namePrefix string
param resourceToken string
param environmentName string
param tenantId string
param subscriptionId string
param resourceGroupName string
param routingConfigJson string
param adminEmailRecipients string
param emailSenderUpn string
@secure()
param teamsAdminWebhookUrl string
param entraPollSchedule string
param intunePollSchedule string
@minValue(0)
@maxValue(720)
param enrollmentLookbackHours int
@minValue(1)
@maxValue(1440)
param auditOverlapMinutes int
param collectionEnabled bool
param tags object = {}

var identityName = 'id-${namePrefix}-${resourceToken}'
var storageName = take('stdn${namePrefix}${resourceToken}', 24)
var functionName = take('func-${namePrefix}-${resourceToken}', 60)
var botName = take('bot-${namePrefix}-${resourceToken}', 42)
var workspaceName = take('log-${namePrefix}-${resourceToken}', 63)
var insightsName = take('appi-${namePrefix}-${resourceToken}', 260)
var blobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var tableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'function-releases'
  properties: { publicAccess: 'None' }
}

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, blobDataOwner)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataOwner)
  }
}

resource queueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, queueDataContributor)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueDataContributor)
  }
}

resource tableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, tableDataContributor)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tableDataContributor)
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}

resource insightsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, identity.id, monitoringMetricsPublisher)
  scope: insights
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${functionName}-fc'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  tags: union(tags, { 'azd-service-name': 'notifier' })
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      runtime: { name: 'node', version: '22' }
      scaleAndConcurrency: { maximumInstanceCount: 10, instanceMemoryMB: 2048 }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD;ClientId=${identity.properties.clientId}' }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: storage.properties.primaryEndpoints.table }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: identity.properties.clientId }
        { name: 'MANAGED_IDENTITY_CLIENT_ID', value: identity.properties.clientId }
        { name: 'STORAGE_ACCOUNT_NAME', value: storage.name }
        { name: 'TABLE_ENDPOINT', value: storage.properties.primaryEndpoints.table }
        { name: 'QUEUE_ENDPOINT', value: storage.properties.primaryEndpoints.queue }
        { name: 'NOTIFICATION_QUEUE_NAME', value: 'device-notifications' }
        { name: 'AZURE_ENV_NAME', value: environmentName }
        { name: 'AZURE_TENANT_ID', value: tenantId }
        { name: 'AZURE_SUBSCRIPTION_ID', value: subscriptionId }
        { name: 'AZURE_RESOURCE_GROUP', value: resourceGroupName }
        { name: 'TEAMS_BOT_APP_ID', value: identity.properties.clientId }
        { name: 'MicrosoftAppType', value: 'UserAssignedMSI' }
        { name: 'MicrosoftAppId', value: identity.properties.clientId }
        { name: 'MicrosoftAppTenantId', value: tenantId }
        { name: 'ROUTING_CONFIG_JSON', value: routingConfigJson }
        { name: 'ADMIN_EMAIL_RECIPIENTS', value: adminEmailRecipients }
        { name: 'EMAIL_SENDER_UPN', value: emailSenderUpn }
        { name: 'TEAMS_ADMIN_WEBHOOK_URL', value: teamsAdminWebhookUrl }
        { name: 'ENTRA_POLL_SCHEDULE', value: entraPollSchedule }
        { name: 'INTUNE_POLL_SCHEDULE', value: intunePollSchedule }
        { name: 'ENROLLMENT_LOOKBACK_HOURS', value: string(enrollmentLookbackHours) }
        { name: 'ENTRA_AUDIT_OVERLAP_MINUTES', value: string(auditOverlapMinutes) }
        { name: 'DEVICE_NOTIFICATION_COLLECTION_ENABLED', value: string(collectionEnabled) }
      ]
    }
  }
  dependsOn: [blobRole, queueRole, tableRole, insightsRole]
}

resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'ftp'
  properties: { allow: false }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'scm'
  properties: { allow: false }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: functionApp
  properties: {
    workspaceId: workspace.id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  location: 'global'
  tags: tags
  kind: 'azurebot'
  sku: { name: 'F0' }
  properties: {
    displayName: 'Device lifecycle notifications'
    endpoint: 'https://${functionApp.properties.defaultHostName}/api/messages'
    msaAppId: identity.properties.clientId
    msaAppMSIResourceId: identity.id
    msaAppTenantId: tenantId
    msaAppType: 'UserAssignedMSI'
  }
}

resource teamsChannel 'Microsoft.BotService/botServices/channels@2022-09-15' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: { isEnabled: true }
  }
}

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output storageAccountName string = storage.name
output workloadClientId string = identity.properties.clientId
output workloadPrincipalId string = identity.properties.principalId
output botName string = bot.name
