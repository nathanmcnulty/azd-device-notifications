[CmdletBinding()]
param(
    [Alias('PlanOnly')]
    [switch] $Plan,

    [switch] $TestDelivery,

    [ValidateNotNullOrEmpty()]
    [ValidateSet('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant')]
    [string[]] $EventType = @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant'),

    [guid] $TestUserId,

    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string] $TestUserUpn,

    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string] $TestUserEmail,

    [string] $OutputPath = 'reports/deployment-validation.json',

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Plan -and $TestDelivery) {
    throw '-Plan and -TestDelivery are mutually exclusive.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$enginePath = Join-Path $PSScriptRoot 'vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1'
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    throw 'The deployment-validation component is missing. Synchronize it from azd-reference before validation.'
}

Import-Module $enginePath -Force
Import-Module (Join-Path $PSScriptRoot 'Deployment.Validation.psm1') -Force

$deliveryParameters = @{
    EventType = $EventType
}
if ($PSBoundParameters.ContainsKey('TestUserId')) { $deliveryParameters.TestUserId = $TestUserId }
if ($PSBoundParameters.ContainsKey('TestUserUpn')) { $deliveryParameters.TestUserUpn = $TestUserUpn }
if ($PSBoundParameters.ContainsKey('TestUserEmail')) { $deliveryParameters.TestUserEmail = $TestUserEmail }

$startedAt = [datetimeoffset]::UtcNow
$mode = if ($Plan) { 'plan' } elseif ($TestDelivery) { 'delivery' } else { 'verify' }
$definitions = @(Get-ProjectValidationDefinition -DeliveryParameters $deliveryParameters)
$checks = @(Invoke-AzdValidationSet -Definitions $definitions -Plan:$Plan -AllowSyntheticDelivery:$TestDelivery)
$report = New-AzdValidationReport `
    -TemplateName 'azd-device-notifications' `
    -TemplateVersion '0.1.0' `
    -Mode $mode `
    -StartedAt $startedAt `
    -Checks $checks `
    -Environment @{
        name = [string] $env:AZURE_ENV_NAME
        tenantId = [string] $env:AZURE_TENANT_ID
        subscriptionId = [string] $env:AZURE_SUBSCRIPTION_ID
        resourceGroup = [string] $env:AZURE_RESOURCE_GROUP
    } `
    -Requirements @{
        tools = @('az', 'azd')
        modules = @()
        permissions = @('Azure resource read access', 'Microsoft Graph application-role assignment read access')
    } `
    -NextSteps @(
        'Keep collection paused until every configured Teams and email route passes explicit delivery testing.',
        'After collection is enabled, confirm a real Graph-backed event on every selected route.'
    )

$writtenPath = Write-AzdValidationReport -Report $report -OutputPath $OutputPath -RepositoryRoot $repositoryRoot
Write-AzdValidationSummary -Report $report
Write-Host "Validation report: $writtenPath"
if ($PassThru) { $report }
Assert-AzdValidationSucceeded -Report $report
