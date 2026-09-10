[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force

function Test-GraphNotFound {
    param([Parameter(Mandatory)] $ErrorRecord)

    $exception = $ErrorRecord.Exception
    $candidates = @()
    foreach ($propertyName in @('ResponseStatusCode', 'StatusCode')) {
        $property = $exception.PSObject.Properties[$propertyName]
        if ($property) { $candidates += $property.Value }
    }
    $responseProperty = $exception.PSObject.Properties['Response']
    if ($responseProperty -and $responseProperty.Value) {
        $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
        if ($statusProperty) { $candidates += $statusProperty.Value }
    }
    foreach ($candidate in $candidates) {
        if ($null -ne $candidate -and [int]$candidate -eq 404) { return $true }
    }
    return $false
}

function Invoke-GraphGetOrNull {
    param([Parameter(Mandatory)][string] $Uri)

    try {
        return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
    }
    catch {
        if (Test-GraphNotFound $_) { return $null }
        throw
    }
}

function Wait-TeamsGraphResourceAbsent {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Description
    )

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        if ($null -eq (Invoke-GraphGetOrNull -Uri $Uri)) { return }
        if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
    }
    throw "$Description still exists after the delete request. Cleanup receipts were preserved."
}

$stateNames = @(
    'DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN',
    'DEVICE_NOTIFICATION_TEAMS_TENANT_ID',
    'DEVICE_NOTIFICATION_TEAMS_USER_UPN',
    'DEVICE_NOTIFICATION_TEAMS_USER_ID',
    'DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID',
    'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION',
    'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_UPDATE_STATUS',
    'DEVICE_NOTIFICATION_TEAMS_AVAILABILITY_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID',
    'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP'
)
foreach ($name in @('AZURE_TENANT_ID', 'AZURE_WORKLOAD_CLIENT_ID') + $stateNames) {
    [void](Get-AzdEnvironmentValue $name -Authoritative)
}

$ownershipNames = @(
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_AVAILABILITY_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP'
)
foreach ($name in $ownershipNames) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value -and $value -notin @('create-pending', 'created', 'adopted')) {
        throw "Teams cleanup ownership state '$name' has unsupported value '$value'."
    }
}

$hasTeamsState = @($stateNames | Where-Object { [Environment]::GetEnvironmentVariable($_) }).Count -gt 0
if (-not $hasTeamsState) {
    Write-Host 'No recorded Teams personal-app intent requires cleanup.'
    return
}
if (($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID -and -not $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP) -or
    ($env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID -and -not $env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP)) {
    throw 'Teams object IDs exist without ownership receipts. Refusing ambiguous tenant deletion.'
}
foreach ($name in @(
        'DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN',
        'DEVICE_NOTIFICATION_TEAMS_TENANT_ID',
        'DEVICE_NOTIFICATION_TEAMS_USER_UPN',
        'DEVICE_NOTIFICATION_TEAMS_USER_ID',
        'DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID',
        'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP'
    )) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "Teams cleanup ownership state '$name' is missing. Refusing ambiguous tenant deletion."
    }
}
if ($env:DEVICE_NOTIFICATION_TEAMS_TENANT_ID -ine $env:AZURE_TENANT_ID -or
    $env:DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID -ine $env:AZURE_WORKLOAD_CLIENT_ID) {
    throw 'Recorded Teams app state does not match the exact deployed tenant and workload identity.'
}
if (-not (Get-Module Microsoft.Graph.Authentication -ListAvailable)) {
    throw 'Microsoft.Graph.Authentication is required for Teams app cleanup.'
}

Import-Module Microsoft.Graph.Authentication
$requiredScopes = @('AppCatalog.ReadWrite.All', 'TeamsAppInstallation.ReadWriteForUser', 'User.ReadBasic.All')
Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -Scopes $requiredScopes -ContextScope Process -NoWelcome
$context = Get-MgContext
if (-not $context -or $context.TenantId -ine $env:AZURE_TENANT_ID -or
    [string]$context.Account -ine $env:DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN) {
    throw 'Microsoft Graph is not connected as the recorded administrator in the exact deployment tenant.'
}
foreach ($scope in $requiredScopes) {
    if ($scope -notin @($context.Scopes)) { throw "Microsoft Graph scope '$scope' was not granted." }
}

$encodedUpn = [uri]::EscapeDataString($env:DEVICE_NOTIFICATION_TEAMS_USER_UPN)
$targetUser = Invoke-GraphGetOrNull -Uri "/v1.0/users/${encodedUpn}?`$select=id,userPrincipalName"
if (-not $targetUser -or [string]$targetUser.id -ine $env:DEVICE_NOTIFICATION_TEAMS_USER_ID -or
    [string]$targetUser.userPrincipalName -ine $env:DEVICE_NOTIFICATION_TEAMS_USER_UPN) {
    throw 'The recorded Teams target UPN and object ID do not resolve to the same user.'
}
$targetUserId = [uri]::EscapeDataString([string]$targetUser.id)

