[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string] $SenderMailbox,
    [string] $AssignmentName = 'DeviceNotifications-MailSend'
)

$ErrorActionPreference = 'Stop'
if (-not $env:AZURE_WORKLOAD_CLIENT_ID -or -not $env:AZURE_WORKLOAD_PRINCIPAL_ID) {
    throw 'Run this from an initialized azd environment after provisioning.'
}
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    throw 'Install ExchangeOnlineManagement, then rerun this script.'
}

Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ShowBanner:$false
try {
    $servicePrincipal = Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID -ErrorAction SilentlyContinue
    if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($env:AZURE_WORKLOAD_CLIENT_ID, 'Create Exchange service principal pointer')) {
        New-ServicePrincipal -AppId $env:AZURE_WORKLOAD_CLIENT_ID -ObjectId $env:AZURE_WORKLOAD_PRINCIPAL_ID -DisplayName 'Device Notifications' | Out-Null
        $servicePrincipal = Get-ServicePrincipal -Identity $env:AZURE_WORKLOAD_CLIENT_ID
    }
    $scopeName = "$AssignmentName-Sender"
    $escapedMailbox = $SenderMailbox.Replace("'", "''")
    $expectedFilter = "PrimarySmtpAddress -eq '$escapedMailbox'"
    $scope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
    if (-not $scope -and $PSCmdlet.ShouldProcess($SenderMailbox, 'Create mailbox-restricted management scope')) {
        New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $expectedFilter | Out-Null
        $scope = Get-ManagementScope -Identity $scopeName
    }
    if ($scope) {
        $scopedRecipients = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter)
        if ($scopedRecipients.Count -ne 1 -or $scopedRecipients[0].PrimarySmtpAddress.ToString() -ne $SenderMailbox) {
            throw "Existing Exchange management scope '$scopeName' does not resolve exclusively to '$SenderMailbox'. Refusing to reuse it."
        }
    }
    $assignment = Get-ManagementRoleAssignment -Identity $AssignmentName -ErrorAction SilentlyContinue
    if ($assignment -and ($assignment.Role -ne 'Application Mail.Send' -or $assignment.CustomResourceScope -ne $scopeName -or $assignment.App -ne $servicePrincipal.ObjectId)) {
        throw "Existing Exchange role assignment '$AssignmentName' does not match the requested app, role, and scope."
    }
    if (-not $assignment -and $PSCmdlet.ShouldProcess($SenderMailbox, 'Assign mailbox-scoped Application Mail.Send')) {
        New-ManagementRoleAssignment -Name $AssignmentName -Role 'Application Mail.Send' -App $servicePrincipal.ObjectId -CustomResourceScope $scopeName | Out-Null
    }
    if ($WhatIfPreference) { return }
    $authorization = @(Test-ServicePrincipalAuthorization -Identity $servicePrincipal.Identity -Resource $SenderMailbox)
    $authorization | Format-Table
    if (-not ($authorization | Where-Object { $_.Role -eq 'Application Mail.Send' -and $_.InScope -eq $true })) {
        throw "Exchange did not report Application Mail.Send in scope for '$SenderMailbox'."
    }
    & azd env set EMAIL_SENDER_UPN $SenderMailbox | Out-Null
    Write-Host "Exchange Application RBAC configured for $SenderMailbox. Run 'azd provision' to apply EMAIL_SENDER_UPN to the Function App."
}
finally { Disconnect-ExchangeOnline -Confirm:$false }
