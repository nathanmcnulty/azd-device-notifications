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
        $configure | Should -Match 'Connect-ExchangeOnline -UserPrincipalName \$AdminUpn'
        $configure | Should -Match 'Assert-ExactExchangeConnection'
        $cleanup | Should -Match 'Connect-ExchangeOnline -UserPrincipalName \$env:DEVICE_NOTIFICATION_EXCHANGE_ADMIN_UPN'
        $pre | Should -Match 'Initialize-AzdResourceGroupOwnership'
        $post | Should -Match 'Confirm-AzdResourceGroupOwnership'
        $cleanup | Should -Match 'Confirm-AzdResourceGroupOwnership -AllowMissing'
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
