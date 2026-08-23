[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME', 'AZURE_WORKLOAD_CLIENT_ID',
        'EMAIL_SENDER_UPN',
        'DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED', 'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP',
        'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP',
        'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME')) {
    [void](Get-AzdEnvironmentValue $name)
}
Assert-AzdTenantContext
if ($env:AZURE_RESOURCE_GROUP -and $env:AZURE_FUNCTION_APP_NAME) {
    $functionExists = & az functionapp show --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
        --name $env:AZURE_FUNCTION_APP_NAME --query name -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $functionExists -and $PSCmdlet.ShouldProcess($env:AZURE_FUNCTION_APP_NAME, 'Pause collection before tenant cleanup')) {
        & az functionapp config appsettings set --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
            --name $env:AZURE_FUNCTION_APP_NAME --settings DEVICE_NOTIFICATION_COLLECTION_ENABLED=false --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to pause collection before tenant cleanup.' }
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_COLLECTION_ENABLED' 'false'
    }
}
if ($env:DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED -ne 'true') {
    Write-Host 'No recorded Exchange Application RBAC configuration requires cleanup.'
    return
}
foreach ($name in @('DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP', 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP',
        'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP', 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Cleanup ownership state '$name' is missing. Refusing ambiguous tenant deletion." }
}
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) { throw 'ExchangeOnlineManagement is required for tenant cleanup.' }

Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ShowBanner:$false
try {
    $connections = @(Get-ConnectionInformation | Where-Object State -eq 'Connected')
    if (@($connections | Where-Object { [string]($_.TenantID) -eq $env:AZURE_TENANT_ID }).Count -eq 0) {
        throw "Exchange Online is not connected to expected tenant '$($env:AZURE_TENANT_ID)'."
    }
    $servicePrincipal = Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID -ErrorAction SilentlyContinue
    $assignment = Get-ManagementRoleAssignment -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME -ErrorAction SilentlyContinue
    if ($env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP -eq 'created' -and $assignment) {
        if (-not $servicePrincipal -or $assignment.Role -ne 'Application Mail.Send' -or
            $assignment.CustomResourceScope -ne $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME -or
            $assignment.App -ne $servicePrincipal.ObjectId) {
            throw "Recorded Exchange assignment '$($assignment.Name)' no longer matches the exact app, role, and scope. Refusing deletion."
        }
    }
    $scope = Get-ManagementScope -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME -ErrorAction SilentlyContinue
    if ($env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP -eq 'created' -and $scope) {
        $scopedRecipients = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter)
        if (-not $env:EMAIL_SENDER_UPN -or $scopedRecipients.Count -ne 1 -or
            $scopedRecipients[0].PrimarySmtpAddress.ToString() -ne $env:EMAIL_SENDER_UPN -or
            $scopedRecipients[0].RecipientTypeDetails -ne 'SharedMailbox') {
            throw "Recorded Exchange scope '$($scope.Name)' no longer resolves exclusively to the recorded shared mailbox. Refusing deletion."
        }
        $remaining = @(Get-ManagementRoleAssignment | Where-Object {
                $_.CustomResourceScope -eq $scope.Name -and
                (-not $assignment -or $_.Identity -ne $assignment.Identity -or $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP -ne 'created')
            })
        if ($remaining.Count -gt 0) { throw "Exchange scope '$($scope.Name)' is still referenced by $($remaining.Count) assignment(s); refusing deletion." }
    }
    if ($env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP -eq 'created' -and $assignment -and
        $PSCmdlet.ShouldProcess($assignment.Name, 'Remove solution-owned Exchange role assignment')) {
        Remove-ManagementRoleAssignment -Identity $assignment.Identity -Confirm:$false
    }
    if ($env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP -eq 'created' -and $scope) {
        if ($PSCmdlet.ShouldProcess($scope.Name, 'Remove solution-owned Exchange management scope')) {
            Remove-ManagementScope -Identity $scope.Identity -Confirm:$false
        }
    }
    if ($env:DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP -eq 'created' -and $servicePrincipal -and
        $PSCmdlet.ShouldProcess($env:AZURE_WORKLOAD_CLIENT_ID, 'Remove solution-owned Exchange service principal pointer')) {
        Remove-ServicePrincipal -Identity $servicePrincipal.Identity -Confirm:$false
    }
    if (-not $WhatIfPreference) {
        foreach ($name in @('DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED', 'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP',
                'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP',
                'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME')) {
            Set-AzdEnvironmentValue $name ''
        }
    }
    Write-Host 'Recorded solution-owned Exchange objects were removed; adopted objects were preserved.'
}
finally { Disconnect-ExchangeOnline -Confirm:$false }
