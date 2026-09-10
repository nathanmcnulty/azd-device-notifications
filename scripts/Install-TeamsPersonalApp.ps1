[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $AdminUpn,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][guid] $UserId,
    [string] $PackagePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'teams-app/device-notifications.zip'),
    [switch] $AdoptExisting,
    [switch] $UpdateExisting,
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
$stateNames = @(
    'DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN',
    'DEVICE_NOTIFICATION_TEAMS_TENANT_ID',
    'DEVICE_NOTIFICATION_TEAMS_USER_ID',
    'DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID',
    'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION',
    'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256',
    'DEVICE_NOTIFICATION_TEAMS_PACKAGE_HASH_FORMAT',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP',
    'DEVICE_NOTIFICATION_TEAMS_CATALOG_UPDATE_STATUS',
    'DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID',
    'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP'
)
foreach ($name in $stateNames) { [void](Get-AzdEnvironmentValue $name -Authoritative) }
Assert-AzdTenantContext
Get-AzdFunctionTarget | Out-Null

$resolvedPackage = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
$legacyPackageSha256 = (Get-FileHash -LiteralPath $resolvedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
$staging = Join-Path ([IO.Path]::GetTempPath()) "device-notifications-manifest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    Expand-Archive -LiteralPath $resolvedPackage -DestinationPath $staging -Force
    $manifestPath = Join-Path $staging 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The Teams package does not contain manifest.json.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
    $canonicalEntries = @(Get-ChildItem -LiteralPath $staging -File -Recurse | ForEach-Object {
            $relativePath = [IO.Path]::GetRelativePath($staging, $_.FullName).Replace('\', '/')
            $contentHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$relativePath`0$contentHash"
        } | Sort-Object)
    $canonicalBytes = [Text.Encoding]::UTF8.GetBytes(($canonicalEntries -join "`n"))
    $packageSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($canonicalBytes)).ToLowerInvariant()
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$packageVersionText = [string]$manifest.version
if ($packageVersionText -notmatch '^\d+\.\d+\.\d+$') { throw 'The Teams package version must use three-part numeric semantic versioning.' }
$packageVersion = [version]$packageVersionText
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
    DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN = $AdminUpn.ToLowerInvariant()
    DEVICE_NOTIFICATION_TEAMS_TENANT_ID = $env:AZURE_TENANT_ID
    DEVICE_NOTIFICATION_TEAMS_USER_ID = [string]$UserId
    DEVICE_NOTIFICATION_TEAMS_WORKLOAD_CLIENT_ID = $env:AZURE_WORKLOAD_CLIENT_ID
}
foreach ($entry in $bindings.GetEnumerator()) {
    $recorded = [Environment]::GetEnvironmentVariable($entry.Key)
    if ($recorded -and $recorded -ine $entry.Value) { throw "Recorded Teams binding $($entry.Key) does not match the requested deployment." }
}

if ($Plan) {
    Write-Host "[PLANNED] Authenticate as administrator $AdminUpn and target recipient object ID $UserId."
    Write-Host "[PLANNED] Publish or update personal-scope package version $packageVersionText (SHA-256 $packageSha256)."
    Write-Host "[PLANNED] Install the catalog app in personal scope for recipient $UserId; Teams availability remains administrator-owned."
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
if ([string]$context.Account -ine $AdminUpn) { throw "Microsoft Graph is connected as '$($context.Account)', not administrator '$AdminUpn'." }
foreach ($scope in $requiredScopes) {
    if ($scope -notin @($context.Scopes)) { throw "Microsoft Graph scope '$scope' was not granted." }
}

$encodedUserId = [uri]::EscapeDataString([string]$UserId)

function Set-TeamsBindings {
    foreach ($entry in $bindings.GetEnumerator()) { Set-AzdEnvironmentValue $entry.Key $entry.Value }
}

function Get-CatalogDefinitions([string] $CatalogAppId) {
    $uri = "/v1.0/appCatalogs/teamsApps/$CatalogAppId/appDefinitions?`$select=id,version,publishingState"
    $definitions = @()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        $definitions += @($response.value)
        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        $uri = if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { $null }
    } while ($uri)
    return @($definitions)
}

function Wait-CatalogDefinition([string] $CatalogAppId, [string] $Version) {
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $definition = @(Get-CatalogDefinitions $CatalogAppId | Where-Object { [string]$_.version -ceq $Version }) | Select-Object -First 1
        if ($definition -and [string]$definition.publishingState -ceq 'published') { return $definition }
        Start-Sleep -Seconds 5
    }
    throw "Teams catalog app version '$Version' was not visible as published after waiting for propagation."
}

function Get-MatchingInstallations {
    $encodedInstallFilter = [uri]::EscapeDataString("teamsApp/externalId eq '$($env:AZURE_WORKLOAD_CLIENT_ID)'")
    $uri = "/v1.0/users/$encodedUserId/teamwork/installedApps?`$filter=$encodedInstallFilter&`$expand=teamsApp,teamsAppDefinition"
    $matches = @()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        $matches += @($response.value)
        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        $uri = if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { $null }
    } while ($uri)
    return @($matches)
}

