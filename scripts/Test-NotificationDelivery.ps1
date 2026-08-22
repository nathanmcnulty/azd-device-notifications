[CmdletBinding()]
param(
    [ValidateSet('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant')]
    [string[]] $EventType = @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant'),
    [guid] $TestUserId,
    [ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $TestUserUpn,
    [ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $TestUserEmail
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Configuration.Validation.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME',
        'AZURE_FUNCTION_APP_URL', 'AZURE_WORKLOAD_CLIENT_ID', 'DEVICE_NOTIFICATION_ROUTING_JSON', 'TEAMS_ADMIN_WEBHOOK_URL',
        'ADMIN_EMAIL_RECIPIENTS', 'EMAIL_SENDER_UPN', 'ENTRA_POLL_SCHEDULE', 'INTUNE_POLL_SCHEDULE',
        'ENROLLMENT_LOOKBACK_HOURS', 'ENTRA_AUDIT_OVERLAP_MINUTES', 'DEVICE_NOTIFICATION_COLLECTION_ENABLED')) {
    [void](Get-AzdEnvironmentValue $name)
}
Assert-AzdTenantContext
$configuration = Get-NotificationConfiguration -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
    -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
    -EmailSenderUpn $env:EMAIL_SENDER_UPN -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
    -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE -EnrollmentLookbackHours $env:ENROLLMENT_LOOKBACK_HOURS `
    -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES
$liveCollection = & az functionapp config appsettings list --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
    --name $env:AZURE_FUNCTION_APP_NAME --query "[?name=='DEVICE_NOTIFICATION_COLLECTION_ENABLED'].value | [0]" -o tsv
if ($LASTEXITCODE -ne 0 -or $env:DEVICE_NOTIFICATION_COLLECTION_ENABLED -ne 'false' -or $liveCollection -ne 'false') {
    throw 'Synthetic delivery testing is allowed only while collection is paused in both azd and the Function App.'
}
$hasUserRoutes = @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant') | Where-Object {
    @($configuration.Routing.events.$_.user).Count -gt 0
}
if ($hasUserRoutes) {
    if (($env:AZD_NON_INTERACTIVE -eq 'true' -or $env:CI -eq 'true') -and
        ($TestUserId -eq [guid]::Empty -or -not $TestUserUpn -or -not $TestUserEmail)) {
        throw 'Noninteractive user-route testing requires TestUserId, TestUserUpn, and TestUserEmail.'
    }
    if ($TestUserId -eq [guid]::Empty) { $TestUserId = [guid](Read-Host 'Enter the prepared test user object ID') }
    if (-not $TestUserUpn) { $TestUserUpn = (Read-Host 'Enter the prepared test user UPN').Trim() }
    if (-not $TestUserEmail) { $TestUserEmail = (Read-Host 'Enter the prepared test user email address').Trim() }
    if ($TestUserUpn -notmatch '^[^@\s]+@[^@\s]+$' -or $TestUserEmail -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'Test user UPN and email must be valid addresses.'
    }
}

$hostKey = $null
try {
    $keys = & az functionapp keys list --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --name $env:AZURE_FUNCTION_APP_NAME --only-show-errors -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to obtain a Function host key for bounded delivery testing.' }
    $hostKey = if ($keys.functionKeys.default) { [string]$keys.functionKeys.default } else { [string]$keys.masterKey }
    if (-not $hostKey) { throw 'The Function App did not return a usable host key.' }
    foreach ($type in $EventType) {
        $body = @{
            eventType = $type
            testUser = @{ id = [string]$TestUserId; upn = $TestUserUpn; email = $TestUserEmail; displayName = 'Device notification test user' }
        } | ConvertTo-Json -Depth 5 -Compress
        $response = Invoke-WebRequest -Method Post -Uri "$($env:AZURE_FUNCTION_APP_URL)/api/test-notification-delivery" `
            -Headers @{ 'x-functions-key' = $hostKey } -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Synthetic delivery test for '$type' failed with HTTP $($response.StatusCode)." }
        $summary = $response.Content | ConvertFrom-Json
        if ($summary.success -ne $true) { throw "Synthetic delivery test for '$type' reported an unavailable or failed route." }
        Write-Host "Synthetic delivery succeeded for every configured '$type' route."
    }
    $allTypes = @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant')
    if (@($allTypes | Where-Object { $_ -notin $EventType }).Count -eq 0) {
        $fingerprint = Get-NotificationDeliveryFingerprint -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
            -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
            -EmailSenderUpn $env:EMAIL_SENDER_UPN -FunctionAppName $env:AZURE_FUNCTION_APP_NAME -WorkloadClientId $env:AZURE_WORKLOAD_CLIENT_ID
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT' $fingerprint
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_DELIVERY_TESTED' 'true'
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ONBOARDING_STATUS' 'delivery-tested'
        Write-Host 'All configured delivery paths passed synthetic delivery. Collection remains PAUSED until Enable-NotificationCollection.ps1 is run.'
    } else {
        Write-Warning 'Only selected event types were tested; collection enablement proof was not recorded.'
    }
}
finally {
    $hostKey = $null
    $keys = $null
    [GC]::Collect()
}
