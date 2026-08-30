[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force

Assert-AzdTenantContext
$expectedResourceGroup = Assert-AzdResourceGroupTarget -AllowDerived
$existsText = ([string](& az group exists --subscription $env:AZURE_SUBSCRIPTION_ID --name $expectedResourceGroup `
        --only-show-errors --output tsv)).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $existsText -notin @('true', 'false')) {
    throw "Unable to verify deletion of exact resource group '$expectedResourceGroup'."
}
if ($existsText -eq 'true') {
    throw "Exact resource group '$expectedResourceGroup' still exists after azd down. Ownership receipts were retained."
}

Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME' ''
Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP' ''
Write-Host "Verified exact resource group '$expectedResourceGroup' is absent after azd down."
