BeforeAll {
    $script:templateRoot = Split-Path -Parent $PSScriptRoot
    $script:envelopeSchema = Join-Path $script:templateRoot 'contracts/notifications/notification-envelope.schema.json'
    $script:resultSchema = Join-Path $script:templateRoot 'contracts/notifications/notification-delivery-result.schema.json'
    $script:environment = [ordered]@{
        name = 'test'
        tenantId = '11111111-1111-4111-8111-111111111111'
        subscriptionId = '22222222-2222-4222-8222-222222222222'
        resourceGroup = 'rg-device-notifications-test'
    }
}

Describe 'notification contract provenance' {
    It 'matches the exact reference revision and file hashes recorded in the component lock' {
        $lock = Get-Content -LiteralPath (Join-Path $script:templateRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'notification-contracts')

        $component.Count | Should -Be 1
        $component[0].version | Should -Be '1.0.0'
        $component[0].sourceRepository | Should -Be 'https://github.com/nathanmcnulty/azd-reference'
        $component[0].sourceRevision | Should -Be 'c8f827cb00b1369d64f468494db651eb84aa1d3c'
        foreach ($file in @($component[0].files)) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:templateRoot $file.target)).Hash.ToLowerInvariant()
            $actualHash | Should -Be $file.sha256
        }
    }

    It 'pins the lock and vendored contracts to LF bytes' {
        $attributes = Get-Content -LiteralPath (Join-Path $script:templateRoot '.gitattributes') -Raw
        $attributes | Should -Match 'azd-components\.lock\.json text eol=lf'
        $attributes | Should -Match 'contracts/notifications/\*\* text eol=lf'
    }
}

Describe 'device notification envelope contract' {
    It 'accepts each solution event and Graph source mapping' -ForEach @(
        @{ EventType = 'entra.device.registered'; Source = 'microsoftGraph.directoryAudit' }
        @{ EventType = 'intune.device.enrolled'; Source = 'microsoftGraph.deviceManagement' }
        @{ EventType = 'intune.device.complianceChanged'; Source = 'microsoftGraph.deviceManagement' }
    ) {
        $envelope = [ordered]@{
            schemaVersion = '1.0'
            eventId = 'event-42'
            eventType = $EventType
            source = $Source
            occurredAt = '2026-08-23T20:00:00Z'
            severity = 'high'
            correlationId = 'correlation-42'
            isTest = $true
            environment = $script:environment
            data = @{ owner = @{ email = 'owner@example.test' }; device = @{ displayName = 'TEST-DEVICE' } }
        }

        ($envelope | ConvertTo-Json -Depth 10 |
            Test-Json -SchemaFile $script:envelopeSchema -ErrorAction Stop) | Should -BeTrue
    }
}

Describe 'device notification delivery-result contract' {
    It 'accepts every stable route mapping' -ForEach @(
        @{ Id = 'user-teams-dm'; Audience = 'user'; Transport = 'teams.bot' }
        @{ Id = 'admin-teams-workflow'; Audience = 'admin'; Transport = 'teams.workflowWebhook' }
        @{ Id = 'user-email'; Audience = 'user'; Transport = 'email.graph' }
        @{ Id = 'admin-email'; Audience = 'admin'; Transport = 'email.graph' }
    ) {
        $result = [ordered]@{
            schemaVersion = '1.0'
            eventId = 'event-42'
            eventType = 'intune.device.complianceChanged'
            correlationId = 'correlation-42'
            idempotencyKey = '59230737f7937c0739fd937fa158616b9bf665d52b5483136d557b52a1df50b9'
            route = [ordered]@{ id = $Id; audience = $Audience; transport = $Transport }
            status = 'succeeded'
            attempt = 1
            recordedAt = '2026-08-23T20:00:03Z'
            isTest = $true
            environment = $script:environment
            evidence = @{}
        }

        ($result | ConvertTo-Json -Depth 10 |
            Test-Json -SchemaFile $script:resultSchema -ErrorAction Stop) | Should -BeTrue
    }

    It 'rejects destinations, recipients, cards, payload PII, and raw provider errors' -ForEach @(
        @{ Name = 'destination'; Value = 'https://example.invalid/workflows/callback?sig=secret' }
        @{ Name = 'recipient'; Value = 'admin@example.test' }
        @{ Name = 'card'; Value = @{ type = 'AdaptiveCard' } }
        @{ Name = 'data'; Value = @{ owner = 'owner@example.test' } }
        @{ Name = 'rawError'; Value = 'provider response body' }
    ) {
        $result = [ordered]@{
            schemaVersion = '1.0'
            eventId = 'event-42'
            eventType = 'intune.device.complianceChanged'
            correlationId = 'event-42'
            idempotencyKey = '59230737f7937c0739fd937fa158616b9bf665d52b5483136d557b52a1df50b9'
            route = @{ id = 'admin-email'; audience = 'admin'; transport = 'email.graph' }
            status = 'succeeded'
            attempt = 1
            recordedAt = '2026-08-23T20:00:03Z'
            isTest = $false
            environment = $script:environment
            evidence = @{}
        }
        $result[$Name] = $Value

        { $result | ConvertTo-Json -Depth 10 |
            Test-Json -SchemaFile $script:resultSchema -ErrorAction Stop } | Should -Throw
    }
}

Describe 'notification contract runtime registration' {
    It 'provides all canonical environment metadata through infrastructure' {
        $resources = Get-Content -LiteralPath (Join-Path $script:templateRoot 'infra/resources.bicep') -Raw
        $main = Get-Content -LiteralPath (Join-Path $script:templateRoot 'infra/main.bicep') -Raw

        foreach ($name in 'AZURE_ENV_NAME', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP') {
            $resources | Should -Match ([regex]::Escape("name: '$name'"))
        }
        $main | Should -Match 'subscriptionId: subscription\(\)\.subscriptionId'
        $main | Should -Match 'resourceGroupName: resourceGroup\.name'
    }

    It 'checks the legacy delivered key but creates reservations with the canonical key' {
        $repository = Get-Content -LiteralPath (Join-Path $script:templateRoot 'src/repositories.ts') -Raw
        $delivery = Get-Content -LiteralPath (Join-Path $script:templateRoot 'src/delivery.ts') -Raw

        $repository | Should -Match 'getEntity<ReservationEntity>\("notification", legacyDeliveredKey\)'
        $repository | Should -Match 'rowKey: key, reservedAt:'
        $delivery | Should -Match 'reserveDelivery\(key, legacyDeliveryKey\(event, route\)\)'
        $delivery | Should -Match 'notificationIdempotencyKey\('
    }

    It 'does not log raw Teams or delivery exceptions' {
        $bot = Get-Content -LiteralPath (Join-Path $script:templateRoot 'src/bot.ts') -Raw
        $delivery = Get-Content -LiteralPath (Join-Path $script:templateRoot 'src/delivery.ts') -Raw

        $bot | Should -Not -Match 'message:\s*error\.message'
        $bot | Should -Not -Match 'owner \$\{ownerObjectId\}'
        $delivery | Should -Not -Match 'message:\s*failure\.message'
        $delivery | Should -Not -Match 'failures\.push\(failure\)'
    }
}
