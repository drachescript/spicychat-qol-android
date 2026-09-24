$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PubspecPath = Join-Path $Root "android_app\pubspec.yaml"
$Repository = "drachescript/spicychat-qol-android"

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

function Get-PublishedReleaseCode {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [int]$FallbackCode = 0
    )

    $Headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "SpicyChat-QOL-Android-Release-Helper"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $Headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
    }

    try {
        $Release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag" `
            -Headers $Headers `
            -Method Get `
            -TimeoutSec 20

        $Asset = @($Release.assets | Where-Object {
            $_.name -eq "update.json"
        }) | Select-Object -First 1

        if ($null -eq $Asset) {
            Write-Host "Published metadata: no update.json; using tag/pubspec fallback." -ForegroundColor Yellow
            return $FallbackCode
        }

        $Metadata = Invoke-RestMethod `
            -Uri $Asset.browser_download_url `
            -Headers @{
                "User-Agent" = "SpicyChat-QOL-Android-Release-Helper"
                "Cache-Control" = "no-cache"
            } `
            -Method Get `
            -TimeoutSec 20

        $Code = 0
        if (
            $null -ne $Metadata.versionCode -and
            [int]::TryParse([string]$Metadata.versionCode, [ref]$Code) -and
            $Code -gt 0
        ) {
            return $Code
        }

        Write-Host "Published metadata had no usable versionCode; using fallback." -ForegroundColor Yellow
        return $FallbackCode
    }
    catch {
        Write-Host "Could not read published versionCode for $Tag; using fallback." -ForegroundColor Yellow
        Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
        return $FallbackCode
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
    $PublishedCode = 0

    Write-Host "Latest tag:       none"
    Write-Host "Baseline:         pubspec $($Current.Name)+$($Current.Code)"
}
else {
    $Latest = $ParsedTags |
        Sort-Object Version -Descending |
        Select-Object -First 1

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
    $PublishedCode = Get-PublishedReleaseCode `
        -Tag $BaseTag `
        -FallbackCode $Tagged.Code

    # Same-visible-version hotfixes can make the published versionCode newer
    # than the immutable tag's pubspec. Always continue from the largest code
    # we know about.
    $BaseCode = [Math]::Max(
        [Math]::Max($Tagged.Code, $PublishedCode),
        $Current.Code
    )

    Write-Host "Latest tag:       $BaseTag"
    Write-Host "Tagged pubspec:   $BaseName+$($Tagged.Code)"
    Write-Host "Published code:   $PublishedCode"
    Write-Host "Version baseline: $BaseName+$BaseCode"
}

$TargetName =
    "$($BaseVersion.Major).$($BaseVersion.Minor).$($BaseVersion.Build + 1)"
$TargetVersion = [version]$TargetName

if ($CurrentVersionObject -lt $BaseVersion) {
    Fail "Current pubspec version $($Current.Name) is older than release baseline $BaseName."
}

$NeedsWrite = $false
$PreparedName = $Current.Name
$PreparedCode = $Current.Code

if ($CurrentVersionObject -eq $BaseVersion) {
    # Normal intentional visible-version bump.
    $PreparedName = $TargetName
    $PreparedCode = $BaseCode + 1
    $NeedsWrite = $true
}
elseif ($CurrentVersionObject -eq $TargetVersion) {
    # Idempotent after an interrupted/previous helper run.
    $PreparedName = $Current.Name
    if ($Current.Code -le $BaseCode) {
        $PreparedCode = $BaseCode + 1
        $NeedsWrite = $true
    }
}
else {
    # A manually prepared version newer than the automatic next patch is valid.
    # Keep its name, but never let its versionCode go backwards behind a
    # same-version hotfix that was already published.
    $PreparedName = $Current.Name
    $PreparedCode = $Current.Code

    if ($PreparedCode -le $BaseCode) {
        $PreparedCode = $BaseCode + 1
        $NeedsWrite = $true
    }
}

$PreparedTag = "v$PreparedName"

$MatchingPreparedTags = @(& git -C $Root tag --list $PreparedTag)
if ($LASTEXITCODE -ne 0) {
    Fail "Could not inspect whether $PreparedTag already exists."
}

if ($MatchingPreparedTags.Count -gt 0) {
    Fail @"
Tag $PreparedTag already exists.

If you are making a same-visible-version Android hotfix, do NOT run
release_next_android.bat. Keep the existing visible version and make the commit
summary start with:

  $PreparedTag ...

Example:
  $PreparedTag options fix

The GitHub workflow will increment only the internal Android versionCode,
rotate the old APK to _old, and replace the current APK automatically.
"@
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

Write-Host "Current pubspec:  $($Current.Name)+$($Current.Code)"
Write-Host "Prepared:         $PreparedName+$PreparedCode" -ForegroundColor Green
Write-Host "Future tag:       $PreparedTag" -ForegroundColor Green
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
