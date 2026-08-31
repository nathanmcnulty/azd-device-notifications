BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:GeneratedPaths = @(
        'function-package/index.cjs'
        'function-package/index.cjs.LEGAL.txt'
        'function-package/THIRD-PARTY-NOTICES.txt'
        'function-package/UNLICENSE.txt'
        'infra/main.json'
    )
}

Describe 'Generated validation artifact line endings' {
    It 'pins every tracked generator output to LF text' {
        $attributes = @(& git -C $script:RepositoryRoot check-attr text eol -- @script:GeneratedPaths)
        $LASTEXITCODE | Should -Be 0

        foreach ($path in $script:GeneratedPaths) {
            $attributes | Should -Contain "${path}: text: set"
            $attributes | Should -Contain "${path}: eol: lf"
        }
    }

    It 'leaves a Windows-style checkout clean after generators rewrite LF bytes' {
        $fixtureRepository = Join-Path $TestDrive 'repository'
        $validationWorktree = Join-Path $TestDrive 'validation-worktree'
        [System.IO.Directory]::CreateDirectory($fixtureRepository) | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.gitattributes') -Destination $fixtureRepository

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        foreach ($path in $script:GeneratedPaths) {
            $fixturePath = Join-Path $fixtureRepository $path
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $fixturePath)) | Out-Null
            [System.IO.File]::WriteAllText($fixturePath, "generated`ncontent`n", $utf8NoBom)
        }

        & git -C $fixtureRepository init --initial-branch main | Out-Null
        $LASTEXITCODE | Should -Be 0
        & git -C $fixtureRepository config user.name 'Generated line ending test'
        & git -C $fixtureRepository config user.email 'generated-line-ending-test@example.invalid'
        & git -C $fixtureRepository config core.autocrlf true
        & git -C $fixtureRepository add -- .gitattributes @script:GeneratedPaths
        $LASTEXITCODE | Should -Be 0
        & git -C $fixtureRepository commit -m 'test fixture' | Out-Null
        $LASTEXITCODE | Should -Be 0
        & git -C $fixtureRepository worktree add -b validation $validationWorktree HEAD | Out-Null
        $LASTEXITCODE | Should -Be 0

        foreach ($path in $script:GeneratedPaths) {
            $validationPath = Join-Path $validationWorktree $path
            [System.IO.File]::ReadAllBytes($validationPath) | Should -Not -Contain 13
            [System.IO.File]::WriteAllText($validationPath, "generated`ncontent`n", $utf8NoBom)
        }

        @(& git -C $validationWorktree status --porcelain -- @script:GeneratedPaths).Count | Should -Be 0
        & git -C $fixtureRepository worktree remove $validationWorktree | Out-Null
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $validationWorktree | Should -BeFalse
    }
}
