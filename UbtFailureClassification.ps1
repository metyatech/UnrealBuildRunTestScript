function Get-UbtLogPath {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'UnrealBuildTool\Log.txt'
}

function Get-UbtLogTail {
    param(
        [string]$LogPath = (Get-UbtLogPath),
        [int]$TailLines = 80
    )

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return ''
    }

    return (Get-Content -LiteralPath $LogPath -Tail $TailLines -ErrorAction SilentlyContinue) -join [Environment]::NewLine
}

function Test-IsConflictingUbtInstanceMessage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text -match '(?im)A conflicting instance of .* is already running\.' -or
        $Text -match '(?im)Another instance of UAT .* is running'
}

function Test-IsUbtMutexAccessDeniedMessage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text -match '(?im)UnauthorizedAccessException:\s*Access to the path [''"]Global\\UnrealBuildTool_Mutex[^''"]*[''"] is denied\.'
}

function Test-IsConflictingUbtInstanceFailure {
    param(
        [int]$ExitCode,
        [string]$LogPath = (Get-UbtLogPath),
        [string]$LogText
    )

    if ($ExitCode -eq 10) {
        return $true
    }

    if ($ExitCode -eq 0) {
        return $false
    }

    $text = $LogText
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = Get-UbtLogTail -LogPath $LogPath
    }

    return (Test-IsConflictingUbtInstanceMessage -Text $text) -or
        (Test-IsUbtMutexAccessDeniedMessage -Text $text)
}