$encodedExternalId = [uri]::EscapeDataString("externalId eq '$($env:AZURE_WORKLOAD_CLIENT_ID)'")
$catalogResponse = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/appCatalogs/teamsApps?`$filter=$encodedExternalId&`$select=id,externalId,displayName,distributionMethod" -OutputType PSObject
$catalogApps = @($catalogResponse.value)
if ($catalogApps.Count -gt 1) { throw 'More than one Teams catalog app matches the deployed workload client ID.' }
$recordedPackageHashMatches = $env:DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256 -ceq $packageSha256 -or
    (-not $env:DEVICE_NOTIFICATION_TEAMS_PACKAGE_HASH_FORMAT -and
    $env:DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256 -ceq $legacyPackageSha256)

$catalogOwnership = 'created'
$catalogWasCreated = $false
if ($catalogApps.Count -eq 1) {
    $catalogApp = $catalogApps[0]
    $recordedCatalogIdMatches = -not $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID -or
        [string]$catalogApp.id -ceq $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID
    $recoverableCreate = $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -eq 'create-pending' -and
        $recordedCatalogIdMatches -and
        $env:DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION -ceq $packageVersionText -and
        $recordedPackageHashMatches
    $recordedCreated = $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -eq 'created' -and
        $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID -and $recordedCatalogIdMatches
    $recordedAdopted = $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -eq 'adopted' -and
        $env:DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID -and $recordedCatalogIdMatches
    if ($recoverableCreate -or $recordedCreated) {
        $catalogOwnership = 'created'
    } elseif ($recordedAdopted) {
        $catalogOwnership = 'adopted'
    } elseif ($AdoptExisting) {
        $catalogOwnership = 'adopted'
    } else {
        throw 'The Teams catalog app already exists without a matching creation receipt. Rerun with -AdoptExisting only after verifying that it belongs to this deployment.'
    }
} else {
    if ($env:DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP -in @('created', 'adopted')) {
        throw 'The recorded Teams catalog app no longer exists. Refusing to create a replacement over stale ownership state.'
    }
    Set-TeamsBindings
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION' $packageVersionText
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256' $packageSha256
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_HASH_FORMAT' 'canonical-content-v1'
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP' 'create-pending'
    $catalogApp = Invoke-MgGraphRequest -Method POST -Uri '/v1.0/appCatalogs/teamsApps' -InputFilePath $resolvedPackage `
        -ContentType 'application/zip' -OutputType PSObject
    if (-not $catalogApp.id) { throw 'Microsoft Graph did not return the created Teams catalog app ID.' }
    $catalogWasCreated = $true
}
if ([string]$catalogApp.externalId -cne $env:AZURE_WORKLOAD_CLIENT_ID -or [string]$catalogApp.distributionMethod -cne 'organization') {
    throw 'The Teams catalog app does not match the expected workload identity and organization distribution method.'
}
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_APP_ID' ([string]$catalogApp.id)
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_OWNERSHIP' $catalogOwnership
Set-TeamsBindings

$definitions = @(Get-CatalogDefinitions ([string]$catalogApp.id))
$newerDefinitions = @($definitions | Where-Object {
        [string]$_.version -match '^\d+\.\d+\.\d+$' -and [version]$_.version -gt $packageVersion
    })
if ($newerDefinitions.Count -gt 0) {
    throw "The Teams catalog contains newer version '$($newerDefinitions[0].version)'; refusing to install or downgrade to '$packageVersionText'."
}
$desiredDefinition = @($definitions | Where-Object { [string]$_.version -ceq $packageVersionText }) | Select-Object -First 1
$recordedVersion = $env:DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION
$recordedHash = $env:DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256
if ($desiredDefinition) {
    if ($recordedVersion -ceq $packageVersionText -and $recordedHash -and -not $recordedPackageHashMatches) {
        throw "Teams package version '$packageVersionText' has different bytes than the recorded deployment. Increment the manifest version before updating the catalog."
    }
    if ([string]$desiredDefinition.publishingState -cne 'published') {
        $desiredDefinition = Wait-CatalogDefinition ([string]$catalogApp.id) $packageVersionText
    }
} elseif ($catalogWasCreated) {
    $desiredDefinition = Wait-CatalogDefinition ([string]$catalogApp.id) $packageVersionText
} else {
    $newerOrEqual = @($definitions | Where-Object {
            [string]$_.version -match '^\d+\.\d+\.\d+$' -and [version]$_.version -ge $packageVersion
        })
    if ($newerOrEqual.Count -gt 0) {
        throw "The Teams catalog already contains version '$($newerOrEqual[0].version)', which is not older than requested version '$packageVersionText'."
    }
    if ($catalogOwnership -eq 'adopted' -and -not $UpdateExisting) {
        throw 'Updating an adopted Teams catalog app requires -UpdateExisting after verifying the new package and version.'
    }
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION' $packageVersionText
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256' $packageSha256
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_HASH_FORMAT' 'canonical-content-v1'
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_UPDATE_STATUS' 'update-pending'
    Invoke-MgGraphRequest -Method POST -Uri "/v1.0/appCatalogs/teamsApps/$($catalogApp.id)/appDefinitions" `
        -InputFilePath $resolvedPackage -ContentType 'application/zip' | Out-Null
    $desiredDefinition = Wait-CatalogDefinition ([string]$catalogApp.id) $packageVersionText
}
if (-not $desiredDefinition) { $desiredDefinition = Wait-CatalogDefinition ([string]$catalogApp.id) $packageVersionText }
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION' $packageVersionText
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256' $packageSha256
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_HASH_FORMAT' 'canonical-content-v1'

