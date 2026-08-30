[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Exchange.Management.psm1') -Force
$stateNames = @(
    'DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS',
    'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN',
    'DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID',
    'DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN',
    'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID',
    'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID',
    'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP',
    'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP',
    'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP',
    'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME',
    'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME'
)
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME', 'AZURE_RESOURCE_GROUP',
        'AZURE_FUNCTION_APP_NAME', 'AZURE_WORKLOAD_CLIENT_ID', 'AZURE_WORKLOAD_PRINCIPAL_ID', 'EMAIL_SENDER_UPN',
        'DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED') + $stateNames) {
    [void](Get-AzdEnvironmentValue $name)
}
Assert-AzdTenantContext
$functionTarget = Get-AzdFunctionTarget -AllowMissing

if ($functionTarget) {
    if ($PSCmdlet.ShouldProcess($env:AZURE_FUNCTION_APP_NAME, 'Pause collection before tenant cleanup')) {
        & az functionapp config appsettings set --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $env:AZURE_RESOURCE_GROUP `
            --name $env:AZURE_FUNCTION_APP_NAME --settings DEVICE_NOTIFICATION_COLLECTION_ENABLED=false --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to pause collection before tenant cleanup.' }
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_COLLECTION_ENABLED' 'false'
    }
}

$ownershipValues = @(
    $env:DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP,
    $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP,
    $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP
)
$hasOwnershipState = $env:DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS -or
    $env:DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED -eq 'true' -or
    @($ownershipValues | Where-Object { $_ }).Count -gt 0
if (-not $hasOwnershipState) {
    Write-Host 'No recorded Exchange Application RBAC intent requires cleanup.'
    return
}

foreach ($name in @('DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN', 'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID',
        'DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID', 'DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN',
        'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID', 'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP',
        'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP',
        'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME', 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Cleanup ownership state '$name' is missing. Refusing ambiguous tenant deletion." }
}
Assert-RecordedExchangeBinding `
    -RecordedClientId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID `
    -RecordedPrincipalId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID `
    -RecordedAdminUpn $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN `
    -RecordedTenantId $env:DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID `
    -RecordedSenderMailbox $env:DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN `
    -ExpectedClientId $(if ($env:AZURE_WORKLOAD_CLIENT_ID) { $env:AZURE_WORKLOAD_CLIENT_ID } else { $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID }) `
    -ExpectedPrincipalId $(if ($env:AZURE_WORKLOAD_PRINCIPAL_ID) { $env:AZURE_WORKLOAD_PRINCIPAL_ID } else { $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID }) `
    -ExpectedAdminUpn $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN `
    -ExpectedTenantId $env:AZURE_TENANT_ID `
    -ExpectedSenderMailbox $(if ($env:EMAIL_SENDER_UPN) { $env:EMAIL_SENDER_UPN } else { $env:DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN }) `
    -RequireRecorded
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) { throw 'ExchangeOnlineManagement is required for tenant cleanup.' }

$removeAssignment = Test-ExchangeOwnershipRemovable $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP
$removeScope = Test-ExchangeOwnershipRemovable $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP
$removeServicePrincipal = Test-ExchangeOwnershipRemovable $env:DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP

Import-Module ExchangeOnlineManagement
try {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Connect-ExchangeOnline -UserPrincipalName $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN -ShowBanner:$false
    Assert-ExactExchangeConnection -Connections @(Get-ConnectionInformation) `
        -ExpectedTenantId $env:AZURE_TENANT_ID -ExpectedAdminUpn $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN | Out-Null

    $servicePrincipals = @(Get-ServicePrincipal -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID -ErrorAction SilentlyContinue)
    if ($servicePrincipals.Count -gt 1) { throw 'More than one Exchange service-principal pointer matched the recorded workload client ID.' }
    $servicePrincipal = if ($servicePrincipals.Count -eq 1) { $servicePrincipals[0] } else { $null }
    if ($servicePrincipal) {
        Assert-ExchangeServicePrincipalExact -ServicePrincipal $servicePrincipal `
            -ExpectedClientId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID `
            -ExpectedPrincipalId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID
    }

    $assignment = Get-ManagementRoleAssignment -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME -ErrorAction SilentlyContinue
    if ($assignment) {
        Assert-ExchangeAssignmentExact -Assignment $assignment `
            -ExpectedAssignmentName $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME `
            -ExpectedScopeName $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME `
            -ExpectedPrincipalId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID
    }

    $scope = Get-ManagementScope -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME -ErrorAction SilentlyContinue
    if ($scope) {
        $scopedRecipients = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter)
        Assert-ExchangeScopeExact -Scope $scope -ScopedRecipients $scopedRecipients `
            -ExpectedScopeName $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME `
            -ExpectedSenderMailbox $env:DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN
    }

    if ($removeAssignment -and $assignment -and
        $PSCmdlet.ShouldProcess($assignment.Name, 'Remove solution-owned Exchange role assignment')) {
        Remove-ManagementRoleAssignment -Identity $assignment.Identity -Confirm:$false
        Wait-ExchangeObjectAbsent -ObjectDescription "Exchange role assignment '$($assignment.Name)'" `
            -Lookup { Get-ManagementRoleAssignment -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME -ErrorAction SilentlyContinue }
        $assignment = $null
    }

    if ($removeScope -and $scope) {
        $remaining = @(Get-ManagementRoleAssignment | Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.CustomResourceScope, [string]$scope.Name) -and
                (-not $removeAssignment -or -not $assignment -or $_.Identity -ne $assignment.Identity)
            })
        if ($remaining.Count -gt 0) { throw "Exchange scope '$($scope.Name)' is still referenced by $($remaining.Count) assignment(s); refusing deletion." }
        if ($PSCmdlet.ShouldProcess($scope.Name, 'Remove solution-owned Exchange management scope')) {
            Remove-ManagementScope -Identity $scope.Identity -Confirm:$false
            Wait-ExchangeObjectAbsent -ObjectDescription "Exchange management scope '$($scope.Name)'" `
                -Lookup { Get-ManagementScope -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME -ErrorAction SilentlyContinue }
            $scope = $null
        }
    }

    if ($removeServicePrincipal -and $servicePrincipal) {
        $remaining = @(Get-ManagementRoleAssignment | Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.App, $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID) -and
                (-not $removeAssignment -or -not $assignment -or $_.Identity -ne $assignment.Identity)
            })
        if ($remaining.Count -gt 0) { throw "The Exchange service-principal pointer is still referenced by $($remaining.Count) assignment(s); refusing deletion." }
        if ($PSCmdlet.ShouldProcess($env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID, 'Remove solution-owned Exchange service principal pointer')) {
            Remove-ServicePrincipal -Identity $servicePrincipal.Identity -Confirm:$false
            Wait-ExchangeObjectAbsent -ObjectDescription 'Exchange service-principal pointer' `
                -Lookup { Get-ServicePrincipal -Identity $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID -ErrorAction SilentlyContinue }
            $servicePrincipal = $null
        }
    }

    if (-not $WhatIfPreference) {
        foreach ($name in @('DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED') + $stateNames) {
            Set-AzdEnvironmentValue $name ''
        }
    }
    Write-Host 'Recorded solution-owned Exchange objects were removed and verified absent; adopted objects were preserved.'
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