$catalogOwnership = $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP
$catalogApp = $null
if ($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID) {
    $catalogApp = Invoke-GraphGetOrNull `
        -Uri "/v1.0/appCatalogs/teamsApps/$($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID)?`$select=id,externalId,distributionMethod"
} elseif ($catalogOwnership -eq 'create-pending') {
    $encodedFilter = [uri]::EscapeDataString("externalId eq '$($env:AZURE_WORKLOAD_CLIENT_ID)'")
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "/v1.0/appCatalogs/teamsApps?`$filter=$encodedFilter&`$select=id,externalId,distributionMethod" `
        -OutputType PSObject
    $catalogMatches = @($response.value)
    if ($catalogMatches.Count -gt 1) { throw 'More than one catalog app matches the recorded workload identity.' }
    if ($catalogMatches.Count -eq 1) { $catalogApp = $catalogMatches[0] }
} else {
    throw "Catalog ownership '$catalogOwnership' requires a recorded catalog app ID."
}
if ($catalogApp -and ([string]$catalogApp.externalId -ine $env:AZURE_WORKLOAD_CLIENT_ID -or
        [string]$catalogApp.distributionMethod -ine 'organization')) {
    throw 'The recorded catalog app does not resolve to the exact deployed organization app.'
}
if ($catalogApp -and $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID -and
    [string]$catalogApp.id -ine $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID) {
    throw 'The resolved catalog app ID does not match the recorded catalog app ID.'
}

$installOwnership = $env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP
$installation = $null
$installationUri = $null
if ($installOwnership) {
    if ($env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID) {
        $installationUri = "/v1.0/users/$targetUserId/teamwork/installedApps/$($env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID)"
        $installation = Invoke-GraphGetOrNull -Uri "${installationUri}?`$expand=teamsApp"
    } elseif ($installOwnership -eq 'create-pending') {
        $response = Invoke-MgGraphRequest -Method GET `
            -Uri "/v1.0/users/$targetUserId/teamwork/installedApps?`$expand=teamsApp" -OutputType PSObject
        $installationMatches = @($response.value | Where-Object {
                [string]$_.teamsApp.externalId -ieq $env:AZURE_WORKLOAD_CLIENT_ID
            })
        if ($installationMatches.Count -gt 1) { throw 'More than one personal installation matches the recorded workload identity.' }
        if ($installationMatches.Count -eq 1) {
            $installation = $installationMatches[0]
            $installationUri = "/v1.0/users/$targetUserId/teamwork/installedApps/$($installation.id)"
        }
    } else {
        throw "Installation ownership '$installOwnership' requires a recorded installation ID."
    }
}
if ($installation -and [string]$installation.teamsApp.externalId -ine $env:AZURE_WORKLOAD_CLIENT_ID) {
    throw 'The recorded personal installation does not reference the exact deployed Teams app.'
}
if ($installation -and $catalogApp -and [string]$installation.teamsApp.id -and
    [string]$installation.teamsApp.id -ine [string]$catalogApp.id) {
    throw 'The recorded personal installation does not reference the exact catalog app.'
}
if ($installation -and $installOwnership -eq 'adopted' -and
    $catalogOwnership -in @('create-pending', 'created')) {
    throw 'The catalog app cannot be removed while its recorded personal installation is adopted.'
}

if ($installation -and $installOwnership -in @('create-pending', 'created') -and
    $PSCmdlet.ShouldProcess($installation.id, 'Remove solution-owned personal Teams app installation')) {
    Invoke-MgGraphRequest -Method DELETE -Uri $installationUri | Out-Null
    Wait-TeamsGraphResourceAbsent -Uri $installationUri -Description "Personal Teams app installation '$($installation.id)'"
}

if ($catalogApp -and $catalogOwnership -in @('create-pending', 'created') -and
    $PSCmdlet.ShouldProcess($catalogApp.id, 'Remove solution-owned Teams catalog app')) {
    $catalogUri = "/v1.0/appCatalogs/teamsApps/$($catalogApp.id)"
    Invoke-MgGraphRequest -Method DELETE -Uri $catalogUri | Out-Null
    Wait-TeamsGraphResourceAbsent -Uri $catalogUri -Description "Teams catalog app '$($catalogApp.id)'"
}

if (-not $WhatIfPreference) {
    foreach ($name in $stateNames) { Set-AzdEnvironmentValue $name '' }
}
Write-Host 'Recorded solution-owned Teams personal-app objects are absent; adopted objects were preserved.'
