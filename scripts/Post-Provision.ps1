[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Configuration.Validation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Graph.Management.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_WORKLOAD_PRINCIPAL_ID', 'AZURE_WORKLOAD_CLIENT_ID',
        'AZURE_FUNCTION_APP_URL', 'DEVICE_NOTIFICATION_ROUTING_JSON', 'TEAMS_ADMIN_WEBHOOK_URL', 'ADMIN_EMAIL_RECIPIENTS',
        'EMAIL_SENDER_UPN', 'ENTRA_POLL_SCHEDULE', 'INTUNE_POLL_SCHEDULE', 'ENROLLMENT_LOOKBACK_HOURS', 'ENTRA_AUDIT_OVERLAP_MINUTES',
        'DEVICE_NOTIFICATION_COLLECTION_ENABLED', 'DEVICE_NOTIFICATION_ONBOARDING_STATUS')) {
    [void](Get-AzdEnvironmentValue $name)
}
Assert-AzdTenantContext

foreach ($name in @('AZURE_WORKLOAD_PRINCIPAL_ID', 'AZURE_WORKLOAD_CLIENT_ID', 'AZURE_FUNCTION_APP_URL')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name was not returned by provisioning." }
}

$configuration = Get-NotificationConfiguration -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
    -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
    -EmailSenderUpn $env:EMAIL_SENDER_UPN -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
    -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE -EnrollmentLookbackHours $env:ENROLLMENT_LOOKBACK_HOURS `
    -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES
$graphArgs = @{ SubscriptionId = $env:AZURE_SUBSCRIPTION_ID }
$graph = Invoke-GraphJson -Method GET -Uri "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles" @graphArgs
if ($graph.value.Count -ne 1) { throw 'Unable to resolve the Microsoft Graph service principal.' }
$graphServicePrincipal = $graph.value[0]
$permissions = @(Get-RequiredGraphPermissionNames -Routing $configuration.Routing)
$plan = @(Resolve-GraphPermissionPlan -GraphServicePrincipal $graphServicePrincipal -RequiredNames $permissions)
$managedNames = @('AuditLog.Read.All', 'DeviceManagementManagedDevices.Read.All', 'User.ReadBasic.All', 'GroupMember.Read.All')
$managedRoles = @(Resolve-GraphPermissionPlan -GraphServicePrincipal $graphServicePrincipal -RequiredNames $managedNames)
$existing = Invoke-GraphJson -Method GET -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments?`$top=999" -RetryNotFound @graphArgs

foreach ($item in $plan) {
    if ($existing.value.appRoleId -contains $item.Id) {
        Write-Host "Microsoft Graph permission already assigned: $($item.Name)"
        continue
    }
    Invoke-GraphJson -Method POST -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments" -Body @{
        principalId = $env:AZURE_WORKLOAD_PRINCIPAL_ID
        resourceId = $graphServicePrincipal.id
        appRoleId = $item.Id
    } -RetryNotFound @graphArgs | Out-Null
    Write-Host "Assigned Microsoft Graph permission: $($item.Name)"
}

foreach ($permission in @('User.ReadBasic.All', 'GroupMember.Read.All')) {
    if ($permissions -contains $permission) { continue }
    $role = $managedRoles | Where-Object Name -eq $permission
    $assignment = @($existing.value | Where-Object { $_.appRoleId -eq $role.Id })
    foreach ($item in $assignment) {
        Invoke-GraphJson -Method DELETE -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments/$($item.id)" @graphArgs | Out-Null
        Write-Host "Removed unneeded Microsoft Graph permission: $permission"
    }
}

$verified = Invoke-GraphJson -Method GET -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments?`$top=999" -RetryNotFound @graphArgs
foreach ($item in $plan) {
    if ($item.Id -notin $verified.value.appRoleId) { throw "Microsoft Graph permission verification failed: $($item.Name)." }
}
foreach ($item in $managedRoles | Where-Object { $_.Name -notin $permissions }) {
    if ($item.Id -in $verified.value.appRoleId) { throw "Unneeded Microsoft Graph permission remains assigned: $($item.Name)." }
}

if ($configuration.UsesEmail -and (Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED') -ne 'true') {
    if ($env:AZD_NON_INTERACTIVE -eq 'true' -or $env:CI -eq 'true') {
        throw 'Email routing is enabled but Exchange Application RBAC is not configured. Run Configure-ExchangeMail.ps1 interactively.'
    }
    & (Join-Path $PSScriptRoot 'Configure-ExchangeMail.ps1') -SenderMailbox $env:EMAIL_SENDER_UPN
}

if ($configuration.UsesTeamsDm) {
    & (Join-Path $PSScriptRoot 'New-TeamsAppPackage.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Teams app package generation failed.' }
}

if ($env:DEVICE_NOTIFICATION_COLLECTION_ENABLED -ne 'true') {
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ONBOARDING_STATUS' 'delivery-validation-required'
    Write-Host 'Infrastructure permissions are ready. Collection remains PAUSED until Test-Deployment.ps1 -TestDelivery passes and Enable-NotificationCollection.ps1 is run.'
} else {
    Write-Host "Infrastructure permissions are ready. Collection remains ENABLED with onboarding status '$($env:DEVICE_NOTIFICATION_ONBOARDING_STATUS)'."
}
