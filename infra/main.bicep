targetScope = 'subscription'

@minLength(1)
param environmentName string
param location string
param tenantId string = tenant().tenantId
param routingConfigJson string
param adminEmailRecipients string = ''
param emailSenderUpn string = ''
@secure()
param teamsAdminWebhookUrl string = ''
param entraPollSchedule string = '0 */5 * * * *'
param intunePollSchedule string = '30 */15 * * * *'
param enrollmentLookbackHours int = 24
param auditOverlapMinutes int = 15

var resourceToken = toLower(uniqueString(subscription().id, environmentName))
var resourceGroupName = 'rg-${environmentName}'
var tags = {
  'azd-env-name': environmentName
  workload: 'device-notifications'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'device-notifications'
  scope: resourceGroup
  params: {
    location: location
    namePrefix: take(replace(environmentName, '-', ''), 12)
    resourceToken: resourceToken
    tenantId: tenantId
    routingConfigJson: routingConfigJson
    adminEmailRecipients: adminEmailRecipients
    emailSenderUpn: emailSenderUpn
    teamsAdminWebhookUrl: teamsAdminWebhookUrl
    entraPollSchedule: entraPollSchedule
    intunePollSchedule: intunePollSchedule
    enrollmentLookbackHours: enrollmentLookbackHours
    auditOverlapMinutes: auditOverlapMinutes
    tags: tags
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_FUNCTION_APP_NAME string = resources.outputs.functionAppName
output AZURE_FUNCTION_APP_URL string = resources.outputs.functionAppUrl
output AZURE_STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
output AZURE_WORKLOAD_CLIENT_ID string = resources.outputs.workloadClientId
output AZURE_WORKLOAD_PRINCIPAL_ID string = resources.outputs.workloadPrincipalId
output TEAMS_BOT_APP_ID string = resources.outputs.workloadClientId
output TEAMS_BOT_NAME string = resources.outputs.botName
output TEAMS_APP_PACKAGE_VALUES string = '${resources.outputs.workloadClientId}|${tenantId}|${resources.outputs.functionAppUrl}'
