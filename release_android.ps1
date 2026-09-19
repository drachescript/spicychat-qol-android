param(
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildScript = Join-Path $Root "build_android.ps1"
$OutputDir = Join-Path $Root "output"
$VersionFile = Join-Path $OutputDir "current-version.txt"
$UpdateJson = Join-Path $OutputDir "update.json"
$ShaFile = Join-Path $OutputDir "SHA256SUMS.txt"
$NotesFile = Join-Path $Root "release-notes.md"

function Stop-WithMessage([string]$Message) {
    throw $Message
}

function Get-VersionValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    $Prefix = "$Name="
    $Line = $Lines |
        Where-Object { $_.StartsWith($Prefix) } |
        Select-Object -First 1

    if (-not $Line) {
        Stop-WithMessage "Could not find '$Name' in output\current-version.txt."
    }

    return $Line.Substring($Prefix.Length).Trim()
}

if (-not (Test-Path -LiteralPath $BuildScript)) {
    Stop-WithMessage "Missing build_android.ps1."
}

if (-not $SkipBuild) {
    & $BuildScript
}

if (-not (Test-Path -LiteralPath $VersionFile)) {
    Stop-WithMessage "Missing output\current-version.txt. Run a successful build first."
}

$VersionLines = Get-Content -LiteralPath $VersionFile
$Version = Get-VersionValue -Name "version" -Lines $VersionLines
$Tag = Get-VersionValue -Name "tag" -Lines $VersionLines
$ApkFileName = Get-VersionValue -Name "apk" -Lines $VersionLines
$Apk = Join-Path $OutputDir $ApkFileName

foreach ($RequiredFile in @($Apk, $UpdateJson, $ShaFile, $NotesFile)) {
    if (-not (Test-Path -LiteralPath $RequiredFile)) {
        Stop-WithMessage "Required release file is missing: $RequiredFile"
    }
}

$ReleaseFolder = Join-Path $OutputDir "release-upload\$Tag"
if (Test-Path -LiteralPath $ReleaseFolder) {
    Remove-Item -LiteralPath $ReleaseFolder -Recurse -Force
}
New-Item -ItemType Directory -Path $ReleaseFolder -Force | Out-Null

Copy-Item -LiteralPath $Apk -Destination $ReleaseFolder -Force
Copy-Item -LiteralPath $UpdateJson -Destination $ReleaseFolder -Force
Copy-Item -LiteralPath $ShaFile -Destination $ReleaseFolder -Force
Copy-Item -LiteralPath $NotesFile -Destination $ReleaseFolder -Force

$Instructions = @"
SpicyChat QOL Android release prepared

Tag: $Tag
Release title: SpicyChat QOL Android $Tag
APK: $ApkFileName

GitHub Desktop / browser workflow:
1. Open GitHub Desktop.
2. Review the source changes, commit them, and click Push origin.
3. Open the repository on GitHub in your browser.
4. Open Releases and choose Draft a new release.
5. Create/select tag: $Tag
6. Use title: SpicyChat QOL Android $Tag
7. Paste the contents of release-notes.md into the description.
8. Upload every file from this folder.
9. Publish the release.

The APK and release-output folder are intentionally excluded from normal Git commits.
"@

Set-Content `
    -LiteralPath (Join-Path $ReleaseFolder "UPLOAD_INSTRUCTIONS.txt") `
    -Value $Instructions `
    -Encoding utf8

Write-Host ""
Write-Host "Release files are ready:" -ForegroundColor Green
Write-Host $ReleaseFolder
Write-Host ""
Write-Host "Next: commit/push the source with GitHub Desktop, then create the GitHub Release in your browser." -ForegroundColor Cyan

Start-Process explorer.exe $ReleaseFolder
