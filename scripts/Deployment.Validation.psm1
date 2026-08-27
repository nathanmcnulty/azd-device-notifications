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
    'AZURE_WORKLOAD_CLIENT_ID'
)

$script:DeliveryScriptPath = $null
$script:DeliveryParameters = @{}

function Resolve-DeviceNotificationContextFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    $message = [string] $ErrorRecord.Exception.Message
    foreach ($name in $script:RequiredEnvironmentNames) {
        if ($message -eq "$name is required.") {
            return New-AzdCheckFailure -Code 'context.requiredValueMissing' `
                -Summary "The required azd environment value $name is missing." `
                -Expected 'All required deployment outputs are available.' `
                -Remediation 'Confirm provisioning completed and the expected azd environment is selected.' `
                -Details @{ environmentValueName = $name }
        }
    }
    if ($message -like 'Tenant context mismatch.*') {
        return New-AzdCheckFailure -Code 'context.tenantMismatch' `
            -Summary 'The azd, subscription, and active Azure CLI tenants do not match.' `
            -Expected 'One exact tenant across azd and Azure CLI.' `
            -Remediation 'Sign in through the normal broker or browser flow for the expected tenant and rerun validation.'
    }
    if ($message -like 'Azure subscription mismatch.*') {
        return New-AzdCheckFailure -Code 'context.subscriptionMismatch' `
            -Summary 'The active Azure CLI subscription does not match the azd environment.' `
            -Expected 'The azd subscription is active in Azure CLI.' `
            -Remediation 'Select the expected subscription with az account set and rerun validation.'
    }
    New-AzdCheckFailure -Code 'context.sessionUnavailable' `
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
            try {
                Initialize-DeviceNotificationValidationContext
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
        -DependsOn 'context.azure-session' `
        -Remediation 'Correct the azd environment values identified by the configuration documentation and rerun validation.' `
        -Action {
            try {
                $configuration = Get-DeviceNotificationValidationConfiguration
                New-AzdCheckOutcome -Summary 'Notification routing configuration is valid.' `
                    -Expected 'At least one valid route with consistent destinations and schedules.' `
                    -Actual ([ordered] @{ enabledRouteCount = [int] $configuration.EnabledRouteCount })
            }
            catch {
                New-AzdCheckFailure -Code 'configuration.invalid' `
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
        -DependsOn 'context.azure-session' `
        -Expected 'Running' `
        -Remediation 'Inspect the Function App deployment and runtime logs, then rerun validation.' `
        -Action {
            $state = & az functionapp show --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME `
                --query state --only-show-errors --output tsv
            if ($LASTEXITCODE -ne 0) {
                return (New-AzdCheckFailure -Code 'runtime.functionReadFailed' `
                    -Summary 'The Function App could not be read.' -Expected 'Running' `
                    -Remediation 'Confirm Azure resource read access and the Function App deployment, then rerun validation.')
            }
            if ($state -ne 'Running') {
                return (New-AzdCheckFailure -Code 'runtime.functionNotRunning' `
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
        -DependsOn 'context.azure-session' `
        -Remediation 'Rerun provisioning after reviewing the configured routing scope and workload identity.' `
        -Action {
            try {
                $configuration = Get-DeviceNotificationValidationConfiguration
                $graphArgs = @{ SubscriptionId = $env:AZURE_SUBSCRIPTION_ID }
                $graph = Invoke-GraphJson -Method GET `
                    -Uri "/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles" @graphArgs
                if (@($graph.value).Count -ne 1) {
                    return (New-AzdCheckFailure -Code 'identity.graphCatalogUnavailable' `
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
                        return (New-AzdCheckFailure -Code 'identity.requiredGraphRoleMissing' `
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
                        return (New-AzdCheckFailure -Code 'identity.unnecessaryGraphRoleAssigned' `
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
                New-AzdCheckFailure -Code 'identity.graphRoleQueryFailed' `
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
        -DependsOn 'context.azure-session' `
        -Remediation 'Rerun provisioning or correct the Bot identity and messaging endpoint.' `
        -Action {
            $configuration = Get-DeviceNotificationValidationConfiguration
            if (-not $configuration.UsesTeamsDm) {
                $botCount = & az resource list --subscription $env:AZURE_SUBSCRIPTION_ID `
                    --resource-group $env:AZURE_RESOURCE_GROUP --resource-type Microsoft.BotService/botServices `
                    --query 'length(@)' --only-show-errors --output tsv
                if ($LASTEXITCODE -ne 0 -or $botCount -ne '0') {
                    return (New-AzdCheckFailure -Code 'configuration.unexpectedBotResource' `
                        -Summary 'Bot Service is present or could not be verified when no personal Teams route is configured.' `
                        -Expected 'No Azure Bot resource.' `
                        -Remediation 'Remove the unused Bot Service resource or enable a personal Teams route intentionally.')
                }
                return (New-AzdCheckOutcome -Summary 'No Azure Bot resource is deployed because no personal Teams route is configured.' `
                    -Expected 0 -Actual 0)
            }
            if (-not $env:TEAMS_BOT_NAME) {
                return (New-AzdCheckFailure -Code 'configuration.botNameMissing' `
                    -Summary 'The Azure Bot name is missing for a personal Teams route.' `
                    -Expected 'A provisioned Azure Bot name.' `
                    -Remediation 'Rerun provisioning and confirm the personal Teams route is enabled.')
            }
            $identityJson = & az functionapp identity show --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME `
                --only-show-errors --output json
            if ($LASTEXITCODE -ne 0 -or -not $identityJson) {
                return (New-AzdCheckFailure -Code 'configuration.workloadIdentityReadFailed' `
                    -Summary 'The Function App workload identity could not be read.' `
                    -Expected 'One readable user-assigned workload identity.' `
                    -Remediation 'Confirm Azure resource read access and the Function App identity configuration.')
            }
            $identity = $identityJson | ConvertFrom-Json
            $assignedIdentities = @($identity.userAssignedIdentities.PSObject.Properties)
            if ($assignedIdentities.Count -ne 1) {
                return (New-AzdCheckFailure -Code 'configuration.workloadIdentityAmbiguous' `
                    -Summary 'The Function App does not have exactly one user-assigned workload identity.' `
                    -Expected 'One user-assigned workload identity.' `
                    -Remediation 'Configure exactly the solution workload identity on the Function App.')
            }
            $workloadIdentityResourceId = [string] $assignedIdentities[0].Name
            $workloadIdentity = $assignedIdentities[0].Value
            if ($workloadIdentity.clientId -ne $env:AZURE_WORKLOAD_CLIENT_ID -or `
                $workloadIdentity.principalId -ne $env:AZURE_WORKLOAD_PRINCIPAL_ID) {
                return (New-AzdCheckFailure -Code 'configuration.workloadIdentityMismatch' `
                    -Summary 'The Function App workload identity does not match the deployed identity outputs.' `
                    -Expected 'The configured workload client and principal identifiers.' `
                    -Remediation 'Rerun provisioning or correct the Function App user-assigned identity.')
            }
            $botJson = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --resource-type Microsoft.BotService/botServices `
                --name $env:TEAMS_BOT_NAME --api-version 2022-09-15 --only-show-errors --output json
            if ($LASTEXITCODE -ne 0 -or -not $botJson) {
                return (New-AzdCheckFailure -Code 'configuration.botReadFailed' `
                    -Summary 'The Azure Bot resource could not be read.' `
                    -Expected 'A readable Azure Bot resource.' `
                    -Remediation 'Confirm Azure resource read access and the Bot deployment, then rerun validation.')
            }
            $bot = $botJson | ConvertFrom-Json
            $expectedEndpoint = "$($env:AZURE_FUNCTION_APP_URL)/api/messages"
            if ($bot.properties.msaAppId -ne $env:AZURE_WORKLOAD_CLIENT_ID) {
                return (New-AzdCheckFailure -Code 'configuration.botIdentityMismatch' `
                    -Summary 'The Azure Bot application identity does not match the deployed workload identity.' `
                    -Expected ([string] $env:AZURE_WORKLOAD_CLIENT_ID) `
                    -Remediation 'Rerun provisioning or correct the Azure Bot application identity.')
            }
            if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string] $bot.properties.msaAppMSIResourceId, $workloadIdentityResourceId)) {
                return (New-AzdCheckFailure -Code 'configuration.botManagedIdentityMismatch' `
                    -Summary 'The Azure Bot managed identity resource does not match the Function App workload identity.' `
                    -Expected 'The Function App user-assigned workload identity resource.' `
                    -Remediation 'Rerun provisioning or correct the Azure Bot managed identity resource.')
            }
            if ($bot.properties.msaAppTenantId -ne $env:AZURE_TENANT_ID) {
                return (New-AzdCheckFailure -Code 'configuration.botTenantMismatch' `
                    -Summary 'The Azure Bot tenant does not match the selected deployment tenant.' `
                    -Expected 'The azd environment tenant.' `
                    -Remediation 'Rerun provisioning in the selected tenant or correct the Azure Bot tenant configuration.')
            }
            if ($bot.properties.msaAppType -ne 'UserAssignedMSI') {
                return (New-AzdCheckFailure -Code 'configuration.botIdentityTypeMismatch' `
                    -Summary 'The Azure Bot is not configured to use a user-assigned managed identity.' `
                    -Expected 'UserAssignedMSI.' `
                    -Remediation 'Rerun provisioning or correct the Azure Bot identity type.')
            }
            if ($bot.properties.endpoint -ne $expectedEndpoint) {
                return (New-AzdCheckFailure -Code 'configuration.botEndpointMismatch' `
                    -Summary 'The Azure Bot messaging endpoint does not match the deployed Function App.' `
                    -Expected $expectedEndpoint `
                    -Remediation 'Rerun provisioning or correct the Azure Bot messaging endpoint.')
            }
            $channelJson = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --resource-type Microsoft.BotService/botServices/channels `
                --name "$($env:TEAMS_BOT_NAME)/MsTeamsChannel" --api-version 2022-09-15 --only-show-errors --output json
            if ($LASTEXITCODE -ne 0 -or -not $channelJson) {
                return (New-AzdCheckFailure -Code 'configuration.teamsChannelReadFailed' `
                    -Summary 'The Microsoft Teams channel could not be read from the Azure Bot.' `
                    -Expected 'An enabled MsTeamsChannel resource.' `
                    -Remediation 'Rerun provisioning or enable the Microsoft Teams channel on the Azure Bot.')
            }
            $channel = $channelJson | ConvertFrom-Json
            if ($channel.properties.channelName -ne 'MsTeamsChannel' -or $channel.properties.properties.isEnabled -ne $true) {
                return (New-AzdCheckFailure -Code 'configuration.teamsChannelDisabled' `
                    -Summary 'The Microsoft Teams channel is missing or not enabled on the Azure Bot.' `
                    -Expected 'MsTeamsChannel with isEnabled=true.' `
                    -Remediation 'Enable the Microsoft Teams channel on the Azure Bot and rerun validation.')
            }
            New-AzdCheckOutcome -Summary 'Azure Bot identity, tenant, endpoint, and Microsoft Teams channel configuration are exact.' `
                -Expected ([ordered] @{ endpoint = $expectedEndpoint; workloadClientId = $env:AZURE_WORKLOAD_CLIENT_ID; teamsChannelEnabled = $true }) `
                -Actual ([ordered] @{ endpoint = [string] $bot.properties.endpoint; workloadClientId = [string] $bot.properties.msaAppId; teamsChannelEnabled = $true })
        }

    New-AzdValidationCheckDefinition `
        -Id 'security.bot-rejects-unauthenticated' `
        -Phase security `
        -Title 'Bot endpoint rejects unauthenticated requests' `
        -Summary 'The Bot endpoint rejects a harmless unauthenticated POST request.' `
        -SideEffect negativeProbe `
        -DependsOn 'context.azure-session' `
        -Remediation 'Inspect Bot Framework authentication before enabling notification collection.' `
        -Action {
            $configuration = Get-DeviceNotificationValidationConfiguration
            if (-not $configuration.UsesTeamsDm) {
                return (New-AzdCheckOutcome -Status skipped `
                    -Summary 'Bot authentication probing is not applicable because no personal Teams route is configured.')
            }
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
                return (New-AzdCheckFailure -Code 'security.botProbeFailed' `
                    -Summary 'The Bot authentication probe could not reach the endpoint.' `
                    -Expected 'HTTP 401 or 403.' `
                    -Remediation 'Confirm the Function endpoint is reachable and rerun validation.')
            }
            if ($response.StatusCode -notin @(401, 403)) {
                return (New-AzdCheckFailure -Code 'security.botUnexpectedStatus' `
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
        -DependsOn 'context.azure-session' `
        -Remediation 'Disable FTP and SCM basic publishing credentials and rerun validation.' `
        -Action {
            $verifiedPolicies = [System.Collections.Generic.List[string]]::new()
            foreach ($policyName in @('ftp', 'scm')) {
                $allow = & az resource show --subscription $env:AZURE_SUBSCRIPTION_ID `
                    --resource-group $env:AZURE_RESOURCE_GROUP `
                    --resource-type Microsoft.Web/sites/basicPublishingCredentialsPolicies `
                    --name "$($env:AZURE_FUNCTION_APP_NAME)/$policyName" --api-version 2024-04-01 `
                    --query properties.allow --only-show-errors --output tsv
                if ($LASTEXITCODE -ne 0 -or $allow -ne 'false') {
                    return (New-AzdCheckFailure -Code 'security.basicPublishingEnabled' `
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
        -DependsOn 'context.azure-session' `
        -Remediation 'Keep collection paused until delivery testing passes; then use Enable-NotificationCollection.ps1.' `
        -Action {
            $setting = & az functionapp config appsettings list --subscription $env:AZURE_SUBSCRIPTION_ID `
                --resource-group $env:AZURE_RESOURCE_GROUP --name $env:AZURE_FUNCTION_APP_NAME `
                --query "[?name=='DEVICE_NOTIFICATION_COLLECTION_ENABLED'].value | [0]" `
                --only-show-errors --output tsv
            if ($LASTEXITCODE -ne 0 -or $setting -notin @('true', 'false')) {
                return (New-AzdCheckFailure -Code 'runtime.collectionSettingInvalid' `
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
        -DependsOn 'context.azure-session' `
        -Remediation 'Keep collection paused, correct the failed Teams or email route, and rerun with -TestDelivery.' `
        -Action {
            try {
                & $script:DeliveryScriptPath @script:DeliveryParameters
                New-AzdCheckOutcome -Summary 'Every selected synthetic event was delivered through all configured routes.' `
                    -Expected @($script:DeliveryParameters.EventType) -Actual @($script:DeliveryParameters.EventType)
            }
            catch {
                New-AzdCheckFailure -Code 'delivery.syntheticFailed' `
                    -Summary 'Synthetic notification delivery failed.' `
                    -Expected @($script:DeliveryParameters.EventType) `
                    -Remediation 'Keep collection paused, inspect the selected route evidence, and rerun with -TestDelivery.'
            }
        }
}

Export-ModuleMember -Function 'Get-ProjectValidationDefinition'
