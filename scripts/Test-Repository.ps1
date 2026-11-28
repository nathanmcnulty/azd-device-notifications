[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $repositoryRoot 'toolchain.lock.json') -Raw | ConvertFrom-Json
$requiredAnalyzerVersion = [version]$toolchain.validation.psScriptAnalyzerMinimumVersion
$requiredPesterVersion = [version]$toolchain.validation.pesterVersion
$requiredBicepVersion = [string]$toolchain.validation.bicepVersion

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
    Where-Object Version -ge $requiredAnalyzerVersion |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $analyzer) {
    throw "PSScriptAnalyzer $requiredAnalyzerVersion or later is required for repository validation."
}
Import-Module $analyzer.Path -Force
$analysis = @(Invoke-ScriptAnalyzer -Path (Join-Path $repositoryRoot 'scripts') -Recurse -Severity Error)
if ($analysis.Count -gt 0) {
    throw ($analysis | Format-Table -AutoSize | Out-String)
}

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object Version -eq $requiredPesterVersion |
    Select-Object -First 1
if (-not $pester) {
    throw "Pester $requiredPesterVersion is required for repository validation. Install it with: Install-Module Pester -RequiredVersion $requiredPesterVersion -Scope CurrentUser."
}
$loadedPesterModules = @(Get-Module -Name Pester)
$incompatiblePesterModules = @($loadedPesterModules | Where-Object Version -ne $requiredPesterVersion)
if ($incompatiblePesterModules.Count -gt 0) {
    $loadedVersions = ($incompatiblePesterModules | ForEach-Object { $_.Version.ToString() }) -join ', '
    throw "Pester $loadedVersions is already loaded in this PowerShell session. Start a fresh session so repository validation can import exact Pester $requiredPesterVersion."
}
if ($loadedPesterModules.Count -eq 0) {
    Import-Module $pester.Path -Force
}
$loadedPester = @(Get-Module -Name Pester | Where-Object Version -eq $requiredPesterVersion)
if ($loadedPester.Count -eq 0) {
    throw "Pester $requiredPesterVersion was not loaded for repository validation."
}
$invokePesterCommand = Get-Command -Name Invoke-Pester -ErrorAction Stop
if ($invokePesterCommand.Module.Version -ne $requiredPesterVersion) {
    throw "Invoke-Pester resolves to version $($invokePesterCommand.Module.Version), not the selected Pester $requiredPesterVersion."
}

Import-Module (Join-Path $PSScriptRoot 'Toolchain.Requirements.psm1') -Force
Import-AzdGraphAuthenticationModule
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
Invoke-CheckedCommand npm @('run', 'test:startup') $sourceRoot 'Real BotBuilder startup'
Invoke-CheckedCommand npm @('audit', '--omit=dev', '--audit-level=high') $sourceRoot 'Production dependency audit'

$deploymentPackageFiles = @(
    'host.json',
    'index.cjs',
    'index.cjs.LEGAL.txt',
    'package.json',
    'THIRD-PARTY-NOTICES.txt',
    'UNLICENSE.txt'
)
foreach ($file in $deploymentPackageFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot "function-package/$file") -PathType Leaf)) {
        throw "The packaged Function artifact is missing required file: function-package/$file."
    }
}
$packageRoot = Join-Path $repositoryRoot 'function-package'
$packageArchive = Join-Path ([System.IO.Path]::GetTempPath()) ("azd-device-notifications-$([guid]::NewGuid().ToString('N')).zip")
try {
    Compress-Archive -Path ($deploymentPackageFiles | ForEach-Object { Join-Path $packageRoot $_ }) `
        -DestinationPath $packageArchive -CompressionLevel Optimal
    $archive = [System.IO.Compression.ZipFile]::OpenRead($packageArchive)
    try {
        $archiveEntries = @($archive.Entries | ForEach-Object FullName | Sort-Object)
    }
    finally {
        $archive.Dispose()
    }
    if (@(Compare-Object -ReferenceObject ($deploymentPackageFiles | Sort-Object) -DifferenceObject $archiveEntries).Count -gt 0) {
        throw 'The rebuilt Function ZIP does not contain exactly the required deployment artifact files.'
    }
}
finally {
    if (Test-Path -LiteralPath $packageArchive -PathType Leaf) {
        [System.IO.File]::Delete($packageArchive)
    }
}

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

$bicepVersionOutput = (& az bicep version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'An already-installed Bicep CLI is required for repository validation.'
}
if ($bicepVersionOutput -notmatch "(?m)^Bicep CLI version $([regex]::Escape($requiredBicepVersion))(?:\s|$)") {
    throw "Bicep CLI $requiredBicepVersion is required for repository validation. Found: $bicepVersionOutput"
}
Invoke-CheckedCommand az @('bicep', 'build', '--file', 'infra/main.bicep', '--no-restore') $repositoryRoot 'Bicep build'
$compiledTemplate = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra/main.json') -Raw | ConvertFrom-Json -Depth 100
$expectedGeneratorPrefix = [regex]::Escape($requiredBicepVersion) + '\.'
if ([string]$compiledTemplate.metadata._generator.version -notmatch "^$expectedGeneratorPrefix") {
    throw "Generated ARM metadata does not identify Bicep $requiredBicepVersion."
}

& git -C $repositoryRoot diff --exit-code -- function-package/index.cjs function-package/index.cjs.LEGAL.txt `
    function-package/THIRD-PARTY-NOTICES.txt function-package/UNLICENSE.txt infra/main.json
if ($LASTEXITCODE -ne 0) {
    throw 'Generated Function bundle, license files, or ARM output differs from the checked-in artifact.'
}
& git -C $repositoryRoot diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Git diff whitespace validation failed.'
}

Write-Host "Repository validation passed: $($testResult.PassedCount) Pester tests and all Node, audit, bundle, Bicep, metadata, and documentation gates."
