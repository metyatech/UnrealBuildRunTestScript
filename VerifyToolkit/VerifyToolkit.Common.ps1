[CmdletBinding()]
param()

$script:UnrealProjectVerifyTempPrefix = 'unreal-project-verify'

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'UbtFailureClassification.ps1')

function Resolve-PowerShellExecutable {
    $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
    if ($null -ne $currentProcess -and -not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
        $leaf = [System.IO.Path]::GetFileName($currentProcess.Path)
        if ($leaf -in @('powershell.exe', 'pwsh.exe', 'powershell', 'pwsh')) {
            return $currentProcess.Path
        }
    }

    foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        $commandPath = $null
        if ($null -ne $command) {
            if ($null -ne $command.Path -and -not [string]::IsNullOrWhiteSpace($command.Path)) {
                $commandPath = $command.Path
            }
            elseif ($null -ne $command.Source -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
                $commandPath = $command.Source
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
            return $commandPath
        }
    }

    throw 'PowerShell executable not found. Tried current host, powershell.exe/powershell, and pwsh.exe/pwsh.'
}

function Resolve-ShellHookTestEnvironment {
    param(
        [switch]$AllowMissingShell
    )

    $shExe = $null
    $pathPrefix = $null
    $gitSource = (Get-Command git -ErrorAction SilentlyContinue).Source

    if (-not [string]::IsNullOrWhiteSpace($gitSource)) {
        $dir = Split-Path $gitSource -Parent
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
            $candidate = Join-Path $dir 'usr\bin\sh.exe'
            if (Test-Path -LiteralPath $candidate) {
                $shExe = $candidate
                $pathPrefix = Join-Path $dir 'usr\bin'
                break
            }
            $parent = Split-Path $dir -Parent
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
    }

    if ($null -eq $shExe) {
        $shCmd = Get-Command 'sh' -ErrorAction SilentlyContinue
        if ($null -ne $shCmd) {
            $shExe = $shCmd.Source
            $pathPrefix = Split-Path $shExe -Parent
        }
    }

    if ($null -eq $shExe) {
        if ($AllowMissingShell) {
            Write-Warning 'Skipping shell hook regression tests because sh was not found and -AllowMissingHookTestShell was set. Tried Git for Windows usr\bin\sh.exe and sh on PATH.'
            return [pscustomobject]@{
                ShPath = $null
                PathPrefix = $null
            }
        }

        throw 'Shell hook regression tests require sh. Install Git for Windows usr\bin\sh.exe (or another sh on PATH), or re-run Verify.ps1 with -AllowMissingHookTestShell to skip intentionally.'
    }

    return [pscustomobject]@{
        ShPath = $shExe
        PathPrefix = $pathPrefix
    }
}

function Remove-TemporaryFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
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

function Resolve-AbsolutePathOnDisk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$BasePath
    )

    $candidatePath = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidatePath)) {
        $rootPath = $BasePath
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            $rootPath = (Get-Location).Path
        }
        $candidatePath = Join-Path $rootPath $candidatePath
    }

    return [System.IO.Path]::GetFullPath($candidatePath)
}

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-OptionalFileContentHash {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) {
        return 'missing'
    }

    return Get-FileContentSha256 -Path $Path
}

function Get-FileIdentitySignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [string]::Join('|', @(
            $item.FullName.ToLowerInvariant(),
            [string]$item.Length,
            [string]$item.LastWriteTimeUtc.Ticks
        ))
}

function Convert-ToPortableAbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$BasePath
    )

    $candidatePath = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidatePath)) {
        $rootPath = $BasePath
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            $rootPath = (Get-Location).Path
        }
        $candidatePath = [System.IO.Path]::Combine($rootPath, $candidatePath)
    }

    return [System.IO.Path]::GetFullPath($candidatePath).Replace('\', '/')
}

function Get-ClangDatabaseIncludeRules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string[]]$RelativePaths = @('Source')
    )

    $rules = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @($RelativePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $portablePath = Convert-ToPortableAbsolutePath -Path $relativePath -BasePath $RepoRoot
        $rules.Add("$portablePath/...")
    }

    return @($rules | Sort-Object -Unique)
}

function Get-ClangDatabaseFileLookup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    if (-not [System.IO.File]::Exists($DatabasePath)) {
        throw "compile_commands.json not found: $DatabasePath"
    }

    $rawDatabase = Get-Content -LiteralPath $DatabasePath -Raw
    if ([string]::IsNullOrWhiteSpace($rawDatabase)) {
        throw "compile_commands.json is empty: $DatabasePath"
    }

    $parsedEntries = ConvertFrom-Json -InputObject $rawDatabase
    [object[]]$entries = @()
    if ($null -ne $parsedEntries) {
        if ($parsedEntries -is [System.Array]) {
            $entries = [object[]]$parsedEntries
        }
        else {
            $entries = [object[]]@($parsedEntries)
        }
    }

    if ($entries.Count -eq 0) {
        throw "compile_commands.json contained no compile commands: $DatabasePath"
    }

    $lookup = @{}
    foreach ($entry in $entries) {
        $entryFileProperty = $entry.PSObject.Properties['file']
        if ($null -eq $entryFileProperty) {
            continue
        }

        $entryFile = [string]$entryFileProperty.Value
        if ([string]::IsNullOrWhiteSpace($entryFile)) {
            continue
        }

        $entryDirectoryProperty = $entry.PSObject.Properties['directory']
        $entryDirectory = if ($null -ne $entryDirectoryProperty) {
            [string]$entryDirectoryProperty.Value
        }
        else {
            ''
        }

        $normalizedKey = Convert-ToPortableAbsolutePath -Path $entryFile -BasePath $entryDirectory
        if (-not $lookup.ContainsKey($normalizedKey)) {
            $lookup[$normalizedKey] = $entryFile
        }
    }

    if ($lookup.Count -eq 0) {
        throw "compile_commands.json contained no usable source entries: $DatabasePath"
    }

    return $lookup
}

function Resolve-ClangDatabaseFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Lookup,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = Convert-ToPortableAbsolutePath -Path $Path -BasePath $RepoRoot
    if ($Lookup.ContainsKey($normalizedPath)) {
        return $Lookup[$normalizedPath]
    }

    throw "Compile command not found in compile_commands.json for: $Path"
}

function Resolve-ClangToolPathFromDatabase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $true)]
        [string]$FallbackPath,

        [Parameter(Mandatory = $true)]
        [string]$ToolLeafName
    )

    if (-not [System.IO.File]::Exists($FallbackPath)) {
        throw "tool executable not found: $FallbackPath"
    }

    if (-not [System.IO.File]::Exists($DatabasePath)) {
        return $FallbackPath
    }

    $rawDatabase = Get-Content -LiteralPath $DatabasePath -Raw
    if ([string]::IsNullOrWhiteSpace($rawDatabase)) {
        return $FallbackPath
    }

    foreach ($entry in @(ConvertFrom-Json -InputObject $rawDatabase)) {
        $commandText = [string]$entry.command
        if ([string]::IsNullOrWhiteSpace($commandText)) {
            continue
        }

        $compilerPath = $null
        $quotedMatch = [regex]::Match($commandText, '^"([^"]+)"')
        if ($quotedMatch.Success) {
            $compilerPath = $quotedMatch.Groups[1].Value
        }
        else {
            $unquotedMatch = [regex]::Match($commandText, '^(\S+)')
            if ($unquotedMatch.Success) {
                $compilerPath = $unquotedMatch.Groups[1].Value
            }
        }

        if ([string]::IsNullOrWhiteSpace($compilerPath)) {
            continue
        }

        $compilerLeaf = [System.IO.Path]::GetFileName($compilerPath)
        if ($compilerLeaf -notin @('clang-cl.exe', 'clang++.exe', 'clang.exe')) {
            continue
        }

        $candidatePath = Join-Path ([System.IO.Path]::GetDirectoryName($compilerPath)) $ToolLeafName
        if ([System.IO.File]::Exists($candidatePath)) {
            return $candidatePath
        }
    }

    return $FallbackPath
}

function Resolve-ClangTidyPathFromDatabase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $true)]
        [string]$FallbackPath
    )

    return Resolve-ClangToolPathFromDatabase `
        -DatabasePath $DatabasePath `
        -FallbackPath $FallbackPath `
        -ToolLeafName 'clang-tidy.exe'
}

function Resolve-ClangFormatPathFromDatabase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $true)]
        [string]$FallbackPath
    )

    return Resolve-ClangToolPathFromDatabase `
        -DatabasePath $DatabasePath `
        -FallbackPath $FallbackPath `
        -ToolLeafName 'clang-format.exe'
}

