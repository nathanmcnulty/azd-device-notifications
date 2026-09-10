BeforeAll { $script:repoRoot = Split-Path $PSScriptRoot -Parent }

Describe 'Teams personal app lifecycle contracts' {
    It 'does not emit the unsupported packageName property' {
        Get-Content (Join-Path $repoRoot 'scripts/New-TeamsAppPackage.ps1') -Raw |
            Should -Not -Match "(?m)^\s*packageName\s*="
    }

    It 'publishes and installs with narrowly scoped delegated Graph access' {
        $installer = Get-Content (Join-Path $repoRoot 'scripts/Install-TeamsPersonalApp.ps1') -Raw
        $installer | Should -Match "'AppCatalog\.ReadWrite\.All', 'TeamsAppInstallation\.ReadWriteForUser'"
        $installer | Should -Match "-Uri '/v1\.0/appCatalogs/teamsApps'"
        $installer | Should -Match '/teamwork/installedApps'
        $installer | Should -Match "scopes\[0\].*-cne 'personal'"
        $installer | Should -Match 'isNotificationOnly.*-ne \$true'
        $installer | Should -Match "CATALOG_OWNERSHIP' 'create-pending'"
        $installer | Should -Match "INSTALL_OWNERSHIP' 'create-pending'"
        $installer | Should -Match 'Update-M365TeamsApp.*-AppAssignmentType UsersAndGroups'
        $installer | Should -Match "AVAILABILITY_OWNERSHIP' 'create-pending'"
        $installer | Should -Match 'blocked by app permission policy'
        $installer | Should -Match '\[switch\] \$AdoptExisting'
        $installer | Should -Not -Match '/teams/'
    }

    It 'removes only objects bound to exact recorded creation receipts' {
        $cleanup = Get-Content (Join-Path $repoRoot 'scripts/Remove-TeamsPersonalApp.ps1') -Raw
        $cleanup | Should -Match "INSTALL_OWNERSHIP -match '\^\(create-pending\|created\)\$'"
        $cleanup | Should -Match "CATALOG_OWNERSHIP -match '\^\(create-pending\|created\)\$'"
        $cleanup | Should -Match 'teamsApp\.externalId -cne \$env:AZURE_WORKLOAD_CLIENT_ID'
        $cleanup | Should -Match 'distributionMethod.*organization'
        $cleanup | Should -Not -Match "OWNERSHIP -match.*adopted"
    }
}
