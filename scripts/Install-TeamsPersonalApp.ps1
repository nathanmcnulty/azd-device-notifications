[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $UserUpn,
    [string] $PackagePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'teams-app/device-notifications.zip'),
    [switch] $AdoptExisting,
    [switch] $Plan
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
foreach ($name in @('AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_ENV_NAME', 'AZURE_WORKLOAD_CLIENT_ID',
        'AZURE_FUNCTION_APP_URL')) {
    [void](Get-AzdEnvironmentValue $name -Authoritative)
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required." }
}
Assert-AzdTenantContext
Get-AzdFunctionTarget | Out-Null

$resolvedPackage = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
$staging = Join-Path ([IO.Path]::GetTempPath()) "device-notifications-manifest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    Expand-Archive -LiteralPath $resolvedPackage -DestinationPath $staging -Force
    $manifestPath = Join-Path $staging 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The Teams package does not contain manifest.json.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$expectedHost = ([uri]$env:AZURE_FUNCTION_APP_URL).Host
if ([string]$manifest.id -cne $env:AZURE_WORKLOAD_CLIENT_ID) { throw 'The Teams manifest ID does not match the deployed workload client ID.' }
$bots = @($manifest.bots)
if ($bots.Count -ne 1 -or [string]$bots[0].botId -cne $env:AZURE_WORKLOAD_CLIENT_ID) {
    throw 'The Teams package must contain exactly one bot bound to the deployed workload client ID.'
}
if (@($bots[0].scopes).Count -ne 1 -or [string]$bots[0].scopes[0] -cne 'personal' -or $bots[0].isNotificationOnly -ne $true) {
    throw 'The Teams bot must be notification-only and personal-scope only.'
}
if (@($manifest.validDomains).Count -ne 1 -or [string]$manifest.validDomains[0] -cne $expectedHost) {
    throw 'The Teams manifest valid domain does not match the deployed Function App.'
}

$bindings = [ordered]@{
    DEVICE_NOTIFICATION_TEAMS_TENANT_ID = $env:AZURE_TENANT_ID
    DEVICE_NOTIFICATION_TEAMS_USER_UPN = $UserUpn.ToLowerInvariant()
    DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID = $env:AZURE_WORKLOAD_CLIENT_ID
}
foreach ($entry in $bindings.GetEnumerator()) {
    $recorded = Get-AzdEnvironmentValue $entry.Key -Authoritative
    if ($recorded -and $recorded -cne $entry.Value) { throw "Recorded Teams binding $($entry.Key) does not match the requested deployment." }
}

if ($Plan) {
    Write-Host "[PLANNED] Publish the validated personal-scope package for workload $($env:AZURE_WORKLOAD_CLIENT_ID)."
    Write-Host "[PLANNED] Install the catalog app in personal scope for $UserUpn."
    return
}

if (-not (Get-Module Microsoft.Graph.Authentication -ListAvailable)) {
    throw 'Microsoft.Graph.Authentication is required. Install it before configuring the Teams app.'
}
Import-Module Microsoft.Graph.Authentication
$requiredScopes = @('AppCatalog.ReadWrite.All', 'TeamsAppInstallation.ReadWriteForUser')
Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -Scopes $requiredScopes -ContextScope Process -NoWelcome
$context = Get-MgContext
if (-not $context -or $context.TenantId -cne $env:AZURE_TENANT_ID) { throw 'Microsoft Graph is not connected to the expected tenant.' }
if ([string]$context.Account -cne $UserUpn) { throw "Microsoft Graph is connected as '$($context.Account)', not '$UserUpn'." }
foreach ($scope in $requiredScopes) {
    if ($scope -notin @($context.Scopes)) { throw "Microsoft Graph scope '$scope' was not granted." }
}

$encodedExternalId = [uri]::EscapeDataString("externalId eq '$($env:AZURE_WORKLOAD_CLIENT_ID)'")
$catalogResponse = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/appCatalogs/teamsApps?`$filter=$encodedExternalId&`$select=id,externalId,displayName,distributionMethod" -OutputType PSObject
$catalogApps = @($catalogResponse.value)
if ($catalogApps.Count -gt 1) { throw 'More than one Teams catalog app matches the deployed workload client ID.' }

$catalogOwnership = 'created'
if ($catalogApps.Count -eq 1) {
    if (-not $AdoptExisting) { throw 'The Teams catalog app already exists. Rerun with -AdoptExisting only after verifying that it belongs to this deployment.' }
    $catalogApp = $catalogApps[0]
    $catalogOwnership = 'adopted'
} else {
    foreach ($entry in $bindings.GetEnumerator()) { Set-AzdEnvironmentValue $entry.Key $entry.Value }
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP' 'create-pending'
    $catalogApp = Invoke-MgGraphRequest -Method POST -Uri '/v1.0/appCatalogs/teamsApps' -InputFilePath $resolvedPackage `
        -ContentType 'application/zip' -OutputType PSObject
    if (-not $catalogApp.id) { throw 'Microsoft Graph did not return the created Teams catalog app ID.' }
}
if ([string]$catalogApp.externalId -cne $env:AZURE_WORKLOAD_CLIENT_ID -or [string]$catalogApp.distributionMethod -cne 'organization') {
    throw 'The Teams catalog app does not match the expected workload identity and organization distribution method.'
}
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID' ([string]$catalogApp.id)
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP' $catalogOwnership

$encodedUpn = [uri]::EscapeDataString($UserUpn)
$installedResponse = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/$encodedUpn/teamwork/installedApps?`$expand=teamsApp" -OutputType PSObject
$matchingInstalls = @($installedResponse.value | Where-Object { [string]$_.teamsApp.externalId -ceq $env:AZURE_WORKLOAD_CLIENT_ID })
if ($matchingInstalls.Count -gt 1) { throw 'More than one personal installation matches the Teams app.' }

$installOwnership = 'created'
if ($matchingInstalls.Count -eq 1) {
    if (-not $AdoptExisting) { throw 'The Teams app is already installed for this user. Rerun with -AdoptExisting only after verifying the installation.' }
    $installation = $matchingInstalls[0]
    $installOwnership = 'adopted'
} else {
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP' 'create-pending'
    $body = @{ 'teamsApp@odata.bind' = "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$($catalogApp.id)" }
    Invoke-MgGraphRequest -Method POST -Uri "/v1.0/users/$encodedUpn/teamwork/installedApps" -Body $body -ContentType 'application/json' | Out-Null
    $installation = $null
    for ($attempt = 1; $attempt -le 12 -and -not $installation; $attempt++) {
        Start-Sleep -Seconds 5
        $installedResponse = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/$encodedUpn/teamwork/installedApps?`$expand=teamsApp" -OutputType PSObject
        $installation = @($installedResponse.value | Where-Object { [string]$_.teamsApp.externalId -ceq $env:AZURE_WORKLOAD_CLIENT_ID }) | Select-Object -First 1
    }
    if (-not $installation) { throw 'The personal Teams app installation was not visible after waiting for propagation.' }
}
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID' ([string]$installation.id)
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP' $installOwnership
foreach ($entry in $bindings.GetEnumerator()) { Set-AzdEnvironmentValue $entry.Key $entry.Value }

Write-Host "Teams catalog app '$($catalogApp.id)' is installed in personal scope for $UserUpn."
