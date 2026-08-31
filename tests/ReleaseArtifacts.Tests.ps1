BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ReleaseScript = Join-Path $script:RepositoryRoot 'scripts/New-ReleaseArtifacts.ps1'
}

Describe 'Release artifact generation' {
    It 'produces byte-identical prerelease artifacts and an SPDX 2.3 SBOM' {
        $first = Join-Path $TestDrive 'first'
        $second = Join-Path $TestDrive 'second'
        & $script:ReleaseScript -Version 'v0.1.0-rc.1' -OutputDirectory $first
        & $script:ReleaseScript -Version 'v0.1.0-rc.1' -OutputDirectory $second

        $firstFiles = @(Get-ChildItem -LiteralPath $first -File | Sort-Object Name)
        $secondFiles = @(Get-ChildItem -LiteralPath $second -File | Sort-Object Name)
        $firstFiles.Name | Should -Be $secondFiles.Name
        foreach ($file in $firstFiles) {
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath (Join-Path $second $file.Name) -Algorithm SHA256).Hash
        }

        $sbom = Get-Content -LiteralPath ($firstFiles | Where-Object Name -Like '*.spdx.json').FullName -Raw |
            ConvertFrom-Json
        $sbom.spdxVersion | Should -Be 'SPDX-2.3'
        $sbom.packages.Count | Should -BeGreaterThan 1
        @($sbom.packages | Group-Object SPDXID | Where-Object Count -gt 1).Count | Should -Be 0
        $sbom.packages[0].licenseDeclared | Should -Be 'Unlicense'
        (Get-Content -LiteralPath (Join-Path $first 'SHA256SUMS')).Count | Should -Be 2
    }

    It 'blocks a stable release while required live evidence is outstanding' {
        {
            & $script:ReleaseScript -Version 'v1.0.0' -OutputDirectory (Join-Path $TestDrive 'stable')
        } | Should -Throw '*Personal Teams direct-message delivery*'
    }

    It 'rejects a version that is not strict SemVer' -ForEach @(
        'v01.0.0-rc.1',
        'v1.00.0-rc.1',
        'v1.0.03-rc.1',
        'v1.0.0-01',
        'v1.0.0-rc..1',
        'v1.0.0-rc.',
        'v1.0.0-',
        'v1.0.0+build..1',
        '1.0.0-rc.1'
    ) {
        {
            & $script:ReleaseScript -Version $_ -OutputDirectory (Join-Path $TestDrive 'invalid')
        } | Should -Throw
    }
}
