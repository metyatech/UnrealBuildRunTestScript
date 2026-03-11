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

function Get-NormalizedCommandLineText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return $Text.Replace('\', '/').ToLowerInvariant()
}

function Get-BlockingProjectEditorProcess {
    param(
        [object[]]$Processes,
        [string]$ProjectName,
        [string]$UProjectPath
    )

    if ($null -eq $Processes) {
        return @()
    }

    $normalizedProjectPath = Get-NormalizedCommandLineText -Text ([System.IO.Path]::GetFullPath($UProjectPath))
    $projectFileName = [System.IO.Path]::GetFileName($UProjectPath).ToLowerInvariant()
    $projectIdentifier = "{0}.uproject" -f $ProjectName.ToLowerInvariant()

    return ,@(
        $Processes | Where-Object {
            $processName = [string]$_.Name
            if ($processName -notin @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')) {
                return $false
            }

            $commandLine = Get-NormalizedCommandLineText -Text ([string]$_.CommandLine)
            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                return $false
            }

            return $commandLine.Contains($normalizedProjectPath) -or $commandLine.Contains($projectFileName) -or
                $commandLine.Contains($projectIdentifier)
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
                -ProjectName $ProjectName `
                -UProjectPath $UProjectPath)

        if ($blocking.Count -eq 0) {
            return
        }

        $summary = ($blocking | ForEach-Object { '{0}:{1}' -f $_.ProcessId, $_.Name }) -join ', '
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
        $buildProc = Start-Process -FilePath $BuildBat -ArgumentList $BuildArgs -NoNewWindow -PassThru -Wait
        $ExitCode = $buildProc.ExitCode

        if (Test-IsConflictingUbtInstanceFailure -ExitCode $ExitCode) {
            $RetryCount++
            if ($RetryCount -lt $MaxRetries) {
                Write-Warning ("Build for {0} ({1}) returned a UBT conflicting-instance failure. Retrying in 10 seconds ({2}/{3})..." -f
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