function Write-ProcessOutputFile {
    param(
        [string]$Path,
        [switch]$ToErrorStream
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return
    }

    $reader = [System.IO.File]::OpenText($Path)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($ToErrorStream) {
                [Console]::Error.WriteLine($line)
            }
            else {
                [Console]::Out.WriteLine($line)
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function New-ProcessOutputCaptureState {
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

<#
.SYNOPSIS
Returns a bounded excerpt from a process output file.

.DESCRIPTION
Reads the file line-by-line, keeps the trailing MaxLines in the returned excerpt,
and only emits lines to the current console when -EmitLines is specified. Callers
that need full replay should opt in with -EmitLines or use Write-ProcessOutputFile.
#>
function Get-ProcessOutputFileExcerpt {
    param(
        [string]$Path,
        [switch]$ToErrorStream,
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxLines = 200,
        [switch]$EmitLines
    )

    return (Get-ProcessOutputFileExcerptInfo `
            -Path $Path `
            -ToErrorStream:$ToErrorStream `
            -MaxLines $MaxLines `
            -EmitLines:$EmitLines).Excerpt
}

function Get-ProcessOutputFileExcerptInfo {
    param(
        [string]$Path,
        [switch]$ToErrorStream,
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxLines = 200,
        [switch]$EmitLines
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return [pscustomobject]@{
            Excerpt         = ''
            LastNonEmptyLine = ''
        }
    }

    $excerptLines = [System.Collections.Generic.Queue[string]]::new()
    $lastNonEmptyLine = ''
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    $reader = $null
    try {
        $defaultEncoding = Get-RedirectedProcessOutputEncoding
        $reader = [System.IO.StreamReader]::new($stream, $defaultEncoding, $true)
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($EmitLines) {
                if ($ToErrorStream) {
                    [Console]::Error.WriteLine($line)
                }
                else {
                    [Console]::Out.WriteLine($line)
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lastNonEmptyLine = $line.TrimEnd()
            }

            $excerptLines.Enqueue($line)
            while ($excerptLines.Count -gt $MaxLines) {
                $null = $excerptLines.Dequeue()
            }
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

    return [pscustomobject]@{
        Excerpt         = [string]::Join([Environment]::NewLine, $excerptLines.ToArray())
        LastNonEmptyLine = $lastNonEmptyLine
    }
}

function Get-LastNonEmptyTextLine {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $lines = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Split([string[]]@("`n"),
        [System.StringSplitOptions]::None)
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        $line = $lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line.TrimEnd()
        }
    }

    return ''
}

function Test-IsWindowsPlatform {
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable -and $isWindowsVariable.Value -is [bool]) {
        return $isWindowsVariable.Value
    }

    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Get-StartProcessParameters {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [object[]]$ArgumentList = @(),

        [string]$WorkingDirectory,

        [switch]$PassThru,
        [switch]$Wait,

        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )

    $parameters = @{
        FilePath = $FilePath
    }

    $resolvedArgumentList = Resolve-StartProcessArgumentList -ArgumentList $ArgumentList
    if ($null -ne $resolvedArgumentList) {
        $parameters.ArgumentList = $resolvedArgumentList
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $parameters.WorkingDirectory = $WorkingDirectory
    }

    if ($PassThru) {
        $parameters.PassThru = $true
    }

    if ($Wait) {
        $parameters.Wait = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)) {
        $parameters.RedirectStandardOutput = $RedirectStandardOutput
    }

    if (-not [string]::IsNullOrWhiteSpace($RedirectStandardError)) {
        $parameters.RedirectStandardError = $RedirectStandardError
    }

    if (Test-IsWindowsPlatform) {
        $parameters.NoNewWindow = $true
    }

    return $parameters
}

$script:StartProcessNativeArgumentArraySupport = $null
$script:StartProcessNativeArgumentArraySupportOverride = $null
$script:StartProcessNativeArgumentArraySupportLock = New-Object System.Object

function Resolve-StartProcessNativeArgumentArraySupportOverride {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [bool]) {
        return $Value
    }

    if ($Value -is [string]) {
        $trimmedValue = $Value.Trim()
        if ($trimmedValue -ieq 'true') {
            return $true
        }
        if ($trimmedValue -ieq 'false') {
            return $false
        }
    }

    $valueType = if ($null -eq $Value) { '<null>' } else { $Value.GetType().FullName }
    $formattedValue = if ($null -eq $Value) {
        '<null>'
    }
    else {
        $escapedValue = ([string]$Value).Replace("`r", '\r').Replace("`n", '\n') -replace "'", "''"
        "'$escapedValue'"
    }
    throw "StartProcessNativeArgumentArraySupportOverride must be a boolean or the string 'true'/'false'. Actual value type: $valueType. Actual value: $formattedValue."
}

function Get-RedirectedProcessOutputEncoding {
    try {
        $consoleEncoding = [Console]::OutputEncoding
        if ($null -ne $consoleEncoding) {
            return $consoleEncoding
        }
    }
    catch {
        Write-Verbose ("Falling back to system default redirected-process encoding because Console.OutputEncoding could not be resolved: {0}" -f $_.Exception.Message)
    }

    return [System.Text.Encoding]::Default
}

function Assert-NoNullArgumentListEntries {
    param(
        [object[]]$ArgumentList = @(),

        [string]$DiagnosticPrefix = 'Argument list'
    )

    $arguments = @($ArgumentList)
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        if ($null -eq $arguments[$index]) {
            throw "$DiagnosticPrefix must not contain `$null. Argument index: $index. Use an empty string to pass an explicit empty argument."
        }
    }
}

function Convert-ArgumentListToStringArray {
    param(
        [object[]]$ArgumentList = @(),

        [string]$DiagnosticPrefix = 'Argument list'
    )

    if ($null -eq $ArgumentList) {
        return @()
    }

    Assert-NoNullArgumentListEntries -ArgumentList $ArgumentList -DiagnosticPrefix $DiagnosticPrefix

    $nativeArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($ArgumentList)) {
        $nativeArguments.Add([string]$argument)
    }

    return $nativeArguments.ToArray()
}

function Assert-NoNullProcessArguments {
    param(
        [object[]]$ArgumentList = @()
    )

    Assert-NoNullArgumentListEntries -ArgumentList $ArgumentList -DiagnosticPrefix 'Process argument list'
}

function Format-InvocationArgument {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Argument,

        [string]$DiagnosticPrefix = 'Argument list'
    )

    Assert-NoNullArgumentListEntries -ArgumentList @($Argument) -DiagnosticPrefix $DiagnosticPrefix

    $text = [string]$Argument
    if ($text.Length -eq 0) {
        return '""'
    }

    if ($text -notmatch '[\s"]') {
        return $text
    }

    $escaped = $text -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-InvocationArgumentList {
    param(
        [object[]]$ArgumentList = @(),

        [string]$DiagnosticPrefix = 'Argument list',

        [switch]$ReturnNullWhenEmpty
    )

    if ($null -eq $ArgumentList -or @($ArgumentList).Count -eq 0) {
        if ($ReturnNullWhenEmpty) {
            return $null
        }

        return ''
    }

    Assert-NoNullArgumentListEntries -ArgumentList $ArgumentList -DiagnosticPrefix $DiagnosticPrefix

    $parts = foreach ($argument in @($ArgumentList)) {
        Format-InvocationArgument -Argument $argument -DiagnosticPrefix $DiagnosticPrefix
    }

    return [string]::Join(' ', $parts)
}

function Format-StartProcessNativeArgumentProbeFailureDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [string]$StdoutPath,

        [string]$StderrPath
    )

    $normalizedReason = $Reason.Replace("`r", '\r').Replace("`n", '\n')
    $stdoutExcerpt = Get-LastNonEmptyTextLine -Text (Get-ProcessOutputFileExcerpt -Path $StdoutPath -MaxLines 20)
    $stderrExcerpt = Get-LastNonEmptyTextLine -Text (Get-ProcessOutputFileExcerpt -Path $StderrPath -MaxLines 20)

    if ([string]::IsNullOrWhiteSpace($stdoutExcerpt)) {
        $stdoutExcerpt = '<empty>'
    }
    else {
        $stdoutExcerpt = $stdoutExcerpt.Replace("`r", '\r').Replace("`n", '\n')
    }

    if ([string]::IsNullOrWhiteSpace($stderrExcerpt)) {
        $stderrExcerpt = '<empty>'
    }
    else {
        $stderrExcerpt = $stderrExcerpt.Replace("`r", '\r').Replace("`n", '\n')
    }

    Write-Verbose ("Falling back to formatted Start-Process invocation because native argument-array probe failed: {0}. Stdout={1}. Stderr={2}" -f
        $normalizedReason,
        $stdoutExcerpt,
        $stderrExcerpt)
}

