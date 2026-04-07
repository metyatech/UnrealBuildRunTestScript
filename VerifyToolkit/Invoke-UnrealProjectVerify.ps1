[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Scope = 'Function', Target = 'Assert-CommandExists', Justification = 'Internal helper keeps the imperative wording used by the verify entry point.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Scope = 'Function', Target = 'Get-ChangedCppFiles', Justification = 'Internal helper name keeps parity with the surrounding verify script terminology.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Scope = 'Function', Target = 'Get-ChangedFormatFiles', Justification = 'Internal helper name keeps parity with the surrounding verify script terminology.')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$TestFilter,

    [ValidateSet('DebugGame', 'Development', 'Shipping')]
    [string]$Configuration = 'Development',

    [ValidateSet('Win64')]
    [string]$Platform = 'Win64',

    [string]$ClangTidyBaseRef,

    [switch]$ClangTidyAll,
    [switch]$FormatAll,
    [ValidateSet('auto', 'local', 'pr', 'push', 'all')]
    [string]$StaticAnalysisScope = 'auto',
    [ValidateSet('auto', 'local', 'all')]
    [string]$BuildAndTestScope = 'auto',
    [int]$StaticAnalysisMaxConcurrency = 0,

    [switch]$SkipScriptLint,
    [switch]$SkipFormat,
    [switch]$SkipClangTidy,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$AllowMissingHookTestShell,

    # By default, run render-path tests (matches BuildAndTest.bat behavior).
    [switch]$EnableNullRHI,

    [switch]$DisableRenderOffscreen,
    [switch]$DisableUnattended,
    [switch]$DisableNoSound
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info([string]$Message) { [Console]::Out.WriteLine("[INFO] $Message") }
function Write-Err([string]$Message) { [Console]::Error.WriteLine("[ERROR] $Message") }

function Assert-RegressionTestResultShape {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [psobject]$Result
    )

    if ($null -eq $Result) {
        throw 'Regression test result must not be $null.'
    }

    $requiredProperties = @('ExitCode', 'Stdout', 'Stderr', 'LastOutputLine')
    $missingProperties = [System.Collections.Generic.List[string]]::new()
    $isDictionary = $Result -is [System.Collections.IDictionary]

    foreach ($propertyName in $requiredProperties) {
        $hasProperty = if ($isDictionary) {
            $Result.Contains($propertyName)
        }
        else {
            $null -ne $Result.PSObject.Properties[$propertyName]
        }

        if (-not $hasProperty) {
            $missingProperties.Add($propertyName)
        }
    }

    if ($missingProperties.Count -gt 0) {
        throw "Regression test result must be an object or dictionary with ExitCode, Stdout, Stderr, and LastOutputLine members. Missing: $($missingProperties -join ', ')."
    }

    $exitCode = if ($isDictionary) { $Result['ExitCode'] } else { $Result.ExitCode }
    if ($exitCode -isnot [int]) {
        $actualType = if ($null -eq $exitCode) { '<null>' } else { $exitCode.GetType().FullName }
        throw "Regression test result property 'ExitCode' must be of type [int]. Actual type: $actualType."
    }

    foreach ($propertyName in @('Stdout', 'Stderr', 'LastOutputLine')) {
        $propertyValue = if ($isDictionary) { $Result[$propertyName] } else { $Result.$propertyName }
        if ($null -ne $propertyValue -and $propertyValue -isnot [string]) {
            $actualType = $propertyValue.GetType().FullName
            throw "Regression test result property '$propertyName' must be of type [string] or `$null. Actual type: $actualType."
        }
    }
}

function Write-RegressionTestResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [psobject]$Result
    )

    Assert-RegressionTestResultShape -Result $Result
    $isDictionary = $Result -is [System.Collections.IDictionary]
    $exitCode = if ($isDictionary) { $Result['ExitCode'] } else { $Result.ExitCode }

    if ($exitCode -ne 0) {
        throw "Write-RegressionTestResult only accepts successful results for '$Label' (ExitCode=$([string]$exitCode))."
    }

    $summaryValue = if ($isDictionary) { $Result['LastOutputLine'] } else { $Result.LastOutputLine }
    $summary = [string]$summaryValue
    if ([string]::IsNullOrWhiteSpace($summary)) {
        Write-Info "$Label passed."
        return
    }

    Write-Info "$Label passed: $summary"
}

