Param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$ManifestDirectory = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
)

$ErrorActionPreference = 'Stop'

function Resolve-CiEngineRootOverride {
    $override = [Environment]::GetEnvironmentVariable('XROIDVERSE_CI_ENGINE_ROOT')
    if ([string]::IsNullOrWhiteSpace($override)) {
        return $null
    }

    $override = $override.Trim()
    if (-not (Test-Path -LiteralPath $override)) {
        throw "CI engine root override from XROIDVERSE_CI_ENGINE_ROOT does not exist: $override"
    }

    return $override
}

try {
    $override = Resolve-CiEngineRootOverride
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        Write-Output $override
        return
    }

    $appName = "UE_$Version"
    $manifestPath = $ManifestDirectory

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
            Write-Warning "Failed to parse manifest: $($file.Name) - $($_.Exception.Message)"
        }
    }

    throw ("UE_{0} install path not found in manifest." -f $Version)
}
catch {
    throw ("Exception while scanning manifests: {0}" -f $_.Exception.Message)
}