function Test-StartProcessNativeArgumentArraySupport {
    if ($null -ne $script:StartProcessNativeArgumentArraySupportOverride) {
        return Resolve-StartProcessNativeArgumentArraySupportOverride -Value $script:StartProcessNativeArgumentArraySupportOverride
    }

    if ($null -ne $script:StartProcessNativeArgumentArraySupport) {
        return [bool]$script:StartProcessNativeArgumentArraySupport
    }

    [System.Threading.Monitor]::Enter($script:StartProcessNativeArgumentArraySupportLock)
    try {
        if ($null -ne $script:StartProcessNativeArgumentArraySupportOverride) {
            return Resolve-StartProcessNativeArgumentArraySupportOverride -Value $script:StartProcessNativeArgumentArraySupportOverride
        }

        if ($null -ne $script:StartProcessNativeArgumentArraySupport) {
            return [bool]$script:StartProcessNativeArgumentArraySupport
        }

        $probeScript = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-startprocess-probe-{1}.ps1" -f $script:UnrealProjectVerifyTempPrefix,
            [Guid]::NewGuid().ToString('N'))
        $probeOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-startprocess-probe-{1}.txt" -f $script:UnrealProjectVerifyTempPrefix,
            [Guid]::NewGuid().ToString('N'))
        $probeStdout = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-startprocess-probe-{1}.stdout.log" -f $script:UnrealProjectVerifyTempPrefix,
            [Guid]::NewGuid().ToString('N'))
        $probeStderr = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-startprocess-probe-{1}.stderr.log" -f $script:UnrealProjectVerifyTempPrefix,
            [Guid]::NewGuid().ToString('N'))
        $probeProcess = $null
        $probeFailureReason = 'native argument-array probe did not complete'

        try {
            @'
param(
    [string]$OutFile,
    [string]$Message,
    [string]$EmptyValue,
    [string]$TailValue
)

$result = [pscustomobject]@{
    Message = $Message
    EmptyValueLength = if ($null -eq $EmptyValue) { -1 } else { $EmptyValue.Length }
    TailValue = $TailValue
}
[System.IO.File]::WriteAllText($OutFile, ($result | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8)
'@ | Set-Content -LiteralPath $probeScript -Encoding ASCII

            $supportsNativeArgumentArray = $false
            try {
                $probeStartProcessParams = @{
                    FilePath               = (Resolve-PowerShellExecutable)
                    ArgumentList           = @(
                        '-NoProfile',
                        '-ExecutionPolicy', 'Bypass',
                        '-File', $probeScript,
                        $probeOutput,
                        "O'Brien test",
                        '',
                        'tail-marker'
                    )
                    PassThru               = $true
                    Wait                   = $true
                    RedirectStandardOutput = $probeStdout
                    RedirectStandardError  = $probeStderr
                }
                if (Test-IsWindowsPlatform) {
                    $probeStartProcessParams.NoNewWindow = $true
                }
                $probeProcess = Start-Process @probeStartProcessParams

                if ($probeProcess.ExitCode -eq 0 -and [System.IO.File]::Exists($probeOutput)) {
                    $probeResult = [System.IO.File]::ReadAllText($probeOutput, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    $supportsNativeArgumentArray = `
                        $probeResult.Message -eq "O'Brien test" -and `
                        $probeResult.EmptyValueLength -eq 0 -and `
                        $probeResult.TailValue -eq 'tail-marker'
                    if (-not $supportsNativeArgumentArray) {
                        $probeFailureReason = "probe returned unexpected values (Message=$($probeResult.Message), EmptyValueLength=$($probeResult.EmptyValueLength), TailValue=$($probeResult.TailValue))"
                    }
                }
                elseif ($probeProcess.ExitCode -ne 0) {
                    $probeFailureReason = "probe child exited with code $($probeProcess.ExitCode)"
                }
                else {
                    $probeFailureReason = 'probe child did not write the expected result file'
                }
            }
            catch {
                $probeFailureReason = "{0}: {1}" -f $_.Exception.GetType().FullName, $_.Exception.Message
                $supportsNativeArgumentArray = $false
            }

            if (-not $supportsNativeArgumentArray) {
                Format-StartProcessNativeArgumentProbeFailureDiagnostic `
                    -Reason $probeFailureReason `
                    -StdoutPath $probeStdout `
                    -StderrPath $probeStderr
            }

            $script:StartProcessNativeArgumentArraySupport = $supportsNativeArgumentArray
            return $supportsNativeArgumentArray
        }
        finally {
            if ($null -ne $probeProcess) {
                $probeProcess.Dispose()
            }
            Remove-TemporaryFile -Path $probeScript
            Remove-TemporaryFile -Path $probeOutput
            Remove-TemporaryFile -Path $probeStdout
            Remove-TemporaryFile -Path $probeStderr
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StartProcessNativeArgumentArraySupportLock)
    }
}

function Test-ProcessArgumentListRequiresNativeSupportResolution {
    param(
        [object[]]$ArgumentList = @()
    )

    foreach ($argument in @($ArgumentList)) {
        $text = [string]$argument
        if ($text.Length -eq 0 -or $text -match '[\s"]') {
            return $true
        }
    }

    return $false
}

function Resolve-StartProcessArgumentList {
    param(
        [object[]]$ArgumentList = @()
    )

    if ($null -eq $ArgumentList -or @($ArgumentList).Count -eq 0) {
        return $null
    }

    Assert-NoNullProcessArguments -ArgumentList $ArgumentList

    if (-not (Test-ProcessArgumentListRequiresNativeSupportResolution -ArgumentList $ArgumentList)) {
        return Convert-ArgumentListToStringArray -ArgumentList $ArgumentList -DiagnosticPrefix 'Process argument list'
    }

    $nativeSupport = Test-StartProcessNativeArgumentArraySupport
    if ($nativeSupport) {
        return Convert-ArgumentListToStringArray -ArgumentList $ArgumentList -DiagnosticPrefix 'Process argument list'
    }

    return Format-ProcessArgumentListForInvocation -ArgumentList $ArgumentList
}

function Format-CommandArgumentForDisplay {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Argument
    )

    if ($null -eq $Argument) {
        return '$null'
    }

    $text = [string]$Argument
    $sanitizedText = $text.Replace("`r", '\r').Replace("`n", '\n')
    $wasSanitized = $sanitizedText -ne $text
    $text = $sanitizedText
    if ($text.Length -eq 0) {
        return "''"
    }

    if ($wasSanitized -or $text -match '[\s''`"]') {
        return "'{0}'" -f $text.Replace("'", "''")
    }

    return $text
}

function Format-CommandLineForDisplay {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [object[]]$ArgumentList = @()
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Format-CommandArgumentForDisplay -Argument $FilePath))
    if ($null -eq $ArgumentList) {
        $ArgumentList = @()
    }

    foreach ($argument in @($ArgumentList)) {
        $parts.Add((Format-CommandArgumentForDisplay -Argument $argument))
    }

    return [string]::Join(' ', $parts)
}

function Format-ProcessArgumentForInvocation {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Argument
    )

    return Format-InvocationArgument -Argument $Argument -DiagnosticPrefix 'Process argument list'
}

function Format-ProcessArgumentListForInvocation {
    param(
        [object[]]$ArgumentList = @()
    )

    return Join-InvocationArgumentList -ArgumentList $ArgumentList -DiagnosticPrefix 'Process argument list'
}

<#
.SYNOPSIS
Runs an external command quietly on success and replays full output on failure.

.DESCRIPTION
Captures stdout and stderr into temporary files. When the command fails, the helper replays the
captured output to the current streams and throws. When the command succeeds, it returns bounded
stdout and stderr excerpts without emitting them, and derives LastOutputLine from stdout only.

.PARAMETER FilePath
Executable or script to run.

.PARAMETER ArgumentList
Arguments forwarded to the child process.

.PARAMETER WorkingDirectory
Working directory used for the child process. Defaults to the current location.

.PARAMETER MaxExcerptLines
Maximum number of lines retained for the returned stdout/stderr excerpts.

.OUTPUTS
PSCustomObject with ExitCode, Stdout, Stderr, and LastOutputLine properties.
#>
function Invoke-ExternalCommandQuietOnSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [object[]]$ArgumentList = @(),

        [string]$WorkingDirectory,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxExcerptLines = 200
    )

    $wd = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($wd)) {
        $wd = (Get-Location).Path
    }

    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}.stdout.log" -f $script:UnrealProjectVerifyTempPrefix,
        [Guid]::NewGuid().ToString('N'))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}.stderr.log" -f $script:UnrealProjectVerifyTempPrefix,
        [Guid]::NewGuid().ToString('N'))
    $proc = $null

    try {
        $startProcessParams = Get-StartProcessParameters `
            -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -WorkingDirectory $wd `
            -PassThru `
            -Wait `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile
        $proc = Start-Process @startProcessParams
        $exitCode = $proc.ExitCode

        if ($exitCode -ne 0) {
            Write-ProcessOutputFile -Path $stdoutFile
            Write-ProcessOutputFile -Path $stderrFile -ToErrorStream
            $commandLine = Format-CommandLineForDisplay -FilePath $FilePath -ArgumentList $ArgumentList
            throw "Command failed (ExitCode=$exitCode): $commandLine"
        }

        $stdoutExcerptInfo = Get-ProcessOutputFileExcerptInfo -Path $stdoutFile -MaxLines $MaxExcerptLines
        $stdoutExcerpt = [string]$stdoutExcerptInfo.Excerpt
        $stderrExcerpt = Get-ProcessOutputFileExcerpt -Path $stderrFile -MaxLines $MaxExcerptLines
        $lastOutputLine = [string]$stdoutExcerptInfo.LastNonEmptyLine

        return [pscustomobject]@{
            ExitCode       = $exitCode
            Stdout         = $stdoutExcerpt
            Stderr         = $stderrExcerpt
            LastOutputLine = $lastOutputLine
        }
    }
    finally {
        if ($null -ne $proc) {
            $proc.Dispose()
        }
        Remove-TemporaryFile -Path $stdoutFile
        Remove-TemporaryFile -Path $stderrFile
    }
}

