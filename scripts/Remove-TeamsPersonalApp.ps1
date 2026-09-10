[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
$stateNames = @(
    'DEVICE_NOTIFICATION_TEAMS_TENANT_ID',
    'DEVICE_NOTIFICATION_TEAMS_USER_UPN',
    'DEVICE_NOTIFICATION_TEAMS_USER_ID',
    'DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_AVAILABILITY_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID',
    'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP'
)
foreach ($name in @('AZURE_TENANT_ID', 'AZURE_WORKLOAD_CLIENT_ID') + $stateNames) {
    [void](Get-AzdEnvironmentValue $name -Authoritative)
}

$hasTeamsState = $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -or
    $env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP
if (-not $hasTeamsState) {
    Write-Host 'No recorded Teams personal-app intent requires cleanup.'
    return
}

foreach ($name in @('DEVICE_NOTIFICATION_TEAMS_TENANT_ID', 'DEVICE_NOTIFICATION_TEAMS_USER_UPN',
        'DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID', 'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "Teams cleanup ownership state '$name' is missing. Refusing ambiguous tenant deletion."
    }
}
if ($env:DEVICE_NOTIFICATION_TEAMS_TENANT_ID -cne $env:AZURE_TENANT_ID -or
    $env:DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID -cne $env:AZURE_WORKLOAD_CLIENT_ID) {
    throw 'Recorded Teams app state does not match the exact deployed tenant and workload identity.'
}
if (-not (Get-Module Microsoft.Graph.Authentication -ListAvailable)) {
    throw 'Microsoft.Graph.Authentication is required for Teams app cleanup.'
}

Import-Module Microsoft.Graph.Authentication
$requiredScopes = @('AppCatalog.ReadWrite.All', 'TeamsAppInstallation.ReadWriteForUser')
Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -Scopes $requiredScopes -ContextScope Process -NoWelcome
$context = Get-MgContext
if (-not $context -or $context.TenantId -cne $env:AZURE_TENANT_ID -or
    [string]$context.Account -ine $env:DEVICE_NOTIFICATION_TEAMS_USER_UPN) {
    throw 'Microsoft Graph is not connected as the recorded user in the exact deployment tenant.'
}

$encodedUpn = [uri]::EscapeDataString($env:DEVICE_NOTIFICATION_TEAMS_USER_UPN)
$catalogApp = $null
if ($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID) {
    try {
        $catalogApp = Invoke-MgGraphRequest -Method GET `
            -Uri "/v1.0/appCatalogs/teamsApps/$($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID)?`$select=id,externalId,distributionMethod" `
            -OutputType PSObject
    } catch {
        if ($_.Exception.Message -notmatch '\b404\b|Not Found') { throw }
    }
} elseif ($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -eq 'create-pending') {
    $encodedFilter = [uri]::EscapeDataString("externalId eq '$($env:AZURE_WORKLOAD_CLIENT_ID)'")
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "/v1.0/appCatalogs/teamsApps?`$filter=$encodedFilter&`$select=id,externalId,distributionMethod" `
        -OutputType PSObject
    $matches = @($response.value)
    if ($matches.Count -gt 1) { throw 'More than one catalog app matches the recorded workload identity.' }
    if ($matches.Count -eq 1) { $catalogApp = $matches[0] }
}
if ($catalogApp -and ([string]$catalogApp.externalId -cne $env:AZURE_WORKLOAD_CLIENT_ID -or
        [string]$catalogApp.distributionMethod -cne 'organization')) {
    throw 'Recorded catalog app ID does not resolve to the exact deployed organization app.'
}

if ($env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP -match '^(create-pending|created)$' -and
    $env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID) {
    $installation = Invoke-MgGraphRequest -Method GET `
        -Uri "/v1.0/users/$encodedUpn/teamwork/installedApps/$($env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID)?`$expand=teamsApp" `
        -OutputType PSObject
    if ([string]$installation.teamsApp.externalId -cne $env:AZURE_WORKLOAD_CLIENT_ID) {
        throw 'Recorded personal installation does not reference the exact deployed Teams app.'
    }
    if ($PSCmdlet.ShouldProcess($env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID, 'Remove solution-owned personal Teams app installation')) {
        Invoke-MgGraphRequest -Method DELETE `
            -Uri "/v1.0/users/$encodedUpn/teamwork/installedApps/$($env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID)" | Out-Null
    }
}

if ($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -match '^(create-pending|created)$' -and $catalogApp -and
    $PSCmdlet.ShouldProcess($catalogApp.id, 'Remove solution-owned Teams catalog app')) {
    Invoke-MgGraphRequest -Method DELETE -Uri "/v1.0/appCatalogs/teamsApps/$($catalogApp.id)" | Out-Null
}

if (-not $WhatIfPreference) {
    foreach ($name in $stateNames) { Set-AzdEnvironmentValue $name '' }
}
Write-Host 'Recorded solution-owned Teams personal app objects were removed; adopted objects were preserved.'
