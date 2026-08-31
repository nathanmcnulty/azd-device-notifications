[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Configuration.Validation.psm1') -Force

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME')) { [void](Get-AzdEnvironmentValue $name) }
Assert-AzdTenantContext
Initialize-AzdResourceGroupOwnership | Out-Null

function Read-YesNo {
    param([Parameter(Mandatory)][string] $Prompt, [bool] $Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(?i)y(es)?$') { return $true }
        if ($answer -match '^(?i)n(o)?$') { return $false }
        Write-Warning 'Enter yes or no.'
    }
}

function Read-GuidList {
    param([Parameter(Mandatory)][string] $Prompt)
    $raw = (Read-Host $Prompt).Trim()
    if (-not $raw) { return @() }
    $values = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($value in $values) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$parsed)) { throw "'$value' is not a valid object ID." }
    }
    return $values
}

$defaults = [ordered]@{
    ENTRA_POLL_SCHEDULE = '0 */5 * * * *'
    INTUNE_POLL_SCHEDULE = '30 */15 * * * *'
    ENROLLMENT_LOOKBACK_HOURS = '0'
    ENTRA_AUDIT_OVERLAP_MINUTES = '15'
    DEVICE_NOTIFICATION_COLLECTION_ENABLED = 'false'
}
foreach ($entry in $defaults.GetEnumerator()) {
    if (-not (Get-AzdEnvironmentValue $entry.Key)) { Set-AzdEnvironmentValue $entry.Key $entry.Value }
}

