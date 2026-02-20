Param(
    [ValidateSet('DebugGame', 'Development', 'Shipping')]
    [string]$Configuration = 'Development',

    [ValidateSet('Win64')]
    [string]$Platform = 'Win64',

    [string]$UEVersion
)

$ErrorActionPreference = 'Stop'

$commonScript = Join-Path $PSScriptRoot 'BuildCommon.ps1'
if (-not (Test-Path -LiteralPath $commonScript)) {
    Write-Error "[ERROR] BuildCommon.ps1 not found: $commonScript" -ErrorAction Continue
    exit 1
}
. $commonScript

try {
    $engineResolverScript = Join-Path $PSScriptRoot 'Get-UEInstallPath.ps1'
    $engineRootResolver = Get-EngineRootResolverFromScript -ScriptPath $engineResolverScript

    $buildResult = Invoke-ProjectBuild `
        -ScriptRoot $PSScriptRoot `
        -Platform $Platform `
        -Configuration $Configuration `
        -EngineRootResolver $engineRootResolver `
        -UEVersionOverride $UEVersion

    if ($buildResult.ExitCode -ne 0) {
        Write-Err "Build failed. ExitCode=$($buildResult.ExitCode)"
        exit $buildResult.ExitCode
    }

    Write-Info 'Build succeeded.'
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
