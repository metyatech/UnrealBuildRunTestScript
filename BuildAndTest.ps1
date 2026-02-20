Param(
    [Parameter(Mandatory = $true)]
    [string]$TestFilter,

    [ValidateSet('DebugGame', 'Development', 'Shipping')]
    [string]$Configuration = 'Development',

    [ValidateSet('Win64')]
    [string]$Platform = 'Win64',

    [switch]$DisableNullRHI,

    [switch]$DisableRenderOffscreen,

    [switch]$DisableUnattended,

    [switch]$DisableNoSound
)

$ErrorActionPreference = 'Stop'

$commonScript = Join-Path $PSScriptRoot 'BuildCommon.ps1'
if (-not (Test-Path -LiteralPath $commonScript)) {
    Write-Error "[ERROR] BuildCommon.ps1 not found: $commonScript" -ErrorAction Continue
    exit 1
}
. $commonScript

function Get-SafeFolderName {
    param([string]$Name)
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeName = $Name
    foreach ($char in $invalidChars) {
        $safeName = $safeName.Replace($char, '_')
    }
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return 'Tests'
    }
    return $safeName
}

function Get-TestDisplayName {
    param([object]$Test)

    if ($null -ne $Test.testDisplayName) {
        return $Test.testDisplayName
    }
    if ($null -ne $Test.fullTestPath) {
        return $Test.fullTestPath
    }
    return '<UnknownTest>'
}

