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
    It 'keeps collection paused by default and requires explicit enablement' {
        Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw | Should -Match 'param collectionEnabled bool = false'
        $enable = Get-Content (Join-Path $repoRoot 'scripts/Enable-NotificationCollection.ps1') -Raw
        $enable | Should -Match 'ENABLE ALL USERS'
        $enable | Should -Match 'DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT'
    }

    It 'removes only recorded created Exchange objects and preserves adopted objects' {
        $cleanup = Get-Content (Join-Path $repoRoot 'scripts/Remove-TenantObjects.ps1') -Raw
        $cleanup | Should -Match "ASSIGNMENT_OWNERSHIP -eq 'created'"
        $cleanup | Should -Match "SCOPE_OWNERSHIP -eq 'created'"
        $cleanup | Should -Match 'adopted objects were preserved'
        $cleanup | Should -Match "Role -ne 'Application Mail.Send'"
        $cleanup | Should -Match 'RecipientTypeDetails -ne ''SharedMailbox'''
    }

    It 'persists collection enablement only after the live setting is verified' {
        $enable = Get-Content (Join-Path $repoRoot 'scripts/Enable-NotificationCollection.ps1') -Raw
        $verifyIndex = $enable.IndexOf("if (`$LASTEXITCODE -ne 0 -or `$actual -ne 'true')")
        $persistIndex = $enable.IndexOf("Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_COLLECTION_ENABLED' 'true'")
        $verifyIndex | Should -BeGreaterOrEqual 0
        $persistIndex | Should -BeGreaterThan $verifyIndex
    }

    It 'validates an unauthenticated bot request is rejected' {
        $validation = Get-Content (Join-Path $repoRoot 'scripts/Test-Deployment.ps1') -Raw
        $validation | Should -Match 'accepted an unauthenticated request'
        $validation | Should -Match 'Collection remains PAUSED|collection is PAUSED'
    }

    It 'keeps the Function host key in a header and clears it after delivery testing' {
        $deliveryTest = Get-Content (Join-Path $repoRoot 'scripts/Test-NotificationDelivery.ps1') -Raw
        $deliveryTest | Should -Match '''x-functions-key'' = \$hostKey'
        $deliveryTest | Should -Not -Match 'code=\$hostKey'
        $deliveryTest | Should -Match '\$hostKey = \$null'
    }
}
