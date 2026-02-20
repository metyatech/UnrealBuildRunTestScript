Param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

function Write-Warn {
    param([string]$Message)
    Write-Warning "[WARN] $Message"
}

try {
    $appName = "UE_$Version"
    $manifestPath = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest directory not found: $manifestPath"
    }

    $itemFiles = Get-ChildItem -Path $manifestPath -Filter *.item -File -ErrorAction Stop
    foreach ($file in $itemFiles) {
        try {
            $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($null -ne $json -and $json.AppName -eq $appName -and $null -ne $json.InstallLocation -and $json.InstallLocation -ne '') {
                Write-Output $json.InstallLocation
                return
            }
        }
        catch {
            Write-Warn "Failed to parse manifest: $($file.Name) - $($_.Exception.Message)"
        }
    }

    throw ("UE_{0} install path not found in manifest." -f $Version)
}
catch {
    throw ("Exception while scanning manifests: {0}" -f $_.Exception.Message)
}
