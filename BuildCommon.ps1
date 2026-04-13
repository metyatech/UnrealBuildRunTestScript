function Write-Info {
    param([string]$Message)
    Write-Information "[INFO] $Message" -InformationAction Continue
}

function Write-Err {
    param([string]$Message)
    Write-Error "[ERROR] $Message" -ErrorAction Continue
}

. (Join-Path $PSScriptRoot 'UbtFailureClassification.ps1')

function Get-ProjectRoot {
    param([string]$ScriptRoot)
    return (Resolve-Path (Join-Path $ScriptRoot '..')).Path
}

function Get-ProjectInfo {
    param([string]$ProjectRoot)

    $uprojectFiles = Get-ChildItem -Path $ProjectRoot -Filter *.uproject -File -ErrorAction Stop

    if ($uprojectFiles.Count -eq 0) {
        throw "No .uproject found: $ProjectRoot"
    }

    if ($uprojectFiles.Count -gt 1) {
        $dirName = Split-Path -Leaf $ProjectRoot
        $preferred = $uprojectFiles | Where-Object { $_.BaseName -ieq $dirName } | Select-Object -First 1
        if ($null -eq $preferred) {
            $paths = $uprojectFiles | ForEach-Object { $_.FullName } | Out-String
            throw "Multiple .uproject files found. Unable to determine target: $paths"
        }
        $uproject = $preferred
    }
    else {
        $uproject = $uprojectFiles[0]
    }

    return [pscustomobject]@{
        ProjectRoot  = $ProjectRoot
        ProjectName  = $uproject.BaseName
        UProjectPath = $uproject.FullName
    }
}

function Get-UEVersionFromProject {
    param([string]$UProjectPath)
    $uprojectJson = Get-Content -LiteralPath $UProjectPath -Raw | ConvertFrom-Json
    return $uprojectJson.EngineAssociation
}

function Get-EngineRootResolverFromScript {
    param([string]$ScriptPath)

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Engine resolver script not found: $ScriptPath"
    }

    $resolverScriptPath = $ScriptPath
    $resolver = { param([string]$Version) & $resolverScriptPath -Version $Version }
    return $resolver.GetNewClosure()
}

function New-EngineRootResolverFromScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Backward-compatible alias.')]
    param([string]$ScriptPath)

    return Get-EngineRootResolverFromScript -ScriptPath $ScriptPath
}

function Get-EngineRoot {
    param(
        [string]$UEVersion,
        [ScriptBlock]$EngineRootResolver
    )

    if ($null -eq $EngineRootResolver) {
        throw "Engine root resolver is not provided."
    }

    $resolvedEngineRoot = & $EngineRootResolver -Version $UEVersion
    if (-not $resolvedEngineRoot) {
        throw ("Engine root not resolved for UE_{0}." -f $UEVersion)
    }
    if (-not (Test-Path -LiteralPath $resolvedEngineRoot)) {
        throw ("Unreal Engine {0} directory not found: {1}" -f $UEVersion, $resolvedEngineRoot)
    }

    return $resolvedEngineRoot
}

function Assert-PathExistsOnDisk {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("{0} not found: {1}" -f $Description, $Path)
    }
}

function Assert-PathExists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Backward-compatible alias.')]
    param(
        [string]$Path,
        [string]$Description
    )

    Assert-PathExistsOnDisk -Path $Path -Description $Description
}

function Get-FileContentSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Sync-FileIfDifferent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (-not [System.IO.File]::Exists($SourcePath)) {
        throw "Source file not found: $SourcePath"
    }

    $shouldCopy = -not [System.IO.File]::Exists($DestinationPath)
    if (-not $shouldCopy) {
        $sourceHash = Get-FileContentSha256 -Path $SourcePath
        $destinationHash = Get-FileContentSha256 -Path $DestinationPath
        $shouldCopy = $sourceHash -ne $destinationHash
    }

    if ($shouldCopy) {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }

    return $shouldCopy
}

function Resolve-BuildUbtConfigurationSourcePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $configDir = Join-Path (Join-Path $ProjectRoot 'Config') 'UBT'
    return Join-Path $configDir 'BuildConfiguration.xml'
}

function Sync-ProjectUbtBuildConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $srcUbtConfig = Resolve-BuildUbtConfigurationSourcePath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $srcUbtConfig)) {
        return $null
    }

    $destUbtDir = Join-Path (Join-Path $ProjectRoot 'Saved') 'UnrealBuildTool'
    $null = New-Item -ItemType Directory -Force -Path $destUbtDir
    $destUbtConfig = Join-Path $destUbtDir 'BuildConfiguration.xml'
    $synced = Sync-FileIfDifferent -SourcePath $srcUbtConfig -DestinationPath $destUbtConfig

    if ($synced) {
        Write-Info 'UBT BuildConfiguration synced from Config\UBT\BuildConfiguration.xml'
    }
    else {
        Write-Info 'UBT BuildConfiguration already current'
    }

    return [pscustomobject]@{
        SourcePath      = $srcUbtConfig
        DestinationPath = $destUbtConfig
        Synced          = $synced
    }
}

