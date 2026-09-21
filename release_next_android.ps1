$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PubspecPath = Join-Path $Root "android_app\pubspec.yaml"

function Fail([string]$Message) {
    throw $Message
}

function Get-PubspecVersion([string]$Text) {
    $m = [regex]::Match(
        $Text,
        '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'
    )

    if (-not $m.Success) {
        Fail "Could not parse version from android_app\pubspec.yaml."
    }

    return [PSCustomObject]@{
        Major = [int]$m.Groups[1].Value
        Minor = [int]$m.Groups[2].Value
        Patch = [int]$m.Groups[3].Value
        Code  = [int]$m.Groups[4].Value
        Name  = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git was not found in PATH."
}

if (-not (Test-Path -LiteralPath (Join-Path $Root ".git"))) {
    Fail "Run this from the spicychat-qol-android repository."
}

if (-not (Test-Path -LiteralPath $PubspecPath)) {
    Fail "Missing android_app\pubspec.yaml."
}

$Branch = (& git -C $Root branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) {
    Fail "Could not determine the current Git branch."
}

if ($Branch -ne "main") {
    Fail "Version preparation is intended for main. Current branch: $Branch"
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " SpicyChat QOL Android - PREPARE NEXT VERSION" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This helper ONLY updates android_app\pubspec.yaml." -ForegroundColor Gray
Write-Host "It does NOT stage, commit, tag, push, or build anything." -ForegroundColor Gray
Write-Host ""

Write-Host "Fetching release tags..." -ForegroundColor Cyan
& git -C $Root fetch origin --tags --prune
if ($LASTEXITCODE -ne 0) {
    Fail "Could not fetch release tags from origin."
}

$PubspecText = [System.IO.File]::ReadAllText(
    $PubspecPath,
    [System.Text.UTF8Encoding]::new($false)
)
$Current = Get-PubspecVersion $PubspecText
$CurrentVersionObject = [version]$Current.Name

$ParsedTags = @()

foreach ($RawTag in @(& git -C $Root tag --list "v*.*.*")) {
    $Tag = $RawTag.Trim()
    $m = [regex]::Match($Tag, '^v(\d+)\.(\d+)\.(\d+)$')
    if (-not $m.Success) {
        continue
    }

    $Name = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
    $ParsedTags += [PSCustomObject]@{
        Tag     = $Tag
        Name    = $Name
        Version = [version]$Name
    }
}

if ($ParsedTags.Count -eq 0) {
    $BaseTag = $null
    $BaseName = $Current.Name
    $BaseVersion = [version]$Current.Name
    $BaseCode = $Current.Code

    Write-Host "Latest tag:      none"
    Write-Host "Baseline:        pubspec $($Current.Name)+$($Current.Code)"
}
else {
    $Latest = $ParsedTags | Sort-Object Version -Descending | Select-Object -First 1
    $BaseTag = $Latest.Tag
    $BaseName = $Latest.Name
    $BaseVersion = $Latest.Version

    $TaggedPubspecLines = @(
        & git -C $Root show "$($Latest.Tag):android_app/pubspec.yaml" 2>$null
    )

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not read android_app/pubspec.yaml from $($Latest.Tag)."
    }

    $TaggedPubspec = $TaggedPubspecLines -join "`n"
    $Tagged = Get-PubspecVersion $TaggedPubspec
    $BaseCode = $Tagged.Code

    Write-Host "Latest tag:      $BaseTag"
    Write-Host "Baseline:        $BaseName+$BaseCode"
}

$TargetName = "$($BaseVersion.Major).$($BaseVersion.Minor).$($BaseVersion.Build + 1)"
$TargetVersion = [version]$TargetName
$TargetTag = "v$TargetName"

if ($CurrentVersionObject -lt $BaseVersion) {
    Fail "Current pubspec version $($Current.Name) is older than release baseline $BaseName."
}

$NeedsWrite = $false
$PreparedName = $Current.Name
$PreparedCode = $Current.Code

if ($CurrentVersionObject -eq $BaseVersion) {
    $PreparedName = $TargetName
    $PreparedCode = [Math]::Max($Current.Code, $BaseCode) + 1
    $NeedsWrite = $true
}
elseif ($CurrentVersionObject -eq $TargetVersion) {
    # Important for interrupted/previous helper runs:
    # if the next version is already in pubspec, do not bump it again.
    $PreparedName = $Current.Name
    if ($Current.Code -le $BaseCode) {
        $PreparedCode = $BaseCode + 1
        $NeedsWrite = $true
    }
}
else {
    # A manually prepared version newer than the automatic next patch is valid.
    # Leave it alone rather than overwriting the user's explicit version.
    $PreparedName = $Current.Name
    $PreparedCode = $Current.Code
}

$PreparedTag = "v$PreparedName"

# Refuse to prepare a version whose tag already exists.
& git -C $Root rev-parse -q --verify "refs/tags/$PreparedTag" *> $null
if ($LASTEXITCODE -eq 0) {
    Fail "Tag $PreparedTag already exists. pubspec must be bumped to a newer version before release."
}

if ($NeedsWrite) {
    $Updated = [regex]::Replace(
        $PubspecText,
        '(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$',
        "version: $PreparedName+$PreparedCode",
        1
    )

    [System.IO.File]::WriteAllText(
        $PubspecPath,
        $Updated,
        [System.Text.UTF8Encoding]::new($false)
    )
}

Write-Host ""
if ($NeedsWrite) {
    Write-Host "VERSION PREPARED" -ForegroundColor Green
}
else {
    Write-Host "VERSION ALREADY PREPARED" -ForegroundColor Green
}
Write-Host "Current pubspec: $($Current.Name)+$($Current.Code)"
Write-Host "Prepared:        $PreparedName+$PreparedCode" -ForegroundColor Green
Write-Host "Future tag:      $PreparedTag" -ForegroundColor Green
Write-Host ""
Write-Host "Nothing was staged." -ForegroundColor Yellow
Write-Host "Nothing was committed." -ForegroundColor Yellow
Write-Host "Nothing was tagged." -ForegroundColor Yellow
Write-Host "Nothing was pushed." -ForegroundColor Yellow
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Review all changes in GitHub Desktop."
Write-Host "  2. Commit them normally."
Write-Host "  3. Push main."
Write-Host "  4. GitHub Actions will create $PreparedTag on that exact commit,"
Write-Host "     build the signed APK, and publish the GitHub Release."
Write-Host ""
