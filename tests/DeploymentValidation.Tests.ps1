BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:enginePath = Join-Path $repoRoot 'scripts/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1'
    Import-Module $enginePath -Force
    Import-Module (Join-Path $repoRoot 'scripts/Deployment.Validation.psm1') -Force
}

Describe 'Deployment validation adapter' {
    It 'defines stable checks with explicit side-effect classifications' {
        $definitions = @(Get-ProjectValidationDefinition)

        $definitions.Count | Should -Be 10
        @($definitions.id | Select-Object -Unique).Count | Should -Be 10
        ($definitions | Where-Object id -eq 'security.bot-rejects-unauthenticated').sideEffect |
            Should -Be 'negativeProbe'
        ($definitions | Where-Object id -eq 'delivery.synthetic-notification').sideEffect |
            Should -Be 'syntheticDelivery'
        @($definitions | Where-Object sideEffect -eq 'syntheticDelivery').Count | Should -Be 1
    }

    It 'plans every check without Azure, azd, web, or delivery calls' {
        Mock az { throw 'az must not run in Plan mode.' }
        Mock azd { throw 'azd must not run in Plan mode.' }
        Mock Invoke-WebRequest { throw 'HTTP must not run in Plan mode.' }

        $report = & (Join-Path $repoRoot 'scripts/Test-Deployment.ps1') -Plan -PassThru `
            -OutputPath 'reports/pester-plan.json'

        $report.mode | Should -Be 'plan'
        $report.outcome | Should -Be 'planned'
        $report.summary.planned | Should -Be 10
        $report.summary.fail | Should -Be 0
        Assert-MockCalled az -Times 0 -Exactly
        Assert-MockCalled azd -Times 0 -Exactly
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects an empty synthetic event selection' {
        {
            & (Join-Path $repoRoot 'scripts/Test-Deployment.ps1') -Plan -EventType @() `
                -OutputPath 'reports/invalid-empty-events.json'
        } | Should -Throw
    }

    It 'blocks every dependent action when exact context validation fails' {
        InModuleScope Deployment.Validation {
            $script:ValidationContextReady = $false
            Mock Initialize-DeviceNotificationValidationContext { throw 'simulated unavailable context' }
            Mock Get-DeviceNotificationValidationConfiguration { throw 'configuration must remain gated' }
            Mock az { throw 'Azure CLI must remain gated' }
            Mock Invoke-GraphJson { throw 'Graph must remain gated' }
            Mock Invoke-WebRequest { throw 'HTTP must remain gated' }

            $definitions = @(Get-ProjectValidationDefinition)
            $results = @(Invoke-AzdValidationSet -Definitions $definitions -AllowSyntheticDelivery)

            ($results | Where-Object id -eq 'context.azure-session').actual.failureCode |
                Should -Be 'context.sessionUnavailable'
            $unexpected = @(
                foreach ($result in $results | Where-Object {
                        $_.id -ne 'context.template-root' -and $_.id -ne 'context.azure-session'
                    }) {
                    $failureCode = if ($result.actual -is [System.Collections.IDictionary]) {
                        $result.actual['failureCode']
                    }
                    else {
                        $result.actual.PSObject.Properties['failureCode'].Value
                    }
                    if ($failureCode -ne 'context.prerequisite') {
                        "$($result.id):$($result.status)"
                    }
                }
            )
            $unexpected | Should -BeNullOrEmpty
            Assert-MockCalled Get-DeviceNotificationValidationConfiguration -Times 0 -Exactly
            Assert-MockCalled az -Times 0 -Exactly
            Assert-MockCalled Invoke-GraphJson -Times 0 -Exactly
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
        }
    }

    It 'accepts only authentication-specific Bot rejections as proof' {
        InModuleScope Deployment.Validation {
            $script:ValidationContextReady = $true
            $definition = @(Get-ProjectValidationDefinition | Where-Object id -eq 'security.bot-rejects-unauthenticated')

            Mock Invoke-WebRequest { [pscustomobject] @{ StatusCode = 404 } }
            $notFound = @(Invoke-AzdValidationSet -Definitions $definition)[0]
            $notFound.status | Should -Be 'fail'
            $notFound.actual.failureCode | Should -Be 'security.botUnexpectedStatus'

            Mock Invoke-WebRequest { [pscustomobject] @{ StatusCode = 401 } }
            $unauthorized = @(Invoke-AzdValidationSet -Definitions $definition)[0]
            $unauthorized.status | Should -Be 'pass'
            $unauthorized.actual | Should -Be 401
        }
    }

    It 'keeps the default wrapper free of azd environment mutations' {
        $wrapper = Get-Content (Join-Path $repoRoot 'scripts/Test-Deployment.ps1') -Raw
        $wrapper | Should -Not -Match 'Set-AzdEnvironmentValue'
        $wrapper | Should -Match 'AllowSyntheticDelivery:\$TestDelivery'
        $wrapper | Should -Match "OutputPath = 'reports/deployment-validation.json'"
    }

    It 'matches every vendored file to its locked hash' {
        $lock = Get-Content (Join-Path $repoRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'deployment-validation')

        $component.Count | Should -Be 1
        $component[0].version | Should -Be '0.2.0'
        $component[0].sourceRevision | Should -Match '^[0-9a-f]{40}$'
        foreach ($file in $component[0].files) {
            $actual = (Get-FileHash -LiteralPath (Join-Path $repoRoot $file.target) -Algorithm SHA256).Hash.ToLowerInvariant()
            $actual | Should -Be $file.sha256
        }
    }
}
