[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [string]$UProjectPath,

    [string]$DefaultTestFilter,

    [string]$DefaultBranchRef = 'origin/main',

    [string]$ToolkitRelativePath = 'UnrealBuildRunTestScript',

    [string[]]$StaticAnalysisPathspec = @('Source'),

    [string[]]$AutomationSpecPatterns = @('Source/*Tests/Private/*.spec.cpp'),

    [string[]]$PowerShellLintPaths = @(),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-ToSingleQuotedPowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    return "'{0}'" -f $Text.Replace("'", "''")
}

function Convert-ToRelativeRepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $resolvedRepoRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        $resolvedPath -ne $resolvedRepoRoot) {
        throw "Expected a path inside the repository root. Repo: $resolvedRepoRoot Path: $resolvedPath"
    }

    $repoUri = [System.Uri]($resolvedRepoRoot + [System.IO.Path]::DirectorySeparatorChar)
    $pathUri = [System.Uri]$resolvedPath
    return [System.Uri]::UnescapeDataString($repoUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Format-PowerShellArrayLiteral {
    param(
        [string[]]$Values,
        [int]$IndentWidth = 4
    )

    $indent = ' ' * $IndentWidth
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return '@()'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('@(')
    foreach ($value in $Values) {
        $lines.Add($indent + (Convert-ToSingleQuotedPowerShellLiteral -Text $value))
    }
    $lines.Add(')')
    return ($lines -join [Environment]::NewLine)
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [switch]$Force
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        throw "Refusing to overwrite existing file without -Force: $Path"
    }

    $parent = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $null = New-Item -ItemType Directory -Force -Path $parent
    }

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$null = & git -C $resolvedRepoRoot rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "RepoRoot is not a git repository: $resolvedRepoRoot"
}

if ([string]::IsNullOrWhiteSpace($DefaultTestFilter)) {
    $DefaultTestFilter = $ProjectName
}

$resolvedToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot $ToolkitRelativePath))
$entryScript = Join-Path $resolvedToolkitRoot 'VerifyToolkit\Invoke-UnrealProjectVerify.ps1'
if (-not (Test-Path -LiteralPath $entryScript)) {
    throw "Toolkit entry script not found. Expected a checked-out toolkit at: $entryScript"
}

if ([string]::IsNullOrWhiteSpace($UProjectPath)) {
    $uprojectFiles = @(Get-ChildItem -LiteralPath $resolvedRepoRoot -Filter '*.uproject' -File -ErrorAction Stop)
    if ($uprojectFiles.Count -ne 1) {
        throw 'UProjectPath was not provided and auto-detection did not find exactly one .uproject file at the repo root.'
    }
    $resolvedUProjectPath = $uprojectFiles[0].FullName
}
else {
    $resolvedUProjectPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot $UProjectPath))
    if (-not (Test-Path -LiteralPath $resolvedUProjectPath)) {
        throw "Configured UProjectPath does not exist: $resolvedUProjectPath"
    }
}

$relativeToolkitPath = Convert-ToRelativeRepoPath -RepoRoot $resolvedRepoRoot -Path $resolvedToolkitRoot
$relativeUProjectPath = Convert-ToRelativeRepoPath -RepoRoot $resolvedRepoRoot -Path $resolvedUProjectPath

if ($PowerShellLintPaths.Count -eq 0) {
    $PowerShellLintPaths = @('Verify.ps1', $relativeToolkitPath, 'tests')
}

$wrapperPath = Join-Path $resolvedRepoRoot 'Verify.ps1'
$configPath = Join-Path $resolvedRepoRoot 'UnrealProjectVerify.config.psd1'
$hookPath = Join-Path (Join-Path $resolvedRepoRoot '.githooks') 'pre-commit'
$hookTemplatePath = Join-Path $PSScriptRoot 'templates\pre-commit'
if (-not (Test-Path -LiteralPath $hookTemplatePath)) {
    throw "Hook template not found: $hookTemplatePath"
}

