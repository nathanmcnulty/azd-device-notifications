[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $AllowUntestedDestination
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Configuration.Validation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Exchange.Management.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME',
        'DEVICE_NOTIFICATION_ROUTING_JSON', 'TEAMS_ADMIN_WEBHOOK_URL', 'ADMIN_EMAIL_RECIPIENTS', 'EMAIL_SENDER_UPN',
        'ENTRA_POLL_SCHEDULE', 'INTUNE_POLL_SCHEDULE', 'ENROLLMENT_LOOKBACK_HOURS', 'ENTRA_AUDIT_OVERLAP_MINUTES',
        'DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED', 'DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED',
        'DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS', 'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN',
        'DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID', 'DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN',
        'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID', 'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID',
        'DEVICE_NOTIFICATION_ONBOARDING_STATUS', 'DEVICE_NOTIFICATION_DELIVERY_TESTED', 'DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT',
        'AZURE_WORKLOAD_CLIENT_ID')) {
    [void](Get-AzdEnvironmentValue $name)
}
Assert-AzdTenantContext
Get-AzdFunctionTarget | Out-Null
$configuration = Get-NotificationConfiguration -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
    -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
    -EmailSenderUpn $env:EMAIL_SENDER_UPN -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
    -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE -EnrollmentLookbackHours $env:ENROLLMENT_LOOKBACK_HOURS `
    -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES
$userCount = @($configuration.Routing.monitoredUserIds).Count
$groupCount = @($configuration.Routing.monitoredGroupIds).Count
$tenantWide = $userCount -eq 0 -and $groupCount -eq 0
if ($tenantWide -and $env:DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED -ne 'true') { throw 'Tenant-wide collection was not explicitly confirmed.' }
if ($configuration.UsesEmail) {
    if ($env:DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED -ne 'true' -or $env:DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS -ne 'complete') {
        throw 'Email is routed but exact Exchange Application RBAC setup is not recorded as complete.'
    }
    Assert-RecordedExchangeBinding `
        -RecordedClientId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID `
        -RecordedPrincipalId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID `
        -RecordedAdminUpn $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN `
        -RecordedTenantId $env:DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID `
        -RecordedSenderMailbox $env:DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN `
        -ExpectedClientId $env:AZURE_WORKLOAD_CLIENT_ID -ExpectedPrincipalId $env:AZURE_WORKLOAD_PRINCIPAL_ID `
        -ExpectedAdminUpn $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN -ExpectedTenantId $env:AZURE_TENANT_ID `
        -ExpectedSenderMailbox $env:EMAIL_SENDER_UPN -RequireRecorded
}

Write-Host 'Collection enablement review:'
Write-Host "  Tenant: $($env:AZURE_TENANT_ID)"
Write-Host "  Subscription: $($env:AZURE_SUBSCRIPTION_ID)"
Write-Host "  Scope: $(if ($tenantWide) { 'ALL USERS' } else { "selected users $userCount, groups $groupCount" })"
Write-Host "  Enrollment: $(if ([int]$env:ENROLLMENT_LOOKBACK_HOURS -eq 0) { 'baseline only' } else { "backfill $($env:ENROLLMENT_LOOKBACK_HOURS) hours" })"
Write-Host "  Routes: $($configuration.EnabledRouteCount)"
$expectedFingerprint = Get-NotificationDeliveryFingerprint -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
    -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
    -EmailSenderUpn $env:EMAIL_SENDER_UPN -FunctionAppName $env:AZURE_FUNCTION_APP_NAME -WorkloadClientId $env:AZURE_WORKLOAD_CLIENT_ID
$proofValid = $env:DEVICE_NOTIFICATION_DELIVERY_TESTED -eq 'true' -and $env:DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT -ceq $expectedFingerprint
if (-not $proofValid -and -not $AllowUntestedDestination) {
    throw 'Current delivery configuration has not passed Test-Deployment.ps1 -TestDelivery. Collection remains paused.'
}
if (-not $proofValid) { Write-Warning 'OVERRIDE: collection will start without proof that every configured destination can deliver. Events can be permanently missed.' }
$expected = if ($tenantWide) { 'ENABLE ALL USERS' } else { 'ENABLE SELECTED SCOPE' }
if ($env:AZD_NON_INTERACTIVE -eq 'true' -or $env:CI -eq 'true') {
    if ($env:DEVICE_NOTIFICATION_ENABLE_CONFIRMATION -cne $expected) { throw "Noninteractive enablement requires DEVICE_NOTIFICATION_ENABLE_CONFIRMATION='$expected'." }
} elseif ((Read-Host "Type $expected after reviewing scope and backfill").Trim() -cne $expected) {
    throw 'Collection enablement was not confirmed.'
}
if ($AllowUntestedDestination -and ($env:AZD_NON_INTERACTIVE -ne 'true' -and $env:CI -ne 'true') -and
    (Read-Host 'Type ENABLE WITHOUT DELIVERY PROOF to accept possible notification loss').Trim() -cne 'ENABLE WITHOUT DELIVERY PROOF') {
    throw 'Untested destination override was not confirmed.'
}

if ($PSCmdlet.ShouldProcess($env:AZURE_FUNCTION_APP_NAME, 'Enable device notification collection')) {
    & az functionapp config appsettings set --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --name $env:AZURE_FUNCTION_APP_NAME --settings DEVICE_NOTIFICATION_COLLECTION_ENABLED=true --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enable collection on the Function App.' }
    $actual = & az functionapp config appsettings list --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --name $env:AZURE_FUNCTION_APP_NAME --query "[?name=='DEVICE_NOTIFICATION_COLLECTION_ENABLED'].value | [0]" -o tsv
    if ($LASTEXITCODE -ne 0 -or $actual -ne 'true') { throw 'Collection enablement could not be verified.' }
    try { Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_COLLECTION_ENABLED' 'true' }
    catch {
        & az functionapp config appsettings set --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
            --name $env:AZURE_FUNCTION_APP_NAME --settings DEVICE_NOTIFICATION_COLLECTION_ENABLED=false --only-show-errors | Out-Null
        throw 'The live Function setting was rolled back because the azd environment could not record enablement.'
    }
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ONBOARDING_STATUS' 'enabled-awaiting-live-event-validation'
    Write-Host 'Collection is ENABLED. Trigger a real Graph-backed event for every selected delivery path; monitor the poison queue and Function logs.'
}