function Write-TestReportSummary {
    param([object]$Report)

    $succeeded = [int]$Report.succeeded
    $succeededWithWarnings = [int]$Report.succeededWithWarnings
    $failed = [int]$Report.failed
    $notRun = [int]$Report.notRun
    $inProcess = [int]$Report.inProcess
    $total = $succeeded + $succeededWithWarnings + $failed + $notRun + $inProcess
    $duration = $Report.totalDuration

    $parts = @(
        "Total=$total",
        "Succeeded=$succeeded",
        "SucceededWithWarnings=$succeededWithWarnings",
        "Failed=$failed",
        "NotRun=$notRun",
        "InProcess=$inProcess"
    )
    if ($null -ne $duration) {
        $parts += ("DurationSeconds={0}" -f ([math]::Round([double]$duration, 3)))
    }

    Write-Info ("Summary: {0}" -f ($parts -join ' '))

    $tests = $Report.tests
    if ($null -eq $tests) {
        return
    }

    $warningTests = @()
    foreach ($test in $tests) {
        $hasWarnings = $false
        if ($null -ne $test.warnings -and $test.warnings -gt 0) {
            $hasWarnings = $true
        }
        elseif ($null -ne $test.entries) {
            $hasWarnings = $null -ne ($test.entries | Where-Object { $_.event -and $_.event.type -eq 'Warning' } | Select-Object -First 1)
        }
        if ($hasWarnings) {
            $warningTests += $test
        }
    }

    if ($warningTests.Count -gt 0) {
        Write-Warn ("Succeeded with warnings ({0}):" -f $warningTests.Count)
        foreach ($test in $warningTests | Select-Object -First 20) {
            $name = Get-TestDisplayName -Test $test
            $warningCount = $test.warnings
            if ($null -eq $warningCount) {
                $warningCount = 0
            }
            Write-Output ("  - {0} (Warnings={1})" -f $name, $warningCount)

            $warningEntry = $null
            if ($null -ne $test.entries) {
                $warningEntry = $test.entries | Where-Object { $_.event -and $_.event.type -eq 'Warning' } | Select-Object -First 1
            }
            if ($null -ne $warningEntry -and $null -ne $warningEntry.event) {
                $message = $warningEntry.event.message
                if ($null -ne $warningEntry.filename -and $warningEntry.lineNumber -ge 0) {
                    Write-Output ("    Warning: {0} ({1}:{2})" -f $message, $warningEntry.filename, $warningEntry.lineNumber)
                }
                else {
                    Write-Output ("    Warning: {0}" -f $message)
                }
            }
        }
        if ($warningTests.Count -gt 20) {
            Write-Warn ("More warnings exist. Showing first 20 of {0}." -f $warningTests.Count)
        }
    }

    $failedTests = @()
    foreach ($test in $tests) {
        if ($null -eq $test.state -or $test.state -ne 'Success') {
            $failedTests += $test
        }
    }

    if ($failedTests.Count -gt 0) {
        Write-Warn ("Failed tests ({0}):" -f $failedTests.Count)
        foreach ($test in $failedTests | Select-Object -First 20) {
            $name = Get-TestDisplayName -Test $test
            $state = $test.state
            Write-Output ("  - {0} (State={1})" -f $name, $state)

            $errorEntry = $null
            if ($null -ne $test.entries) {
                $errorEntry = $test.entries | Where-Object { $_.event -and $_.event.type -eq 'Error' } | Select-Object -First 1
            }
            if ($null -ne $errorEntry -and $null -ne $errorEntry.event) {
                $message = $errorEntry.event.message
                if ($null -ne $errorEntry.filename -and $errorEntry.lineNumber -ge 0) {
                    Write-Output ("    Error: {0} ({1}:{2})" -f $message, $errorEntry.filename, $errorEntry.lineNumber)
                }
                else {
                    Write-Output ("    Error: {0}" -f $message)
                }
            }
        }
        if ($failedTests.Count -gt 20) {
            Write-Warn ("More failures exist. Showing first 20 of {0}." -f $failedTests.Count)
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($TestFilter)) {
        throw 'Test filter is required. Example: -TestFilter MySpec'
    }

    $engineResolverScript = Join-Path $PSScriptRoot 'Get-UEInstallPath.ps1'
    $engineRootResolver = Get-EngineRootResolverFromScript -ScriptPath $engineResolverScript

    $buildResult = Invoke-ProjectBuild `
        -ScriptRoot $PSScriptRoot `
        -Platform $Platform `
        -Configuration $Configuration `
        -EngineRootResolver $engineRootResolver

    if ($buildResult.ExitCode -ne 0) {
        Write-Err "Build failed. ExitCode=$($buildResult.ExitCode)"
        exit $buildResult.ExitCode
    }

    $editorCmd = Join-Path $buildResult.EngineRoot 'Engine\\Binaries\\Win64\\UnrealEditor-Cmd.exe'
    Assert-PathExistsOnDisk -Path $editorCmd -Description 'UnrealEditor-Cmd.exe'

    $projectRoot = Split-Path -Parent $buildResult.UProjectPath
    $reportRoot = Join-Path $projectRoot 'Saved\AutomationReports'
    $reportFolderName = Get-SafeFolderName -Name $TestFilter
    $reportExportPath = Join-Path $reportRoot $reportFolderName
    $null = New-Item -ItemType Directory -Force -Path $reportExportPath

    $execCmds = "Automation RunTests $TestFilter; Quit"
    $cmdArgsParts = @(
        "`"$($buildResult.UProjectPath)`"",
        "-ExecCmds=`"$execCmds`"",
        "-ReportExportPath=`"$reportExportPath`"",
        '-nop4',
        '-nosplash'
    )
    if (-not $DisableUnattended) {
        $cmdArgsParts += '-unattended'
    }
    if (-not $DisableNoSound) {
        $cmdArgsParts += '-nosound'
    }
    if (-not $DisableNullRHI) {
        $cmdArgsParts += '-nullrhi'
    }
    elseif (-not $DisableRenderOffscreen) {
        $cmdArgsParts += '-RenderOffscreen'
    }
    $cmdArgs = $cmdArgsParts -join ' '

    Write-Info "Tests started: $TestFilter"
    Write-Info "Engine: $($buildResult.EngineRoot)"
    Write-Info "Project: $($buildResult.UProjectPath)"
    Write-Info "Report: $reportExportPath"

    $editorCmdDir = Split-Path -Parent $editorCmd
    $proc = Start-Process -FilePath $editorCmd -ArgumentList $cmdArgs -WorkingDirectory $editorCmdDir -NoNewWindow -PassThru -Wait
    $exitCode = $proc.ExitCode

    $indexJsonPath = Join-Path $reportExportPath 'index.json'
    if (Test-Path -LiteralPath $indexJsonPath) {
        try {
            $reportJson = Get-Content -LiteralPath $indexJsonPath -Raw
            $report = $reportJson | ConvertFrom-Json
            Write-Info "Report index: $indexJsonPath"
            Write-TestReportSummary -Report $report
        }
        catch {
            Write-Warn "Failed to read test report: $indexJsonPath"
        }
    }
    else {
        Write-Warn "Test report not found: $indexJsonPath"
    }

    if ($exitCode -ne 0) {
        Write-Err "Tests failed. ExitCode=$exitCode"
        exit $exitCode
    }

    Write-Info 'Tests completed.'
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
