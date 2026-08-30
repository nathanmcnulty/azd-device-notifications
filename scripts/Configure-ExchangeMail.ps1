[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $SenderMailbox,
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $AdminUpn,
    [switch] $AdoptExisting
)

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
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME', 'AZURE_WORKLOAD_CLIENT_ID',
        'AZURE_WORKLOAD_PRINCIPAL_ID', 'DEVICE_NOTIFICATION_COLLECTION_ENABLED') + $stateNames) {
    [void](Get-AzdEnvironmentValue $name)
}
if (-not $env:AZURE_WORKLOAD_CLIENT_ID -or -not $env:AZURE_WORKLOAD_PRINCIPAL_ID -or -not $env:AZURE_ENV_NAME) {
    throw 'Run this from an initialized azd environment after provisioning.'
}
Assert-AzdTenantContext
Get-AzdFunctionTarget | Out-Null
if ($env:DEVICE_NOTIFICATION_COLLECTION_ENABLED -eq 'true') { throw 'Pause notification collection before changing Exchange delivery authorization.' }
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    throw 'Install ExchangeOnlineManagement, then rerun this script.'
}

Assert-RecordedExchangeBinding `
    -RecordedClientId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID `
    -RecordedPrincipalId $env:DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID `
    -RecordedAdminUpn $env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN `
    -RecordedTenantId $env:DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID `
    -RecordedSenderMailbox $env:DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN `
    -ExpectedClientId $env:AZURE_WORKLOAD_CLIENT_ID `
    -ExpectedPrincipalId $env:AZURE_WORKLOAD_PRINCIPAL_ID `
    -ExpectedAdminUpn $AdminUpn -ExpectedTenantId $env:AZURE_TENANT_ID -ExpectedSenderMailbox $SenderMailbox

$safeEnvironment = [regex]::Replace($env:AZURE_ENV_NAME, '[^A-Za-z0-9-]', '-')
if ($safeEnvironment.Length -gt 20) { $safeEnvironment = $safeEnvironment.Substring(0, 20) }
$prefix = "DeviceNotifications-$safeEnvironment-$($env:AZURE_WORKLOAD_CLIENT_ID.Substring(0, 8))"
$assignmentName = "$prefix-MailSend"
$scopeName = "$prefix-Sender"
foreach ($binding in @(
        @{ Name = 'scope name'; Recorded = $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME; Expected = $scopeName },
        @{ Name = 'assignment name'; Recorded = $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME; Expected = $assignmentName }
    )) {
    if ($binding.Recorded -and -not [System.StringComparer]::OrdinalIgnoreCase.Equals($binding.Recorded, $binding.Expected)) {
        throw "Recorded Exchange $($binding.Name) '$($binding.Recorded)' does not match '$($binding.Expected)'."
    }
}

