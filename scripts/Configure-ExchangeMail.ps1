[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $SenderMailbox
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME', 'AZURE_WORKLOAD_CLIENT_ID', 'AZURE_WORKLOAD_PRINCIPAL_ID',
        'DEVICE_NOTIFICATION_COLLECTION_ENABLED')) {
    [void](Get-AzdEnvironmentValue $name)
}
if (-not $env:AZURE_WORKLOAD_CLIENT_ID -or -not $env:AZURE_WORKLOAD_PRINCIPAL_ID -or -not $env:AZURE_ENV_NAME) {
    throw 'Run this from an initialized azd environment after provisioning.'
}
Assert-AzdTenantContext
if ($env:DEVICE_NOTIFICATION_COLLECTION_ENABLED -eq 'true') { throw 'Pause notification collection before changing Exchange delivery authorization.' }
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    throw 'Install ExchangeOnlineManagement, then rerun this script.'
}

Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ShowBanner:$false
try {
    $connections = @(Get-ConnectionInformation | Where-Object State -eq 'Connected')
    if ($connections.Count -eq 0 -or @($connections | Where-Object { [string]($_.TenantID) -eq $env:AZURE_TENANT_ID }).Count -eq 0) {
        throw "Exchange Online is not connected to the expected tenant '$($env:AZURE_TENANT_ID)'. Refusing tenant mutation."
    }
    $safeEnvironment = [regex]::Replace($env:AZURE_ENV_NAME, '[^A-Za-z0-9-]', '-')
    if ($safeEnvironment.Length -gt 20) { $safeEnvironment = $safeEnvironment.Substring(0, 20) }
    $prefix = "DeviceNotifications-$safeEnvironment-$($env:AZURE_WORKLOAD_CLIENT_ID.Substring(0, 8))"
    $assignmentName = "$prefix-MailSend"
    $scopeName = "$prefix-Sender"

    $servicePrincipal = Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID -ErrorAction SilentlyContinue
    $servicePrincipalOwnership = if ($servicePrincipal) { 'adopted' } else { 'created' }
    if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($env:AZURE_WORKLOAD_CLIENT_ID, 'Create Exchange service principal pointer')) {
        New-ServicePrincipal -AppId $env:AZURE_WORKLOAD_CLIENT_ID -ObjectId $env:AZURE_WORKLOAD_PRINCIPAL_ID -DisplayName 'Device Notifications' | Out-Null
        $servicePrincipal = Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID
    }
    $escapedMailbox = $SenderMailbox.Replace("'", "''")
    $expectedFilter = "PrimarySmtpAddress -eq '$escapedMailbox'"
    $scope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
    $scopeOwnership = if ($scope) { 'adopted' } else { 'created' }
    if (-not $scope -and $PSCmdlet.ShouldProcess($SenderMailbox, 'Create mailbox-restricted management scope')) {
        New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $expectedFilter | Out-Null
        $scope = Get-ManagementScope -Identity $scopeName
    }
    if ($scope) {
        $scopedRecipients = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter)
        if ($scopedRecipients.Count -ne 1 -or $scopedRecipients[0].PrimarySmtpAddress.ToString() -ne $SenderMailbox -or
            $scopedRecipients[0].RecipientTypeDetails -ne 'SharedMailbox') {
            throw "Exchange management scope '$scopeName' must resolve exclusively to shared mailbox '$SenderMailbox'."
        }
    }
    $assignment = Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
    $assignmentOwnership = if ($assignment) { 'adopted' } else { 'created' }
    if ($assignment -and ($assignment.Role -ne 'Application Mail.Send' -or $assignment.CustomResourceScope -ne $scopeName -or $assignment.App -ne $servicePrincipal.ObjectId)) {
        throw "Existing Exchange role assignment '$assignmentName' does not match the requested app, role, and scope."
    }
    if (-not $assignment -and $PSCmdlet.ShouldProcess($SenderMailbox, 'Assign mailbox-scoped Application Mail.Send')) {
        New-ManagementRoleAssignment -Name $assignmentName -Role 'Application Mail.Send' -App $servicePrincipal.ObjectId -CustomResourceScope $scopeName | Out-Null
    }
    if ($WhatIfPreference) { return }
    $authorization = @(Test-ServicePrincipalAuthorization -Identity $servicePrincipal.Identity -Resource $SenderMailbox)
    $authorization | Format-Table
    if (-not ($authorization | Where-Object { $_.Role -eq 'Application Mail.Send' -and $_.InScope -eq $true })) {
        throw "Exchange did not report Application Mail.Send in scope for '$SenderMailbox'."
    }
    Set-AzdEnvironmentValue 'EMAIL_SENDER_UPN' $SenderMailbox
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP' $servicePrincipalOwnership
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP' $scopeOwnership
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP' $assignmentOwnership
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_SCOPE_NAME' $scopeName
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_NAME' $assignmentName
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED' 'true'
    Write-Host "Exchange Application RBAC configuration is verified for $SenderMailbox. Actual Graph enforcement can take 30 minutes to 2 hours; validate a real message before enabling collection."
}
finally { Disconnect-ExchangeOnline -Confirm:$false }
