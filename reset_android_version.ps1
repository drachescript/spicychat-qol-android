$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Join-Path $Root "android_app"
$Pubspec = Join-Path $Project "pubspec.yaml"
$OutputDir = Join-Path $Root "output"
$ArchiveRoot = Join-Path $Root "archive"

function Fail([string]$Message) {
    throw $Message
}

if (-not (Test-Path -LiteralPath $Pubspec)) {
    Fail "Could not find android_app\pubspec.yaml."
}

$PubspecText = Get-Content -LiteralPath $Pubspec -Raw
$Pattern = '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'
$Match = [regex]::Match($PubspecText, $Pattern)

if (-not $Match.Success) {
    Fail "Could not read the current Flutter version from pubspec.yaml."
}

# Keep Android's numeric versionCode monotonic so the reset build can still
# update over your previous test APKs.
$HighestCode = [int]$Match.Groups[4].Value

$CurrentVersionFile = Join-Path $OutputDir "current-version.txt"
if (Test-Path -LiteralPath $CurrentVersionFile) {
    $Line = Get-Content -LiteralPath $CurrentVersionFile |
        Where-Object { $_ -match '^versionCode=(\d+)$' } |
        Select-Object -First 1

    if ($Line -match '^versionCode=(\d+)$') {
        $HighestCode = [Math]::Max($HighestCode, [int]$Matches[1])
    }
}

$UpdateJson = Join-Path $OutputDir "update.json"
if (Test-Path -LiteralPath $UpdateJson) {
    try {
        $Metadata = Get-Content -LiteralPath $UpdateJson -Raw | ConvertFrom-Json
        if ($Metadata.versionCode) {
            $HighestCode = [Math]::Max($HighestCode, [int]$Metadata.versionCode)
        }
    }
    catch {
        Write-Host "Could not read old update.json; continuing with versionCode $HighestCode." -ForegroundColor Yellow
    }
}

# Archive old generated APK/version files so output starts clean at v0.0.1.
if (Test-Path -LiteralPath $OutputDir) {
    $Items = @(
        Get-ChildItem -LiteralPath $OutputDir -Force -ErrorAction SilentlyContinue
    )

    if ($Items.Count -gt 0) {
        $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ArchiveDir = Join-Path $ArchiveRoot "android-before-v0.0.1-$Stamp"
        New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null

        foreach ($Item in $Items) {
            Move-Item -LiteralPath $Item.FullName -Destination $ArchiveDir -Force
        }

        Write-Host "Previous generated APKs were moved to:" -ForegroundColor DarkGray
        Write-Host $ArchiveDir
    }
}

# Baseline is 0.0.0. The normal build script increments BEFORE building,
# therefore the next APK becomes v0.0.1.
$ResetPubspec = [regex]::Replace(
    $PubspecText,
    $Pattern,
    "version: 0.0.0+$HighestCode",
    1
)

[System.IO.File]::WriteAllText(
    $Pubspec,
    $ResetPubspec,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "Android public/test version sequence reset successfully." -ForegroundColor Green
Write-Host "Visible baseline: 0.0.0"
Write-Host "Preserved Android versionCode: $HighestCode"
Write-Host ""
Write-Host "The NEXT successful build_android.bat run will create:" -ForegroundColor Cyan
Write-Host "SpicyChat-QOL-Android-v0.0.1.apk"
Write-Host "with Android versionCode $($HighestCode + 1)."