function Get-SourceFilesForFullStaticAnalysis {
    param(
        [string[]]$Extensions,

        [string[]]$Pathspec = @('Source')
    )

    $gitArgs = @('ls-files', '--cached', '--others', '--exclude-standard')
    if (@($Pathspec).Count -gt 0) {
        $gitArgs += '--'
        $gitArgs += $Pathspec
    }

    $files = & git @gitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files failed (ExitCode=$LASTEXITCODE)."
    }

    return @($files | Sort-Object -Unique | Where-Object {
        $ext = [System.IO.Path]::GetExtension($_)
        (Test-Path -LiteralPath $_) -and ($Extensions -contains $ext)
    })
}

function Get-LocalChangedRepositoryFiles {
    param(
        [string[]]$Pathspec = @()
    )

    $hasHead = $false
    $null = & git rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -eq 0) {
        $hasHead = $true
    }

    if (-not $hasHead) {
        $lsFilesArgs = @('ls-files', '--cached', '--others', '--exclude-standard')
        if ($Pathspec.Count -gt 0) {
            $lsFilesArgs += '--'
            $lsFilesArgs += $Pathspec
        }

        $files = & git @lsFilesArgs
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed (ExitCode=$LASTEXITCODE)."
        }

        return @($files | Sort-Object -Unique)
    }

    $diffArgs = @('diff', '-w', '--name-only', '--diff-filter=ACDMRT', 'HEAD', '--')
    if ($Pathspec.Count -gt 0) {
        $diffArgs += $Pathspec
    }

    $diffFiles = & git @diffArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git diff failed (ExitCode=$LASTEXITCODE)."
    }

    $untrackedArgs = @('ls-files', '--others', '--exclude-standard')
    if ($Pathspec.Count -gt 0) {
        $untrackedArgs += '--'
        $untrackedArgs += $Pathspec
    }

    $untrackedFiles = & git @untrackedArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files for untracked files failed (ExitCode=$LASTEXITCODE)."
    }

    return @(($diffFiles + $untrackedFiles) | Sort-Object -Unique)
}

function Resolve-StaticAnalysisSelectionScope {
    param(
        [ValidateSet('auto', 'local', 'pr', 'push', 'all')]
        [string]$RequestedScope = 'auto',

        [string]$GitHubEventName = $env:GITHUB_EVENT_NAME,

        [string]$GitHubActions = $env:GITHUB_ACTIONS
    )

    if ($RequestedScope -ne 'auto') {
        return $RequestedScope
    }

    if ($GitHubActions -eq 'true') {
        switch ($GitHubEventName) {
            'pull_request' { return 'pr' }
            'pull_request_target' { return 'pr' }
            'push' { return 'push' }
        }
    }

    return 'local'
}

function Resolve-StaticAnalysisBaseRef {
    param(
        [string]$DefaultBaseRef,

        [ValidateSet('auto', 'local', 'pr', 'push', 'all')]
        [string]$ResolvedScope,

        [string]$GitHubBaseRef = $env:GITHUB_BASE_REF
    )

    if ($ResolvedScope -eq 'pr' -and -not [string]::IsNullOrWhiteSpace($GitHubBaseRef)) {
        return ('origin/{0}' -f $GitHubBaseRef)
    }

    return $DefaultBaseRef
}

function Try-Resolve-StaticAnalysisPushRange {
    param(
        [string]$GitHubEventPath = $env:GITHUB_EVENT_PATH,

        [string]$GitHubSha = $env:GITHUB_SHA
    )

    if ([string]::IsNullOrWhiteSpace($GitHubEventPath) -or -not (Test-Path -LiteralPath $GitHubEventPath)) {
        return $null
    }

    $payload = ConvertFrom-Json (Get-Content -LiteralPath $GitHubEventPath -Raw)
    if ($null -eq $payload) {
        return $null
    }

    $beforeProperty = $payload.PSObject.Properties['before']
    $afterProperty = $payload.PSObject.Properties['after']
    $before = if ($null -ne $beforeProperty) { [string]$beforeProperty.Value } else { '' }
    $after = if (-not [string]::IsNullOrWhiteSpace($GitHubSha)) { $GitHubSha } elseif ($null -ne $afterProperty) { [string]$afterProperty.Value } else { '' }

    $shaPattern = '^[0-9a-fA-F]{40}$'
    if ([string]::IsNullOrWhiteSpace($before) -or $before -notmatch $shaPattern) {
        return $null
    }
    if ($before -match '^0+$') {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($after) -or $after -notmatch $shaPattern) {
        return $null
    }

    return [pscustomobject]@{
        Before = $before
        After  = $after
    }
}

