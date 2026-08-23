Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Configuration.Validation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Graph.Management.psm1') -Force

$script:EnvironmentNames = @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_TENANT_ID',
    'AZURE_RESOURCE_GROUP',
    'AZURE_FUNCTION_APP_NAME',
    'AZURE_FUNCTION_APP_URL',
    'AZURE_WORKLOAD_PRINCIPAL_ID',
    'AZURE_WORKLOAD_CLIENT_ID',
    'TEAMS_BOT_NAME',
    'DEVICE_NOTIFICATION_ROUTING_JSON',
    'TEAMS_ADMIN_WEBHOOK_URL',
    'ADMIN_EMAIL_RECIPIENTS',
    'EMAIL_SENDER_UPN',
    'ENTRA_POLL_SCHEDULE',
    'INTUNE_POLL_SCHEDULE',
    'ENROLLMENT_LOOKBACK_HOURS',
    'ENTRA_AUDIT_OVERLAP_MINUTES',
    'DEVICE_NOTIFICATION_COLLECTION_ENABLED',
    'DEVICE_NOTIFICATION_ONBOARDING_STATUS'
)

$script:RequiredEnvironmentNames = @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_TENANT_ID',
    'AZURE_RESOURCE_GROUP',
    'AZURE_FUNCTION_APP_NAME',
    'AZURE_FUNCTION_APP_URL',
    'AZURE_WORKLOAD_PRINCIPAL_ID',
    'AZURE_WORKLOAD_CLIENT_ID',
    'TEAMS_BOT_NAME'
)

$script:ValidationContextReady = $false
$script:DeliveryScriptPath = $null
$script:DeliveryParameters = @{}

function New-DeviceNotificationValidationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][A-Za-z0-9.]+$')]
        [string] $Code,

        [Parameter(Mandatory)]
        [string] $Summary,

        [Parameter(Mandatory)]
        [string] $Remediation,

        [AllowNull()]
        [object] $Expected,

        [hashtable] $Details = @{}
    )

    $actual = [ordered] @{ failureCode = $Code }
    foreach ($name in $Details.Keys) {
        $actual[[string] $name] = $Details[$name]
    }
    New-AzdCheckOutcome -Status fail -Summary $Summary -Expected $Expected `
        -Actual $actual -Remediation $Remediation
}

function Get-DeviceNotificationContextFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CheckName)

    if ($script:ValidationContextReady) { return $null }
    New-DeviceNotificationValidationFailure -Code 'context.prerequisite' `
        -Summary "$CheckName was not attempted because exact tenant and subscription validation did not pass." `
        -Expected 'A validated azd and Azure CLI context.' `
        -Remediation 'Correct the context.azure-session failure and rerun validation.'
}

function Resolve-DeviceNotificationContextFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    $message = [string] $ErrorRecord.Exception.Message
    foreach ($name in $script:RequiredEnvironmentNames) {
        if ($message -eq "$name is required.") {
            return New-DeviceNotificationValidationFailure -Code 'context.requiredValueMissing' `
                -Summary "The required azd environment value $name is missing." `
                -Expected 'All required deployment outputs are available.' `
                -Remediation 'Confirm provisioning completed and the expected azd environment is selected.' `
                -Details @{ environmentValueName = $name }
        }
    }
    if ($message -like 'Tenant context mismatch.*') {
        return New-DeviceNotificationValidationFailure -Code 'context.tenantMismatch' `
            -Summary 'The azd, subscription, and active Azure CLI tenants do not match.' `
            -Expected 'One exact tenant across azd and Azure CLI.' `
            -Remediation 'Sign in through the normal broker or browser flow for the expected tenant and rerun validation.'
    }
    if ($message -like 'Azure subscription mismatch.*') {
        return New-DeviceNotificationValidationFailure -Code 'context.subscriptionMismatch' `
            -Summary 'The active Azure CLI subscription does not match the azd environment.' `
            -Expected 'The azd subscription is active in Azure CLI.' `
            -Remediation 'Select the expected subscription with az account set and rerun validation.'
    }
    New-DeviceNotificationValidationFailure -Code 'context.sessionUnavailable' `
        -Summary 'The cached Azure CLI context could not be validated.' `
        -Expected 'A usable cached Azure CLI session for the azd tenant and subscription.' `
        -Remediation 'Use az login through the normal broker or browser flow, select the expected subscription, and rerun validation.'
}

function Initialize-DeviceNotificationValidationContext {
    [CmdletBinding()]
    param()

    foreach ($name in $script:EnvironmentNames) {
        [void] (Get-AzdEnvironmentValue $name)
    }
    foreach ($name in $script:RequiredEnvironmentNames) {
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            throw "$name is required."
        }
    }
    Assert-AzdTenantContext
}

function Get-DeviceNotificationValidationConfiguration {
    [CmdletBinding()]
    param()

    Get-NotificationConfiguration -RoutingJson $env:DEVICE_NOTIFICATION_ROUTING_JSON `
        -TeamsWebhookUrl $env:TEAMS_ADMIN_WEBHOOK_URL `
        -AdminEmailRecipients $env:ADMIN_EMAIL_RECIPIENTS `
        -EmailSenderUpn $env:EMAIL_SENDER_UPN `
        -EntraPollSchedule $env:ENTRA_POLL_SCHEDULE `
        -IntunePollSchedule $env:INTUNE_POLL_SCHEDULE `
        -EnrollmentLookbackHours $env:ENROLLMENT_LOOKBACK_HOURS `
        -AuditOverlapMinutes $env:ENTRA_AUDIT_OVERLAP_MINUTES
}