function Invoke-RegressionTestCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [object[]]$ArgumentList = @(),

        [string]$WorkingDirectory
    )

    try {
        return Invoke-ExternalCommandQuietOnSuccess `
            -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -WorkingDirectory $WorkingDirectory
    }
    catch {
        $_.ErrorDetails = [System.Management.Automation.ErrorDetails]::new("${Label} failed: $($_.Exception.Message)")
        $_.Exception.Data['RegressionTestLabel'] = $Label
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Assert-CommandExists {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $Name"
    }
}

function Get-ConfigStringArray {
    param(
        [object]$Value,
        [string[]]$Default = @()
    )

    if ($null -eq $Value) {
        return @($Default)
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return @()
        }
        return @($Value)
    }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) {
            continue
        }

        $text = [string]$entry
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $items.Add($text)
    }

    if ($items.Count -eq 0) {
        return @($Default)
    }

    return @($items)
}

function Import-UnrealProjectVerifyConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $rawConfig = Import-PowerShellDataFile -LiteralPath $resolvedPath
    if ($null -eq $rawConfig) {
        throw "Verify config was empty: $resolvedPath"
    }

    $isDictionary = $rawConfig -is [System.Collections.IDictionary]
    function Get-OptionalConfigEntryValue {
        param([string]$Name)

        if ($isDictionary) {
            if ($rawConfig.Contains($Name)) {
                return $rawConfig[$Name]
            }
            return $null
        }

        $property = $rawConfig.PSObject.Properties[$Name]
        if ($null -ne $property) {
            return $property.Value
        }

        return $null
    }

    $projectName = [string](Get-OptionalConfigEntryValue -Name 'ProjectName')
    $defaultTestFilter = [string](Get-OptionalConfigEntryValue -Name 'DefaultTestFilter')
    if ([string]::IsNullOrWhiteSpace($defaultTestFilter) -and -not [string]::IsNullOrWhiteSpace($projectName)) {
        $defaultTestFilter = $projectName
    }

    $defaultBranchRef = [string](Get-OptionalConfigEntryValue -Name 'DefaultBranchRef')
    if ([string]::IsNullOrWhiteSpace($defaultBranchRef)) {
        $defaultBranchRef = 'origin/main'
    }

    $normalizedRegressionTests = [System.Collections.Generic.List[psobject]]::new()
    foreach ($entry in @(Get-OptionalConfigEntryValue -Name 'RegressionTests')) {
        if ($null -eq $entry) {
            continue
        }

        $label = [string]$entry.Label
        $scriptPath = [string]$entry.ScriptPath
        if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($scriptPath)) {
            throw "Each RegressionTests entry must define Label and ScriptPath in: $resolvedPath"
        }

        $normalizedRegressionTests.Add([pscustomobject]@{
                Label = $label
                ScriptPath = $scriptPath
            })
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedPath
        RepoRoot = Split-Path $resolvedPath -Parent
        ProjectName = $projectName
        UProjectPath = [string](Get-OptionalConfigEntryValue -Name 'UProjectPath')
        DefaultTestFilter = $defaultTestFilter
        DefaultBranchRef = $defaultBranchRef
        StaticAnalysisPathspec = @(Get-ConfigStringArray -Value (Get-OptionalConfigEntryValue -Name 'StaticAnalysisPathspec') -Default @('Source'))
        BuildImpactPatterns = @(Get-ConfigStringArray -Value (Get-OptionalConfigEntryValue -Name 'BuildImpactPatterns') -Default @(
                '*.uproject',
                '*.uplugin',
                '*.Build.cs',
                '*.Target.cs',
                'Source/*',
                'Config/*',
                'Plugins/*/Source/*',
                'Plugins/*/Config/*'
            ))
        AutomationSpecPatterns = @(Get-ConfigStringArray -Value (Get-OptionalConfigEntryValue -Name 'AutomationSpecPatterns') -Default @('Source/*Tests/Private/*.spec.cpp'))
        PowerShellLintPaths = @(Get-ConfigStringArray -Value (Get-OptionalConfigEntryValue -Name 'PowerShellLintPaths') -Default @('Verify.ps1', 'UnrealBuildRunTestScript', 'tests'))
        RegressionTests = @($normalizedRegressionTests)
        ShellHookRegressionScript = [string](Get-OptionalConfigEntryValue -Name 'ShellHookRegressionScript')
    }
}

$verifyCommonPath = Join-Path $PSScriptRoot 'VerifyToolkit.Common.ps1'
if (-not (Test-Path -LiteralPath $verifyCommonPath)) {
    throw "VerifyToolkit.Common.ps1 not found: $verifyCommonPath"
}

. $verifyCommonPath
$script:ToolkitRoot = Split-Path $PSScriptRoot -Parent
$script:PowerShellExecutable = Resolve-PowerShellExecutable
$verifyConfig = Import-UnrealProjectVerifyConfig -Path $ConfigPath
$repoRoot = $verifyConfig.RepoRoot
$projectDescriptor = Resolve-UnrealProjectDescriptor `
    -RepoRoot $repoRoot `
    -ConfiguredPath $verifyConfig.UProjectPath `
    -ConfiguredProjectName $verifyConfig.ProjectName
$projectName = $projectDescriptor.ProjectName
$uprojectPath = $projectDescriptor.UProjectPath

if (-not $PSBoundParameters.ContainsKey('TestFilter')) {
    $TestFilter = if ([string]::IsNullOrWhiteSpace($verifyConfig.DefaultTestFilter)) {
        $projectName
    }
    else {
        $verifyConfig.DefaultTestFilter
    }
}

if (-not $PSBoundParameters.ContainsKey('ClangTidyBaseRef')) {
    $ClangTidyBaseRef = $verifyConfig.DefaultBranchRef
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$EngineRoot
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $null -ne $cmd.Path -and -not [string]::IsNullOrWhiteSpace($cmd.Path)) {
        return $cmd.Path
    }

    if ([string]::IsNullOrWhiteSpace($EngineRoot)) {
        throw "Required command not found on PATH: $Name"
    }

    $candidates = @(
        (Join-Path $EngineRoot 'Engine\Extras\ThirdPartyNotUE\LLVM\Win64\bin'),
        (Join-Path $EngineRoot 'Engine\Binaries\ThirdParty\LLVM\Win64\bin'),
        (Join-Path $EngineRoot 'Engine\Binaries\ThirdParty\LLVM\Win64\bin\clang'),
        (Join-Path $EngineRoot 'Engine\Binaries\ThirdParty\LLVM\Win64\bin\llvm')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    foreach ($dir in $candidates) {
        $exe = Join-Path $dir ($Name + '.exe')
        if (Test-Path -LiteralPath $exe) {
            return $exe
        }
    }

    throw "Required command not found: $Name (not on PATH, and not found under UE EngineRoot: $EngineRoot)"
}

function Get-UEVersionFromProject([string]$UProjectPath) {
    $json = Get-Content -LiteralPath $UProjectPath -Raw | ConvertFrom-Json
    if ($null -eq $json.EngineAssociation -or [string]::IsNullOrWhiteSpace([string]$json.EngineAssociation)) {
        throw "EngineAssociation missing in: $UProjectPath"
    }
    return [string]$json.EngineAssociation
}

function Resolve-EngineRoot {
    param(
        [string]$UEVersion
    )

    $resolverScript = Join-Path $script:ToolkitRoot 'Get-UEInstallPath.ps1'
    if (-not (Test-Path -LiteralPath $resolverScript)) {
        throw "Engine resolver script not found: $resolverScript"
    }

    $engineRoot = & $script:PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $resolverScript -Version $UEVersion
    if ([string]::IsNullOrWhiteSpace($engineRoot)) {
        throw "Engine root not resolved for UE_$UEVersion (resolver returned empty)."
    }

    $engineRoot = $engineRoot.Trim()
    if (-not (Test-Path -LiteralPath $engineRoot)) {
        throw "Engine root resolved but does not exist: $engineRoot"
    }

    return $engineRoot
}

function Get-ClangDatabasePath {
    param(
        [string]$RepoRoot,
        [string]$EngineRoot,
        [string]$UProjectPath,
        [string]$Platform,
        [string]$Configuration,
        [string[]]$StaticAnalysisPathspec = @('Source')
    )

    $ubt = Join-Path $EngineRoot 'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe'
    if (-not (Test-Path -LiteralPath $ubt)) {
        throw "UnrealBuildTool.exe not found: $ubt"
    }

    $outDir = Join-Path $RepoRoot 'Intermediate\ClangDatabase'
    $null = New-Item -ItemType Directory -Force -Path $outDir

    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($UProjectPath)
    $target = "${projectName}Editor"
    $sourceIncludeRules = @(Get-ClangDatabaseIncludeRules -RepoRoot $RepoRoot -RelativePaths $StaticAnalysisPathspec)

    $ubtArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
            '-Mode=GenerateClangDatabase',
            $target, $Platform, $Configuration,
            "-Project=$UProjectPath",
            '-Game',
            '-Engine',
            '-WaitMutex',
            "-OutputDir=$outDir",
            '-OutputFilename=compile_commands.json'
        )) {
        $ubtArgs.Add([string]$argument)
    }

    foreach ($includeRule in @($sourceIncludeRules)) {
        $ubtArgs.Add("-Include=$includeRule")
    }

    Write-Info "Generating compile database (UBT GenerateClangDatabase) ..."
    Invoke-ExternalCommand `
        -FilePath $ubt `
        -ArgumentList $ubtArgs.ToArray() `
        -RetryOnUbtConflict `
        -WorkingDirectory $RepoRoot

    $dbFile = Join-Path $outDir 'compile_commands.json'
    if (-not (Test-Path -LiteralPath $dbFile)) {
        throw "compile_commands.json was not generated at: $dbFile"
    }

    $null = Get-ClangDatabaseFileLookup -DatabasePath $dbFile

    return $outDir
}

