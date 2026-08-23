[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Configuration.Validation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Graph.Management.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME',
        'AZURE_FUNCTION_APP_URL', 'AZURE_WORKLOAD_PRINCIPAL_ID', 'AZURE_WORKLOAD_CLIENT_ID', 'TEAMS_BOT_NAME',
        'DEVICE_NOTIFICATION_ROUTING_JSON', 'TEAMS_ADMIN_WEBHOOK_URL', 'ADMIN_EMAIL_RECIPIENTS', 'EMAIL_SENDER_UPN',
        'ENTRA_POLL_SCHEDULE', 'INTUNE_POLL_SCHEDULE', 'ENROLLMENT_LOOKBACK_HOURS', 'ENTRA_AUDIT_OVERLAP_MINUTES',
        'DEVICE_NOTIFICATION_COLLECTION_ENABLED', 'DEVICE_NOTIFICATION_ONBOARDING_STATUS')) { [void](Get-AzdEnvironmentValue $name) }
Assert-AzdTenantContext
foreach ($name in @('AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME', 'AZURE_WORKLOAD_PRINCIPAL_ID', 'AZURE_WORKLOAD_CLIENT_ID')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required." }
}

$configuration = Get-NotificationConfiguration -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
    -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
    -EmailSenderUpn $env:EMAIL_SENDER_UPN -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
    -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE -EnrollmentLookbackHours $env:ENROLLMENT_LOOKBACK_HOURS `
    -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES
$state = & az functionapp show --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME --query state -o tsv
if ($LASTEXITCODE -ne 0 -or $state -ne 'Running') { throw "Function App is not running (state: $state)." }

$graphArgs = @{ SubscriptionId = $env:AZURE_SUBSCRIPTION_ID }
$graph = Invoke-GraphJson -Method GET -Uri "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles" @graphArgs
if (@($graph.value).Count -ne 1) { throw 'Unable to resolve Microsoft Graph application roles.' }
$requiredNames = @(Get-RequiredGraphPermissionNames -Routing $configuration.Routing)
$required = @(Resolve-GraphPermissionPlan -GraphServicePrincipal $graph.value[0] -RequiredNames $requiredNames)
$assignments = Invoke-GraphJson -Method GET -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments?`$top=999" @graphArgs
foreach ($role in $required) {
    if ($role.Id -notin $assignments.value.appRoleId) { throw "Required Microsoft Graph role is missing: $($role.Name)." }
}
$managed = @(Resolve-GraphPermissionPlan -GraphServicePrincipal $graph.value[0] -RequiredNames @('AuditLog.Read.All', 'DeviceManagementManagedDevices.Read.All', 'User.ReadBasic.All', 'GroupMember.Read.All'))
foreach ($role in $managed | Where-Object { $_.Name -notin $requiredNames }) {
    if ($role.Id -in $assignments.value.appRoleId) { throw "Unneeded conditional Microsoft Graph role remains assigned: $($role.Name)." }
}

if ($configuration.UsesTeamsDm) {
    if (-not $env:TEAMS_BOT_NAME) { throw 'TEAMS_BOT_NAME is required for personal Teams notification routes.' }
    $bot = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --resource-type Microsoft.BotService/botServices --name $env:TEAMS_BOT_NAME --api-version 2022-09-15 -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $bot.properties.msaAppId -ne $env:AZURE_WORKLOAD_CLIENT_ID -or
        $bot.properties.endpoint -ne "$($env:AZURE_FUNCTION_APP_URL)/api/messages") { throw 'Azure Bot identity or endpoint configuration is incorrect.' }
    $response = Invoke-WebRequest -Method Post -Uri "$($env:AZURE_FUNCTION_APP_URL)/api/messages" -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { throw 'The Bot endpoint accepted an unauthenticated request.' }
} else {
    $botCount = & az resource list --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --resource-type Microsoft.BotService/botServices --query 'length(@)' -o tsv
    if ($LASTEXITCODE -ne 0 -or $botCount -ne '0') { throw 'Bot Service must be absent when no personal Teams route is enabled.' }
}

foreach ($policyName in @('ftp', 'scm')) {
    $allow = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --resource-type Microsoft.Web/sites/basicPublishingCredentialsPolicies --name "$($env:AZURE_FUNCTION_APP_NAME)/$policyName" `
        --api-version 2024-04-01 --query properties.allow -o tsv
    if ($LASTEXITCODE -ne 0 -or $allow -ne 'false') { throw "Function App $policyName basic publishing credentials are not disabled." }
}

$appSetting = & az functionapp config appsettings list --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
    --name $env:AZURE_FUNCTION_APP_NAME --query "[?name=='DEVICE_NOTIFICATION_COLLECTION_ENABLED'].value | [0]" -o tsv
if ($LASTEXITCODE -ne 0 -or $appSetting -notin @('true', 'false')) { throw 'Collection readiness setting is missing or invalid.' }
if ($appSetting -eq 'false') {
    if ($env:DEVICE_NOTIFICATION_ONBOARDING_STATUS -notin @('delivery-tested', 'delivery-validation-required')) {
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ONBOARDING_STATUS' 'delivery-validation-required'
    }
    Write-Host 'Infrastructure validation passed. Notification collection is PAUSED. Install the Teams app, validate every selected destination, then run Enable-NotificationCollection.ps1.'
} else {
    if ($env:DEVICE_NOTIFICATION_ONBOARDING_STATUS -notlike 'enabled-*') {
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ONBOARDING_STATUS' 'enabled-awaiting-live-event-validation'
    }
    Write-Host 'Infrastructure validation passed and collection is ENABLED. Confirm a real event on every selected route; infrastructure readiness alone is not delivery proof.'
}
