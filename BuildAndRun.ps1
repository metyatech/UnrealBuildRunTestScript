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

    $editorExe = Join-Path $buildResult.EngineRoot 'Engine\\Binaries\\Win64\\UnrealEditor.exe'
    Assert-PathExistsOnDisk -Path $editorExe -Description 'UnrealEditor.exe'

    Write-Info 'Build succeeded. Launching Unreal Editor.'
    $editorArgs = '"' + $buildResult.UProjectPath + '"'
    Start-Process -FilePath $editorExe -ArgumentList $editorArgs | Out-Null
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
