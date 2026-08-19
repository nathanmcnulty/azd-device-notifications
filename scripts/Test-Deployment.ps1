[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
foreach ($name in @('AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME', 'AZURE_WORKLOAD_PRINCIPAL_ID')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required." }
}

$state = & az functionapp show --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME --query state -o tsv
if ($LASTEXITCODE -ne 0 -or $state -ne 'Running') { throw "Function App is not running (state: $state)." }

$graph = & az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'00000003-0000-0000-c000-000000000000'&`$select=appRoles" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($graph.value).Count -ne 1) { throw 'Unable to resolve Microsoft Graph application roles.' }
$requiredRoleIds = @($graph.value[0].appRoles | Where-Object { $_.value -in @('AuditLog.Read.All', 'DeviceManagementManagedDevices.Read.All') } | ForEach-Object id)
$assignments = & az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($requiredRoleIds | Where-Object { $_ -notin $assignments.value.appRoleId }).Count -gt 0) {
    throw 'The exact required Microsoft Graph app role assignments were not found.'
}

Write-Host 'Deployment validation passed. Install teams-app/device-notifications.zip for users who should receive Teams DMs.'