$matchingInstalls = @(Get-MatchingInstallations)
if ($matchingInstalls.Count -gt 1) { throw 'More than one personal installation matches the Teams app.' }

$installOwnership = 'created'
$installationWasCreated = $false
if ($matchingInstalls.Count -eq 1) {
    $installation = $matchingInstalls[0]
    $recordedInstallIdMatches = -not $env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID -or
        [string]$installation.id -ceq $env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID
    $recoverableInstall = $env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP -eq 'create-pending' -and $recordedInstallIdMatches
    $recordedInstall = $env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP -eq 'created' -and
        $env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID -and $recordedInstallIdMatches
    $recordedAdoptedInstall = $env:DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP -eq 'adopted' -and
        $env:DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID -and $recordedInstallIdMatches
    if ($recoverableInstall -or $recordedInstall) {
        $installOwnership = 'created'
    } elseif ($recordedAdoptedInstall) {
        $installOwnership = 'adopted'
    } elseif ($AdoptExisting) {
        $installOwnership = 'adopted'
    } else {
        throw 'The Teams app is already installed without a matching creation receipt. Rerun with -AdoptExisting only after verifying the installation.'
    }
} else {
    Set-TeamsBindings
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP' 'create-pending'
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID' ''
    $body = @{ 'teamsApp@odata.bind' = "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$($catalogApp.id)" }
    $installSubmitted = $false
    for ($attempt = 1; $attempt -le 18 -and -not $installSubmitted; $attempt++) {
        try {
            Invoke-MgGraphRequest -Method POST -Uri "/v1.0/users/$encodedUserId/teamwork/installedApps" `
                -Body $body -ContentType 'application/json' | Out-Null
            $installSubmitted = $true
        } catch {
            $message = $_.Exception.Message
            if ($message -match '\b409\b|Conflict|already installed') {
                $installSubmitted = $true
                continue
            }
            if ($message -notmatch 'blocked by app permission policy|app is blocked|not allowed.*app') { throw }
            if ($attempt -eq 18) {
                throw "Teams policy still blocks this personal installation. In Teams admin center, make app '$($env:AZURE_WORKLOAD_CLIENT_ID)' available to recipient object ID '$UserId'. For a legacy tenant, use a narrowly assigned app permission/setup policy; for app-centric management, assign the exact user or an administrator-owned group. Wait for policy propagation, then rerun this command."
            }
            Write-Host "Waiting for administrator-owned Teams app policy to propagate (attempt $attempt of 18)..."
            Start-Sleep -Seconds 10
        }
    }
    $installation = $null
    for ($attempt = 1; $attempt -le 12 -and -not $installation; $attempt++) {
        Start-Sleep -Seconds 5
        $installation = @(Get-MatchingInstallations) | Select-Object -First 1
    }
    if (-not $installation) { throw 'The personal Teams app installation was not visible after waiting for propagation.' }
    $installationWasCreated = $true
}
if (-not $installationWasCreated -and
    [string]$installation.teamsAppDefinition.version -cne $packageVersionText) {
    Invoke-MgGraphRequest -Method POST `
        -Uri "/v1.0/users/$encodedUserId/teamwork/installedApps/$($installation.id)/upgrade" | Out-Null
}
for ($attempt = 1; $attempt -le 12; $attempt++) {
    $verifiedInstallation = Invoke-MgGraphRequest -Method GET `
        -Uri "/v1.0/users/$encodedUserId/teamwork/installedApps/$($installation.id)?`$expand=teamsApp,teamsAppDefinition" `
        -OutputType PSObject
    if ([string]$verifiedInstallation.teamsApp.externalId -cne $env:AZURE_WORKLOAD_CLIENT_ID) {
        throw 'The personal Teams app installation no longer references the exact deployed app.'
    }
    if ([string]$verifiedInstallation.teamsAppDefinition.version -ceq $packageVersionText) { break }
    if ($attempt -eq 12) { throw "The personal Teams app installation did not reach version '$packageVersionText'." }
    Start-Sleep -Seconds 5
}
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALLATION_ID' ([string]$installation.id)
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_INSTALL_OWNERSHIP' $installOwnership
Set-TeamsBindings
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_TEAMS_CATALOG_UPDATE_STATUS' 'complete'

Write-Host "Teams catalog app '$($catalogApp.id)' version '$packageVersionText' is installed in personal scope for recipient $UserId. Teams availability remains controlled by the tenant administrator."
