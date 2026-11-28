BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Toolchain = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'toolchain.lock.json') -Raw | ConvertFrom-Json
}

Describe 'Pinned toolchain selections' {
    It 'records the exact validation and Graph module versions with package integrity metadata' {
        $script:Toolchain.schemaVersion | Should -Be 1
        $script:Toolchain.validation.testedPowerShellVersion | Should -Be '7.6.6'
        $script:Toolchain.validation.pesterVersion | Should -Be '6.2.0'
        $script:Toolchain.validation.bicepVersion | Should -Be '0.46.1'
        $script:Toolchain.azdBicepCompiler.environmentVariable | Should -Be 'AZD_BICEP_TOOL_PATH'
        $script:Toolchain.azdBicepCompiler.banner | Should -Be 'Bicep CLI version 0.46.1 (545b338e2c)'
        $script:Toolchain.azdBicepCompiler.linuxX64BinarySha256 |
            Should -Be '3e011d629ea4311b7a7dd8f0040ab2b1a072ea4ff5d02cb75e0e55a9a6703fb9'
        $script:Toolchain.administratorModules.'Microsoft.Graph.Authentication'.version | Should -Be '2.41.0'
        $script:Toolchain.administratorModules.'Microsoft.Graph.Authentication'.source | Should -Be 'PowerShell Gallery'
        $script:Toolchain.administratorModules.'Microsoft.Graph.Authentication'.projectUrl |
            Should -Be 'https://github.com/microsoftgraph/msgraph-sdk-powershell'
        $script:Toolchain.administratorModules.'Microsoft.Graph.Authentication'.packageSha256 |
            Should -Be '42e8b7a8bba6afd1910510d8108c1871ee5d12c5a4818cc4c36ca406369a7afd'
        $script:Toolchain.administratorModules.'Microsoft.Graph.Authentication'.payloadFiles | Should -Be 58
    }

    It 'installs exact Pester and Graph versions and Bicep in both CI validation paths' {
        foreach ($workflowPath in @('.github/workflows/validate.yml', '.github/workflows/release.yml')) {
            $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $workflowPath) -Raw
            $workflow | Should -Match 'Install-Module Pester -RequiredVersion 6\.2\.0'
            $workflow | Should -Match 'Install-Module Microsoft\.Graph\.Authentication -RequiredVersion 2\.41\.0'
            $workflow | Should -Match 'az bicep install --version v0\.46\.1'
            $workflow | Should -Not -Match 'Install-Module Pester -RequiredVersion 5\.7\.1'
        }
    }

    It 'imports the exact Graph module selected by the toolchain lock' {
        $requirementsPath = Join-Path $script:RepositoryRoot 'scripts/Toolchain.Requirements.psm1'
        $requirements = Get-Content -LiteralPath $requirementsPath -Raw
        $requirements | Should -Match 'toolchain\.lock\.json'
        $requirements | Should -Match '-RequiredVersion \$requiredVersion'
        $requirements | Should -Match 'already loaded in this PowerShell session'

        foreach ($scriptPath in @('scripts/Install-TeamsPersonalApp.ps1', 'scripts/Remove-TeamsPersonalApp.ps1')) {
            $scriptText = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $scriptPath) -Raw
            $scriptText | Should -Match 'Import-AzdGraphAuthenticationModule'
            $scriptText | Should -Not -Match 'Import-Module Microsoft\.Graph\.Authentication(?![^\r\n]*RequiredVersion)'
        }

        $loadedExactVersion = @(Get-Module -Name Microsoft.Graph.Authentication |
            Where-Object Version -eq ([version]'2.41.0'))
        $loadedExactVersion.Count | Should -Be 1
    }

    It 'keeps the Graph PowerShell module outside the deployed Function package boundary' {
        foreach ($packagePath in @('src/package.json', 'function-package/package.json')) {
            $package = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $packagePath) -Raw
            $package | Should -Not -Match 'Microsoft\.Graph\.Authentication'
        }

        $repositoryValidation = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidation | Should -Match 'Compress-Archive'
        $repositoryValidation | Should -Match 'required deployment artifact files'
        $repositoryValidation | Should -Match 'already loaded in this PowerShell session'
    }

    It 'matches the committed ARM banner to the selected Bicep release' {
        $compiled = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'infra/main.json') -Raw | ConvertFrom-Json -Depth 100
        $compiled.metadata._generator.name | Should -Be 'bicep'
        [string]$compiled.metadata._generator.version | Should -Match '^0\.46\.1\.'

        $deploymentDocs = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/deployment.md') -Raw
        $deploymentDocs | Should -Match 'AZD_BICEP_TOOL_PATH'
        $deploymentDocs | Should -Match 'absolute path of the selected Bicep 0\.46\.1 binary'
        $compilerSetupBlock = [regex]::Match($deploymentDocs, '(?s)```powershell\s*(\$env:AZD_BICEP_TOOL_PATH[^`]+)```').Groups[1].Value
        $compilerSetupBlock | Should -Not -Match '\bazd\s+up\b'
    }
}