Import-Module ExchangeOnlineManagement
try {
    Connect-AzdExchangeOnline -ExpectedTenantId $env:AZURE_TENANT_ID -ExpectedAdminUpn $AdminUpn | Out-Null

    $servicePrincipals = @(Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID -ErrorAction SilentlyContinue)
    if ($servicePrincipals.Count -gt 1) { throw 'More than one Exchange service-principal pointer matched the exact workload client ID.' }
    $servicePrincipal = if ($servicePrincipals.Count -eq 1) { $servicePrincipals[0] } else { $null }
    if ($servicePrincipal) {
        Assert-ExchangeServicePrincipalExact -ServicePrincipal $servicePrincipal `
            -ExpectedClientId $env:AZURE_WORKLOAD_CLIENT_ID -ExpectedPrincipalId $env:AZURE_WORKLOAD_PRINCIPAL_ID
    }

    $scope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
    if ($scope) {
        $scopedRecipients = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter)
        Assert-ExchangeScopeExact -Scope $scope -ScopedRecipients $scopedRecipients `
            -ExpectedScopeName $scopeName -ExpectedSenderMailbox $SenderMailbox
    }

    $assignment = Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
    if ($assignment) {
        Assert-ExchangeAssignmentExact -Assignment $assignment -ExpectedAssignmentName $assignmentName `
            -ExpectedScopeName $scopeName -ExpectedPrincipalId $env:AZURE_WORKLOAD_PRINCIPAL_ID
    }

    $servicePrincipalOwnership = Resolve-ExchangeObjectOwnership -Exists ([bool]$servicePrincipal) `
        -RecordedOwnership $env:DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP `
        -AdoptExisting:$AdoptExisting -ObjectDescription 'Exchange service-principal pointer'
    $scopeOwnership = Resolve-ExchangeObjectOwnership -Exists ([bool]$scope) `
        -RecordedOwnership $env:DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP `
        -AdoptExisting:$AdoptExisting -ObjectDescription "Exchange management scope '$scopeName'"
    $assignmentOwnership = Resolve-ExchangeObjectOwnership -Exists ([bool]$assignment) `
        -RecordedOwnership $env:DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP `
        -AdoptExisting:$AdoptExisting -ObjectDescription "Exchange role assignment '$assignmentName'"

    if ($WhatIfPreference) {
        if (-not $servicePrincipal) { [void]$PSCmdlet.ShouldProcess($env:AZURE_WORKLOAD_CLIENT_ID, 'Create Exchange service principal pointer') }
        if (-not $scope) { [void]$PSCmdlet.ShouldProcess($SenderMailbox, 'Create mailbox-restricted management scope') }
        if (-not $assignment) { [void]$PSCmdlet.ShouldProcess($SenderMailbox, 'Assign mailbox-scoped Application Mail.Send') }
        return
    }

    # Persist the exact target and all planned ownership before the first tenant mutation.
    Set-AzdEnvironmentValue 'EMAIL_SENDER_UPN' $SenderMailbox
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN' $AdminUpn
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_TENANT_ID' $env:AZURE_TENANT_ID
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SENDER_UPN' $SenderMailbox
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_CLIENT_ID' $env:AZURE_WORKLOAD_CLIENT_ID
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_WORKLOAD_PRINCIPAL_ID' $env:AZURE_WORKLOAD_PRINCIPAL_ID
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME' $scopeName
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME' $assignmentName
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP' $servicePrincipalOwnership
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP' $scopeOwnership
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP' $assignmentOwnership
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS' 'pending'

    if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($env:AZURE_WORKLOAD_CLIENT_ID, 'Create Exchange service principal pointer')) {
        New-ServicePrincipal -AppId $env:AZURE_WORKLOAD_CLIENT_ID -ObjectId $env:AZURE_WORKLOAD_PRINCIPAL_ID -DisplayName 'Device Notifications' | Out-Null
        $servicePrincipals = @(Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID)
        if ($servicePrincipals.Count -ne 1) { throw 'The created Exchange service-principal pointer could not be resolved exactly once.' }
        $servicePrincipal = $servicePrincipals[0]
        Assert-ExchangeServicePrincipalExact -ServicePrincipal $servicePrincipal `
            -ExpectedClientId $env:AZURE_WORKLOAD_CLIENT_ID -ExpectedPrincipalId $env:AZURE_WORKLOAD_PRINCIPAL_ID
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP' 'created'
    }
    if (-not $servicePrincipal) { throw 'The exact Exchange service-principal pointer is unavailable.' }

    $escapedMailbox = $SenderMailbox.Replace("'", "''")
    $expectedFilter = "PrimarySmtpAddress -eq '$escapedMailbox'"
    if (-not $scope -and $PSCmdlet.ShouldProcess($SenderMailbox, 'Create mailbox-restricted management scope')) {
        New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $expectedFilter | Out-Null
        $scope = Get-ManagementScope -Identity $scopeName
        if (-not $scope) { throw "The created Exchange management scope '$scopeName' could not be resolved." }
        $scopedRecipients = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter)
        Assert-ExchangeScopeExact -Scope $scope -ScopedRecipients $scopedRecipients `
            -ExpectedScopeName $scopeName -ExpectedSenderMailbox $SenderMailbox
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP' 'created'
    }
    if (-not $scope) { throw "The exact Exchange management scope '$scopeName' is unavailable." }

    if (-not $assignment -and $PSCmdlet.ShouldProcess($SenderMailbox, 'Assign mailbox-scoped Application Mail.Send')) {
        New-ManagementRoleAssignment -Name $assignmentName -Role 'Application Mail.Send' `
            -App $servicePrincipal.ObjectId -CustomResourceScope $scopeName | Out-Null
        $assignment = Get-ManagementRoleAssignment -Identity $assignmentName
        if (-not $assignment) { throw "The created Exchange role assignment '$assignmentName' could not be resolved." }
        Assert-ExchangeAssignmentExact -Assignment $assignment -ExpectedAssignmentName $assignmentName `
            -ExpectedScopeName $scopeName -ExpectedPrincipalId $env:AZURE_WORKLOAD_PRINCIPAL_ID
        Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP' 'created'
    }
    if (-not $assignment) { throw "The exact Exchange role assignment '$assignmentName' is unavailable." }

    $authorization = @(Test-ServicePrincipalAuthorization -Identity $servicePrincipal.Identity -Resource $SenderMailbox)
    $authorization | Format-Table
    if (-not ($authorization | Where-Object { $_.Role -eq 'Application Mail.Send' -and $_.InScope -eq $true })) {
        throw "Exchange did not report Application Mail.Send in scope for '$SenderMailbox'."
    }
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED' 'true'
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS' 'complete'
    Write-Host "Exchange Application RBAC configuration is verified for $SenderMailbox. Actual Graph enforcement can take 30 minutes to 2 hours; validate a real message before enabling collection."
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
