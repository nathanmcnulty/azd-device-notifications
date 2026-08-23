[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'deploy', 'package')]
    [string] $Command = 'up',

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $AzdArguments = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw 'Azure Developer CLI (azd) is required. Install it, then rerun this command.'
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    if (-not $IsWindows) {
        throw 'Automatic portable Node setup currently supports Windows. Install Node.js 22 or later, then rerun this command.'
    }

    $nodeVersion = 'v22.17.1'
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $packages = @{
        X64 = [pscustomobject]@{
            Name = "node-$nodeVersion-win-x64"
            Sha256 = 'b1fdb5635ba860f6bf71474f2ca882459a582de49b1d869451e3ad188e3943eb'
        }
        Arm64 = [pscustomobject]@{
            Name = "node-$nodeVersion-win-arm64"
            Sha256 = '588d42c7c90eecf14ed4fc126a64cc70993e3a002f93e26be9c979cdc516b0d3'
        }
    }
    $package = $packages[$architecture]
    if (-not $package) { throw "Automatic portable Node setup does not support Windows $architecture." }

    $repoRoot = Split-Path $PSScriptRoot -Parent
    $toolsRoot = Join-Path $repoRoot '.azure/tools'
    $nodeRoot = Join-Path $toolsRoot $package.Name
    $npmPath = Join-Path $nodeRoot 'npm.cmd'
    if (-not (Test-Path -LiteralPath $npmPath)) {
        New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
        $archivePath = Join-Path $toolsRoot "$($package.Name).zip"
        $downloadPath = "$archivePath.download"
        $downloadUri = "https://nodejs.org/dist/$nodeVersion/$($package.Name).zip"

        Write-Host "Downloading a portable Node.js toolchain for this azd environment..."
        Invoke-WebRequest -Uri $downloadUri -OutFile $downloadPath -UseBasicParsing
        $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
        if ($actualHash -ne $package.Sha256) {
            throw "Portable Node.js archive hash validation failed. Expected $($package.Sha256), received $actualHash."
        }
        Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
        Expand-Archive -LiteralPath $archivePath -DestinationPath $toolsRoot -Force
    }

    $env:PATH = "$nodeRoot;$env:PATH"
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'Portable Node.js setup completed, but npm is not available.'
    }
}

& azd $Command @AzdArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