function Get-NormalizedCommandLineText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return $Text.Replace('\', '/').ToLowerInvariant()
}

function Get-UProjectCommandLineMatchSet {
    param(
        [string]$CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return @()
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $patterns = @(
        '(?i)-project=(?:"(?<Path>[^"]+\.uproject)"|(?<Path>[^\s"]+\.uproject))',
        '(?i)(?:"(?<Path>[^"]+\.uproject)"|(?<Path>[^\s"]+\.uproject))'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($CommandLine, $pattern)) {
            $candidate = $match.Groups['Path'].Value
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidates.Contains($candidate)) {
                $candidates.Add($candidate)
            }
        }
    }

    return @($candidates)
}

function Remove-TemporaryFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove temporary file')) {
        return
    }

    if ([System.IO.File]::Exists($Path)) {
        $maxAttempts = 20
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($Path)
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -eq $maxAttempts) {
                    throw
                }
                Start-Sleep -Milliseconds 100
            }
            catch [System.UnauthorizedAccessException] {
                if ($attempt -eq $maxAttempts) {
                    throw
                }
                Start-Sleep -Milliseconds 100
            }
        }
    }
}

function Initialize-ProcessOutputCaptureState {
    param(
        [int]$MaxLines = 200
    )

    return [pscustomobject]@{
        Position = 0L
        PartialLine = ''
        Lines = [System.Collections.Generic.Queue[string]]::new()
        MaxLines = $MaxLines
    }
}

function Add-ProcessOutputExcerptLine {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [string]$Line
    )

    $State.Lines.Enqueue($Line)
    while ($State.Lines.Count -gt $State.MaxLines) {
        $null = $State.Lines.Dequeue()
    }
}

function Get-ProcessOutputExcerpt {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    $lines = @($State.Lines.ToArray())
    if (-not [string]::IsNullOrEmpty($State.PartialLine)) {
        $lines += $State.PartialLine
    }
    return [string]::Join([Environment]::NewLine, $lines)
}

function Write-ProcessOutputDelta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [switch]$ToErrorStream,
        [switch]$FlushPartial
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    $reader = $null
    try {
        if ($State.Position -gt $stream.Length) {
            $State.Position = 0L
            $State.PartialLine = ''
        }

        $null = $stream.Seek($State.Position, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream, $true)
        $delta = $reader.ReadToEnd()
        $State.Position = $stream.Position

        $buffer = $State.PartialLine + $delta
        if ([string]::IsNullOrEmpty($buffer) -and -not $FlushPartial) {
            return
        }

        $buffer = $buffer.Replace("`r`n", "`n").Replace("`r", "`n")
        $endsWithNewline = $buffer.EndsWith("`n", [System.StringComparison]::Ordinal)
        $parts = $buffer.Split([string[]]@("`n"), [System.StringSplitOptions]::None)
        $completeCount = if ($endsWithNewline) { $parts.Length } else { [Math]::Max(0, $parts.Length - 1) }

        for ($index = 0; $index -lt $completeCount; $index++) {
            $line = $parts[$index]
            if ($ToErrorStream) {
                [Console]::Error.WriteLine($line)
            }
            else {
                [Console]::Out.WriteLine($line)
            }
            Add-ProcessOutputExcerptLine -State $State -Line $line
        }

        $State.PartialLine = if ($endsWithNewline) {
            ''
        }
        elseif ($parts.Length -gt 0) {
            $parts[$parts.Length - 1]
        }
        else {
            ''
        }

        if ($FlushPartial -and -not [string]::IsNullOrEmpty($State.PartialLine)) {
            if ($ToErrorStream) {
                [Console]::Error.WriteLine($State.PartialLine)
            }
            else {
                [Console]::Out.WriteLine($State.PartialLine)
            }
            Add-ProcessOutputExcerptLine -State $State -Line $State.PartialLine
            $State.PartialLine = ''
        }
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        else {
            $stream.Dispose()
        }
    }
}