function Get-ProjectValidationDefinition {
    [CmdletBinding()]
    param([hashtable] $DeliveryParameters = @{})

    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:DeliveryScriptPath = Join-Path $PSScriptRoot 'Test-NotificationDelivery.ps1'
    $script:DeliveryParameters = $DeliveryParameters.Clone()

    New-AzdValidationCheckDefinition `
        -Id 'context.template-root' `
        -Phase context `
        -Title 'Template root is complete' `
        -Summary 'azure.yaml exists at the repository root.' `
        -SideEffect none `
        -Action ({
            if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'azure.yaml') -PathType Leaf)) {
                throw 'azure.yaml was not found.'
            }
        }.GetNewClosure())

    New-AzdValidationCheckDefinition `
        -Id 'context.azure-session' `
        -Phase context `
        -Title 'Azure and azd context is exact' `
        -Summary 'The cached Azure CLI session matches the tenant and subscription selected by azd.' `
        -SideEffect readOnly `
        -Remediation 'Use az login through the normal broker or browser flow, select the expected subscription, and rerun validation.' `
        -Action {
            $script:ValidationContextReady = $false
            try {
                Initialize-DeviceNotificationValidationContext
                $script:ValidationContextReady = $true
                New-AzdCheckOutcome -Summary 'The cached Azure CLI session matches the azd tenant and subscription.' `
                    -Expected 'One exact tenant and subscription.' -Actual 'Validated'
            }
            catch {
                Resolve-DeviceNotificationContextFailure -ErrorRecord $_
            }
        }

    New-AzdValidationCheckDefinition `
        -Id 'configuration.notification-routing' `
        -Phase configuration `
        -Title 'Notification routing is valid' `
        -Summary 'Notification routes, destinations, polling schedules, and numeric bounds are internally consistent.' `
        -SideEffect none `
        -Remediation 'Correct the azd environment values identified by the configuration documentation and rerun validation.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Notification routing validation'
            if ($prerequisite) { return $prerequisite }
            try {
                $configuration = Get-DeviceNotificationValidationConfiguration
                New-AzdCheckOutcome -Summary 'Notification routing configuration is valid.' `
                    -Expected 'At least one valid route with consistent destinations and schedules.' `
                    -Actual ([ordered] @{ enabledRouteCount = [int] $configuration.EnabledRouteCount })
            }
            catch {
                New-DeviceNotificationValidationFailure -Code 'configuration.invalid' `
                    -Summary 'Notification routing configuration is invalid.' `
                    -Expected 'Consistent routes, destinations, schedules, and numeric bounds.' `
                    -Remediation 'Review docs/configuration.md, correct the azd environment values, and rerun validation.'
            }
        }

    New-AzdValidationCheckDefinition `
        -Id 'runtime.function-app' `
        -Phase runtime `
        -Title 'Function App is running' `
        -Summary 'The deployed notification Function App is running.' `
        -SideEffect readOnly `
        -Expected 'Running' `
        -Remediation 'Inspect the Function App deployment and runtime logs, then rerun validation.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Function App runtime validation'
            if ($prerequisite) { return $prerequisite }
            $state = & az functionapp show --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME `
                --query state --only-show-errors --output tsv
            if ($LASTEXITCODE -ne 0) {
                return (New-DeviceNotificationValidationFailure -Code 'runtime.functionReadFailed' `
                    -Summary 'The Function App could not be read.' -Expected 'Running' `
                    -Remediation 'Confirm Azure resource read access and the Function App deployment, then rerun validation.')
            }
            if ($state -ne 'Running') {
                return (New-DeviceNotificationValidationFailure -Code 'runtime.functionNotRunning' `
                    -Summary 'The Function App is not running.' -Expected 'Running' `
                    -Remediation 'Inspect the Function App deployment and runtime logs, then rerun validation.' `
                    -Details @{ state = [string] $state })
            }
            New-AzdCheckOutcome -Summary 'The notification Function App is running.' `
                -Expected 'Running' -Actual ([string] $state)
        }

    New-AzdValidationCheckDefinition `
        -Id 'identity.graph-app-roles' `
        -Phase identity `
        -Title 'Microsoft Graph application roles are least privilege' `
        -Summary 'Every required Graph application role is assigned and no managed conditional role is unnecessary.' `
        -SideEffect readOnly `
        -Remediation 'Rerun provisioning after reviewing the configured routing scope and workload identity.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Microsoft Graph role validation'
            if ($prerequisite) { return $prerequisite }
            try {
                $configuration = Get-DeviceNotificationValidationConfiguration
                $graphArgs = @{ SubscriptionId = $env:AZURE_SUBSCRIPTION_ID }
                $graph = Invoke-GraphJson -Method GET `
                    -Uri "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles" @graphArgs
                if (@($graph.value).Count -ne 1) {
                    return (New-DeviceNotificationValidationFailure -Code 'identity.graphCatalogUnavailable' `
                        -Summary 'The Microsoft Graph application-role catalog could not be resolved exactly once.' `
                        -Expected 'One Microsoft Graph service principal.' `
                        -Remediation 'Confirm Graph directory read access and tenant context, then rerun validation.')
                }

                $requiredNames = @(Get-RequiredGraphPermissionNames -Routing $configuration.Routing)
                $required = @(Resolve-GraphPermissionPlan -GraphServicePrincipal $graph.value[0] -RequiredNames $requiredNames)
                $assignments = Invoke-GraphJson -Method GET `
                    -Uri "/servicePrincipals/$($env:AZURE_WORKLOAD_PRINCIPAL_ID)/appRoleAssignments?`$top=999" @graphArgs
                foreach ($role in $required) {
                    if ($role.Id -notin $assignments.value.appRoleId) {
                        return (New-DeviceNotificationValidationFailure -Code 'identity.requiredGraphRoleMissing' `
                            -Summary "The required Microsoft Graph role $($role.Name) is missing." `
                            -Expected $requiredNames `
                            -Remediation 'Rerun provisioning after confirming Privileged Role Administrator activation.' `
                            -Details @{ roleName = [string] $role.Name })
                    }
                }

                $managedNames = @('AuditLog.Read.All', 'DeviceManagementManagedDevices.Read.All', 'User.ReadBasic.All', 'GroupMember.Read.All')
                $managed = @(Resolve-GraphPermissionPlan -GraphServicePrincipal $graph.value[0] -RequiredNames $managedNames)
                foreach ($role in $managed | Where-Object { $_.Name -notin $requiredNames }) {
                    if ($role.Id -in $assignments.value.appRoleId) {
                        return (New-DeviceNotificationValidationFailure -Code 'identity.unnecessaryGraphRoleAssigned' `
                            -Summary "The conditional Microsoft Graph role $($role.Name) is assigned but not required." `
                            -Expected $requiredNames `
                            -Remediation 'Rerun provisioning after reviewing the selected monitoring scope.' `
                            -Details @{ roleName = [string] $role.Name })
                    }
                }

                New-AzdCheckOutcome -Summary 'Microsoft Graph application roles match the least-privilege plan.' `
                    -Expected $requiredNames -Actual $requiredNames `
                    -Evidence @{ verifiedRoleNames = $requiredNames }
            }
            catch {
                New-DeviceNotificationValidationFailure -Code 'identity.graphRoleQueryFailed' `
                    -Summary 'Microsoft Graph application-role validation could not be completed.' `
                    -Expected 'Readable role catalog and workload app-role assignments.' `
                    -Remediation 'Confirm Graph directory read access and the exact tenant context, then rerun validation.'
            }
        }

    New-AzdValidationCheckDefinition `
        -Id 'configuration.bot-endpoint' `
        -Phase configuration `
        -Title 'Azure Bot identity and endpoint are exact' `
        -Summary 'The Azure Bot uses the deployed workload identity and Function message endpoint.' `
        -SideEffect readOnly `
        -Remediation 'Rerun provisioning or correct the Bot identity and messaging endpoint.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Azure Bot configuration validation'
            if ($prerequisite) { return $prerequisite }
            $botJson = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --resource-type Microsoft.BotService/botServices `
                --name $env:TEAMS_BOT_NAME --api-version 2022-09-15 --only-show-errors --output json
            if ($LASTEXITCODE -ne 0 -or -not $botJson) {
                return (New-DeviceNotificationValidationFailure -Code 'configuration.botReadFailed' `
                    -Summary 'The Azure Bot resource could not be read.' `
                    -Expected 'A readable Azure Bot resource.' `
                    -Remediation 'Confirm Azure resource read access and the Bot deployment, then rerun validation.')
            }
            $bot = $botJson | ConvertFrom-Json
            $expectedEndpoint = "$($env:AZURE_FUNCTION_APP_URL)/api/messages"
            if ($bot.properties.msaAppId -ne $env:AZURE_WORKLOAD_CLIENT_ID) {
                return (New-DeviceNotificationValidationFailure -Code 'configuration.botIdentityMismatch' `
                    -Summary 'The Azure Bot application identity does not match the deployed workload identity.' `
                    -Expected ([string] $env:AZURE_WORKLOAD_CLIENT_ID) `
                    -Remediation 'Rerun provisioning or correct the Azure Bot application identity.')
            }
            if ($bot.properties.endpoint -ne $expectedEndpoint) {
                return (New-DeviceNotificationValidationFailure -Code 'configuration.botEndpointMismatch' `
                    -Summary 'The Azure Bot messaging endpoint does not match the deployed Function App.' `
                    -Expected $expectedEndpoint `
                    -Remediation 'Rerun provisioning or correct the Azure Bot messaging endpoint.')
            }
            New-AzdCheckOutcome -Summary 'Azure Bot identity and endpoint configuration are exact.' `
                -Expected ([ordered] @{ endpoint = $expectedEndpoint; workloadClientId = $env:AZURE_WORKLOAD_CLIENT_ID }) `
                -Actual ([ordered] @{ endpoint = [string] $bot.properties.endpoint; workloadClientId = [string] $bot.properties.msaAppId })
        }

    New-AzdValidationCheckDefinition `
        -Id 'security.bot-rejects-unauthenticated' `
        -Phase security `
        -Title 'Bot endpoint rejects unauthenticated requests' `
        -Summary 'The Bot endpoint rejects a harmless unauthenticated POST request.' `
        -SideEffect negativeProbe `
        -Remediation 'Inspect Bot Framework authentication before enabling notification collection.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Bot authentication rejection probe'
            if ($prerequisite) { return $prerequisite }
            $activity = @{
                type = 'message'
                id = 'azd-validation-probe'
                timestamp = [datetimeoffset]::UtcNow.ToString('o')
                serviceUrl = 'https://smba.trafficmanager.net/teams/'
                channelId = 'msteams'
                from = @{ id = 'azd-validation-probe' }
                conversation = @{ id = 'azd-validation-probe' }
                recipient = @{ id = 'azd-validation-probe' }
                text = 'azd validation probe'
            } | ConvertTo-Json -Depth 4 -Compress
            try {
                $response = Invoke-WebRequest -Method Post -Uri "$($env:AZURE_FUNCTION_APP_URL)/api/messages" `
                    -ContentType 'application/json' -Body $activity -SkipHttpErrorCheck
            }
            catch {
                return (New-DeviceNotificationValidationFailure -Code 'security.botProbeFailed' `
                    -Summary 'The Bot authentication probe could not reach the endpoint.' `
                    -Expected 'HTTP 401 or 403.' `
                    -Remediation 'Confirm the Function endpoint is reachable and rerun validation.')
            }
            if ($response.StatusCode -notin @(401, 403)) {
                return (New-DeviceNotificationValidationFailure -Code 'security.botUnexpectedStatus' `
                    -Summary 'The Bot endpoint did not return an authentication-specific rejection.' `
                    -Expected 'HTTP 401 or 403.' -Details @{ statusCode = [int] $response.StatusCode } `
                    -Remediation 'Inspect endpoint health and Bot Framework authentication before enabling collection.')
            }
            New-AzdCheckOutcome -Summary 'The Bot endpoint returned an authentication-specific rejection.' `
                -Expected 'HTTP 401 or 403.' -Actual ([int] $response.StatusCode)
        }

    New-AzdValidationCheckDefinition `
        -Id 'security.basic-publishing-disabled' `
        -Phase security `
        -Title 'Basic publishing credentials are disabled' `
        -Summary 'FTP and SCM basic publishing credentials are disabled for the Function App.' `
        -SideEffect readOnly `
        -Remediation 'Disable FTP and SCM basic publishing credentials and rerun validation.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Basic publishing credential validation'
            if ($prerequisite) { return $prerequisite }
            $verifiedPolicies = [System.Collections.Generic.List[string]]::new()
            foreach ($policyName in @('ftp', 'scm')) {
                $allow = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID `
                    --resource-group $env:AZURE_RESOURCE_GROUP `
                    --resource-type Microsoft.Web/sites/basicPublishingCredentialsPolicies `
                    --name "$($env:AZURE_FUNCTION_APP_NAME)/$policyName" --api-version 2024-04-01 `
                    --query properties.allow --only-show-errors --output tsv
                if ($LASTEXITCODE -ne 0 -or $allow -ne 'false') {
                    return (New-DeviceNotificationValidationFailure -Code 'security.basicPublishingEnabled' `
                        -Summary "Function App $policyName basic publishing credentials are not disabled." `
                        -Expected $false -Details @{ policyName = $policyName; allow = [string] $allow } `
                        -Remediation 'Disable FTP and SCM basic publishing credentials and rerun validation.')
                }
                $verifiedPolicies.Add($policyName)
            }
            New-AzdCheckOutcome -Summary 'FTP and SCM basic publishing credentials are disabled.' `
                -Expected $false -Actual $false -Evidence @{ policies = @($verifiedPolicies) }
        }

    New-AzdValidationCheckDefinition `
        -Id 'runtime.collection-readiness' `
        -Phase runtime `
        -Title 'Notification collection readiness is explicit' `
        -Summary 'The deployed collection readiness setting is present and valid.' `
        -SideEffect readOnly `
        -Remediation 'Keep collection paused until delivery testing passes; then use Enable-NotificationCollection.ps1.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Notification collection readiness validation'
            if ($prerequisite) { return $prerequisite }
            $setting = & az functionapp config appsettings list --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME `
                --query "[?name=='DEVICE_NOTIFICATION_COLLECTION_ENABLED'].value | [0]" `
                --only-show-errors --output tsv
            if ($LASTEXITCODE -ne 0 -or $setting -notin @('true', 'false')) {
                return (New-DeviceNotificationValidationFailure -Code 'runtime.collectionSettingInvalid' `
                    -Summary 'The collection readiness setting is missing or invalid.' `
                    -Expected 'true or false.' `
                    -Remediation 'Rerun provisioning and confirm DEVICE_NOTIFICATION_COLLECTION_ENABLED is present.')
            }
            if ($setting -eq 'false') {
                return (New-AzdCheckOutcome -Status warning `
                    -Summary 'Infrastructure is ready, but notification collection remains paused pending delivery proof.' `
                    -Expected 'false until delivery testing is complete.' -Actual $setting `
                    -Remediation 'Install the Teams app, validate every selected destination with -TestDelivery, then run Enable-NotificationCollection.ps1.')
            }
            New-AzdCheckOutcome `
                -Summary 'Notification collection is enabled; real-event validation remains an operational follow-up.' `
                -Expected 'true after explicit enablement.' -Actual $setting
        }

    New-AzdValidationCheckDefinition `
        -Id 'delivery.synthetic-notification' `
        -Phase delivery `
        -Title 'Configured notification routes deliver synthetic events' `
        -Summary 'Every selected synthetic event was delivered through all configured routes.' `
        -SideEffect syntheticDelivery `
        -Remediation 'Keep collection paused, correct the failed Teams or email route, and rerun with -TestDelivery.' `
        -Action {
            $prerequisite = Get-DeviceNotificationContextFailure -CheckName 'Synthetic notification delivery'
            if ($prerequisite) { return $prerequisite }
            try {
                & $script:DeliveryScriptPath @script:DeliveryParameters
                New-AzdCheckOutcome -Summary 'Every selected synthetic event was delivered through all configured routes.' `
                    -Expected @($script:DeliveryParameters.EventType) -Actual @($script:DeliveryParameters.EventType)
            }
            catch {
                New-DeviceNotificationValidationFailure -Code 'delivery.syntheticFailed' `
                    -Summary 'Synthetic notification delivery failed.' `
                    -Expected @($script:DeliveryParameters.EventType) `
                    -Remediation 'Keep collection paused, inspect the selected route evidence, and rerun with -TestDelivery.'
            }
        }
}

Export-ModuleMember -Function 'Get-ProjectValidationDefinition'
