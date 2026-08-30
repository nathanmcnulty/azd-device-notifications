[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME')) {
    [void](Get-AzdEnvironmentValue $name)
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required to deploy the Function package." }
}
Assert-AzdTenantContext

$packageRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'function-package'
$requiredFiles = @(
    'host.json',
    'index.cjs',
    'index.cjs.LEGAL.txt',
    'package.json',
    'THIRD-PARTY-NOTICES.txt',
    'UNLICENSE.txt'
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $file) -PathType Leaf)) {
        throw "The repository deployment artifact is incomplete: function-package/$file is missing."
    }
}

$archivePath = Join-Path $packageRoot 'device-notifications.zip'
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
Compress-Archive -Path ($requiredFiles | ForEach-Object { Join-Path $packageRoot $_ }) -DestinationPath $archivePath -CompressionLevel Optimal

Write-Host 'Deploying the reviewed Function package included with this repository (remote build disabled)...'
& az functionapp deployment source config-zip --subscription $env:AZURE_SUBSCRIPTION_ID `
    --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME `
    --src $archivePath --build-remote false --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Azure Function package deployment failed.' }