$wrapperContent = @"
[CmdletBinding()]
param(
    [string]`$TestFilter,

    [ValidateSet('DebugGame', 'Development', 'Shipping')]
    [string]`$Configuration = 'Development',

    [ValidateSet('Win64')]
    [string]`$Platform = 'Win64',

    [string]`$ClangTidyBaseRef,

    [switch]`$ClangTidyAll,
    [switch]`$FormatAll,
    [ValidateSet('auto', 'local', 'pr', 'push', 'all')]
    [string]`$StaticAnalysisScope = 'auto',
    [ValidateSet('auto', 'local', 'all')]
    [string]`$BuildAndTestScope = 'auto',
    [int]`$StaticAnalysisMaxConcurrency = 0,

    [switch]`$SkipScriptLint,
    [switch]`$SkipFormat,
    [switch]`$SkipClangTidy,
    [switch]`$SkipBuild,
    [switch]`$SkipTests,
    [switch]`$AllowMissingHookTestShell,

    [switch]`$EnableNullRHI,

    [switch]`$DisableRenderOffscreen,
    [switch]`$DisableUnattended,
    [switch]`$DisableNoSound
)

`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

`$toolkitRoot = Join-Path `$PSScriptRoot $(Convert-ToSingleQuotedPowerShellLiteral -Text $relativeToolkitPath)
`$entryScript = Join-Path `$toolkitRoot 'VerifyToolkit\Invoke-UnrealProjectVerify.ps1'
`$configPath = Join-Path `$PSScriptRoot 'UnrealProjectVerify.config.psd1'

if (-not (Test-Path -LiteralPath `$entryScript)) {
    throw "Verify toolkit entry script not found: `$entryScript"
}

if (-not (Test-Path -LiteralPath `$configPath)) {
    throw "Verify config not found: `$configPath"
}

`$forwarded = @{}
foreach (`$entry in `$PSBoundParameters.GetEnumerator()) {
    `$forwarded[`$entry.Key] = `$entry.Value
}

& `$entryScript -ConfigPath `$configPath @forwarded
exit `$LASTEXITCODE
"@

$configContent = @"
@{
    ProjectName = $(Convert-ToSingleQuotedPowerShellLiteral -Text $ProjectName)
    UProjectPath = $(Convert-ToSingleQuotedPowerShellLiteral -Text $relativeUProjectPath)
    DefaultTestFilter = $(Convert-ToSingleQuotedPowerShellLiteral -Text $DefaultTestFilter)
    DefaultBranchRef = $(Convert-ToSingleQuotedPowerShellLiteral -Text $DefaultBranchRef)
    StaticAnalysisPathspec = $(Format-PowerShellArrayLiteral -Values $StaticAnalysisPathspec -IndentWidth 8)
    BuildImpactPatterns = @(
        '*.uproject'
        '*.uplugin'
        '*.Build.cs'
        '*.Target.cs'
        'Source/*'
        'Config/*'
        'Plugins/*/Source/*'
        'Plugins/*/Config/*'
    )
    AutomationSpecPatterns = $(Format-PowerShellArrayLiteral -Values $AutomationSpecPatterns -IndentWidth 8)
    PowerShellLintPaths = $(Format-PowerShellArrayLiteral -Values $PowerShellLintPaths -IndentWidth 8)
    RegressionTests = @()
    ShellHookRegressionScript = ''
}
"@

Write-Utf8NoBomFile -Path $wrapperPath -Content $wrapperContent -Force:$Force
Write-Utf8NoBomFile -Path $configPath -Content $configContent -Force:$Force
Write-Utf8NoBomFile -Path $hookPath -Content ([System.IO.File]::ReadAllText($hookTemplatePath)) -Force:$Force

$null = & git -C $resolvedRepoRoot config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure git core.hooksPath to .githooks.'
}

[Console]::Out.WriteLine(("Installed Unreal project verify toolkit in {0}" -f $resolvedRepoRoot))
[Console]::Out.WriteLine(("  Verify wrapper: {0}" -f $wrapperPath))
[Console]::Out.WriteLine(("  Config: {0}" -f $configPath))
[Console]::Out.WriteLine(("  Hook: {0}" -f $hookPath))
