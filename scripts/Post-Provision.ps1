[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Assert-AzdTenantContext

foreach ($name in @('AZURE_WORKLOAD_PRINCIPAL_ID', 'AZURE_WORKLOAD_CLIENT_ID', 'AZURE_FUNCTION_APP_URL')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name was not returned by provisioning." }
}

function Invoke-GraphJson {
    param([Parameter(Mandatory)][string] $Method, [Parameter(Mandatory)][string] $Uri, [object] $Body)
    $arguments = @('rest', '--method', $Method, '--url', "https://graph.microsoft.com/v1.0$Uri", '--headers', 'Content-Type=application/json')
    if ($null -ne $Body) { $arguments += @('--body', ($Body | ConvertTo-Json -Depth 10 -Compress)) }
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $result = & az @arguments 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($result) { return ($result -join "`n") | ConvertFrom-Json }
            return
        }
        if ($attempt -lt 5) { Start-Sleep -Seconds ([Math]::Min([Math]::Pow(2, $attempt), 15)) }
    }
    throw "Microsoft Graph request failed after retries: $Method $Uri"
}

$graph = Invoke-GraphJson -Method GET -Uri "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles"
if ($graph.value.Count -ne 1) { throw 'Unable to resolve the Microsoft Graph service principal.' }
$graphServicePrincipal = $graph.value[0]
$existing = Invoke-GraphJson -Method GET -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments"
$routing = $env:DEVICE_NOTIFICATION_ROUTING_JSON | ConvertFrom-Json
$permissions = [System.Collections.Generic.List[string]]::new()
$permissions.Add('AuditLog.Read.All')
$permissions.Add('DeviceManagementManagedDevices.Read.All')
if (@($routing.monitoredGroupIds).Count -gt 0) {
    $permissions.Add('User.ReadBasic.All')
    $permissions.Add('GroupMember.Read.All')
}

foreach ($permission in $permissions) {
    $role = @($graphServicePrincipal.appRoles | Where-Object { $_.value -eq $permission -and $_.allowedMemberTypes -contains 'Application' })
    if ($role.Count -ne 1) { throw "Unable to resolve Microsoft Graph application role '$permission'." }
    if ($existing.value.appRoleId -contains $role[0].id) {
        Write-Host "Microsoft Graph permission already assigned: $permission"
        continue
    }
    Invoke-GraphJson -Method POST -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments" -Body @{
        principalId = $env:AZURE_WORKLOAD_PRINCIPAL_ID
        resourceId = $graphServicePrincipal.id
        appRoleId = $role[0].id
    } | Out-Null
    Write-Host "Assigned Microsoft Graph permission: $permission"
}

foreach ($permission in @('User.ReadBasic.All', 'GroupMember.Read.All')) {
    if ($permissions -contains $permission) { continue }
    $role = @($graphServicePrincipal.appRoles | Where-Object { $_.value -eq $permission -and $_.allowedMemberTypes -contains 'Application' })
    $assignment = @($existing.value | Where-Object { $_.appRoleId -eq $role[0].id })
    foreach ($item in $assignment) {
        Invoke-GraphJson -Method DELETE -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments/$($item.id)" | Out-Null
        Write-Host "Removed unneeded Microsoft Graph permission: $permission"
    }
}

& (Join-Path $PSScriptRoot 'New-TeamsAppPackage.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Teams app package generation failed.' }

Write-Host 'Provisioning completed. Mail.Send was intentionally not granted; run Configure-ExchangeMail.ps1 only when email routing is enabled.'
