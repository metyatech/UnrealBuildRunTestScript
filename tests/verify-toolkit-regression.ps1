[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$passed = 0
$failed = 0

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    try {
        & $Body
        [Console]::Out.WriteLine("PASS $Name")
        $script:passed++
    }
    catch {
        [Console]::Out.WriteLine("FAIL ${Name}: $($_.Exception.Message)")
        $script:failed++
    }
}

$toolkitRoot = Split-Path $PSScriptRoot -Parent
$commonPath = Join-Path $toolkitRoot 'VerifyToolkit\VerifyToolkit.Common.ps1'
. $commonPath
$resolverScript = Join-Path $toolkitRoot 'Get-UEInstallPath.ps1'

Invoke-TestCase -Name 'build and test plan honors custom impact patterns' -Body {
    $plan = Resolve-BuildAndTestPlan -RequestedScope 'local' -ChangedFiles @('Docs/Verify.md') -ImpactPatterns @('Docs/*')
    if (-not $plan.ShouldRun) {
        throw 'Expected custom impact patterns to trigger Unreal verification.'
    }
    if ($plan.MatchedFiles.Count -ne 1 -or $plan.MatchedFiles[0] -ne 'Docs/Verify.md') {
        throw "Expected Docs/Verify.md to be matched, got: $($plan.MatchedFiles -join ', ')"
    }
}

