BeforeAll { $script:repoRoot = Split-Path $PSScriptRoot -Parent }

Describe 'Tenant and subscription safety' {
    BeforeAll { Import-Module (Join-Path $repoRoot 'scripts/Tenant.Guards.psm1') -Force }

    It 'accepts one exact tenant context' {
        { Assert-TenantMatch -ExpectedTenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionTenantId '11111111-1111-4111-8111-111111111111' `
                -ActiveTenantId '11111111-1111-4111-8111-111111111111' } | Should -Not -Throw
    }

    It 'rejects a tenant mismatch before mutation' {
        { Assert-TenantMatch -ExpectedTenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionTenantId '22222222-2222-4222-8222-222222222222' `
                -ActiveTenantId '11111111-1111-4111-8111-111111111111' } | Should -Throw '*mismatch*'
    }

    It 'enforces the active subscription identifier' {
        Get-Content (Join-Path $repoRoot 'scripts/Tenant.Guards.psm1') -Raw | Should -Match '\$active\.id -ne \$env:AZURE_SUBSCRIPTION_ID'
    }

    It 'requires a fresh resource group or an exact local creation receipt and tags' {
        Resolve-AzdResourceGroupOwnership -Exists $false -RecordedOwnership '' -Tags $null -EnvironmentName 'proof-123' |
            Should -Be 'create-pending'
        { Resolve-AzdResourceGroupOwnership -Exists $true -RecordedOwnership '' `
                -Tags ([pscustomobject]@{ 'azd-env-name' = 'proof-123'; workload = 'device-notifications' }) `
                -EnvironmentName 'proof-123' } | Should -Throw '*fresh azd environment name*'
        Resolve-AzdResourceGroupOwnership -Exists $true -RecordedOwnership 'create-pending' `
            -Tags ([pscustomobject]@{ 'azd-env-name' = 'proof-123'; workload = 'device-notifications' }) `
            -EnvironmentName 'proof-123' | Should -Be 'created'
        { Resolve-AzdResourceGroupOwnership -Exists $true -RecordedOwnership 'created' `
                -Tags ([pscustomobject]@{ 'azd-env-name' = 'other'; workload = 'device-notifications' }) `
                -EnvironmentName 'proof-123' } | Should -Throw '*ownership tags*'
    }

    It 'rejects a stale resource-group output after an azd environment switch' {
        { Assert-AzdResourceGroupNameBinding -EnvironmentName 'current' -ResourceGroupName 'rg-previous' `
                -RecordedResourceGroupName 'rg-current' } | Should -Throw '*does not match exact target*'
        Assert-AzdResourceGroupNameBinding -EnvironmentName 'current' -ResourceGroupName 'rg-current' `
            -RecordedResourceGroupName 'rg-current' | Should -Be 'rg-current'
    }

    It 'requires the Function App exact resource ID and all ownership tags' {
        $function = [pscustomobject]@{
            name = 'func-current'
            resourceGroup = 'rg-current'
            id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-current/providers/Microsoft.Web/sites/func-current'
            tags = [pscustomobject]@{
                'azd-env-name' = 'current'
                workload = 'device-notifications'
                'azd-service-name' = 'notifier'
            }
        }
        $parameters = @{
            Function = $function
            SubscriptionId = '11111111-1111-4111-8111-111111111111'
            ResourceGroupName = 'rg-current'
            FunctionAppName = 'func-current'
            EnvironmentName = 'current'
        }
        { Assert-AzdFunctionResourceBinding @parameters } | Should -Not -Throw
        $function.resourceGroup = 'rg-previous'
        { Assert-AzdFunctionResourceBinding @parameters } | Should -Throw '*exact resource ID and ownership tags*'
        $function.resourceGroup = 'rg-current'
        $function.tags.workload = 'other'
        { Assert-AzdFunctionResourceBinding @parameters } | Should -Throw '*exact resource ID and ownership tags*'
    }

    It 'authoritatively refreshes azd values instead of trusting stale process state' {
        $env:AZD_STALE_TARGET_TEST = 'stale-value'
        Mock azd -ModuleName Tenant.Guards { $global:LASTEXITCODE = 0; 'authoritative-value' }
        Get-AzdEnvironmentValue 'AZD_STALE_TARGET_TEST' -Authoritative | Should -Be 'authoritative-value'
        $env:AZD_STALE_TARGET_TEST | Should -Be 'authoritative-value'
        Remove-Item Env:AZD_STALE_TARGET_TEST -ErrorAction SilentlyContinue
    }
}

Describe 'Exchange ownership and context safety' {
    BeforeAll { Import-Module (Join-Path $repoRoot 'scripts/Exchange.Management.psm1') -Force }

    It 'requires exactly one Exchange connection bound to the expected tenant and administrator' {
        $exact = [pscustomobject]@{
            State = 'Connected'
            TenantID = '11111111-1111-4111-8111-111111111111'
            UserPrincipalName = 'admin@contoso.com'
        }
        { Assert-ExactExchangeConnection -Connections @($exact) `
                -ExpectedTenantId $exact.TenantID -ExpectedAdminUpn $exact.UserPrincipalName } | Should -Not -Throw
        { Assert-ExactExchangeConnection -Connections @($exact, $exact) `
                -ExpectedTenantId $exact.TenantID -ExpectedAdminUpn $exact.UserPrincipalName } | Should -Throw '*exactly one*'
        { Assert-ExactExchangeConnection -Connections @() `
                -ExpectedTenantId $exact.TenantID -ExpectedAdminUpn $exact.UserPrincipalName } | Should -Throw '*found 0*'
        { Assert-ExactExchangeConnection -Connections @($exact) `
                -ExpectedTenantId $exact.TenantID -ExpectedAdminUpn 'other@contoso.com' } | Should -Throw '*expected administrator*'
    }

    It 'connects with a cached tenant-scoped token and preserves exact session validation' {
        $tenantId = '11111111-1111-4111-8111-111111111111'
        $adminUpn = 'admin@contoso.com'
        Mock Get-AzureCliExchangeAccessToken -ModuleName Exchange.Management { 'opaque-test-token' }
        Mock Invoke-ExchangeOnlineTokenConnection -ModuleName Exchange.Management {}
        Mock Get-ActiveExchangeOnlineConnections -ModuleName Exchange.Management {
            [pscustomobject]@{ State = 'Connected'; TenantID = $tenantId; UserPrincipalName = $adminUpn }
        }

        Connect-AzdExchangeOnline -ExpectedTenantId $tenantId -ExpectedAdminUpn $adminUpn | Out-Null

        Assert-MockCalled Get-AzureCliExchangeAccessToken -ModuleName Exchange.Management -Times 1 -Exactly `
            -ParameterFilter { $ExpectedTenantId -eq $tenantId }
        Assert-MockCalled Invoke-ExchangeOnlineTokenConnection -ModuleName Exchange.Management -Times 1 -Exactly `
            -ParameterFilter {
                $AccessToken -eq 'opaque-test-token' -and $ExpectedTenantId -eq $tenantId -and $ExpectedAdminUpn -eq $adminUpn
            }
    }

    It 'fails closed when cached token acquisition or exact session validation fails' {
        $tenantId = '11111111-1111-4111-8111-111111111111'
        $adminUpn = 'admin@contoso.com'
        Mock Get-AzureCliExchangeAccessToken -ModuleName Exchange.Management { throw 'cached token unavailable' }
        Mock Invoke-ExchangeOnlineTokenConnection -ModuleName Exchange.Management {}
        { Connect-AzdExchangeOnline -ExpectedTenantId $tenantId -ExpectedAdminUpn $adminUpn } |
            Should -Throw '*cached token unavailable*'
        Assert-MockCalled Invoke-ExchangeOnlineTokenConnection -ModuleName Exchange.Management -Times 0 -Exactly

        Mock Get-AzureCliExchangeAccessToken -ModuleName Exchange.Management { 'opaque-test-token' }
        Mock Invoke-ExchangeOnlineTokenConnection -ModuleName Exchange.Management { throw 'Exchange token connection failed' }
        { Connect-AzdExchangeOnline -ExpectedTenantId $tenantId -ExpectedAdminUpn $adminUpn } |
            Should -Throw '*token connection failed*'

        Mock Invoke-ExchangeOnlineTokenConnection -ModuleName Exchange.Management {}
        Mock Get-ActiveExchangeOnlineConnections -ModuleName Exchange.Management {
            [pscustomobject]@{ State = 'Connected'; TenantID = '22222222-2222-4222-8222-222222222222'; UserPrincipalName = $adminUpn }
        }
        { Connect-AzdExchangeOnline -ExpectedTenantId $tenantId -ExpectedAdminUpn $adminUpn } |
            Should -Throw '*instead of expected tenant*'
    }

    It 'requires explicit adoption but resumes objects covered by pending creation receipts' {
        { Resolve-ExchangeObjectOwnership -Exists $true -RecordedOwnership '' -ObjectDescription 'scope' } |
            Should -Throw '*AdoptExisting*'
        Resolve-ExchangeObjectOwnership -Exists $true -RecordedOwnership '' -AdoptExisting -ObjectDescription 'scope' |
            Should -Be 'adopted'
        Resolve-ExchangeObjectOwnership -Exists $true -RecordedOwnership 'create-pending' -ObjectDescription 'scope' |
            Should -Be 'created'
        Resolve-ExchangeObjectOwnership -Exists $false -RecordedOwnership '' -ObjectDescription 'scope' |
            Should -Be 'create-pending'
        { Resolve-ExchangeObjectOwnership -Exists $false -RecordedOwnership 'adopted' -ObjectDescription 'scope' } |
            Should -Throw '*adopted*missing*'
    }

    It 'treats a create-pending checkpoint as removable after a crash and preserves adopted objects' {
        Test-ExchangeOwnershipRemovable 'create-pending' | Should -BeTrue
        Test-ExchangeOwnershipRemovable 'created' | Should -BeTrue
        Test-ExchangeOwnershipRemovable 'adopted' | Should -BeFalse
    }

    It 'binds an Exchange pointer to both exact workload identifiers' {
        $pointer = [pscustomobject]@{ AppId = '11111111-1111-4111-8111-111111111111'; ObjectId = '22222222-2222-4222-8222-222222222222' }
        { Assert-ExchangeServicePrincipalExact -ServicePrincipal $pointer `
                -ExpectedClientId $pointer.AppId -ExpectedPrincipalId $pointer.ObjectId } | Should -Not -Throw
        { Assert-ExchangeServicePrincipalExact -ServicePrincipal $pointer `
                -ExpectedClientId $pointer.AppId -ExpectedPrincipalId '33333333-3333-4333-8333-333333333333' } | Should -Throw '*exact workload*'
    }

    It 'refuses to retarget recorded tenant, administrator, workload, or sender bindings' {
        $parameters = @{
            RecordedClientId = '11111111-1111-4111-8111-111111111111'
            RecordedPrincipalId = '22222222-2222-4222-8222-222222222222'
            RecordedAdminUpn = 'admin@contoso.com'
            RecordedTenantId = '33333333-3333-4333-8333-333333333333'
            RecordedSenderMailbox = 'notifications@contoso.com'
            ExpectedClientId = '11111111-1111-4111-8111-111111111111'
            ExpectedPrincipalId = '22222222-2222-4222-8222-222222222222'
            ExpectedAdminUpn = 'admin@contoso.com'
            ExpectedTenantId = '33333333-3333-4333-8333-333333333333'
            ExpectedSenderMailbox = 'other@contoso.com'
        }
        { Assert-RecordedExchangeBinding @parameters } | Should -Throw '*sender mailbox*Refusing to retarget*'
        $parameters.RecordedSenderMailbox = ''
        $parameters.ExpectedSenderMailbox = 'notifications@contoso.com'
        { Assert-RecordedExchangeBinding @parameters -RequireRecorded } | Should -Throw '*sender mailbox is missing*'
    }

    It 'waits for post-delete absence and fails closed when an object remains' {
        $script:lookupCount = 0
        { Wait-ExchangeObjectAbsent -ObjectDescription 'test object' -DelaySeconds 0 -Attempts 3 -Lookup {
                $script:lookupCount++
                if ($script:lookupCount -lt 2) { [pscustomobject]@{ id = 'still-present' } }
            } } | Should -Not -Throw
        { Wait-ExchangeObjectAbsent -ObjectDescription 'test object' -DelaySeconds 0 -Attempts 2 -Lookup {
                [pscustomobject]@{ id = 'still-present' }
            } } | Should -Throw '*receipts were retained*'
    }
}

Describe 'Configuration validation' {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'scripts/Configuration.Validation.psm1') -Force
        $script:routing = '{"events":{"deviceRegistered":{"user":["teamsDm"],"admin":[]},"deviceEnrolled":{"user":["teamsDm"],"admin":[]},"deviceNoncompliant":{"user":["teamsDm"],"admin":[]}},"monitoredUserIds":["11111111-1111-4111-8111-111111111111"],"monitoredGroupIds":[],"privilegedUserIds":[]}'
    }

    It 'accepts a scoped baseline-only setup' {
        $result = Get-NotificationConfiguration -RoutingJson $routing -EntraPollSchedule '0 */5 * * * *' `
            -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15
        $result.EnabledRouteCount | Should -Be 3
        $result.EnrollmentLookbackHours | Should -Be 0
        $result.UsesTeamsDm | Should -BeTrue
    }

    It 'rejects an enabled webhook route without a destination' {
        $webhookRouting = $routing.Replace('"admin":[]', '"admin":["teamsWebhook"]')
        { Get-NotificationConfiguration -RoutingJson $webhookRouting -EntraPollSchedule '0 */5 * * * *' `
                -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15 } | Should -Throw '*TEAMS_ADMIN_WEBHOOK_URL*'
    }

    It 'rejects invalid schedules and unsafe numeric bounds' {
        { Get-NotificationConfiguration -RoutingJson $routing -EntraPollSchedule '* * * * *' `
                -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15 } | Should -Throw '*six-field*'
        { Get-NotificationConfiguration -RoutingJson $routing -EntraPollSchedule '0 */5 * * * *' `
                -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 721 -AuditOverlapMinutes 15 } | Should -Throw '*0 through 720*'
    }

    It 'rejects duplicate delivery routes' {
        $duplicateRouting = $routing.Replace('["teamsDm"]', '["teamsDm","teamsDm"]')
        { Get-NotificationConfiguration -RoutingJson $duplicateRouting -EntraPollSchedule '0 */5 * * * *' `
                -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15 } | Should -Throw '*duplicate transports*'
    }

    It 'round-trips routing JSON through a JSON-safe UTF-8 base64 transport' {
        $raw = '{"text":"quote \" backslash \\ and snowman ☃","lines":"one\ntwo"}'
        $encoded = ConvertTo-RoutingConfigBase64 -RoutingJson $raw
        $encoded | Should -Match '^[A-Za-z0-9+/]+={0,2}$'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | Should -BeExactly $raw
    }

    It 'bootstraps the derived transport only after validating first-run raw routing' {
        $derivedBase64 = $null
        { Get-NotificationConfiguration -RoutingJson $routing -EntraPollSchedule '0 */5 * * * *' `
                -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15 } |
            Should -Not -Throw
        $derivedBase64 | Should -BeNullOrEmpty
        $derivedBase64 = ConvertTo-RoutingConfigBase64 -RoutingJson $routing
        $derivedBase64 | Should -Not -BeNullOrEmpty
    }

    It 'rejects empty, array, null, scalar, and scalar-event routing structures' {
        foreach ($invalidRouting in @(
                '{}',
                '{"events":{}}',
                '{"events":[]}',
                '[]',
                'null',
                '"scalar"',
                '{"events":{"deviceRegistered":"invalid","deviceEnrolled":{},"deviceNoncompliant":{}}}',
                '{"events":{"deviceRegistered":{"user":"invalid","admin":[]},"deviceEnrolled":{"user":[],"admin":[]},"deviceNoncompliant":{"user":[],"admin":[]}}}'
            )) {
            { Get-NotificationConfiguration -RoutingJson $invalidRouting -EntraPollSchedule '0 */5 * * * *' `
                    -IntunePollSchedule '30 */15 * * * *' -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15 } |
                Should -Throw
        }
    }
}

Describe 'Graph permission planning' {
    BeforeAll { Import-Module (Join-Path $repoRoot 'scripts/Graph.Management.psm1') -Force }

    It 'adds the documented permission pair only for group scope' {
        $none = Get-RequiredGraphPermissionNames -Routing ([pscustomobject]@{ monitoredGroupIds = @() })
        $group = Get-RequiredGraphPermissionNames -Routing ([pscustomobject]@{ monitoredGroupIds = @('11111111-1111-4111-8111-111111111111') })
        $none | Should -Not -Contain 'User.ReadBasic.All'
        $group | Should -Contain 'User.ReadBasic.All'
        $group | Should -Contain 'GroupMember.Read.All'
    }

    It 'fails the complete plan when any role cannot be pre-resolved' {
        $graph = [pscustomobject]@{ appRoles = @([pscustomobject]@{ value = 'AuditLog.Read.All'; id = 'role-1'; allowedMemberTypes = @('Application') }) }
        { Resolve-GraphPermissionPlan -GraphServicePrincipal $graph -RequiredNames @('AuditLog.Read.All', 'Missing.Read.All') } | Should -Throw '*Missing.Read.All*'
    }

    It 'pre-resolves the complete managed plan before the first assignment write' {
        $post = Get-Content (Join-Path $repoRoot 'scripts/Post-Provision.ps1') -Raw
        $planIndex = $post.IndexOf('$managedRoles = @(Resolve-GraphPermissionPlan')
        $writeIndex = $post.IndexOf('Invoke-GraphJson -Method POST')
        $planIndex | Should -BeGreaterOrEqual 0
        $writeIndex | Should -BeGreaterThan $planIndex
        $post | Should -Match '\$verified = Invoke-GraphJson -Method GET'
        $post | Should -Match '-RetryNotFound'
    }
}

Describe 'Lifecycle safety contracts' {
    It 'deploys the committed runtime without a local or remote Node build' {
        $deployment = Get-Content (Join-Path $repoRoot 'scripts/Deploy-FunctionPackage.ps1') -Raw
        $deployment | Should -Match 'function-package'
        $deployment | Should -Match '--build-remote false'
        $deployment | Should -Match "'index\.cjs\.LEGAL\.txt'"
        $deployment | Should -Match "'THIRD-PARTY-NOTICES\.txt'"
        $deployment | Should -Match "'UNLICENSE\.txt'"
        $deployment | Should -Not -Match 'npm|nodejs\.org'
        Test-Path (Join-Path $repoRoot 'function-package/index.cjs') | Should -BeTrue
        Test-Path (Join-Path $repoRoot 'function-package/index.cjs.LEGAL.txt') | Should -BeTrue
        Test-Path (Join-Path $repoRoot 'function-package/THIRD-PARTY-NOTICES.txt') | Should -BeTrue
        Test-Path (Join-Path $repoRoot 'function-package/UNLICENSE.txt') | Should -BeTrue
        Test-Path (Join-Path $repoRoot 'scripts/Invoke-Azd.ps1') | Should -BeFalse
    }

    It 'marks the reproducible runtime bundle as generated without weakening handwritten diff checks' {
        $attributes = Get-Content (Join-Path $repoRoot '.gitattributes') -Raw
        $attributes | Should -Match 'function-package/index\.cjs linguist-generated=true -whitespace'
        $attributes | Should -Match 'function-package/index\.cjs\.LEGAL\.txt linguist-generated=true -whitespace'
        $attributes | Should -Match 'function-package/THIRD-PARTY-NOTICES\.txt linguist-generated=true -whitespace'
        $attributes | Should -Match 'function-package/UNLICENSE\.txt linguist-generated=true -whitespace'
    }

    It 'retains the generated third-party legal notice in the reproducible deployment package' {
        $package = Get-Content (Join-Path $repoRoot 'src/package.json') -Raw
        $repositoryValidation = Get-Content (Join-Path $repoRoot 'scripts/Test-Repository.ps1') -Raw
        $package | Should -Match 'scripts/bundle\.mjs'
        Get-Content (Join-Path $repoRoot 'src/scripts/bundle.mjs') -Raw | Should -Match "legalComments: 'external'"
        $repositoryValidation | Should -Match "'index\.cjs\.LEGAL\.txt'"
        $repositoryValidation | Should -Match "'THIRD-PARTY-NOTICES\.txt'"
        $repositoryValidation | Should -Match "'UNLICENSE\.txt'"
        $repositoryValidation | Should -Match 'function-package/index\.cjs\.LEGAL\.txt'
        $repositoryValidation | Should -Match 'function-package/THIRD-PARTY-NOTICES\.txt'
        $repositoryValidation | Should -Match 'Compress-Archive'
    }

    It 'does not require Bot Service for email-only owner delivery' {
        $emailRouting = $routing.Replace('"teamsDm"', '"email"')
        $result = Get-NotificationConfiguration -RoutingJson $emailRouting -EmailSenderUpn 'notifications@contoso.com' `
            -EntraPollSchedule '0 */5 * * * *' -IntunePollSchedule '30 */15 * * * *' `
            -EnrollmentLookbackHours 0 -AuditOverlapMinutes 15
        $result.UsesTeamsDm | Should -BeFalse
        $result.UsesEmail | Should -BeTrue
    }

    It 'registers the queue binding extension in source and deployment hosts' {
        foreach ($path in @('src/host.json', 'function-package/host.json')) {
            $hostConfig = Get-Content (Join-Path $repoRoot $path) -Raw | ConvertFrom-Json
            $hostConfig.extensionBundle.id | Should -Be 'Microsoft.Azure.Functions.ExtensionBundle'
            $hostConfig.extensionBundle.version | Should -Be '[4.0.0, 5.0.0)'
        }
    }

    It 'creates Bot Service only when personal Teams delivery is selected' {
        $infra = Get-Content (Join-Path $repoRoot 'infra/resources.bicep') -Raw
        $infra | Should -Match "resource bot .* = if \(teamsBotEnabled\)"
        $infra | Should -Match "resource teamsChannel .* = if \(teamsBotEnabled\)"
        $parameters = Get-Content (Join-Path $repoRoot 'infra/main.parameters.json') -Raw
        $parameters | Should -Match 'DEVICE_NOTIFICATION_TEAMS_BOT_ENABLED=false'
    }

    It 'keeps collection paused by default and requires explicit enablement' {
        Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw | Should -Match 'param collectionEnabled bool = false'
        $enable = Get-Content (Join-Path $repoRoot 'scripts/Enable-NotificationCollection.ps1') -Raw
        $enable | Should -Match 'ENABLE ALL USERS'
        $enable | Should -Match 'DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT'
        $enable | Should -Match "EXCHANGE_INTENT_STATUS -ne 'complete'"
        $enable | Should -Match 'Assert-RecordedExchangeBinding'
    }

    It 'transports validated routing JSON through base64 and decodes it before Function configuration' {
        $parameters = Get-Content (Join-Path $repoRoot 'infra/main.parameters.json') -Raw
        $main = Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw
        $resources = Get-Content (Join-Path $repoRoot 'infra/resources.bicep') -Raw
        $pre = Get-Content (Join-Path $repoRoot 'scripts/Pre-Provision.ps1') -Raw
        $parameters | Should -Match '\$\{DEVICE_NOTIFICATION_ROUTING_BASE64=\}'
        $parameters | Should -Not -Match '\$\{DEVICE_NOTIFICATION_ROUTING_JSON\}'
        $firstRunParameters = $parameters.Replace('${DEVICE_NOTIFICATION_ROUTING_BASE64=}', '')
        $firstRunParameters = [regex]::Replace($firstRunParameters, '\$\{[^}]+\}', 'safe')
        ($firstRunParameters | ConvertFrom-Json).parameters.routingConfigBase64.value | Should -BeExactly ''
        $sampleJson = '{"quoted":"a \"value\"","path":"C:\\proof","label":"café"}'
        $sampleBase64 = ConvertTo-RoutingConfigBase64 -RoutingJson $sampleJson
        $renderedParameters = $parameters.Replace('${DEVICE_NOTIFICATION_ROUTING_BASE64=}', $sampleBase64)
        $renderedParameters = [regex]::Replace($renderedParameters, '\$\{[^}]+\}', 'safe')
        $parsedParameters = $renderedParameters | ConvertFrom-Json
        $parsedParameters.parameters.routingConfigBase64.value | Should -BeExactly $sampleBase64
        $main | Should -Match 'param routingConfigBase64 string'
        $main | Should -Not -Match '(?s)@minLength\(1\)\s*param routingConfigBase64 string'
        $main | Should -Match 'base64ToString\(routingConfigBase64\)'
        $main | Should -Match 'json\(routingConfigJson\)'
        $main | Should -Match 'routingConfigJson: string\(validatedRoutingConfig\)'
        $main | Should -Match '(?s)@secure\(\)\s*param teamsAdminWebhookUrl string'
        $resources | Should -Match 'param routingConfigJson string'
        $resources | Should -Match "name: 'ROUTING_CONFIG_JSON', value: routingConfigJson"
        $validationIndex = $pre.LastIndexOf('$configuration = Get-NotificationConfiguration')
        $transportIndex = $pre.IndexOf("Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_ROUTING_BASE64'")
        $validationIndex | Should -BeGreaterOrEqual 0
        $transportIndex | Should -BeGreaterThan $validationIndex
        $pre | Should -Match 'Get-NotificationDeliveryFingerprint -RoutingJson \$env:DEVICE_NOTIFICATION_ROUTING_JSON'
    }

    It 'emits root deployment expressions that force every required object and array path' {
        $compiled = Get-Content (Join-Path $repoRoot 'infra/main.json') -Raw | ConvertFrom-Json -Depth 100
        $compiled.parameters.routingConfigBase64.type | Should -BeExactly 'string'
        $compiled.parameters.routingConfigBase64.PSObject.Properties.Name | Should -Not -Contain 'minLength'
        foreach ($eventName in @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant')) {
            $expression = [string]$compiled.variables."${eventName}Routing"
            $expression | Should -Match "union\(variables\('routingConfig'\)\.events\.$eventName"
            $expression | Should -Match "concat\(createArray\(\), variables\('routingConfig'\)\.events\.$eventName\.user\)"
            $expression | Should -Match "concat\(createArray\(\), variables\('routingConfig'\)\.events\.$eventName\.admin\)"
        }
        [string]$compiled.variables.validatedRoutingConfig | Should -Match "union\(variables\('routingConfig'\)"
        [string]$compiled.variables.validatedRoutingConfig | Should -Match "union\(variables\('routingConfig'\)\.events"
        $deployment = @($compiled.resources | Where-Object type -eq 'Microsoft.Resources/deployments') | Select-Object -First 1
        [string]$deployment.properties.parameters.routingConfigJson.value |
            Should -BeExactly "[string(variables('validatedRoutingConfig'))]"
        $compiled.PSObject.Properties.Name | Should -Not -Contain 'definitions'
    }

    It 'executes root guards offline and rejects invalid dynamic routing payloads' {
        $fixture = Join-Path $repoRoot "tests/.routing-root-$([guid]::NewGuid().ToString('N')).bicepparam"
        $snapshotPath = [IO.Path]::ChangeExtension($fixture, '.snapshot.json')
        $contextId = '11111111-1111-4111-8111-111111111111'
        function Write-RoutingSnapshotParameters([string] $RawRouting) {
            $encoded = ConvertTo-RoutingConfigBase64 -RoutingJson $RawRouting
            $content = @"
using '../infra/main.bicep'

param environmentName = 'routing-test'
param location = 'westus2'
param tenantId = '$contextId'
param routingConfigBase64 = '$encoded'
"@
            [IO.File]::WriteAllText($fixture, $content, [Text.Encoding]::UTF8)
        }

        try {
            $emptyContent = @"
using '../infra/main.bicep'

param environmentName = 'routing-test'
param location = 'westus2'
param tenantId = '$contextId'
param routingConfigBase64 = ''
"@
            [IO.File]::WriteAllText($fixture, $emptyContent, [Text.Encoding]::UTF8)
            $emptyDiagnostics = @(& az bicep snapshot --file $fixture --subscription-id $contextId `
                    --tenant-id $contextId --location westus2 --only-show-errors 2>&1)
            $LASTEXITCODE | Should -Not -Be 0 -Because 'An absent first-run derived value must fail at root evaluation after preprovision'
            ($emptyDiagnostics -join "`n") | Should -Match 'Template snapshotting could not be completed'

            Write-RoutingSnapshotParameters $routing
            $validDiagnostics = @(& az bicep snapshot --file $fixture --subscription-id $contextId `
                    --tenant-id $contextId --location westus2 --only-show-errors 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because ($validDiagnostics -join "`n")
            $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 100
            $function = @($snapshot.predictedResources | Where-Object type -eq 'Microsoft.Web/sites')
            $function.Count | Should -Be 1
            $routingSetting = @($function[0].properties.siteConfig.appSettings |
                    Where-Object name -eq 'ROUTING_CONFIG_JSON')
            $routingSetting.Count | Should -Be 1
            $evaluatedRouting = $routingSetting[0].value | ConvertFrom-Json
            foreach ($eventName in @('deviceRegistered', 'deviceEnrolled', 'deviceNoncompliant')) {
                @($evaluatedRouting.events.$eventName.user).Count | Should -Be 1
                @($evaluatedRouting.events.$eventName.admin).Count | Should -Be 0
            }
            @($evaluatedRouting.monitoredUserIds).Count | Should -Be 1

            foreach ($invalidRouting in @(
                    '{}',
                    '{"events":{}}',
                    '{"events":[]}',
                    '[]',
                    'null',
                    '"scalar"',
                    '{"events":{"deviceRegistered":"invalid","deviceEnrolled":{},"deviceNoncompliant":{}}}',
                    '{"events":{"deviceRegistered":{"user":"invalid","admin":[]},"deviceEnrolled":{"user":[],"admin":[]},"deviceNoncompliant":{"user":[],"admin":[]}}}'
                )) {
                Write-RoutingSnapshotParameters $invalidRouting
                $invalidDiagnostics = @(& az bicep snapshot --file $fixture --subscription-id $contextId `
                        --tenant-id $contextId --location westus2 --only-show-errors 2>&1)
                $LASTEXITCODE | Should -Not -Be 0 -Because "Invalid routing must fail offline root expression evaluation: $invalidRouting"
                ($invalidDiagnostics -join "`n") | Should -Match 'Template snapshotting could not be completed'
            }
        }
        finally {
            foreach ($path in @($fixture, $snapshotPath)) {
                if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
            }
        }
    }

    It 'records Exchange intent before mutation and cleans crash-resumable ownership states' {
        $configure = Get-Content (Join-Path $repoRoot 'scripts/Configure-ExchangeMail.ps1') -Raw
        $cleanup = Get-Content (Join-Path $repoRoot 'scripts/Remove-TenantObjects.ps1') -Raw
        $intentIndex = $configure.IndexOf("Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_EXCHANGE_INTENT_STATUS' 'pending'")
        $firstWriteIndex = $configure.IndexOf('New-ServicePrincipal')
        $intentIndex | Should -BeGreaterOrEqual 0
        $firstWriteIndex | Should -BeGreaterThan $intentIndex
        $configure | Should -Match '\[switch\] \$AdoptExisting'
        $configure | Should -Match "SERVICE_PRINCIPAL_OWNERSHIP' 'created'"
        $configure | Should -Match "SCOPE_OWNERSHIP' 'created'"
        $configure | Should -Match "ASSIGNMENT_OWNERSHIP' 'created'"
        $cleanup | Should -Not -Match "EXCHANGE_CONFIGURED -ne 'true'"
        $cleanup | Should -Match 'Test-ExchangeOwnershipRemovable'
        $cleanup | Should -Match 'Wait-ExchangeObjectAbsent'
        $cleanup | Should -Match 'adopted objects were preserved'
    }

    It 'binds Exchange login and Azure resource-group ownership before lifecycle mutation' {
        $configure = Get-Content (Join-Path $repoRoot 'scripts/Configure-ExchangeMail.ps1') -Raw
        $cleanup = Get-Content (Join-Path $repoRoot 'scripts/Remove-TenantObjects.ps1') -Raw
        $pre = Get-Content (Join-Path $repoRoot 'scripts/Pre-Provision.ps1') -Raw
        $post = Get-Content (Join-Path $repoRoot 'scripts/Post-Provision.ps1') -Raw
        $exchangeModule = Get-Content (Join-Path $repoRoot 'scripts/Exchange.Management.psm1') -Raw
        $configure | Should -Match 'Connect-AzdExchangeOnline'
        $cleanup | Should -Match 'Connect-AzdExchangeOnline'
        $configure | Should -Not -Match '(?m)^\s*Connect-ExchangeOnline\b'
        $cleanup | Should -Not -Match '(?m)^\s*Connect-ExchangeOnline\b'
        $exchangeModule | Should -Match "az account get-access-token --tenant \`$ExpectedTenantId"
        $exchangeModule | Should -Match "--resource 'https://outlook\.office365\.com'"
        $exchangeModule | Should -Match 'Connect-ExchangeOnline -AccessToken \$AccessToken -Organization \$ExpectedTenantId'
        $exchangeModule | Should -Match 'Assert-ExactExchangeConnection -Connections'
        $pre | Should -Match 'Initialize-AzdResourceGroupOwnership'
        $post | Should -Match 'Get-AzdFunctionTarget'
        $cleanup | Should -Match 'Get-AzdFunctionTarget -AllowMissing'
    }

    It 'validates the exact Function target before every sensitive Function operation' {
        foreach ($path in @(
                'scripts/Deploy-FunctionPackage.ps1',
                'scripts/Test-NotificationDelivery.ps1',
                'scripts/Enable-NotificationCollection.ps1',
                'scripts/Remove-TenantObjects.ps1',
                'scripts/New-TeamsAppPackage.ps1',
                'scripts/Configure-ExchangeMail.ps1',
                'scripts/Post-Provision.ps1'
            )) {
            Get-Content (Join-Path $repoRoot $path) -Raw | Should -Match 'Get-AzdFunctionTarget'
        }
        Get-Content (Join-Path $repoRoot 'scripts/Deployment.Validation.psm1') -Raw |
            Should -Match 'Get-AzdFunctionTarget'
    }

    It 'verifies exact resource-group absence after down before clearing ownership receipts' {
        $down = Get-Content (Join-Path $repoRoot 'scripts/Test-DownCleanup.ps1') -Raw
        $down | Should -Match 'Assert-AzdResourceGroupTarget -AllowDerived'
        $down | Should -Match 'az group exists'
        $verifyIndex = $down.IndexOf("if (`$existsText -eq 'true')")
        $clearIndex = $down.IndexOf("Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME' ''")
        $verifyIndex | Should -BeGreaterOrEqual 0
        $clearIndex | Should -BeGreaterThan $verifyIndex
        Get-Content (Join-Path $repoRoot 'azure.yaml') -Raw | Should -Match 'postdown:[\s\S]*Test-DownCleanup\.ps1'
    }

    It 'persists collection enablement only after the live setting is verified' {
        $enable = Get-Content (Join-Path $repoRoot 'scripts/Enable-NotificationCollection.ps1') -Raw
        $verifyIndex = $enable.IndexOf("if (`$LASTEXITCODE -ne 0 -or `$actual -ne 'true')")
        $persistIndex = $enable.IndexOf("Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_COLLECTION_ENABLED' 'true'")
        $verifyIndex | Should -BeGreaterOrEqual 0
        $persistIndex | Should -BeGreaterThan $verifyIndex
    }

    It 'validates an unauthenticated bot request is rejected' {
        $validation = Get-Content (Join-Path $repoRoot 'scripts/Deployment.Validation.psm1') -Raw
        $validation | Should -Match 'StatusCode -notin @\(401, 403\)'
        $validation | Should -Match 'authentication-specific rejection'
        $validation | Should -Match 'collection remains paused|Keep collection paused'
    }

    It 'keeps the Function host key in a header and clears it after delivery testing' {
        $deliveryTest = Get-Content (Join-Path $repoRoot 'scripts/Test-NotificationDelivery.ps1') -Raw
        $deliveryTest | Should -Match '''x-functions-key'' = \$hostKey'
        $deliveryTest | Should -Not -Match 'code=\$hostKey'
        $deliveryTest | Should -Match '\$hostKey = \$null'
    }
}