function Resolve-StaticAnalysisSelectionContext {
    param(
        [ValidateSet('auto', 'local', 'pr', 'push', 'all')]
        [string]$RequestedScope = 'auto',

        [string]$DefaultBaseRef,

        [string]$GitHubEventName = $env:GITHUB_EVENT_NAME,

        [string]$GitHubActions = $env:GITHUB_ACTIONS,

        [string]$GitHubBaseRef = $env:GITHUB_BASE_REF,

        [string]$GitHubEventPath = $env:GITHUB_EVENT_PATH,

        [string]$GitHubSha = $env:GITHUB_SHA
    )

    $resolvedScope = Resolve-StaticAnalysisSelectionScope `
        -RequestedScope $RequestedScope `
        -GitHubEventName $GitHubEventName `
        -GitHubActions $GitHubActions
    $baseRef = Resolve-StaticAnalysisBaseRef -DefaultBaseRef $DefaultBaseRef -ResolvedScope $resolvedScope -GitHubBaseRef $GitHubBaseRef
    $pushRange = $null
    $description = ''

    switch ($resolvedScope) {
        'local' {
            $description = 'local working tree diff vs HEAD'
        }
        'pr' {
            $description = ('pull request diff vs {0} plus local working tree changes' -f $baseRef)
        }
        'push' {
            $pushRange = Try-Resolve-StaticAnalysisPushRange -GitHubEventPath $GitHubEventPath -GitHubSha $GitHubSha
            if ($null -eq $pushRange) {
                $resolvedScope = 'all'
                $description = 'full configured static-analysis tree (push range unavailable)'
            }
            else {
                $description = ('push diff {0}..{1} plus local working tree changes' -f $pushRange.Before.Substring(0, 7), $pushRange.After.Substring(0, 7))
            }
        }
        'all' {
            $description = 'full configured static-analysis tree'
        }
    }

    return [pscustomobject]@{
        Scope       = $resolvedScope
        BaseRef     = $baseRef
        Before      = if ($null -ne $pushRange) { $pushRange.Before } else { $null }
        After       = if ($null -ne $pushRange) { $pushRange.After } else { $null }
        Description = $description
    }
}

function Get-ChangedSourceFilesForStaticAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$SelectionContext,

        [Parameter(Mandatory = $true)]
        [string[]]$Extensions,

        [string[]]$Pathspec = @('Source'),

        [switch]$All
    )

    if ($null -eq $Extensions -or $Extensions.Count -eq 0) {
        return @()
    }

    if ($All -or $SelectionContext.Scope -eq 'all') {
        return @(Get-SourceFilesForFullStaticAnalysis -Extensions $Extensions -Pathspec $Pathspec)
    }

    $localChangedFiles = @(Get-LocalChangedRepositoryFiles -Pathspec $Pathspec)
    $diffFiles = @()

    switch ($SelectionContext.Scope) {
        'local' {
            $diffFiles = $localChangedFiles
        }
        'pr' {
            $hasBase = $false
            $null = & git rev-parse --verify $SelectionContext.BaseRef 2>$null
            if ($LASTEXITCODE -eq 0) {
                $hasBase = $true
            }

            if (-not $hasBase) {
                Write-Warning "Base ref not found locally ($($SelectionContext.BaseRef)). Falling back to full static-analysis scan."
                return @(Get-SourceFilesForFullStaticAnalysis -Extensions $Extensions -Pathspec $Pathspec)
            }

            $mergeBase = & git merge-base $SelectionContext.BaseRef HEAD
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBase)) {
                Write-Warning "git merge-base failed for $($SelectionContext.BaseRef)..HEAD. Falling back to full static-analysis scan."
                return @(Get-SourceFilesForFullStaticAnalysis -Extensions $Extensions -Pathspec $Pathspec)
            }

            $gitDiffArgs = @('diff', '-w', '--name-only', '--diff-filter=ACMRT', $mergeBase, 'HEAD', '--')
            $gitDiffArgs += $Pathspec
            $diffFiles = & git @gitDiffArgs
            if ($LASTEXITCODE -ne 0) {
                throw "git diff failed (ExitCode=$LASTEXITCODE)."
            }
        }
        'push' {
            if ([string]::IsNullOrWhiteSpace($SelectionContext.Before) -or [string]::IsNullOrWhiteSpace($SelectionContext.After)) {
                Write-Warning 'Push diff range was unavailable. Falling back to full static-analysis scan.'
                return @(Get-SourceFilesForFullStaticAnalysis -Extensions $Extensions -Pathspec $Pathspec)
            }

            $gitDiffArgs = @('diff', '-w', '--name-only', '--diff-filter=ACMRT', $SelectionContext.Before, $SelectionContext.After, '--')
            $gitDiffArgs += $Pathspec
            $diffFiles = & git @gitDiffArgs
            if ($LASTEXITCODE -ne 0) {
                throw "git diff failed (ExitCode=$LASTEXITCODE)."
            }
        }
        default {
            throw "Unsupported static analysis scope: $($SelectionContext.Scope)"
        }
    }

    return @(($diffFiles + $localChangedFiles) | Sort-Object -Unique | Where-Object {
        $ext = [System.IO.Path]::GetExtension($_)
        (Test-Path -LiteralPath $_) -and ($Extensions -contains $ext)
    })
}

function Test-PathMatchesAnyWildcard {
    param(
        [string]$Path,
        [string[]]$Patterns
    )

    $normalizedPath = $Path.Replace('\', '/')
    foreach ($pattern in $Patterns) {
        if ($normalizedPath -like $pattern) {
            return $true
        }
    }

    return $false
}

function Resolve-BuildAndTestPlan {
    param(
        [ValidateSet('auto', 'local', 'all')]
        [string]$RequestedScope = 'auto',

        [string[]]$ChangedFiles,

        [string[]]$ImpactPatterns = @(
            '*.uproject',
            '*.uplugin',
            '*.Build.cs',
            '*.Target.cs',
            'Source/*',
            'Config/*',
            'Plugins/*/Source/*',
            'Plugins/*/Config/*'
        ),

        [string]$GitHubActions = $env:GITHUB_ACTIONS
    )

    $resolvedScope = $RequestedScope
    if ($resolvedScope -eq 'auto') {
        if ($GitHubActions -eq 'true') {
            $resolvedScope = 'all'
        }
        else {
            $resolvedScope = 'local'
        }
    }

    if ($resolvedScope -eq 'all') {
        return [pscustomobject]@{
            Scope        = 'all'
            ShouldRun    = $true
            ChangedFiles = @()
            MatchedFiles = @()
            Description  = 'Build/test selection: full verification scope.'
        }
    }

    $candidateFiles = @()
    if ($PSBoundParameters.ContainsKey('ChangedFiles')) {
        $candidateFiles = @($ChangedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        $candidateFiles = @(Get-LocalChangedRepositoryFiles)
    }

    $matchedFiles = @($candidateFiles | Where-Object {
        Test-PathMatchesAnyWildcard -Path $_ -Patterns $ImpactPatterns
    })

    if ($matchedFiles.Count -gt 0) {
        return [pscustomobject]@{
            Scope        = 'local'
            ShouldRun    = $true
            ChangedFiles = $candidateFiles
            MatchedFiles = $matchedFiles
            Description  = ('Build/test selection: local changes require Unreal verification ({0}).' -f $matchedFiles[0])
        }
    }

    return [pscustomobject]@{
        Scope        = 'local'
        ShouldRun    = $false
        ChangedFiles = $candidateFiles
        MatchedFiles = @()
        Description  = 'Build/test selection: skipping local Unreal build and automation tests because no build/test-affecting files changed.'
    }
}

function Resolve-UbtBuildConfigurationSourcePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [psobject]$BuildAndTestPlan
    )

    $configDir = Join-Path (Join-Path $RepoRoot 'Config') 'UBT'
    $defaultConfigPath = Join-Path $configDir 'BuildConfiguration.xml'
    $fullVerifyConfigPath = Join-Path $configDir 'BuildConfiguration.FullVerify.xml'

    if ($BuildAndTestPlan.Scope -eq 'all' -and (Test-Path -LiteralPath $fullVerifyConfigPath)) {
        return $fullVerifyConfigPath
    }

    return $defaultConfigPath
}

function Test-IsAutomationSpecImplementationFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$SpecPatterns = @('Source/*Tests/Private/*.spec.cpp')
    )

    $normalizedPath = $Path.Replace('\', '/')
    return Test-PathMatchesAnyWildcard -Path $normalizedPath -Patterns $SpecPatterns
}

function Try-Resolve-AutomationSpecFilterFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $absolutePath = Resolve-AbsolutePathOnDisk -Path $Path -BasePath $RepoRoot
    if (-not [System.IO.File]::Exists($absolutePath)) {
        return $null
    }

    $fileText = Get-Content -LiteralPath $absolutePath -Raw
    if ([string]::IsNullOrWhiteSpace($fileText)) {
        return $null
    }

    $match = [System.Text.RegularExpressions.Regex]::Match(
        $fileText,
        'BEGIN_DEFINE_SPEC\s*\(\s*[^,]+,\s*"([^"]+)"',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        return $null
    }

    $resolvedFilter = $match.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($resolvedFilter)) {
        return $null
    }

    return $resolvedFilter
}

function Resolve-AutomationTestFilterPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedFilter,

        [Parameter(Mandatory = $true)]
        [psobject]$BuildAndTestPlan,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string[]]$SpecPatterns = @('Source/*Tests/Private/*.spec.cpp'),

        [bool]$UserProvidedFilter = $false,

        [string]$GitHubActions = $env:GITHUB_ACTIONS
    )

    if ($UserProvidedFilter) {
        return [pscustomobject]@{
            Filter      = $RequestedFilter
            Narrowed    = $false
            Description = ('Automation test filter: preserving explicitly requested filter ({0}).' -f $RequestedFilter)
            SpecFiles   = @()
        }
    }

    if ($BuildAndTestPlan.Scope -eq 'all' -or $GitHubActions -eq 'true') {
        return [pscustomobject]@{
            Filter      = $RequestedFilter
            Narrowed    = $false
            Description = ('Automation test filter: keeping full filter ({0}) for non-local/full verification scope.' -f
                $RequestedFilter)
            SpecFiles   = @()
        }
    }

    if (-not $BuildAndTestPlan.ShouldRun) {
        return [pscustomobject]@{
            Filter      = $RequestedFilter
            Narrowed    = $false
            Description = ''
            SpecFiles   = @()
        }
    }

    $matchedFiles = @($BuildAndTestPlan.MatchedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($matchedFiles.Count -eq 0) {
        return [pscustomobject]@{
            Filter      = $RequestedFilter
            Narrowed    = $false
            Description = ('Automation test filter: keeping full filter ({0}) because no local build-impact files were matched.' -f
                $RequestedFilter)
            SpecFiles   = @()
        }
    }

    $specFiles = @($matchedFiles | Where-Object {
        Test-IsAutomationSpecImplementationFile -Path $_ -SpecPatterns $SpecPatterns
    })
    if ($specFiles.Count -ne $matchedFiles.Count) {
        return [pscustomobject]@{
            Filter      = $RequestedFilter
            Narrowed    = $false
            Description = ('Automation test filter: keeping full filter ({0}) because non-spec build-impact files changed.' -f
                $RequestedFilter)
            SpecFiles   = @()
        }
    }

    $specFilters = [System.Collections.Generic.List[string]]::new()
    foreach ($specFile in $specFiles) {
        $resolvedFilter = Try-Resolve-AutomationSpecFilterFromFile -RepoRoot $RepoRoot -Path $specFile
        if ([string]::IsNullOrWhiteSpace($resolvedFilter)) {
            return [pscustomobject]@{
                Filter      = $RequestedFilter
                Narrowed    = $false
                Description = ('Automation test filter: keeping full filter ({0}) because {1} did not expose BEGIN_DEFINE_SPEC.' -f
                    $RequestedFilter, $specFile)
                SpecFiles   = @($specFiles)
            }
        }

        if (-not $specFilters.Contains($resolvedFilter)) {
            $specFilters.Add($resolvedFilter)
        }
    }

    if ($specFilters.Count -eq 0) {
        return [pscustomobject]@{
            Filter      = $RequestedFilter
            Narrowed    = $false
            Description = ('Automation test filter: keeping full filter ({0}) because no spec names were resolved.' -f
                $RequestedFilter)
            SpecFiles   = @($specFiles)
        }
    }

    $resolvedCombinedFilter = [string]::Join('+', $specFilters.ToArray())
    return [pscustomobject]@{
        Filter      = $resolvedCombinedFilter
        Narrowed    = $true
        Description = ('Automation test filter: narrowed local spec-only change set from {0} to {1}.' -f
            $RequestedFilter, $resolvedCombinedFilter)
        SpecFiles   = @($specFiles)
    }
}

function Get-StaticAnalysisSystemProfile {
    $processorCount = [Math]::Max(1, [Environment]::ProcessorCount)
    $computerSystem = $null
    $operatingSystem = $null

    if ($null -ne (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        try {
            $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
            $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        }
        catch {
        }
    }

    if (($null -eq $computerSystem -or $null -eq $operatingSystem) -and
        $null -ne (Get-Command Get-WmiObject -ErrorAction SilentlyContinue)) {
        try {
            $computerSystem = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
            $operatingSystem = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        }
        catch {
        }
    }

    $totalPhysicalMemoryBytes = $null
    if ($null -ne $computerSystem -and $null -ne $computerSystem.PSObject.Properties['TotalPhysicalMemory']) {
        try {
            $totalPhysicalMemoryBytes = [int64]$computerSystem.PSObject.Properties['TotalPhysicalMemory'].Value
        }
        catch {
            $totalPhysicalMemoryBytes = $null
        }
    }

    $freePhysicalMemoryBytes = $null
    if ($null -ne $operatingSystem -and $null -ne $operatingSystem.PSObject.Properties['FreePhysicalMemory']) {
        try {
            $freePhysicalMemoryBytes = [int64]$operatingSystem.PSObject.Properties['FreePhysicalMemory'].Value * 1KB
        }
        catch {
            $freePhysicalMemoryBytes = $null
        }
    }

    return [pscustomobject]@{
        ProcessorCount           = $processorCount
        TotalPhysicalMemoryBytes = $totalPhysicalMemoryBytes
        FreePhysicalMemoryBytes  = $freePhysicalMemoryBytes
    }
}

function Resolve-StaticAnalysisCpuCap {
    param(
        [ValidateSet('generic', 'clang-format', 'clang-tidy')]
        [string]$ToolKind = 'generic',

        [int]$ProcessorCount = 0
    )

    $resolvedProcessorCount = [Math]::Max(1, $ProcessorCount)
    if ($resolvedProcessorCount -eq 1) {
        return 1
    }

    $targetFraction = switch ($ToolKind) {
        'clang-format' { 0.75 }
        'clang-tidy' { 0.5 }
        default { 0.5 }
    }

    $cpuCap = [int][Math]::Floor([double]$resolvedProcessorCount * $targetFraction)
    if ($cpuCap -ge $resolvedProcessorCount) {
        $cpuCap = $resolvedProcessorCount - 1
    }

    return [Math]::Max(1, $cpuCap)
}

function Resolve-StaticAnalysisMemoryCap {
    param(
        [ValidateSet('generic', 'clang-format', 'clang-tidy')]
        [string]$ToolKind = 'generic',

        [object]$AvailablePhysicalMemoryBytes = $null
    )

    $resolvedAvailablePhysicalMemoryBytes = $null
    if ($null -ne $AvailablePhysicalMemoryBytes) {
        try {
            $resolvedAvailablePhysicalMemoryBytes = [int64]$AvailablePhysicalMemoryBytes
        }
        catch {
            $resolvedAvailablePhysicalMemoryBytes = $null
        }
    }

    if ($null -eq $resolvedAvailablePhysicalMemoryBytes -or $resolvedAvailablePhysicalMemoryBytes -le 0) {
        return $null
    }

    $reservedBytes = [int64]1GB
    $bytesPerWorker = [int64]2GB
    switch ($ToolKind) {
        'clang-format' {
            $reservedBytes = [int64]1GB
            $bytesPerWorker = [int64]512MB
        }
        'clang-tidy' {
            $reservedBytes = [int64]2GB
            $bytesPerWorker = [int64]4GB
        }
    }

    $usableBytes = $resolvedAvailablePhysicalMemoryBytes - $reservedBytes
    if ($usableBytes -le 0) {
        return 1
    }

    $memoryCap = [int][Math]::Floor([double]$usableBytes / [double]$bytesPerWorker)
    return [Math]::Max(1, $memoryCap)
}

function Resolve-StaticAnalysisConcurrencyPlan {
    param(
        [int]$RequestedMaxConcurrency = 0,

        [ValidateSet('generic', 'clang-format', 'clang-tidy')]
        [string]$ToolKind = 'generic',

        [int]$FileCount = 0,

        [int]$ProcessorCount = 0,

        [object]$TotalPhysicalMemoryBytes = $null,

        [object]$FreePhysicalMemoryBytes = $null
    )

    $resolvedProcessorCount = $ProcessorCount
    $resolvedTotalPhysicalMemoryBytes = $null
    $resolvedFreePhysicalMemoryBytes = $null

    if ($null -ne $TotalPhysicalMemoryBytes) {
        try {
            $resolvedTotalPhysicalMemoryBytes = [int64]$TotalPhysicalMemoryBytes
        }
        catch {
            $resolvedTotalPhysicalMemoryBytes = $null
        }
    }

    if ($null -ne $FreePhysicalMemoryBytes) {
        try {
            $resolvedFreePhysicalMemoryBytes = [int64]$FreePhysicalMemoryBytes
        }
        catch {
            $resolvedFreePhysicalMemoryBytes = $null
        }
    }

    if ($resolvedProcessorCount -le 0 -or
        ($null -eq $resolvedTotalPhysicalMemoryBytes -and $null -eq $resolvedFreePhysicalMemoryBytes)) {
        $profile = Get-StaticAnalysisSystemProfile
        if ($resolvedProcessorCount -le 0) {
            $resolvedProcessorCount = $profile.ProcessorCount
        }
        if ($null -eq $resolvedTotalPhysicalMemoryBytes) {
            $resolvedTotalPhysicalMemoryBytes = $profile.TotalPhysicalMemoryBytes
        }
        if ($null -eq $resolvedFreePhysicalMemoryBytes) {
            $resolvedFreePhysicalMemoryBytes = $profile.FreePhysicalMemoryBytes
        }
    }

    $resolvedProcessorCount = [Math]::Max(1, $resolvedProcessorCount)
    $fileCap = $null
    if ($FileCount -gt 0) {
        $fileCap = [Math]::Max(1, $FileCount)
    }

    if ($RequestedMaxConcurrency -gt 0) {
        $resolvedConcurrency = [Math]::Max(1, $RequestedMaxConcurrency)
        if ($null -ne $fileCap) {
            $resolvedConcurrency = [Math]::Min($resolvedConcurrency, $fileCap)
        }

        return [pscustomobject]@{
            Mode                     = 'manual'
            ToolKind                 = $ToolKind
            RequestedMaxConcurrency  = $RequestedMaxConcurrency
            ResolvedConcurrency      = $resolvedConcurrency
            ProcessorCount           = $resolvedProcessorCount
            CpuCap                   = $null
            MemoryCap                = $null
            FileCap                  = $fileCap
            MemorySource             = 'manual'
            TotalPhysicalMemoryBytes = $resolvedTotalPhysicalMemoryBytes
            FreePhysicalMemoryBytes  = $resolvedFreePhysicalMemoryBytes
        }
    }

    $cpuCap = Resolve-StaticAnalysisCpuCap -ToolKind $ToolKind -ProcessorCount $resolvedProcessorCount
    $memorySource = 'unknown'
    $memoryBasisBytes = $null
    if ($null -ne $resolvedFreePhysicalMemoryBytes -and $resolvedFreePhysicalMemoryBytes -gt 0) {
        $memorySource = 'free'
        $memoryBasisBytes = $resolvedFreePhysicalMemoryBytes
    }
    elseif ($null -ne $resolvedTotalPhysicalMemoryBytes -and $resolvedTotalPhysicalMemoryBytes -gt 0) {
        $memorySource = 'total'
        $memoryBasisBytes = $resolvedTotalPhysicalMemoryBytes
    }

    $memoryCap = Resolve-StaticAnalysisMemoryCap -ToolKind $ToolKind -AvailablePhysicalMemoryBytes $memoryBasisBytes
    $resolvedConcurrency = $cpuCap
    if ($null -ne $memoryCap) {
        $resolvedConcurrency = [Math]::Min($resolvedConcurrency, $memoryCap)
    }
    if ($null -ne $fileCap) {
        $resolvedConcurrency = [Math]::Min($resolvedConcurrency, $fileCap)
    }

    return [pscustomobject]@{
        Mode                     = 'auto'
        ToolKind                 = $ToolKind
        RequestedMaxConcurrency  = $RequestedMaxConcurrency
        ResolvedConcurrency      = [Math]::Max(1, $resolvedConcurrency)
        ProcessorCount           = $resolvedProcessorCount
        CpuCap                   = $cpuCap
        MemoryCap                = $memoryCap
        FileCap                  = $fileCap
        MemorySource             = $memorySource
        TotalPhysicalMemoryBytes = $resolvedTotalPhysicalMemoryBytes
        FreePhysicalMemoryBytes  = $resolvedFreePhysicalMemoryBytes
    }
}

function Format-StaticAnalysisConcurrencyPlan {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Plan
    )

    if ($Plan.Mode -eq 'manual') {
        $parts = @(
            ('manual {0} worker(s)' -f $Plan.ResolvedConcurrency)
        )
        if ($null -ne $Plan.FileCap) {
            $parts += ('file cap={0}' -f $Plan.FileCap)
        }
        return [string]::Join(', ', $parts)
    }

    $parts = @(
        ('auto {0} worker(s)' -f $Plan.ResolvedConcurrency),
        ('cpu cap={0}' -f $Plan.CpuCap)
    )

    if ($null -ne $Plan.MemoryCap) {
        $memoryBytes = $null
        if ($Plan.MemorySource -eq 'free') {
            $memoryBytes = $Plan.FreePhysicalMemoryBytes
        }
        elseif ($Plan.MemorySource -eq 'total') {
            $memoryBytes = $Plan.TotalPhysicalMemoryBytes
        }

        if ($null -ne $memoryBytes -and $memoryBytes -gt 0) {
            $parts += ('memory cap={0} ({1} RAM {2:N1} GiB)' -f $Plan.MemoryCap, $Plan.MemorySource,
                ([double]$memoryBytes / 1GB))
        }
        else {
            $parts += ('memory cap={0}' -f $Plan.MemoryCap)
        }
    }

    if ($null -ne $Plan.FileCap) {
        $parts += ('file cap={0}' -f $Plan.FileCap)
    }

    return [string]::Join(', ', $parts)
}

function Resolve-StaticAnalysisConcurrency {
    param(
        [int]$RequestedMaxConcurrency = 0,

        [ValidateSet('generic', 'clang-format', 'clang-tidy')]
        [string]$ToolKind = 'generic',

        [int]$FileCount = 0,

        [int]$ProcessorCount = 0,

        [object]$TotalPhysicalMemoryBytes = $null,

        [object]$FreePhysicalMemoryBytes = $null
    )

    return (Resolve-StaticAnalysisConcurrencyPlan `
            -RequestedMaxConcurrency $RequestedMaxConcurrency `
            -ToolKind $ToolKind `
            -FileCount $FileCount `
            -ProcessorCount $ProcessorCount `
            -TotalPhysicalMemoryBytes $TotalPhysicalMemoryBytes `
            -FreePhysicalMemoryBytes $FreePhysicalMemoryBytes).ResolvedConcurrency
}

function Get-VerifyCacheRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $cacheRoot = Join-Path (Join-Path $RepoRoot 'Saved') 'VerifyCache'
    $null = New-Item -ItemType Directory -Force -Path $cacheRoot
    return $cacheRoot
}

function Normalize-VerifyEngineRootPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EngineRoot
    )

    $resolvedEngineRoot = [System.IO.Path]::GetFullPath($EngineRoot).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($resolvedEngineRoot)) {
        throw 'Engine root path must not be empty.'
    }

    return $resolvedEngineRoot
}

function Get-VerifyEngineRootMarkerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    return Join-Path (Get-VerifyCacheRoot -RepoRoot $RepoRoot) 'engine-root.txt'
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$CandidatePath
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    $normalizedCandidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd('\', '/')
    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedCandidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-VerifyEngineSensitiveBuildDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $repoRootPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $candidateDirectories = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @(
            'Intermediate\Build\Win64',
            'Intermediate\ClangDatabase',
            'Binaries\Win64'
        )) {
        $candidateDirectories.Add((Join-Path $repoRootPath $relativePath))
    }

    $pluginsRoot = Join-Path $repoRootPath 'Plugins'
    if ([System.IO.Directory]::Exists($pluginsRoot)) {
        $pluginFiles = Get-ChildItem -LiteralPath $pluginsRoot -Filter '*.uplugin' -File -Recurse -ErrorAction Stop
        foreach ($pluginFile in @($pluginFiles)) {
            $pluginRoot = Split-Path $pluginFile.FullName -Parent
            foreach ($relativePath in @(
                    'Intermediate\Build\Win64',
                    'Binaries\Win64'
                )) {
                $candidateDirectories.Add((Join-Path $pluginRoot $relativePath))
            }
        }
    }

    $seenDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $resolvedDirectories = [System.Collections.Generic.List[string]]::new()
    foreach ($candidateDirectory in @($candidateDirectories)) {
        $resolvedDirectory = [System.IO.Path]::GetFullPath($candidateDirectory)
        if (-not (Test-PathWithinRoot -RootPath $repoRootPath -CandidatePath $resolvedDirectory)) {
            throw "Refusing to consider a verify build-artifact directory outside the repository root: $resolvedDirectory"
        }
        if ($seenDirectories.Add($resolvedDirectory)) {
            $resolvedDirectories.Add($resolvedDirectory)
        }
    }

    return @($resolvedDirectories)
}

function Clear-ReadOnlyAttributeIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $attributes = [System.IO.File]::GetAttributes($Path)
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        [System.IO.File]::SetAttributes(
            $Path,
            $attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly))
    }
}

function Remove-DirectoryTreeIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.Directory]::Exists($Path)) {
        return
    }

    $maxAttempts = 20
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Clear-ReadOnlyAttributeIfNeeded -Path $Path
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries(
                    $Path,
                    '*',
                    [System.IO.SearchOption]::AllDirectories)) {
                Clear-ReadOnlyAttributeIfNeeded -Path $entry
            }
            [System.IO.Directory]::Delete($Path, $true)
            return
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

function Sync-VerifyEngineRootBuildArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$EngineRoot
    )

    $currentEngineRoot = Normalize-VerifyEngineRootPath -EngineRoot $EngineRoot
    $currentEngineRootKey = $currentEngineRoot.ToLowerInvariant()
    $markerPath = Get-VerifyEngineRootMarkerPath -RepoRoot $RepoRoot
    $previousEngineRoot = $null
    $previousEngineRootKey = $null

    if ([System.IO.File]::Exists($markerPath)) {
        $storedEngineRoot = [System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($storedEngineRoot)) {
            $previousEngineRoot = $storedEngineRoot
            $previousEngineRootKey = (Normalize-VerifyEngineRootPath -EngineRoot $storedEngineRoot).ToLowerInvariant()
        }
    }

    $existingArtifactDirectories = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in @(Get-VerifyEngineSensitiveBuildDirectories -RepoRoot $RepoRoot)) {
        if ([System.IO.Directory]::Exists($directory)) {
            $existingArtifactDirectories.Add($directory)
        }
    }

    $reason = 'unchanged'
    $shouldPurge = $false
    if ([string]::IsNullOrWhiteSpace($previousEngineRootKey)) {
        if ($existingArtifactDirectories.Count -gt 0) {
            $reason = 'initialized-with-existing-artifacts'
            $shouldPurge = $true
        }
        else {
            $reason = 'initialized-clean'
        }
    }
    elseif ($previousEngineRootKey -ne $currentEngineRootKey) {
        $reason = 'engine-root-changed'
        $shouldPurge = $existingArtifactDirectories.Count -gt 0
    }

    $purgedDirectories = [System.Collections.Generic.List[string]]::new()
    if ($shouldPurge) {
        foreach ($directory in @($existingArtifactDirectories)) {
            Remove-DirectoryTreeIfExists -Path $directory
            $purgedDirectories.Add($directory)
        }
    }

    [System.IO.File]::WriteAllText($markerPath, $currentEngineRoot, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        CurrentEngineRoot = $currentEngineRoot
        PreviousEngineRoot = $previousEngineRoot
        Reason = $reason
        MarkerPath = $markerPath
        PurgedDirectories = @($purgedDirectories)
    }
}

function Get-StaticAnalysisCacheMarkerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateSet('clang-format', 'clang-tidy')]
        [string]$ToolKind,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $cacheDir = Join-Path (Get-VerifyCacheRoot -RepoRoot $RepoRoot) $ToolKind
    $null = New-Item -ItemType Directory -Force -Path $cacheDir
    $portablePath = Convert-ToPortableAbsolutePath -Path $Path -BasePath $RepoRoot
    $markerName = ((Get-TextSha256 -Text $portablePath).ToLowerInvariant() + '.txt')
    return Join-Path $cacheDir $markerName
}

function Get-StaticAnalysisSuccessCacheKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ToolIdentity,

        [Parameter(Mandatory = $true)]
        [string]$ConfigSignature,

        [string]$ExtraSignature = ''
    )

    $absolutePath = Resolve-AbsolutePathOnDisk -Path $Path -BasePath $RepoRoot
    $portablePath = $absolutePath.Replace('\', '/').ToLowerInvariant()
    $fileHash = Get-FileContentSha256 -Path $absolutePath
    return Get-TextSha256 -Text ([string]::Join('|', @(
                $portablePath,
                $fileHash,
                $ToolIdentity,
                $ConfigSignature,
                $ExtraSignature
            )))
}

function Test-StaticAnalysisSuccessCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateSet('clang-format', 'clang-tidy')]
        [string]$ToolKind,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedKey
    )

    $markerPath = Get-StaticAnalysisCacheMarkerPath -RepoRoot $RepoRoot -ToolKind $ToolKind -Path $Path
    if (-not [System.IO.File]::Exists($markerPath)) {
        return $false
    }

    $cachedKey = (Get-Content -LiteralPath $markerPath -Raw).Trim()
    return $cachedKey -eq $ExpectedKey
}

function Write-StaticAnalysisSuccessCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateSet('clang-format', 'clang-tidy')]
        [string]$ToolKind,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$CacheKey
    )

    $markerPath = Get-StaticAnalysisCacheMarkerPath -RepoRoot $RepoRoot -ToolKind $ToolKind -Path $Path
    [System.IO.File]::WriteAllText($markerPath, $CacheKey, [System.Text.Encoding]::ASCII)
}

function Resolve-StaticAnalysisSuccessCachePlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateSet('clang-format', 'clang-tidy')]
        [string]$ToolKind,

        [string[]]$Files,

        [Parameter(Mandatory = $true)]
        [string]$ToolIdentity,

        [Parameter(Mandatory = $true)]
        [string]$ConfigSignature,

        [string]$ExtraSignature = ''
    )

    $pendingFiles = [System.Collections.Generic.List[string]]::new()
    $cacheKeys = @{}
    $cacheHitCount = 0

    foreach ($file in @($Files)) {
        $cacheKey = Get-StaticAnalysisSuccessCacheKey `
            -RepoRoot $RepoRoot `
            -Path $file `
            -ToolIdentity $ToolIdentity `
            -ConfigSignature $ConfigSignature `
            -ExtraSignature $ExtraSignature
        $cacheKeys[$file] = $cacheKey

        if (Test-StaticAnalysisSuccessCache -RepoRoot $RepoRoot -ToolKind $ToolKind -Path $file -ExpectedKey $cacheKey) {
            $cacheHitCount++
            continue
        }

        $pendingFiles.Add($file)
    }

    return [pscustomobject]@{
        ToolKind     = $ToolKind
        FilesToRun   = @($pendingFiles)
        CacheHitCount = $cacheHitCount
        TotalCount   = @($Files).Count
        CacheKeys    = $cacheKeys
    }
}

function Write-StaticAnalysisSuccessCacheEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateSet('clang-format', 'clang-tidy')]
        [string]$ToolKind,

        [string[]]$Files,

        [Parameter(Mandatory = $true)]
        [hashtable]$CacheKeys
    )

    foreach ($file in @($Files)) {
        if (-not $CacheKeys.ContainsKey($file)) {
            continue
        }

        Write-StaticAnalysisSuccessCache `
            -RepoRoot $RepoRoot `
            -ToolKind $ToolKind `
            -Path $file `
            -CacheKey ([string]$CacheKeys[$file])
    }
}

function Stop-ParallelProcessRecord {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Record
    )

    try {
        if ($null -ne $Record.Process) {
            if (-not $Record.Process.HasExited) {
                Stop-Process -Id $Record.Process.Id -Force -ErrorAction SilentlyContinue
            }
            $Record.Process.Dispose()
        }
    }
    finally {
        Remove-TemporaryFile -Path $Record.StdoutPath
        Remove-TemporaryFile -Path $Record.StderrPath
    }
}

function Invoke-ParallelToolForFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Files,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ArgumentListFactory,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessagePrefix,

        [string]$WorkingDirectory,

        [string]$ProgressLabel = 'static analysis',

        [ValidateSet('generic', 'clang-format', 'clang-tidy')]
        [string]$ToolKind = 'generic',

        [int]$MaxConcurrency = 0
    )

    if ($Files.Count -eq 0) {
        return
    }

    $wd = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($wd)) {
        $wd = (Get-Location).Path
    }

    $concurrencyPlan = Resolve-StaticAnalysisConcurrencyPlan `
        -RequestedMaxConcurrency $MaxConcurrency `
        -ToolKind $ToolKind `
        -FileCount $Files.Count
    $resolvedConcurrency = $concurrencyPlan.ResolvedConcurrency
    Write-Host ("[INFO] {0} concurrency: {1}" -f $ProgressLabel,
        (Format-StaticAnalysisConcurrencyPlan -Plan $concurrencyPlan)) -ForegroundColor Cyan
    $pendingFiles = [System.Collections.Generic.Queue[string]]::new()
    foreach ($file in $Files) {
        $pendingFiles.Enqueue($file)
    }

    $activeRecords = [System.Collections.Generic.List[psobject]]::new()
    $totalCount = $Files.Count
    $completedCount = 0

    try {
        while ($pendingFiles.Count -gt 0 -or $activeRecords.Count -gt 0) {
            while ($activeRecords.Count -lt $resolvedConcurrency -and $pendingFiles.Count -gt 0) {
                $file = $pendingFiles.Dequeue()
                $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) (
                    "{0}-{1}-{2}.stdout.log" -f $script:UnrealProjectVerifyTempPrefix, $ProgressLabel.Replace(' ', '-'), [Guid]::NewGuid().ToString('N'))
                $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) (
                    "{0}-{1}-{2}.stderr.log" -f $script:UnrealProjectVerifyTempPrefix, $ProgressLabel.Replace(' ', '-'), [Guid]::NewGuid().ToString('N'))
                $argumentList = @(& $ArgumentListFactory $file)
                $startProcessParams = Get-StartProcessParameters `
                    -FilePath $ToolPath `
                    -ArgumentList $argumentList `
                    -WorkingDirectory $wd `
                    -PassThru `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError $stderrPath
                $process = Start-Process @startProcessParams
                $null = $process.Handle

                $activeRecords.Add([pscustomobject]@{
                        File       = $file
                        Process    = $process
                        StdoutPath = $stdoutPath
                        StderrPath = $stderrPath
                    })

                Write-Host ("[INFO] {0} started [{1}/{2}] {3}" -f $ProgressLabel, ($completedCount + $activeRecords.Count),
                    $totalCount, $file) -ForegroundColor Cyan
            }

            $completedRecord = $null
            foreach ($record in $activeRecords) {
                if ($record.Process.HasExited) {
                    $completedRecord = $record
                    break
                }
            }

            if ($null -eq $completedRecord) {
                Start-Sleep -Milliseconds 250
                continue
            }

            $null = $completedRecord.Process.WaitForExit()
            $completedRecord.Process.Refresh()
            $exitCode = $completedRecord.Process.ExitCode

            $null = $activeRecords.Remove($completedRecord)
            $completedCount++

            if ($exitCode -ne 0) {
                Write-ProcessOutputFile -Path $completedRecord.StdoutPath
                Write-ProcessOutputFile -Path $completedRecord.StderrPath -ToErrorStream
                Stop-ParallelProcessRecord -Record $completedRecord
                throw "${FailureMessagePrefix}: $($completedRecord.File) (ExitCode=$exitCode)"
            }

            Write-Host ("[INFO] {0} completed [{1}/{2}] {3}" -f $ProgressLabel, $completedCount, $totalCount,
                $completedRecord.File) -ForegroundColor Cyan
            Stop-ParallelProcessRecord -Record $completedRecord
        }
    }
    catch {
        foreach ($record in @($activeRecords)) {
            Stop-ParallelProcessRecord -Record $record
        }
        throw
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [object[]]$ArgumentList = @(),

        [string]$WorkingDirectory,

        [switch]$RetryOnUbtConflict,

        [int]$MaxAttempts = 0,

        [int]$RetryDelaySeconds = 10
    )

    $wd = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($wd)) {
        $wd = (Get-Location).Path
    }

    $RetryLimit = 1
    if ($RetryOnUbtConflict) {
        $RetryLimit = if ($MaxAttempts -gt 0) { $MaxAttempts } else { 10 }
    }

    $RetryCount = 0
    $ExitCode = 0

    while ($RetryCount -lt $RetryLimit) {
        $logText = $null

        if ($RetryOnUbtConflict) {
            $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}.stdout.log" -f $script:UnrealProjectVerifyTempPrefix, [Guid]::NewGuid().ToString('N'))
            $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}.stderr.log" -f $script:UnrealProjectVerifyTempPrefix, [Guid]::NewGuid().ToString('N'))
            $stdoutState = New-ProcessOutputCaptureState
            $stderrState = New-ProcessOutputCaptureState
            $proc = $null

            try {
                $startProcessParams = Get-StartProcessParameters `
                    -FilePath $FilePath `
                    -ArgumentList $ArgumentList `
                    -WorkingDirectory $wd `
                    -PassThru `
                    -RedirectStandardOutput $stdoutFile `
                    -RedirectStandardError $stderrFile
                $proc = Start-Process @startProcessParams
                $null = $proc.Handle

                while (-not $proc.HasExited) {
                    Write-ProcessOutputDelta -Path $stdoutFile -State $stdoutState
                    Write-ProcessOutputDelta -Path $stderrFile -State $stderrState -ToErrorStream
                    Start-Sleep -Milliseconds 250
                }

                Write-ProcessOutputDelta -Path $stdoutFile -State $stdoutState -FlushPartial
                Write-ProcessOutputDelta -Path $stderrFile -State $stderrState -ToErrorStream -FlushPartial
                $proc.WaitForExit()
                $proc.Refresh()
                $ExitCode = $proc.ExitCode

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
                if ($null -ne $proc) {
                    $proc.Dispose()
                }
                Remove-TemporaryFile -Path $stdoutFile
                Remove-TemporaryFile -Path $stderrFile
            }
        }
        else {
            $proc = $null
            try {
                $startProcessParams = Get-StartProcessParameters `
                    -FilePath $FilePath `
                    -ArgumentList $ArgumentList `
                    -WorkingDirectory $wd `
                    -PassThru `
                    -Wait
                $proc = Start-Process @startProcessParams
                $ExitCode = $proc.ExitCode
            }
            finally {
                if ($null -ne $proc) {
                    $proc.Dispose()
                }
            }
        }

        if ($RetryOnUbtConflict -and (Test-IsConflictingUbtInstanceFailure -ExitCode $ExitCode -LogText $logText)) {
            $RetryCount++
            if ($RetryCount -lt $RetryLimit) {
                Write-Warning "Retryable UBT single-instance failure detected. Retrying in $RetryDelaySeconds seconds ($RetryCount/$RetryLimit)..."
                Start-Sleep -Seconds $RetryDelaySeconds
                continue
            }
        }

        if ($ExitCode -ne 0) {
            $commandLine = Format-CommandLineForDisplay -FilePath $FilePath -ArgumentList $ArgumentList
            throw "Command failed (ExitCode=$ExitCode): $commandLine"
        }
        break
    }
}
