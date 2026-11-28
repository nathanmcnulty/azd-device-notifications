BeforeAll {
    $script:repositoryRoot = Split-Path $PSScriptRoot -Parent

    function Invoke-RepositoryGateFixture {
        param([string] $Name, [string] $Tests)

        $fixtureRoot = Join-Path $TestDrive $Name
        $scriptsRoot = Join-Path $fixtureRoot 'scripts'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        [void] [IO.Directory]::CreateDirectory($scriptsRoot)
        [void] [IO.Directory]::CreateDirectory($testsRoot)
        [void] [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'src'))
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts/Test-Repository.ps1') `
            -Destination (Join-Path $scriptsRoot 'Test-Repository.ps1')
        [IO.File]::WriteAllText((Join-Path $testsRoot 'Fixture.Tests.ps1'), $Tests)

        # Run real Pester in a separate process. The first subsequent npm call
        # is a tripwire: a rejected suite must never reach dependency install.
        $runner = @'
$ErrorActionPreference = 'Stop'
$global:RepositoryGateRuntimeReached = $false
$failure = $null
function global:npm {
    param([Parameter(ValueFromRemainingArguments)][object[]] $Arguments)
    $global:RepositoryGateRuntimeReached = $true
    throw 'RepositoryGateFixtureRuntimeTripwire'
}
try {
    & '__VALIDATOR__'
    $outcome = 'unexpected-completion'
}
catch {
    $failure = $_.Exception.Message
    $outcome = if ($_.Exception.Message -eq 'RepositoryGateFixtureRuntimeTripwire') {
        'accepted-suite'
    } else {
        'rejected-suite'
    }
}
@{ outcome = $outcome; runtimeReached = $global:RepositoryGateRuntimeReached; failure = $failure } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath '__RESULT__'
'@
        $resultPath = Join-Path $fixtureRoot 'result.json'
        $validatorPath = Join-Path $scriptsRoot 'Test-Repository.ps1'
        $runner = $runner.Replace('__VALIDATOR__', $validatorPath.Replace("'", "''"))
        $runner = $runner.Replace('__RESULT__', $resultPath.Replace("'", "''"))
        $runnerPath = Join-Path $fixtureRoot 'Run-Fixture.ps1'
        [IO.File]::WriteAllText($runnerPath, $runner)

        $runtimeName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $runtimeName))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', $runnerPath)) {
            $start.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            [void] $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) {
                $process.Kill($true)
                [void] $process.WaitForExit(5000)
                throw 'Repository gate fixture exceeded its process deadline.'
            }
            $stdout.GetAwaiter().GetResult() | Out-Null
            $stderr.GetAwaiter().GetResult() | Out-Null
            $process.ExitCode | Should -Be 0
            Test-Path -LiteralPath $resultPath | Should -BeTrue
            Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        }
        finally {
            $process.Dispose()
        }
    }
}

Describe 'Repository validation rejects omitted PowerShell tests before Node work' {
    It 'admits a completely passed real suite' {
        $result = Invoke-RepositoryGateFixture 'passed' @'
Describe 'Fixture' { It 'passes' { 1 | Should -Be 1 } }
'@
        $result.outcome | Should -Be 'accepted-suite' -Because $result.failure
        $result.runtimeReached | Should -BeTrue
    }

    It 'rejects a passing suite that also contains a skipped test' {
        $result = Invoke-RepositoryGateFixture 'partly-skipped' @'
Describe 'Fixture' {
    It 'passes' { 1 | Should -Be 1 }
    It 'is skipped' -Skip { throw 'This test must not execute.' }
}
'@
        $result.outcome | Should -Be 'rejected-suite'
        $result.runtimeReached | Should -BeFalse
        $result.failure | Should -Match 'repository (?:test|validation)'
    }

    It 'rejects a suite in which every test is skipped' {
        $result = Invoke-RepositoryGateFixture 'all-skipped' @'
Describe 'Fixture' { It 'is skipped' -Skip { throw 'This test must not execute.' } }
'@
        $result.outcome | Should -Be 'rejected-suite'
        $result.runtimeReached | Should -BeFalse
        $result.failure | Should -Match 'repository (?:test|validation)'
    }

    It 'rejects an empty suite' {
        $result = Invoke-RepositoryGateFixture 'empty' '# No tests are declared.'
        $result.outcome | Should -Be 'rejected-suite'
        $result.runtimeReached | Should -BeFalse
        $result.failure | Should -Match 'repository (?:test|validation)'
    }

    It 'rejects a discovery failure before any runtime command' {
        $result = Invoke-RepositoryGateFixture 'discovery-failure' @'
Describe 'Fixture' {
    throw 'Intentional fixture discovery failure.'
    It 'cannot run' { 1 | Should -Be 1 }
}
'@
        $result.outcome | Should -Be 'rejected-suite'
        $result.runtimeReached | Should -BeFalse
        $result.failure | Should -Match 'repository (?:test|validation)'
    }
}
