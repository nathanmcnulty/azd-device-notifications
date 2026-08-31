[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$')]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$readinessPath = Join-Path $repositoryRoot '.release/readiness.json'
$readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json
$isPrerelease = $Version.Contains('-')
if (-not $isPrerelease -and $readiness.stableReleaseApproved -ne $true) {
    $reasons = @($readiness.blockingEvidence) -join ' '
    throw "Stable releases are blocked by .release/readiness.json. $reasons"
}

$revision = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$') {
    throw 'A full Git revision is required to produce release provenance.'
}
$commitDateText = (& git -C $repositoryRoot show -s --format=%cI $revision).Trim()
if ($LASTEXITCODE -ne 0) { throw 'The release commit timestamp could not be read.' }
$created = ([DateTimeOffset]::Parse($commitDateText)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
Get-ChildItem -LiteralPath $outputRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force

$artifactBase = "azd-device-notifications-function-$Version"
$archivePath = Join-Path $outputRoot "$artifactBase.zip"
$packageRoot = Join-Path $repositoryRoot 'function-package'
$packageFiles = @(
    'host.json',
    'index.cjs',
    'index.cjs.LEGAL.txt',
    'package.json',
    'THIRD-PARTY-NOTICES.txt',
    'UNLICENSE.txt'
)

$archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
try {
    $archive = [System.IO.Compression.ZipArchive]::new(
        $archiveStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        foreach ($relativePath in ($packageFiles | Sort-Object)) {
            $sourcePath = Join-Path $packageRoot $relativePath
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "The deployment package is missing $relativePath."
            }
            $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entry.ExternalAttributes = 0
            $inputStream = [System.IO.File]::OpenRead($sourcePath)
            $entryStream = $entry.Open()
            try { $inputStream.CopyTo($entryStream) }
            finally {
                $entryStream.Dispose()
                $inputStream.Dispose()
            }
        }
    }
    finally { $archive.Dispose() }
}
finally { $archiveStream.Dispose() }

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$lock = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src/package-lock.json') -Raw |
    ConvertFrom-Json -Depth 100 -AsHashtable
$packages = [System.Collections.Generic.List[object]]::new()
$relationships = [System.Collections.Generic.List[object]]::new()
$seenPackageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$rootSpdxId = 'SPDXRef-Package-DeviceNotificationsFunction'

$packages.Add([ordered]@{
    name = 'azd-device-notifications-function'
    SPDXID = $rootSpdxId
    versionInfo = $Version.Substring(1)
    downloadLocation = 'NOASSERTION'
    filesAnalyzed = $false
    licenseConcluded = 'NOASSERTION'
    licenseDeclared = 'Unlicense'
    copyrightText = 'NOASSERTION'
    checksums = @([ordered]@{ algorithm = 'SHA256'; checksumValue = $archiveHash })
})

foreach ($property in @($lock.packages.GetEnumerator() | Sort-Object Key)) {
    $package = $property.Value
    if ($property.Key -notmatch 'node_modules/' -or ($package.Contains('dev') -and $package.dev -eq $true)) { continue }
    if (-not $package.Contains('version') -or -not $package.version) { continue }
    $packageName = $property.Key -replace '^.*node_modules/', ''
    $keyBytes = [Text.Encoding]::UTF8.GetBytes("$packageName@$($package.version)")
    $keyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($keyBytes)).Substring(0, 16)
    $spdxId = "SPDXRef-Npm-$keyHash"
    if (-not $seenPackageIds.Add($spdxId)) { continue }
    $purlName = if ($packageName.StartsWith('@') -and $packageName.Contains('/')) {
        $parts = $packageName.Split('/', 2)
        "$([Uri]::EscapeDataString($parts[0]))/$([Uri]::EscapeDataString($parts[1]))"
    } else {
        [Uri]::EscapeDataString($packageName)
    }
    $declaredLicense = if ($package.Contains('license') -and $package.license -is [string] -and $package.license) {
        $package.license
    } else { 'NOASSERTION' }
    $entry = [ordered]@{
        name = $packageName
        SPDXID = $spdxId
        versionInfo = [string] $package.version
        downloadLocation = if ($package.Contains('resolved') -and $package.resolved) { [string] $package.resolved } else { 'NOASSERTION' }
        filesAnalyzed = $false
        licenseConcluded = 'NOASSERTION'
        licenseDeclared = $declaredLicense
        copyrightText = 'NOASSERTION'
        externalRefs = @([ordered]@{
            referenceCategory = 'PACKAGE-MANAGER'
            referenceType = 'purl'
            referenceLocator = "pkg:npm/$purlName@$($package.version)"
        })
    }
    if ($package.Contains('integrity') -and $package.integrity -match '^sha512-(.+)$') {
        $entry.checksums = @([ordered]@{
            algorithm = 'SHA512'
            checksumValue = [Convert]::ToHexString([Convert]::FromBase64String($Matches[1])).ToLowerInvariant()
        })
    }
    $packages.Add($entry)
    $relationships.Add([ordered]@{
        spdxElementId = $rootSpdxId
        relationshipType = 'CONTAINS'
        relatedSpdxElement = $spdxId
    })
}

$sbom = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = "$artifactBase.spdx"
    documentNamespace = "https://github.com/nathanmcnulty/azd-device-notifications/releases/tag/$Version/$revision"
    creationInfo = [ordered]@{
        created = $created
        creators = @('Tool: scripts/New-ReleaseArtifacts.ps1')
    }
    documentDescribes = @($rootSpdxId)
    packages = @($packages)
    relationships = @($relationships)
}
$sbomPath = Join-Path $outputRoot "$artifactBase.spdx.json"
$sbomJson = ($sbom | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($sbomPath, "$sbomJson`n", [Text.UTF8Encoding]::new($false))

$checksumPath = Join-Path $outputRoot 'SHA256SUMS'
$checksumLines = foreach ($path in @($archivePath, $sbomPath)) {
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($path))"
}
[System.IO.File]::WriteAllText($checksumPath, (($checksumLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

Write-Host "Created deterministic release artifacts for $Version at $outputRoot."
