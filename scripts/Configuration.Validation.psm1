function Test-NotificationCronSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Schedule)

    if ($Schedule -match '[\r\n]' -or @($Schedule.Trim() -split '\s+').Count -ne 6) { return $false }
    return $Schedule -match '^[0-9A-Za-z*?,/\-]+(?:\s+[0-9A-Za-z*?,/\-]+){5}$'
}

function Get-NotificationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RoutingJson,
        [AllowEmptyString()][string] $TeamsWebhookUrl = '',
        [AllowEmptyString()][string] $AdminEmailRecipients = '',
        [AllowEmptyString()][string] $EmailSenderUpn = '',
        [Parameter(Mandatory)][string] $EntraPollSchedule,
        [Parameter(Mandatory)][string] $IntunePollSchedule,
        [Parameter(Mandatory)][string] $EnrollmentLookbackHours,
        [Parameter(Mandatory)][string] $AuditOverlapMinutes
    )

    try { $routing = $RoutingJson | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'DEVICE_NOTIFICATION_ROUTING_JSON must contain valid JSON.' }
    if (-not $routing.events) { throw 'Routing configuration must contain an events object.' }
    $eventNames = @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant')
    $validTransports = @('teamsDm', 'teamsWebhook', 'email')
    $usesWebhook = $false
    $usesEmail = $false
    $enabledRouteCount = 0
    foreach ($eventName in $eventNames) {
        $routeEvent = $routing.events.$eventName
        if (-not $routeEvent) { throw "Routing configuration must define '$eventName'." }
        foreach ($audience in @('user', 'admin')) {
            $routeValue = $routeEvent.$audience
            if ($null -eq $routeValue -or $routeValue -is [string] -or -not ($routeValue -is [System.Collections.IEnumerable])) {
                throw "$eventName.$audience must be an array."
            }
            $routes = @($routeValue)
            if (@($routes | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
                throw "$eventName.$audience cannot contain duplicate transports."
            }
            foreach ($route in $routes) {
                if ($route -notin $validTransports) { throw "Unsupported route '$route' in $eventName.$audience." }
                if ($audience -eq 'user' -and $route -eq 'teamsWebhook') { throw "teamsWebhook is only valid for the admin audience ($eventName)." }
                if ($audience -eq 'admin' -and $route -eq 'teamsDm') { throw "teamsDm is only valid for the user audience ($eventName)." }
                if ($route -eq 'teamsWebhook') { $usesWebhook = $true }
                if ($route -eq 'email') { $usesEmail = $true }
                $enabledRouteCount++
            }
        }
    }
    if ($enabledRouteCount -eq 0) { throw 'At least one notification delivery route must be enabled.' }
    if ($usesWebhook) {
        $uri = $null
        if (-not [uri]::TryCreate($TeamsWebhookUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
            throw 'TEAMS_ADMIN_WEBHOOK_URL must be a valid HTTPS URL when teamsWebhook routing is enabled.'
        }
    }
    $emails = @($AdminEmailRecipients -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($usesEmail) {
        if ($EmailSenderUpn -notmatch '^[^@\s]+@[^@\s]+$') { throw 'EMAIL_SENDER_UPN must be a valid address when email routing is enabled.' }
        $adminUsesEmail = $eventNames | Where-Object { @($routing.events.$_.admin) -contains 'email' }
        if ($adminUsesEmail -and ($emails.Count -eq 0 -or @($emails | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+$' }).Count -gt 0)) {
            throw 'ADMIN_EMAIL_RECIPIENTS must contain valid comma-separated addresses when admin email routing is enabled.'
        }
    }
    if (-not (Test-NotificationCronSchedule $EntraPollSchedule)) { throw 'ENTRA_POLL_SCHEDULE must be a valid six-field NCRONTAB expression.' }
    if (-not (Test-NotificationCronSchedule $IntunePollSchedule)) { throw 'INTUNE_POLL_SCHEDULE must be a valid six-field NCRONTAB expression.' }
    $lookback = 0
    if (-not [int]::TryParse($EnrollmentLookbackHours, [ref]$lookback) -or $lookback -lt 0 -or $lookback -gt 720) {
        throw 'ENROLLMENT_LOOKBACK_HOURS must be an integer from 0 through 720.'
    }
    $overlap = 0
    if (-not [int]::TryParse($AuditOverlapMinutes, [ref]$overlap) -or $overlap -lt 1 -or $overlap -gt 1440) {
        throw 'ENTRA_AUDIT_OVERLAP_MINUTES must be an integer from 1 through 1440.'
    }
    foreach ($name in @('excludedOwnership', 'excludedOperatingSystems', 'monitoredUserIds', 'monitoredGroupIds', 'privilegedUserIds', 'adminMentions')) {
        $value = $routing.$name
        if ($null -eq $value) { continue }
        if ($value -is [string] -or -not ($value -is [System.Collections.IEnumerable])) { throw "$name must be an array." }
    }
    foreach ($name in @('excludedOwnership', 'excludedOperatingSystems')) {
        if ($null -eq $routing.$name) { continue }
        if (@($routing.$name | Where-Object { $_ -isnot [string] }).Count -gt 0) { throw "$name must contain only strings." }
    }
    foreach ($name in @('monitoredUserIds', 'monitoredGroupIds', 'privilegedUserIds')) {
        if ($null -eq $routing.$name) { continue }
        foreach ($id in @($routing.$name)) {
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse([string]$id, [ref]$parsed)) { throw "$name must contain only GUIDs." }
        }
    }
    if ($null -ne $routing.adminMentions) {
        foreach ($mention in @($routing.adminMentions)) {
            if (-not $mention -or $mention.name -isnot [string] -or $mention.upn -notmatch '^[^@\s]+@[^@\s]+$') {
                throw 'adminMentions must contain name and valid UPN values.'
            }
        }
    }
    if ($routing.quietHours) {
        $start = $routing.quietHours.start
        $end = $routing.quietHours.end
        $startHour = 0
        $endHour = 0
        if (-not [int]::TryParse([string]$start, [ref]$startHour) -or $startHour -lt 0 -or $startHour -gt 23 -or
            -not [int]::TryParse([string]$end, [ref]$endHour) -or $endHour -lt 0 -or $endHour -gt 23 -or
            $routing.quietHours.timeZone -isnot [string]) { throw 'quietHours requires start/end integers from 0 through 23 and a timeZone.' }
        try { [void][TimeZoneInfo]::FindSystemTimeZoneById($routing.quietHours.timeZone) }
        catch { throw "quietHours.timeZone is invalid: $($routing.quietHours.timeZone)" }
    }
    return [pscustomobject]@{
        Routing = $routing
        UsesWebhook = $usesWebhook
        UsesEmail = $usesEmail
        EnabledRouteCount = $enabledRouteCount
        AdminEmailRecipients = $emails
        EnrollmentLookbackHours = $lookback
        AuditOverlapMinutes = $overlap
    }
}

function Get-NotificationDeliveryFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RoutingJson,
        [AllowEmptyString()][string] $TeamsWebhookUrl = '',
        [AllowEmptyString()][string] $AdminEmailRecipients = '',
        [AllowEmptyString()][string] $EmailSenderUpn = '',
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][string] $WorkloadClientId
    )
    $material = @($RoutingJson, $TeamsWebhookUrl, $AdminEmailRecipients, $EmailSenderUpn, $FunctionAppName, $WorkloadClientId) -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($material)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

Export-ModuleMember -Function Test-NotificationCronSchedule, Get-NotificationConfiguration, Get-NotificationDeliveryFingerprint