function Get-BlockingProjectEditorProcess {
    param(
        [object[]]$Processes,
        [string]$UProjectPath
    )

    if ($null -eq $Processes) {
        return @()
    }

    $normalizedProjectPath = Get-NormalizedCommandLineText -Text ([System.IO.Path]::GetFullPath($UProjectPath))
    $projectFileName = [System.IO.Path]::GetFileName($UProjectPath).ToLowerInvariant()

    return @(
        $Processes | Where-Object {
            $processName = [string]$_.Name
            if ($processName -notin @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')) {
                return $false
            }

            $commandLine = Get-NormalizedCommandLineText -Text ([string]$_.CommandLine)
            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                return $false
            }

            $uprojectCandidates = @(Get-UProjectCommandLineMatchSet -CommandLine ([string]$_.CommandLine))
            if ($uprojectCandidates.Count -gt 0) {
                foreach ($candidate in $uprojectCandidates) {
                    if ([System.IO.Path]::IsPathRooted($candidate)) {
                        $normalizedCandidate = Get-NormalizedCommandLineText -Text ([System.IO.Path]::GetFullPath($candidate))
                        if ($normalizedCandidate -eq $normalizedProjectPath) {
                            return $true
                        }
                        continue
                    }

                    if ([System.IO.Path]::GetFileName($candidate).ToLowerInvariant() -eq $projectFileName) {
                        return $true
                    }
                }

                return $false
            }

            return $commandLine.Contains($normalizedProjectPath)
        }
    )
}

function Wait-ForProjectEditorProcessesToExit {
    param(
        [string]$ProjectName,
        [string]$UProjectPath,
        [int]$TimeoutSeconds = 30,
        [int]$PollIntervalSeconds = 2,
        [ScriptBlock]$ProcessProvider,
        [ScriptBlock]$SleepAction
    )

    if ($null -eq $ProcessProvider) {
        $ProcessProvider = {
            Get-CimInstance Win32_Process -Filter "Name = 'UnrealEditor.exe' OR Name = 'UnrealEditor-Cmd.exe'" |
                Select-Object ProcessId, Name, CommandLine
        }
    }
    if ($null -eq $SleepAction) {
        $SleepAction = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $blocking = @(Get-BlockingProjectEditorProcess `
                -Processes (& $ProcessProvider) `
                -UProjectPath $UProjectPath)

        $blockingSummary = @(
            foreach ($process in $blocking) {
                if ($null -eq $process) {
                    continue
                }

                $processId = [string]$process.ProcessId
                $processName = [string]$process.Name
                $commandLine = [string]$process.CommandLine
                if ([string]::IsNullOrWhiteSpace($processName) -and [string]::IsNullOrWhiteSpace($commandLine)) {
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($processId)) {
                    if ([string]::IsNullOrWhiteSpace($processName)) {
                        $commandPreview = $commandLine.Trim()
                        if ($commandPreview.Length -gt 120) {
                            $commandPreview = $commandPreview.Substring(0, 120)
                        }
                        $commandPreview
                        continue
                    }

                    $processName
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($processName)) {
                    $processId
                    continue
                }

                '{0}:{1}' -f $processId, $processName
            }
        )

        if ($blockingSummary.Count -eq 0) {
            return
        }

        $summary = $blockingSummary -join ', '
        if ((Get-Date) -ge $deadline) {
            throw ("Timed out waiting for {0} editor process(es) to exit before build: {1}" -f $ProjectName, $summary)
        }

        Write-Warning ("Waiting for {0} editor process(es) to release project DLLs before build: {1}" -f
                $ProjectName, $summary)
        & $SleepAction -Seconds $PollIntervalSeconds
    }
}

