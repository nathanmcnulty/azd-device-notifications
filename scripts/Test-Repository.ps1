[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $Operation
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$Operation failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

foreach ($command in 'node', 'npm', 'az', 'git') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required for repository validation."
    }
}

$parseErrors = [System.Collections.Generic.List[object]]::new()
Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -Recurse -File |
    Where-Object Extension -in '.ps1', '.psm1' |
    ForEach-Object {
        $tokens = $null
        $fileErrors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile(
            $_.FullName,
            [ref] $tokens,
            [ref] $fileErrors
        )
        foreach ($fileError in @($fileErrors)) {
            $parseErrors.Add($fileError)
        }
    }
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Format-List | Out-String)
}

$analyzer = Get-Module -ListAvailable PSScriptAnalyzer |
    Where-Object Version -ge ([version] '1.24.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $analyzer) {
    throw 'PSScriptAnalyzer 1.24.0 or later is required for repository validation.'
}
Import-Module $analyzer.Path -Force
$analysis = @(Invoke-ScriptAnalyzer -Path (Join-Path $repositoryRoot 'scripts') -Recurse -Severity Error)
if ($analysis.Count -gt 0) {
    throw ($analysis | Format-Table -AutoSize | Out-String)
}

$pester = Get-Module -ListAvailable Pester |
    Where-Object Version -ge ([version] '5.7.1') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    throw 'Pester 5.7.1 or later is required for repository validation.'
}
Import-Module $pester.Path -Force
Set-StrictMode -Off
try {
    $testResult = Invoke-Pester -Path (Join-Path $repositoryRoot 'tests') -Output Detailed -PassThru
}
finally {
    Set-StrictMode -Version Latest
}
if ($testResult.FailedCount -gt 0) {
    throw "$($testResult.FailedCount) repository test(s) failed."
}

$sourceRoot = Join-Path $repositoryRoot 'src'
Invoke-CheckedCommand npm @('ci') $sourceRoot 'npm dependency installation'
Invoke-CheckedCommand npm @('test') $sourceRoot 'Node tests'
Invoke-CheckedCommand npm @('run', 'typecheck') $sourceRoot 'TypeScript typecheck'
Invoke-CheckedCommand npm @('run', 'build') $sourceRoot 'TypeScript build'
Invoke-CheckedCommand npm @('run', 'bundle') $sourceRoot 'Function bundle build'
Invoke-CheckedCommand npm @('audit', '--omit=dev', '--audit-level=high') $sourceRoot 'Production dependency audit'

$sourceHost = (Get-Content -LiteralPath (Join-Path $sourceRoot 'host.json') -Raw) -replace "`r`n", "`n"
$packagedHost = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'function-package/host.json') -Raw) -replace "`r`n", "`n"
if ($sourceHost -cne $packagedHost) {
    throw 'The packaged Function host.json differs from src/host.json.'
}

$catalog = Get-Content -LiteralPath (Join-Path $repositoryRoot '.azd/catalog.json') -Raw | ConvertFrom-Json
$parameters = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra/main.parameters.json') -Raw | ConvertFrom-Json
if ($null -eq $catalog -or $null -eq $parameters) {
    throw 'Template metadata did not parse as JSON.'
}

$missingLinks = [System.Collections.Generic.List[string]]::new()
$markdown = @(Get-Item -LiteralPath (Join-Path $repositoryRoot 'README.md')) +
    @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'docs') -Filter '*.md' -File)
foreach ($file in $markdown) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber++
        foreach ($match in [regex]::Matches($line, '\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)')) {
            $target = $match.Groups[1].Value
            if ($target -notmatch '^(https?://|mailto:)') {
                $resolved = Join-Path $file.DirectoryName $target
                if (-not (Test-Path -LiteralPath $resolved)) {
                    $missingLinks.Add("$($file.FullName):$lineNumber -> $target")
                }
            }
        }
    }
}
if ($missingLinks.Count -gt 0) {
    throw "Local documentation links are missing:`n$($missingLinks -join "`n")"
}

& az bicep version | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'An already-installed Bicep CLI is required for repository validation.'
}
Invoke-CheckedCommand az @('bicep', 'build', '--file', 'infra/main.bicep', '--no-restore') $repositoryRoot 'Bicep build'
Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra/main.json') -Raw | ConvertFrom-Json -Depth 100 | Out-Null

& git -C $repositoryRoot diff --exit-code -- function-package/index.cjs infra/main.json
if ($LASTEXITCODE -ne 0) {
    throw 'Generated Function or ARM output differs from the checked-in artifact.'
}
& git -C $repositoryRoot diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Git diff whitespace validation failed.'
}

Write-Host "Repository validation passed: $($testResult.PassedCount) Pester tests and all Node, audit, bundle, Bicep, metadata, and documentation gates."