$routingJson = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ROUTING_JSON'
$setupComplete = (Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_SETUP_COMPLETE') -eq 'true'
$nonInteractive = $env:AZD_NON_INTERACTIVE -eq 'true' -or $env:CI -eq 'true'

if (-not $routingJson) {
    if ($nonInteractive) { throw 'DEVICE_NOTIFICATION_ROUTING_JSON is required for noninteractive deployment.' }
    Write-Host 'Device notification setup'
    Write-Host 'Collection remains paused after deployment until Enable-NotificationCollection.ps1 is run.'
    $scopeChoice = (Read-Host 'Monitor [1] selected users/groups or [2] all users?').Trim()
    $users = @()
    $groups = @()
    $tenantWideConfirmed = 'false'
    if ($scopeChoice -eq '2') {
        if ((Read-Host 'Type ALL USERS to confirm tenant-wide monitoring').Trim() -cne 'ALL USERS') { throw 'Tenant-wide monitoring was not confirmed.' }
        $scopeMode = 'all'
        $tenantWideConfirmed = 'true'
    } elseif ($scopeChoice -eq '1') {
        $scopeMode = 'selected'
        $users = @(Read-GuidList 'Enter monitored Entra user object IDs, comma-separated (or blank)')
        $groups = @(Read-GuidList 'Enter monitored Entra group object IDs, comma-separated (or blank)')
        if ($users.Count -eq 0 -and $groups.Count -eq 0) { throw 'Selected scope requires at least one user or group object ID.' }
    } else { throw 'Scope selection must be 1 or 2.' }

    $userTeams = Read-YesNo 'Send Teams personal notifications to device owners?' $true
    $userEmail = Read-YesNo 'Send email notifications to device owners?' $false
    $adminWebhook = Read-YesNo 'Send admin notifications to a Teams Workflow webhook?' $false
    $adminEmail = Read-YesNo 'Send admin notifications by email?' $false
    if (-not ($userTeams -or $userEmail -or $adminWebhook -or $adminEmail)) { throw 'Select at least one delivery path.' }

    $webhook = ''
    $webhookSecretId = ''
    if ($adminWebhook) {
        $webhookInput = (Read-Host 'Paste the Teams Workflow HTTPS callback URL or an existing Key Vault secret ID').Trim()
        if ($webhookInput -match '^https://[^/]+\.vault\.azure\.net/secrets/[^/]+(?:/[^/]+)?$') {
            $webhookSecretId = $webhookInput
            $webhook = & az keyvault secret show --subscription $env:AZURE_SUBSCRIPTION_ID --id $webhookSecretId --query value -o tsv
            if ($LASTEXITCODE -ne 0 -or -not $webhook) { throw 'Unable to read the supplied Key Vault webhook secret.' }
            $webhook = ($webhook -join "`n").Trim()
        } else { $webhook = $webhookInput }
        Write-Warning 'The callback is a credential stored in the local azd environment. Never commit the .azure directory.'
    }
    $senderMailbox = ''
    $adminRecipients = ''
    if ($userEmail -or $adminEmail) {
        if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) { throw 'Email delivery requires ExchangeOnlineManagement. Install it before continuing.' }
        $senderMailbox = (Read-Host 'Enter the Exchange Online sender mailbox address').Trim()
    }
    if ($adminEmail) { $adminRecipients = (Read-Host 'Enter comma-separated administrator email recipients').Trim() }

    $lookback = '0'
    if (Read-YesNo 'Notify for recently enrolled devices found during the first Intune baseline?' $false) {
        $lookback = (Read-Host 'Enter enrollment backfill hours (1-720)').Trim()
    }
    $userRoutes = @()
    if ($userTeams) { $userRoutes += 'teamsDm' }
    if ($userEmail) { $userRoutes += 'email' }
    $adminRoutes = @()
    if ($adminWebhook) { $adminRoutes += 'teamsWebhook' }
    if ($adminEmail) { $adminRoutes += 'email' }
    $routingJson = ([ordered]@{
        events = [ordered]@{
            deviceRegistered = [ordered]@{ user = $userRoutes; admin = $adminRoutes }
            deviceEnrolled = [ordered]@{ user = $userRoutes; admin = $adminRoutes }
            deviceNoncompliant = [ordered]@{ user = $userRoutes; admin = $adminRoutes }
        }
        excludedOwnership = @(); excludedOperatingSystems = @(); monitoredUserIds = $users; monitoredGroupIds = $groups
        privilegedUserIds = @(); adminMentions = @()
    } | ConvertTo-Json -Depth 10 -Compress)
    $configuration = Get-NotificationConfiguration -RoutingJson $routingJson -TeamsWebhookUrl $webhook `
        -AdminEmailRecipients $adminRecipients -EmailSenderUpn $senderMailbox -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
        -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE -EnrollmentLookbackHours $lookback -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES

    Write-Host 'Final review (no tenant or Azure resources have been changed):'
    Write-Host "  Tenant: $($env:AZURE_TENANT_ID)"
    Write-Host "  Subscription: $($env:AZURE_SUBSCRIPTION_ID)"
    Write-Host "  Scope: $scopeMode (users: $($users.Count), groups: $($groups.Count), tenant-wide confirmed: $tenantWideConfirmed)"
    Write-Host "  Routes: $($configuration.EnabledRouteCount); Teams webhook: $($configuration.UsesWebhook); email: $($configuration.UsesEmail)"
    Write-Host "  Enrollment: $(if ([int]$lookback -eq 0) { 'baseline only' } else { "backfill $lookback hours" })"
    Write-Host '  Collection after deployment: PAUSED'
    if (-not (Read-YesNo 'Save this configuration and continue provisioning?' $false)) { throw 'Setup cancelled.' }
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ROUTING_JSON' $routingJson
    if ($webhookSecretId) {
        & azd env set-secret TEAMS_ADMIN_WEBHOOK_URL $webhookSecretId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to store the existing Key Vault secret reference in the azd environment.' }
        [Environment]::SetEnvironmentVariable('TEAMS_ADMIN_WEBHOOK_URL', $webhook, 'Process')
    } else { Set-AzdEnvironmentValue 'TEAMS_ADMIN_WEBHOOK_URL' $webhook }
    Set-AzdEnvironmentValue 'EMAIL_SENDER_UPN' $senderMailbox
    Set-AzdEnvironmentValue 'ADMIN_EMAIL_RECIPIENTS' $adminRecipients
    Set-AzdEnvironmentValue 'ENROLLMENT_LOOKBACK_HOURS' $lookback
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_SCOPE_MODE' $scopeMode
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED' $tenantWideConfirmed
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_SETUP_COMPLETE' 'true'
    $setupComplete = $true
}

foreach ($name in @('DEVICE_NOTIFICATION_ROUTING_JSON', 'TEAMS_ADMIN_WEBHOOK_URL', 'ADMIN_EMAIL_RECIPIENTS', 'EMAIL_SENDER_UPN',
        'ENTRA_POLL_SCHEDULE', 'INTUNE_POLL_SCHEDULE', 'ENROLLMENT_LOOKBACK_HOURS', 'ENTRA_AUDIT_OVERLAP_MINUTES',
        'DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED', 'DEVICE_NOTIFICATION_COLLECTION_ENABLED')) { [void](Get-AzdEnvironmentValue $name) }
$configuration = Get-NotificationConfiguration -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
    -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
    -EmailSenderUpn $env:EMAIL_SENDER_UPN -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
    -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE -EnrollmentLookbackHours $env:ENROLLMENT_LOOKBACK_HOURS `
    -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ROUTING_BASE64' `
    (ConvertTo-RoutingConfigBase64 -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON)
if ($configuration.UsesEmail) {
    $exchangeAdminUpn = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN'
    if (-not $exchangeAdminUpn) {
        if ($nonInteractive) { throw 'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN is required for noninteractive email deployment.' }
        $activeAdminUpn = (& az account show --query user.name --output tsv 2>$null | Out-String).Trim()
        $prompt = if ($activeAdminUpn -match '^[^@\s]+@[^@\s]+$') {
            "Enter the Exchange administrator UPN (blank uses $activeAdminUpn)"
        } else {
            'Enter the Exchange administrator UPN'
        }
        $exchangeAdminUpn = (Read-Host $prompt).Trim()
        if (-not $exchangeAdminUpn) { $exchangeAdminUpn = $activeAdminUpn }
        if ($exchangeAdminUpn -notmatch '^[^@\s]+@[^@\s]+$') { throw 'The Exchange administrator UPN is invalid.' }
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN' $exchangeAdminUpn
    } elseif ($exchangeAdminUpn -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN is invalid.'
    }
}
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_BOT_ENABLED' $configuration.UsesTeamsDm.ToString().ToLowerInvariant()
$userCount = @($configuration.Routing.monitoredUserIds).Count
$groupCount = @($configuration.Routing.monitoredGroupIds).Count
if ($userCount -eq 0 -and $groupCount -eq 0 -and $env:DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED -ne 'true') {
    throw 'An empty monitored user/group scope requires exact DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED=true.'
}
if ($userCount -gt 0 -or $groupCount -gt 0) { Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED' 'false' }
if (-not $setupComplete) {
    if ($nonInteractive) { throw 'DEVICE_NOTIFICATION_SETUP_COMPLETE=true is required for noninteractive provisioning.' }
    Write-Host "Preconfigured routing review: routes $($configuration.EnabledRouteCount); users $userCount; groups $groupCount; enrollment lookback $($env:ENROLLMENT_LOOKBACK_HOURS) hours; collection PAUSED."
    if (-not (Read-YesNo 'Adopt this preconfigured setup and continue?' $false)) { throw 'Setup adoption cancelled.' }
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_SETUP_COMPLETE' 'true'
}
Write-Host "Configuration validated: $($configuration.EnabledRouteCount) routes; users $userCount; groups $groupCount; collection $($env:DEVICE_NOTIFICATION_COLLECTION_ENABLED)."
if ($env:DEVICE_NOTIFICATION_COLLECTION_ENABLED -eq 'true') {
    foreach ($name in @('AZURE_FUNCTION_APP_NAME', 'AZURE_WORKLOAD_CLIENT_ID', 'DEVICE_NOTIFICATION_DELIVERY_TESTED', 'DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT')) {
        [void](Get-AzdEnvironmentValue $name)
    }
    if (-not $env:AZURE_FUNCTION_APP_NAME -or -not $env:AZURE_WORKLOAD_CLIENT_ID) { throw 'Enabled collection requires existing Function App outputs.' }
    Get-AzdFunctionTarget | Out-Null
    $expectedFingerprint = Get-NotificationDeliveryFingerprint -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
        -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
        -EmailSenderUpn $env:EMAIL_SENDER_UPN -FunctionAppName $env:AZURE_FUNCTION_APP_NAME -WorkloadClientId $env:AZURE_WORKLOAD_CLIENT_ID
    if ($env:DEVICE_NOTIFICATION_DELIVERY_TESTED -ne 'true' -or $env:DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT -cne $expectedFingerprint) {
        throw 'Collection is enabled but the current configuration lacks matching delivery proof. Pause collection before provisioning changes.'
    }
}