function Get-ChangedCppFiles {
    param(
        [psobject]$SelectionContext,
        [string[]]$StaticAnalysisPathspec = @('Source'),
        [switch]$All
    )
    $extensions = @('.cpp', '.cc', '.cxx', '.c')
    return @(Get-ChangedSourceFilesForStaticAnalysis -SelectionContext $SelectionContext -Extensions $extensions -Pathspec $StaticAnalysisPathspec -All:$All)
}

function Get-ChangedFormatFiles {
    param(
        [psobject]$SelectionContext,
        [string[]]$StaticAnalysisPathspec = @('Source'),
        [switch]$All
    )

    $extensions = @('.h', '.hh', '.hpp', '.hxx', '.inl', '.ipp', '.c', '.cc', '.cpp', '.cxx')
    return @(Get-ChangedSourceFilesForStaticAnalysis -SelectionContext $SelectionContext -Extensions $extensions -Pathspec $StaticAnalysisPathspec -All:$All)
}

try {
    Assert-CommandExists git

    Set-Location $repoRoot
    $userProvidedTestFilter = $PSBoundParameters.ContainsKey('TestFilter')
    $staticAnalysisPathspec = @($verifyConfig.StaticAnalysisPathspec)
    if ($staticAnalysisPathspec.Count -eq 0) {
        throw 'Verify config must define at least one StaticAnalysisPathspec entry.'
    }

    Write-Info "Repo: $repoRoot"
    Write-Info "Project: $projectName"

    if (-not $SkipScriptLint) {
        Write-Info 'Running PowerShell lint (PSScriptAnalyzer) ...'
        $psaModule = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1
        if ($null -eq $psaModule) {
            throw 'PSScriptAnalyzer module not found. Install it (PowerShell Gallery) or preinstall on the runner.'
        }
        Import-Module PSScriptAnalyzer -ErrorAction Stop

        $lintPaths = [System.Collections.Generic.List[string]]::new()
        foreach ($lintPath in @($verifyConfig.PowerShellLintPaths)) {
            $resolvedLintPath = Resolve-AbsolutePathOnDisk -Path $lintPath -BasePath $repoRoot
            if (-not (Test-Path -LiteralPath $resolvedLintPath)) {
                throw "Configured PowerShell lint path not found: $resolvedLintPath"
            }
            $lintPaths.Add($resolvedLintPath)
        }

        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($lintPath in $lintPaths) {
            foreach ($result in @(Invoke-ScriptAnalyzer -Path $lintPath -Recurse -Severity @('Warning', 'Error'))) {
                if ($null -ne $result) {
                    $results.Add($result)
                }
            }
        }

        if ($null -ne $results -and $results.Count -gt 0) {
            $results |
                Select-Object RuleName, Severity, ScriptName, Line, Message |
                Format-Table -AutoSize |
                Out-Host
            throw "PSScriptAnalyzer reported $($results.Count) issue(s)."
        }

        foreach ($regressionTest in @($verifyConfig.RegressionTests)) {
            Write-Info "Running $($regressionTest.Label) ..."
            $regressionTestPath = Resolve-AbsolutePathOnDisk -Path $regressionTest.ScriptPath -BasePath $repoRoot
            $regressionResult = Invoke-RegressionTestCommand -Label $regressionTest.Label -FilePath $script:PowerShellExecutable -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $regressionTestPath
            ) -WorkingDirectory $repoRoot
            Write-RegressionTestResult -Label $regressionTest.Label -Result $regressionResult
        }

        if (-not [string]::IsNullOrWhiteSpace($verifyConfig.ShellHookRegressionScript)) {
            Write-Info 'Running shell hook regression tests ...'
            $hookTestScript = Resolve-AbsolutePathOnDisk -Path $verifyConfig.ShellHookRegressionScript -BasePath $repoRoot
            $hookTestScript = ((Resolve-Path -LiteralPath $hookTestScript).Path -replace '\\', '/')

            $shellHookTestEnvironment = Resolve-ShellHookTestEnvironment -AllowMissingShell:$AllowMissingHookTestShell
            if ($null -ne $shellHookTestEnvironment.ShPath) {
                # Prepend Git's usr\bin to PATH so POSIX tools (dirname, grep, mktemp, ...)
                # are available to sh.exe and any child processes it spawns.
                $savedPath = $env:PATH
                try {
                    if (-not [string]::IsNullOrWhiteSpace($shellHookTestEnvironment.PathPrefix)) {
                        $env:PATH = "$($shellHookTestEnvironment.PathPrefix)$([System.IO.Path]::PathSeparator)$env:PATH"
                    }
                    $hookRegressionResult = Invoke-RegressionTestCommand `
                        -Label 'Shell hook regression tests' `
                        -FilePath $shellHookTestEnvironment.ShPath `
                        -ArgumentList @($hookTestScript) `
                        -WorkingDirectory $repoRoot
                    Write-RegressionTestResult -Label 'Shell hook regression tests' -Result $hookRegressionResult
                }
                finally {
                    $env:PATH = $savedPath
                }
            }
        }
    }

    $ueVersion = $null
    $engineRoot = $null
    $clangFormat = $null
    $clangTidy = $null
    $needsEngineTools = (-not $SkipBuild) -or (-not $SkipFormat) -or (-not $SkipClangTidy)
    if ($needsEngineTools) {
        $ueVersion = Get-UEVersionFromProject -UProjectPath $uprojectPath
        $engineRoot = Resolve-EngineRoot -UEVersion $ueVersion

        Write-Info "UE: UE_$ueVersion ($engineRoot)"

        $engineRootBuildArtifactSync = Sync-VerifyEngineRootBuildArtifacts -RepoRoot $repoRoot -EngineRoot $engineRoot
        if ($engineRootBuildArtifactSync.PurgedDirectories.Count -gt 0) {
            $directoryCount = $engineRootBuildArtifactSync.PurgedDirectories.Count
            $directoryNoun = if ($directoryCount -eq 1) { 'directory' } else { 'directories' }

            if ($engineRootBuildArtifactSync.Reason -eq 'engine-root-changed') {
                Write-Info ("Cleared {0} repo-local build artifact {1} after switching Unreal engine root from '{2}' to '{3}'." -f
                    $directoryCount,
                    $directoryNoun,
                    $engineRootBuildArtifactSync.PreviousEngineRoot,
                    $engineRootBuildArtifactSync.CurrentEngineRoot)
            }
            else {
                Write-Info ("Cleared {0} repo-local build artifact {1} before recording the active Unreal engine root '{2}' to avoid mixed-engine caches." -f
                    $directoryCount,
                    $directoryNoun,
                    $engineRootBuildArtifactSync.CurrentEngineRoot)
            }
        }

        if (-not $SkipFormat) {
            $clangFormat = Resolve-ToolPath -Name 'clang-format' -EngineRoot $engineRoot
        }
        if (-not $SkipClangTidy) {
            $clangTidy = Resolve-ToolPath -Name 'clang-tidy' -EngineRoot $engineRoot
        }
    }

    if (-not $SkipBuild) {
        $buildAndTestPlan = Resolve-BuildAndTestPlan -RequestedScope $BuildAndTestScope -ImpactPatterns $verifyConfig.BuildImpactPatterns
        Write-Info $buildAndTestPlan.Description

        if (-not $buildAndTestPlan.ShouldRun) {
            Write-Info 'Skipping Unreal build/test phases.'
        }
        else {
            $effectiveTestFilter = $TestFilter
            if (-not $SkipTests) {
                $automationTestFilterPlan = Resolve-AutomationTestFilterPlan `
                    -RequestedFilter $TestFilter `
                    -BuildAndTestPlan $buildAndTestPlan `
                    -RepoRoot $repoRoot `
                    -SpecPatterns $verifyConfig.AutomationSpecPatterns `
                    -UserProvidedFilter:$userProvidedTestFilter
                if (-not [string]::IsNullOrWhiteSpace($automationTestFilterPlan.Description)) {
                    Write-Info $automationTestFilterPlan.Description
                }
                $effectiveTestFilter = $automationTestFilterPlan.Filter
            }

            # Sync project-level UBT configuration so all builds use identical
            # settings regardless of local Saved/ state. An absent or stale
            # BuildConfiguration.xml causes XmlConfigCache.bin to be regenerated.
            # Full verify uses a dedicated config that disables git working-set
            # discovery so staged/unstaged transitions do not rewrite *.Shared.rsp
            # and invalidate the entire makefile between reruns.
            $srcUbtConfig = Resolve-UbtBuildConfigurationSourcePath -RepoRoot $repoRoot -BuildAndTestPlan $buildAndTestPlan
            if (Test-Path -LiteralPath $srcUbtConfig) {
                $destUbtDir = Join-Path (Join-Path $repoRoot 'Saved') 'UnrealBuildTool'
                $null = New-Item -ItemType Directory -Force -Path $destUbtDir
                $destUbtConfig = Join-Path $destUbtDir 'BuildConfiguration.xml'
                if (Sync-FileIfDifferent -SourcePath $srcUbtConfig -DestinationPath $destUbtConfig) {
                    $relativeUbtConfig = Resolve-Path -LiteralPath $srcUbtConfig -Relative
                    Write-Info "UBT BuildConfiguration synced from $relativeUbtConfig"
                }
                else {
                    Write-Info 'UBT BuildConfiguration already current'
                }
            }

            if ($SkipTests) {
                Write-Info 'Building project (no tests) ...'
                $buildScript = Join-Path $script:ToolkitRoot 'Build.ps1'
                Invoke-ExternalCommand -FilePath $script:PowerShellExecutable -ArgumentList @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', $buildScript,
                    '-Platform', $Platform,
                    '-Configuration', $Configuration
                ) -WorkingDirectory $repoRoot
            }
            else {
                if ([string]::IsNullOrWhiteSpace($effectiveTestFilter)) {
                    throw 'TestFilter is required unless -SkipTests is set.'
                }

                Write-Info "Building and running automation tests: $effectiveTestFilter"
                $testScript = Join-Path $script:ToolkitRoot 'BuildAndTest.ps1'

                $argsList = @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', $testScript,
                    '-Platform', $Platform,
                    '-Configuration', $Configuration,
                    '-TestFilter', $effectiveTestFilter
                )

                if (-not $EnableNullRHI) {
                    $argsList += '-DisableNullRHI'
                }
                if ($DisableRenderOffscreen) {
                    $argsList += '-DisableRenderOffscreen'
                }
                if ($DisableUnattended) {
                    $argsList += '-DisableUnattended'
                }
                if ($DisableNoSound) {
                    $argsList += '-DisableNoSound'
                }

                Invoke-ExternalCommand -FilePath $script:PowerShellExecutable -ArgumentList $argsList -WorkingDirectory $repoRoot
            }
        }
    }

    $staticAnalysisSelection = $null
    $formatFiles = @()
    if (-not $SkipFormat) {
        $staticAnalysisSelection = Resolve-StaticAnalysisSelectionContext `
            -RequestedScope $StaticAnalysisScope `
            -DefaultBaseRef $ClangTidyBaseRef
        Write-Info "Static analysis selection: $($staticAnalysisSelection.Description)"
        $formatFiles = @(Get-ChangedFormatFiles -SelectionContext $staticAnalysisSelection -StaticAnalysisPathspec $staticAnalysisPathspec -All:$FormatAll)
    }

    $cppFiles = @()
    if (-not $SkipClangTidy) {
        if ($null -eq $staticAnalysisSelection) {
            $staticAnalysisSelection = Resolve-StaticAnalysisSelectionContext `
                -RequestedScope $StaticAnalysisScope `
                -DefaultBaseRef $ClangTidyBaseRef
            Write-Info "Static analysis selection: $($staticAnalysisSelection.Description)"
        }
        $cppFiles = @(Get-ChangedCppFiles -SelectionContext $staticAnalysisSelection -StaticAnalysisPathspec $staticAnalysisPathspec -All:$ClangTidyAll)
    }

    $clangDbDir = $null
    $clangDbFile = $null
    $clangDbLookup = $null
    if ($cppFiles.Count -gt 0) {
        $clangDbDir = Get-ClangDatabasePath `
            -RepoRoot $repoRoot `
            -EngineRoot $engineRoot `
            -UProjectPath $uprojectPath `
            -Platform $Platform `
            -Configuration $Configuration `
            -StaticAnalysisPathspec $staticAnalysisPathspec
        $clangDbFile = Join-Path $clangDbDir 'compile_commands.json'
    }

    if (-not $SkipFormat) {
        Write-Info 'Running C++ format check (clang-format --dry-run --Werror) ...'

        if ($formatFiles.Count -eq 0) {
            Write-Info 'No C/C++ source files selected for clang-format.'
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($clangDbFile)) {
                $clangFormat = Resolve-ClangFormatPathFromDatabase -DatabasePath $clangDbFile -FallbackPath $clangFormat
            }
            Write-Info "clang-format tool: $clangFormat"

            $clangFormatCachePlan = Resolve-StaticAnalysisSuccessCachePlan `
                -RepoRoot $repoRoot `
                -ToolKind 'clang-format' `
                -Files $formatFiles `
                -ToolIdentity (Get-FileIdentitySignature -Path $clangFormat) `
                -ConfigSignature (Get-OptionalFileContentHash -Path (Join-Path $repoRoot '.clang-format'))
            Write-Info ("clang-format cache: {0} hit(s), {1} file(s) to run." -f
                $clangFormatCachePlan.CacheHitCount, $clangFormatCachePlan.FilesToRun.Count)

            if ($clangFormatCachePlan.FilesToRun.Count -eq 0) {
                Write-Info 'No C/C++ source files require clang-format after cache filtering.'
            }
            else {
                Invoke-ParallelToolForFiles `
                    -ToolPath $clangFormat `
                    -Files $clangFormatCachePlan.FilesToRun `
                    -WorkingDirectory $repoRoot `
                    -MaxConcurrency $StaticAnalysisMaxConcurrency `
                    -ProgressLabel 'clang-format' `
                    -ToolKind 'clang-format' `
                    -FailureMessagePrefix 'clang-format check failed' `
                    -ArgumentListFactory {
                        param([string]$File)
                        @('--dry-run', '--Werror', '--style=file', $File)
                    }

                Write-StaticAnalysisSuccessCacheEntries `
                    -RepoRoot $repoRoot `
                    -ToolKind 'clang-format' `
                    -Files $clangFormatCachePlan.FilesToRun `
                    -CacheKeys $clangFormatCachePlan.CacheKeys
            }
        }
    }

    if (-not $SkipClangTidy) {
        Write-Info 'Running C++ lint (clang-tidy) ...'

        if ($cppFiles.Count -eq 0) {
            Write-Info 'No C/C++ source files selected for clang-tidy.'
        }
        else {
            $clangTidy = Resolve-ClangTidyPathFromDatabase -DatabasePath $clangDbFile -FallbackPath $clangTidy
            $clangDbLookup = Get-ClangDatabaseFileLookup -DatabasePath $clangDbFile
            Write-Info "clang-tidy tool: $clangTidy"

            $clangTidyCachePlan = Resolve-StaticAnalysisSuccessCachePlan `
                -RepoRoot $repoRoot `
                -ToolKind 'clang-tidy' `
                -Files $cppFiles `
                -ToolIdentity (Get-FileIdentitySignature -Path $clangTidy) `
                -ConfigSignature (Get-OptionalFileContentHash -Path (Join-Path $repoRoot '.clang-tidy')) `
                -ExtraSignature (Get-FileContentSha256 -Path $clangDbFile)
            Write-Info ("clang-tidy cache: {0} hit(s), {1} file(s) to run." -f
                $clangTidyCachePlan.CacheHitCount, $clangTidyCachePlan.FilesToRun.Count)

            if ($clangTidyCachePlan.FilesToRun.Count -eq 0) {
                Write-Info 'No C/C++ source files require clang-tidy after cache filtering.'
            }
            else {
                Invoke-ParallelToolForFiles `
                    -ToolPath $clangTidy `
                    -Files $clangTidyCachePlan.FilesToRun `
                    -WorkingDirectory $repoRoot `
                    -MaxConcurrency $StaticAnalysisMaxConcurrency `
                    -ProgressLabel 'clang-tidy' `
                    -ToolKind 'clang-tidy' `
                    -FailureMessagePrefix 'clang-tidy failed' `
                    -ArgumentListFactory {
                        param([string]$File)
                        $clangTidyFile = Resolve-ClangDatabaseFilePath -Lookup $clangDbLookup -RepoRoot $repoRoot -Path $File
                        @('-p', $clangDbDir, '--quiet', "--warnings-as-errors=*", $clangTidyFile)
                    }

                Write-StaticAnalysisSuccessCacheEntries `
                    -RepoRoot $repoRoot `
                    -ToolKind 'clang-tidy' `
                    -Files $clangTidyCachePlan.FilesToRun `
                    -CacheKeys $clangTidyCachePlan.CacheKeys
            }
        }
    }

    Write-Info 'VERIFY PASSED'
    exit 0
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
