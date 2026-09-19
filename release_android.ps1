param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [int]$VersionCode = 0,

    [switch]$Push
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Pubspec = Join-Path $Root "android_app\pubspec.yaml"
$NotesFile = Join-Path $Root "release-notes.md"

function Fail([string]$Message) {
    throw $Message
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    & git @Args
    if ($LASTEXITCODE -ne 0) {
        Fail "git $($Args -join ' ') failed."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git was not found in PATH."
}

if (-not (Test-Path -LiteralPath $Pubspec)) {
    Fail "Missing android_app\pubspec.yaml."
}

if (-not (Test-Path -LiteralPath $NotesFile)) {
    Fail "Missing release-notes.md. Write the stable release notes before tagging."
}

$Match = [regex]::Match(
    $Version.Trim(),
    '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
)

if (-not $Match.Success) {
    Fail "Version must use MAJOR.MINOR.PATCH, for example 0.1.0."
}

$Major = [int]$Match.Groups[1].Value
$Minor = [int]$Match.Groups[2].Value
$Patch = [int]$Match.Groups[3].Value

if ($Major -gt 100 -or $Minor -gt 99 -or $Patch -gt 99) {
    Fail "Version must be between 0.0.0 and 100.99.99."
}

$Version = "$Major.$Minor.$Patch"
$Tag = "v$Version"

$Branch = (& git branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) {
    Fail "Could not determine the current Git branch."
}
if ($Branch -ne "main") {
    Fail "Android stable releases must be created from main. Current branch: $Branch"
}

$Dirty = (& git status --porcelain) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Fail "Could not read Git status."
}
if (-not [string]::IsNullOrWhiteSpace($Dirty)) {
    Fail @"
The repository has uncommitted changes.

Commit/push your Android source and release-notes.md first, then run this script.
"@
}

& git rev-parse -q --verify "refs/tags/$Tag" *> $null
if ($LASTEXITCODE -eq 0) {
    Fail "Local tag $Tag already exists."
}

& git ls-remote --exit-code --tags origin "refs/tags/$Tag" *> $null
if ($LASTEXITCODE -eq 0) {
    Fail "Remote tag $Tag already exists."
}

$Notes = [System.IO.File]::ReadAllText(
    $NotesFile,
    [System.Text.UTF8Encoding]::new($false)
)
if ([string]::IsNullOrWhiteSpace($Notes)) {
    Fail "release-notes.md is empty."
}

$PubspecText = [System.IO.File]::ReadAllText(
    $Pubspec,
    [System.Text.UTF8Encoding]::new($false)
)

$VersionPattern = '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'
$PubspecMatch = [regex]::Match($PubspecText, $VersionPattern)
if (-not $PubspecMatch.Success) {
    Fail "Could not read the version line in android_app\pubspec.yaml."
}

$CurrentCode = [int]$PubspecMatch.Groups[4].Value

if ($VersionCode -le 0) {
    $VersionCode = $CurrentCode + 1
}

if ($VersionCode -le $CurrentCode) {
    Fail "versionCode must increase. Current: $CurrentCode; requested: $VersionCode"
}

$UpdatedPubspec = [regex]::Replace(
    $PubspecText,
    $VersionPattern,
    "version: $Version+$VersionCode",
    1
)

[System.IO.File]::WriteAllText(
    $Pubspec,
    $UpdatedPubspec,
    [System.Text.UTF8Encoding]::new($false)
)

# Keep the release notes title aligned with the tag when it uses the normal
# SpicyChat QOL Android heading.
$UpdatedNotes = [regex]::Replace(
    $Notes,
    '(?m)^#\s+SpicyChat QOL Android(?:\s+v?\d+\.\d+\.\d+)?\s*$',
    "# SpicyChat QOL Android $Tag",
    1
)
[System.IO.File]::WriteAllText(
    $NotesFile,
    $UpdatedNotes,
    [System.Text.UTF8Encoding]::new($false)
)

Invoke-Git -Args @("add", "android_app/pubspec.yaml", "release-notes.md")
Invoke-Git -Args @("commit", "-m", "Release $Tag")
Invoke-Git -Args @("tag", "-a", $Tag, "-m", "SpicyChat QOL Android $Tag")

Write-Host ""
Write-Host "Stable Android release prepared." -ForegroundColor Green
Write-Host "Version: $Version"
Write-Host "versionCode: $VersionCode"
Write-Host "Tag: $Tag"
Write-Host ""

if ($Push) {
    Write-Host "Pushing main..." -ForegroundColor Cyan
    Invoke-Git -Args @("push", "origin", "main")

    Write-Host "Pushing $Tag..." -ForegroundColor Cyan
    Invoke-Git -Args @("push", "origin", $Tag)

    Write-Host ""
    Write-Host "Done. GitHub Actions will build and publish the APK release automatically." -ForegroundColor Green
}
else {
    Write-Host "Nothing has been pushed yet." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Review the commit/tag, then run:" -ForegroundColor Cyan
    Write-Host "  git push origin main"
    Write-Host "  git push origin $Tag"
    Write-Host ""
    Write-Host "Or rerun this script on a clean pre-release state with -Push next time."
}
