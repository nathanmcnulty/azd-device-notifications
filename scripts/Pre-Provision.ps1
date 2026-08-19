[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force

foreach ($command in @('az', 'azd', 'node', 'npm')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}
Assert-AzdTenantContext

$defaults = [ordered]@{
    ENTRA_POLL_SCHEDULE = '0 */5 * * * *'
    INTUNE_POLL_SCHEDULE = '30 */15 * * * *'
    ENROLLMENT_LOOKBACK_HOURS = '24'
    ENTRA_AUDIT_OVERLAP_MINUTES = '15'
    DEVICE_NOTIFICATION_ROUTING_JSON = '{"events":{"deviceRegistered":{"user":["teamsDm"],"admin":["teamsWebhook"]},"deviceEnrolled":{"user":["teamsDm"],"admin":["teamsWebhook"]},"deviceNoncompliant":{"user":["teamsDm","email"],"admin":["teamsWebhook","email"]}},"excludedOwnership":[],"excludedOperatingSystems":[],"monitoredUserIds":[],"monitoredGroupIds":[],"privilegedUserIds":[],"adminMentions":[]}'
}

foreach ($entry in $defaults.GetEnumerator()) {
    $current = [Environment]::GetEnvironmentVariable($entry.Key)
    if (-not $current) {
        & azd env set $entry.Key $entry.Value | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to set azd environment value '$($entry.Key)'." }
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}

try { $env:DEVICE_NOTIFICATION_ROUTING_JSON | ConvertFrom-Json -ErrorAction Stop | Out-Null }
catch { throw 'DEVICE_NOTIFICATION_ROUTING_JSON must contain valid JSON.' }

Write-Host 'Environment and tenant context validated.'
