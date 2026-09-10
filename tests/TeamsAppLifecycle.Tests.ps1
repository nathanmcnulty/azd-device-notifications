BeforeAll { $script:repoRoot = Split-Path $PSScriptRoot -Parent }

Describe 'Teams personal app lifecycle contracts' {
    BeforeAll {
        $script:installer = Get-Content (Join-Path $repoRoot 'scripts/Install-TeamsPersonalApp.ps1') -Raw
        $script:cleanup = Get-Content (Join-Path $repoRoot 'scripts/Remove-TeamsPersonalApp.ps1') -Raw
    }

    It 'separates the administrator from the exact recipient object ID before mutation' {
        $installer | Should -Match '\[string\] \$AdminUpn'
        $installer | Should -Match '\[guid\] \$UserId'
        $installer | Should -Match 'context\.Account -ine \$AdminUpn'
        $installer | Should -Match "'AppCatalog\.ReadWrite\.All', 'TeamsAppInstallation\.ReadWriteForUser'"
        $installer | Should -Not -Match 'User\.ReadBasic\.All|UserUpn|encodedUpn'
        $identityCheck = $installer.IndexOf('DEVICE_NOTIFICATION_TEAMS_USER_ID = [string]$UserId')
        $firstMutation = $installer.IndexOf("Invoke-MgGraphRequest -Method POST -Uri '/v1.0/appCatalogs/teamsApps'")
        $identityCheck | Should -BeGreaterOrEqual 0
        $firstMutation | Should -BeGreaterThan $identityCheck
    }

    It 'versions catalog packages and updates only through appDefinitions' {
        $installer | Should -Match 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION'
        $installer | Should -Match 'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256'
        $installer | Should -Match '/appDefinitions'
        $installer | Should -Match '\[switch\] \$UpdateExisting'
        $installer | Should -Match 'elseif \(\$catalogWasCreated\)'
        $installer | Should -Match 'canonicalEntries'
        $installer | Should -Match 'recordedPackageHashMatches'
        $installer | Should -Match "recoverableCreate[\s\S]+recordedPackageHashMatches"
        $installer | Should -Match "publishingState -ceq 'published'"
        $installer | Should -Match '\[version\]\$_.version -gt \$packageVersion'
        $installer | Should -Match 'teamsAppDefinition\.version -cne \$packageVersionText'
        $installer | Should -Match "Properties\['@odata\.nextLink'\]"
        ([regex]::Matches($installer, "Properties\['@odata\.nextLink'\]").Count) | Should -BeGreaterThan 1
        $installer | Should -Match 'recordedAdopted'
        $installer | Should -Match 'recordedAdoptedInstall'
        $installer | Should -Not -Match 'Update-M365TeamsApp|Connect-MicrosoftTeams'
    }

    It 'binds cleanup to the recorded administrator, tenant, workload, and target identity' {
        $cleanup | Should -Match 'DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN'
        $cleanup | Should -Match 'context\.Account -ine \$env:DEVICE_NOTIFICATION_TEAMS_ADMIN_UPN'
        $cleanup | Should -Match 'EscapeDataString\(\$env:DEVICE_NOTIFICATION_TEAMS_USER_ID\)'
        $cleanup | Should -Not -Match 'encodedUpn|targetUser\.|User\.ReadBasic\.All'
        $cleanup | Should -Match "'AppCatalog\.ReadWrite\.All', 'TeamsAppInstallation\.ReadWriteForUser'"
    }

    It 'recovers pending catalog and installation intents by exact workload identity' {
        $cleanup | Should -Match "catalogOwnership -eq 'create-pending'"
        $cleanup | Should -Match ([regex]::Escape('externalId eq ''$($env:AZURE_WORKLOAD_CLIENT_ID)'''))
        $cleanup | Should -Match "installOwnership -eq 'create-pending'"
        $cleanup | Should -Match 'teamsApp/externalId eq'
        $cleanup | Should -Match "Properties\['@odata\.nextLink'\]"
        $cleanup | Should -Match 'catalogMatches\.Count -gt 1'
        $cleanup | Should -Match 'installationMatches\.Count -gt 1'
        $cleanup | Should -Match 'installation\.teamsApp\.externalId -ine \$env:AZURE_WORKLOAD_CLIENT_ID'
    }

    It 'treats only an HTTP 404 as idempotent absence' {
        $cleanup | Should -Match ([regex]::Escape('[int]$candidate -eq 404'))
        $cleanup | Should -Match 'if \(Test-GraphNotFound \$_\) \{ return \$null \}'
        $cleanup | Should -Not -Match "Exception\.Message -notmatch.*404"
    }

    It 'deletes only created or pending objects and preserves adopted objects' {
        $cleanup | Should -Match "installOwnership -in @\('create-pending', 'created'\)"
        $cleanup | Should -Match "catalogOwnership -in @\('create-pending', 'created'\)"
        $cleanup | Should -Not -Match "-in @\([^\r\n]*'adopted'"
        $cleanup | Should -Match "installOwnership -eq 'adopted'"
        $cleanup | Should -Match 'cannot be removed while its recorded personal installation is adopted'
        $cleanup | Should -Not -Match 'Update-M365TeamsApp'
    }

    It 'verifies both deletes before clearing any ownership receipts' {
        $installDelete = $cleanup.IndexOf("Invoke-MgGraphRequest -Method DELETE -Uri `$installationUri")
        $installVerify = $cleanup.IndexOf('Wait-TeamsGraphResourceAbsent -Uri $installationUri')
        $catalogDelete = $cleanup.IndexOf("Invoke-MgGraphRequest -Method DELETE -Uri `$catalogUri")
        $catalogVerify = $cleanup.IndexOf('Wait-TeamsGraphResourceAbsent -Uri $catalogUri')
        $clear = $cleanup.IndexOf("Set-AzdEnvironmentValue `$name ''")

        $installDelete | Should -BeGreaterOrEqual 0
        $installVerify | Should -BeGreaterThan $installDelete
        $catalogDelete | Should -BeGreaterThan $installVerify
        $catalogVerify | Should -BeGreaterThan $catalogDelete
        $clear | Should -BeGreaterThan $catalogVerify
        $cleanup | Should -Match 'still exists after the delete request\. Cleanup receipts were preserved\.'
        foreach ($receipt in @(
                'DEVICE_NOTIFICATION_TEAMS_PACKAGE_VERSION',
                'DEVICE_NOTIFICATION_TEAMS_PACKAGE_SHA256',
                'DEVICE_NOTIFICATION_TEAMS_CATALOG_UPDATE_STATUS'
            )) {
            $cleanup | Should -Match $receipt
        }
    }

    It 'keeps WhatIf free of deletion and receipt clearing through ShouldProcess guards' {
        $cleanup | Should -Match ([regex]::Escape("ShouldProcess(`$installation.id, 'Remove solution-owned personal Teams app installation')"))
        $cleanup | Should -Match ([regex]::Escape("ShouldProcess(`$catalogApp.id, 'Remove solution-owned Teams catalog app')"))
        $cleanup | Should -Match 'if \(-not \$WhatIfPreference\)'
    }

    It 'does not emit the unsupported Teams manifest packageName property' {
        $packager = Get-Content (Join-Path $repoRoot 'scripts/New-TeamsAppPackage.ps1') -Raw
        $packager | Should -Not -Match "(?m)^\s*packageName\s*="
        $packager | Should -Match 'version = \$AppVersion'
        $packager | Should -Match 'docs/terms\.md'
    }

}