Invoke-TestCase -Name 'automation filter narrowing honors custom spec patterns' -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("unreal-project-verify-spec-{0}" -f [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $tempDir
    try {
        $specPath = Join-Path $tempDir 'Tests\Gameplay\FooSpec.cpp'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $specPath -Parent)
        @'
BEGIN_DEFINE_SPEC(FFooSpec, "MyProject.Gameplay.Foo", EAutomationTestFlags::ProductFilter)
'@ | Set-Content -LiteralPath $specPath -Encoding ASCII

        $plan = Resolve-AutomationTestFilterPlan `
            -RequestedFilter 'MyProject' `
            -BuildAndTestPlan ([pscustomobject]@{
                    Scope = 'local'
                    ShouldRun = $true
                    MatchedFiles = @('Tests/Gameplay/FooSpec.cpp')
                }) `
            -RepoRoot $tempDir `
            -SpecPatterns @('Tests/*/*.cpp')

        if (-not $plan.Narrowed) {
            throw 'Expected the automation test filter to narrow for custom spec patterns.'
        }
        if ($plan.Filter -ne 'MyProject.Gameplay.Foo') {
            throw "Expected narrowed filter MyProject.Gameplay.Foo, got $($plan.Filter)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

Invoke-TestCase -Name 'project descriptor auto-detects the single repo-root .uproject and derives the project name' -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("unreal-project-verify-descriptor-{0}" -f [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $tempDir

    try {
        '@{}' | Set-Content -LiteralPath (Join-Path $tempDir 'AutoDetected.uproject') -Encoding ASCII

        $descriptor = Resolve-UnrealProjectDescriptor -RepoRoot $tempDir
        if ($descriptor.ProjectName -ne 'AutoDetected') {
            throw "Expected auto-detected project name AutoDetected, got: $($descriptor.ProjectName)"
        }
        if ([System.IO.Path]::GetFileName($descriptor.UProjectPath) -ne 'AutoDetected.uproject') {
            throw "Expected auto-detected .uproject path to end with AutoDetected.uproject, got: $($descriptor.UProjectPath)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

Invoke-TestCase -Name 'project descriptor requires explicit UProjectPath when multiple repo-root .uproject files exist' -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("unreal-project-verify-ambiguous-{0}" -f [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $tempDir

    try {
        '@{}' | Set-Content -LiteralPath (Join-Path $tempDir 'First.uproject') -Encoding ASCII
        '@{}' | Set-Content -LiteralPath (Join-Path $tempDir 'Second.uproject') -Encoding ASCII

        $threw = $false
        try {
            $null = Resolve-UnrealProjectDescriptor -RepoRoot $tempDir
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Set UProjectPath explicitly') {
                throw "Expected ambiguous project detection failure to require explicit UProjectPath, got: $($_.Exception.Message)"
            }
        }

        if (-not $threw) {
            throw 'Expected ambiguous repo-root .uproject detection to throw.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

Invoke-TestCase -Name 'installer scaffolds verify wrapper, config, and hook' -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("unreal-project-verify-install-{0}" -f [Guid]::NewGuid().ToString('N'))
    $repoDir = Join-Path $tempDir 'SampleRepo'
    $toolkitCopy = Join-Path $repoDir 'UnrealBuildRunTestScript'

    $null = New-Item -ItemType Directory -Force -Path $repoDir
    try {
        $null = & git -C $repoDir init
        if ($LASTEXITCODE -ne 0) {
            throw 'git init failed'
        }

        Copy-Item -LiteralPath $toolkitRoot -Destination $toolkitCopy -Recurse -Force
        '@{}' | Set-Content -LiteralPath (Join-Path $repoDir 'SampleRepo.uproject') -Encoding ASCII

        $installScript = Join-Path $toolkitCopy 'Install-UnrealProjectVerify.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript `
            -RepoRoot $repoDir `
            -DefaultBranchRef 'origin/main'
        if ($LASTEXITCODE -ne 0) {
            throw "Install-UnrealProjectVerify.ps1 failed with ExitCode=$LASTEXITCODE"
        }

        $verifyPath = Join-Path $repoDir 'Verify.ps1'
        $configPath = Join-Path $repoDir 'UnrealProjectVerify.config.psd1'
        $hookPath = Join-Path $repoDir '.githooks\pre-commit'

        foreach ($path in @($verifyPath, $configPath, $hookPath)) {
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Expected generated file not found: $path"
            }
        }

        $configText = Get-Content -LiteralPath $configPath -Raw
        if ($configText -match "ProjectName\s*=") {
            throw 'Expected generated config to omit ProjectName when auto-detection is sufficient.'
        }
        if ($configText -match "UProjectPath\s*=") {
            throw 'Expected generated config to omit UProjectPath when auto-detection is sufficient.'
        }
        if ($configText -notmatch "DefaultTestFilter = 'SampleRepo'") {
            throw 'Expected generated config to derive DefaultTestFilter from the auto-detected project name.'
        }
        if ($configText -match "'tests'") {
            throw 'Expected generated config to omit the tests lint path when the target repository has no tests directory.'
        }

        $verifyOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyPath `
            -SkipFormat `
            -SkipClangTidy `
            -SkipBuild `
            -SkipTests
        if ($LASTEXITCODE -ne 0) {
            throw "Expected installed Verify.ps1 to succeed with script lint enabled and Unreal phases skipped, got ExitCode=$LASTEXITCODE"
        }
        if (($verifyOutput -join [Environment]::NewLine) -notmatch 'VERIFY PASSED') {
            throw 'Expected installed Verify.ps1 to report VERIFY PASSED with script lint enabled and Unreal phases skipped.'
        }
        if (($verifyOutput -join [Environment]::NewLine) -notmatch '\[INFO\] Project: SampleRepo') {
            throw 'Expected installed Verify.ps1 to auto-detect and log the project name from the repo-root .uproject.'
        }

        $hookPathConfig = (& git -C $repoDir config --get core.hooksPath).Trim()
        if ($hookPathConfig -ne '.githooks') {
            throw "Expected core.hooksPath=.githooks, got: $hookPathConfig"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

Invoke-TestCase -Name 'Get-UEInstallPath prefers the generic CI engine root override' -Body {
    $overrideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("unreal-project-verify-engine-{0}" -f [Guid]::NewGuid().ToString('N'))
    $engineRoot = Join-Path $overrideRoot 'Engine'
    $savedOverride = [Environment]::GetEnvironmentVariable('UNREAL_VERIFY_CI_ENGINE_ROOT')

    $null = New-Item -ItemType Directory -Force -Path $engineRoot
    try {
        [Environment]::SetEnvironmentVariable('UNREAL_VERIFY_CI_ENGINE_ROOT', $overrideRoot, 'Process')
        $resolved = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolverScript -Version '5.6'
        if ($LASTEXITCODE -ne 0) {
            throw "Expected Get-UEInstallPath.ps1 to succeed, got ExitCode=$LASTEXITCODE"
        }

        if ($resolved.Trim() -ne $overrideRoot) {
            throw "Expected direct override root $overrideRoot, got $resolved"
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable('UNREAL_VERIFY_CI_ENGINE_ROOT', $savedOverride, 'Process')
        if (Test-Path -LiteralPath $overrideRoot) {
            Remove-Item -LiteralPath $overrideRoot -Recurse -Force
        }
    }
}

Invoke-TestCase -Name 'Get-UEInstallPath resolves a versioned install beneath the generic CI engine root override' -Body {
    $overrideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("unreal-project-verify-engine-root-{0}" -f [Guid]::NewGuid().ToString('N'))
    $versionedRoot = Join-Path $overrideRoot 'UE_5.6'
    $engineRoot = Join-Path $versionedRoot 'Engine'
    $savedOverride = [Environment]::GetEnvironmentVariable('UNREAL_VERIFY_CI_ENGINE_ROOT')

    $null = New-Item -ItemType Directory -Force -Path $engineRoot
    try {
        [Environment]::SetEnvironmentVariable('UNREAL_VERIFY_CI_ENGINE_ROOT', $overrideRoot, 'Process')
        $resolved = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolverScript -Version '5.6'
        if ($LASTEXITCODE -ne 0) {
            throw "Expected Get-UEInstallPath.ps1 to succeed, got ExitCode=$LASTEXITCODE"
        }

        if ($resolved.Trim() -ne $versionedRoot) {
            throw "Expected versioned override root $versionedRoot, got $resolved"
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable('UNREAL_VERIFY_CI_ENGINE_ROOT', $savedOverride, 'Process')
        if (Test-Path -LiteralPath $overrideRoot) {
            Remove-Item -LiteralPath $overrideRoot -Recurse -Force
        }
    }
}

[Console]::Out.WriteLine("$passed passed, $failed failed")
if ($failed -gt 0) {
    exit 1
}

exit 0
