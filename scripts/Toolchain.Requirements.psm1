Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-AzdGraphAuthenticationModule {
    $lockPath = Join-Path $PSScriptRoot '../toolchain.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw 'The repository toolchain lock is missing.'
    }

    $toolchain = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $requiredVersion = [version]$toolchain.administratorModules.'Microsoft.Graph.Authentication'.version
    if (-not $requiredVersion) {
        throw 'The exact Microsoft.Graph.Authentication version is missing from toolchain.lock.json.'
    }

    $loadedModules = @(Get-Module -Name Microsoft.Graph.Authentication)
    $incompatibleModules = @($loadedModules | Where-Object Version -ne $requiredVersion)
    if ($incompatibleModules.Count -gt 0) {
        $loadedVersions = ($incompatibleModules | ForEach-Object { $_.Version.ToString() }) -join ', '
        throw "Microsoft.Graph.Authentication $loadedVersions is already loaded in this PowerShell session. Start a fresh session so the helper can import the exact required version $requiredVersion."
    }

    $available = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
        Where-Object Version -eq $requiredVersion)
    if ($available.Count -eq 0) {
        throw "Microsoft.Graph.Authentication $requiredVersion is required. Install it with: Install-Module Microsoft.Graph.Authentication -RequiredVersion $requiredVersion -Scope CurrentUser."
    }

    Import-Module -Name Microsoft.Graph.Authentication -RequiredVersion $requiredVersion -Global -ErrorAction Stop
    $loaded = @(Get-Module -Name Microsoft.Graph.Authentication |
        Where-Object Version -eq $requiredVersion)
    if ($loaded.Count -eq 0) {
        throw "Microsoft.Graph.Authentication $requiredVersion did not load as the selected module version."
    }

    $connectCommand = Get-Command -Name Connect-MgGraph -ErrorAction SilentlyContinue
    if (-not $connectCommand -or $connectCommand.Module.Version -ne $requiredVersion) {
        throw "Connect-MgGraph is not exported by Microsoft.Graph.Authentication $requiredVersion."
    }
}

Export-ModuleMember -Function Import-AzdGraphAuthenticationModule