function Get-EditorBuildCommandLine {
    param(
        [string]$ProjectName,
        [string]$Platform,
        [string]$Configuration,
        [string]$UProjectPath
    )

    return @(
        "${ProjectName}Editor",
        $Platform,
        $Configuration,
        "-Project=`"$UProjectPath`"",
        '-WaitMutex',
        '-NoHotReload'
    ) -join ' '
}

function Get-EditorBuildArgs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Backward-compatible alias.')]
    param(
        [string]$ProjectName,
        [string]$Platform,
        [string]$Configuration,
        [string]$UProjectPath
    )

    return Get-EditorBuildCommandLine `
        -ProjectName $ProjectName `
        -Platform $Platform `
        -Configuration $Configuration `
        -UProjectPath $UProjectPath
}

function Invoke-EditorBuild {
    param(
        [string]$BuildBat,
        [string]$BuildArgs,
        [string]$ProjectName,
        [string]$UProjectPath
    )

    $MaxRetries = 2
    $RetryCount = 0
    $ExitCode = 0

    while ($RetryCount -lt $MaxRetries) {
        $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("xroidverse-build-{0}.stdout.log" -f [Guid]::NewGuid().ToString('N'))
        $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("xroidverse-build-{0}.stderr.log" -f [Guid]::NewGuid().ToString('N'))
        $stdoutState = Initialize-ProcessOutputCaptureState
        $stderrState = Initialize-ProcessOutputCaptureState
        $buildProc = $null
        $logText = $null

        try {
            $buildProc = Start-Process `
                -FilePath $BuildBat `
                -ArgumentList $BuildArgs `
                -NoNewWindow `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile `
                -PassThru
            $null = $buildProc.Handle

            while (-not $buildProc.HasExited) {
                Write-ProcessOutputDelta -Path $stdoutFile -State $stdoutState
                Write-ProcessOutputDelta -Path $stderrFile -State $stderrState -ToErrorStream
                Start-Sleep -Milliseconds 250
            }

            Write-ProcessOutputDelta -Path $stdoutFile -State $stdoutState -FlushPartial
            Write-ProcessOutputDelta -Path $stderrFile -State $stderrState -ToErrorStream -FlushPartial
            $buildProc.WaitForExit()
            $buildProc.Refresh()
            $ExitCode = $buildProc.ExitCode

            if ($ExitCode -ne 0) {
                $stdoutExcerpt = Get-ProcessOutputExcerpt -State $stdoutState
                $stderrExcerpt = Get-ProcessOutputExcerpt -State $stderrState
                $logTextParts = @()
                if (-not [string]::IsNullOrEmpty($stdoutExcerpt)) {
                    $logTextParts += $stdoutExcerpt
                }
                if (-not [string]::IsNullOrEmpty($stderrExcerpt)) {
                    $logTextParts += $stderrExcerpt
                }
                $logText = [string]::Join([Environment]::NewLine, $logTextParts)
            }
        }
        finally {
            if ($null -ne $buildProc) {
                $buildProc.Dispose()
            }
            Remove-TemporaryFile -Path $stdoutFile
            Remove-TemporaryFile -Path $stderrFile
        }

        if (Test-IsConflictingUbtInstanceFailure -ExitCode $ExitCode -LogText $logText) {
            $RetryCount++
            if ($RetryCount -lt $MaxRetries) {
                Write-Warning ("Build for {0} ({1}) hit a retryable UBT single-instance failure. Retrying in 10 seconds ({2}/{3})..." -f
                        $ProjectName, $UProjectPath, $RetryCount, $MaxRetries)
                Start-Sleep -Seconds 10
                continue
            }
        }
        break
    }

    return $ExitCode
}

function Invoke-ProjectBuild {
    param(
        [string]$ScriptRoot,
        [string]$Platform,
        [string]$Configuration,
        [ScriptBlock]$EngineRootResolver,
        [string]$UEVersionOverride
    )

    $projectRoot = Get-ProjectRoot -ScriptRoot $ScriptRoot
    $projectInfo = Get-ProjectInfo -ProjectRoot $projectRoot
    $null = Sync-ProjectUbtBuildConfiguration -ProjectRoot $projectRoot

    $UEVersion = $UEVersionOverride
    if ([string]::IsNullOrWhiteSpace($UEVersion)) {
        $UEVersion = Get-UEVersionFromProject -UProjectPath $projectInfo.UProjectPath
    }
    $engineRoot = Get-EngineRoot -UEVersion $UEVersion -EngineRootResolver $EngineRootResolver

    $buildBat = Join-Path $engineRoot 'Engine\\Build\\BatchFiles\\Build.bat'
    Assert-PathExistsOnDisk -Path $buildBat -Description 'Build.bat'

    $buildArgs = Get-EditorBuildCommandLine `
        -ProjectName $projectInfo.ProjectName `
        -Platform $Platform `
        -Configuration $Configuration `
        -UProjectPath $projectInfo.UProjectPath

    $editorTarget = "{0}Editor" -f $projectInfo.ProjectName
    Write-Info "Build started: $editorTarget $Platform $Configuration"
    Write-Info "Engine: $engineRoot"
    Write-Info "Project: $($projectInfo.UProjectPath)"

    Wait-ForProjectEditorProcessesToExit `
        -ProjectName $projectInfo.ProjectName `
        -UProjectPath $projectInfo.UProjectPath

    $exitCode = Invoke-EditorBuild `
        -BuildBat $buildBat `
        -BuildArgs $buildArgs `
        -ProjectName $projectInfo.ProjectName `
        -UProjectPath $projectInfo.UProjectPath

    return [pscustomobject]@{
        ProjectName  = $projectInfo.ProjectName
        UProjectPath = $projectInfo.UProjectPath
        EngineRoot   = $engineRoot
        ExitCode     = $exitCode
    }
}
