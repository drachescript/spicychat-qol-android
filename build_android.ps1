$ErrorActionPreference = "Stop"



$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$Project = Join-Path $Root "android_app"

$OutputDir = Join-Path $Root "output"

$FlutterApk = Join-Path $Project "build\app\outputs\flutter-apk\app-release.apk"

$Keystore = Join-Path $Project "android\upload-keystore.jks"

$KeyProperties = Join-Path $Project "android\key.properties"

$Gradlew = Join-Path $Project "android\gradlew.bat"

$Pubspec = Join-Path $Project "pubspec.yaml"

$UpdateScript = Join-Path $Root "update_android.ps1"

$BundleService = Join-Path $Project "lib\services\js_bundle_service.dart"
$AndroidManifest = Join-Path $Project "android\app\src\main\AndroidManifest.xml"
$MainActivity = Join-Path $Project "android\app\src\main\kotlin\uk\drache\spicychatqol\MainActivity.kt"
$LegacyMainActivity = Join-Path $Project "android\app\src\main\kotlin\com\dragonscript\dragonscript_app\MainActivity.kt"

$ExtensionSourceRoot = "D:\Documents\extentions\spicychat-qol"



$GitHubRepository = "drachescript/spicychat-qol-android"

$AndroidPackageName = "uk.drache.spicychatqol"

$MinimumAndroidSdk = 24



function Fail([string]$Message) {

    throw $Message

}

function Write-AsciiFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.Encoding]::ASCII
    )
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}



function Stop-Gradle {

    if (Test-Path -LiteralPath $Gradlew) {

        Write-Host "Stopping stale Gradle processes..." -ForegroundColor DarkGray

        & $Gradlew --stop | Out-Host

        Start-Sleep -Seconds 2

    }

}



function Remove-DirectoryWithRetry {

    param(

        [string]$Path,

        [int]$Attempts = 4

    )



    if (-not (Test-Path -LiteralPath $Path)) {

        return $true

    }



    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {

        try {

            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop

            return $true

        }

        catch {

            if ($Attempt -eq $Attempts) {

                return $false

            }



            Write-Host "Build files are locked. Retrying cleanup ($Attempt/$Attempts)..." -ForegroundColor Yellow

            Stop-Gradle

            Start-Sleep -Seconds 2

        }

    }



    return $false

}



function Assert-AndroidPackageSource {
    foreach ($RequiredSource in @($AndroidManifest, $MainActivity)) {
        if (-not (Test-Path -LiteralPath $RequiredSource)) {
            Fail "Required package-migration file is missing: $RequiredSource"
        }
    }

    $ManifestText = [System.IO.File]::ReadAllText(
        $AndroidManifest,
        [System.Text.UTF8Encoding]::new($false)
    )
    $ActivityText = [System.IO.File]::ReadAllText(
        $MainActivity,
        [System.Text.UTF8Encoding]::new($false)
    )

    if (-not $ManifestText.Contains('android:name="uk.drache.spicychatqol.MainActivity"')) {
        Fail "AndroidManifest.xml does not point to uk.drache.spicychatqol.MainActivity."
    }

    if (-not $ActivityText.Contains("package uk.drache.spicychatqol")) {
        Fail "MainActivity.kt does not use package uk.drache.spicychatqol."
    }

    if (Test-Path -LiteralPath $LegacyMainActivity) {
        $LegacyText = [System.IO.File]::ReadAllText(
            $LegacyMainActivity,
            [System.Text.UTF8Encoding]::new($false)
        )
        if ($LegacyText -match '(?m)^\s*class\s+MainActivity\b') {
            Fail "Legacy MainActivity still declares a class. Replace the changed-files patch completely before building."
        }
    }
}

function Assert-ApkPackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$ApkPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $Zip = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $ManifestEntry = $Zip.GetEntry("AndroidManifest.xml")
        if ($null -eq $ManifestEntry) {
            Fail "Built APK has no AndroidManifest.xml."
        }

        $ManifestStream = $ManifestEntry.Open()
        try {
            $Memory = New-Object System.IO.MemoryStream
            $ManifestStream.CopyTo($Memory)
            $ManifestBytes = $Memory.ToArray()
        }
        finally {
            $ManifestStream.Dispose()
        }

        # Binary Android manifests store their string pool as UTF-16LE.
        $ManifestUnicode = [System.Text.Encoding]::Unicode.GetString($ManifestBytes)
        if (-not $ManifestUnicode.Contains("uk.drache.spicychatqol")) {
            Fail "Built APK does not contain package uk.drache.spicychatqol. Refusing to publish it."
        }

        $FoundActivity = $false
        foreach ($Entry in $Zip.Entries) {
            if ($Entry.FullName -notmatch '^classes(\d*)\.dex$') {
                continue
            }

            $DexStream = $Entry.Open()
            try {
                $Memory = New-Object System.IO.MemoryStream
                $DexStream.CopyTo($Memory)
                $DexText = [System.Text.Encoding]::ASCII.GetString($Memory.ToArray())
            }
            finally {
                $DexStream.Dispose()
            }

            if ($DexText.Contains("Luk/drache/spicychatqol/MainActivity;")) {
                $FoundActivity = $true
                break
            }
        }

        if (-not $FoundActivity) {
            Fail "Built APK does not contain uk.drache.spicychatqol.MainActivity. This APK would crash at launch, so it was not copied to output."
        }
    }
    finally {
        $Zip.Dispose()
    }
}

function Get-NextVersion {

    param(

        [int]$Major,

        [int]$Minor,

        [int]$Patch

    )



    # 0.0.1 ... 0.0.9 -> 0.1 -> 0.1.1 ... 0.1.9 -> 0.2

    if ($Patch -lt 9) {

        $Patch++

    }

    else {

        $Minor++

        $Patch = 0

    }



    return @{

        Major = $Major

        Minor = $Minor

        Patch = $Patch

    }

}



function Get-DisplayVersion {

    param(

        [int]$Major,

        [int]$Minor,

        [int]$Patch

    )



    if ($Patch -eq 0) {

        return "$Major.$Minor"

    }



    return "$Major.$Minor.$Patch"

}



if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {

    Fail "Flutter was not found in PATH."

}



foreach ($Required in @($Project, $Keystore, $KeyProperties, $Pubspec, $UpdateScript)) {

    if (-not (Test-Path -LiteralPath $Required)) {

        Fail "Required Android build file/folder is missing: $Required"

    }

}



Write-Host ""

Write-Host "====================================================" -ForegroundColor Cyan

Write-Host " SpicyChat QOL Android - FULL SYNC + RELEASE BUILD" -ForegroundColor Cyan

Write-Host "====================================================" -ForegroundColor Cyan

Write-Host ""



# Always perform the complete extension -> Android sync before compiling.

& $UpdateScript -SourceRoot $ExtensionSourceRoot

if ((Get-Item -LiteralPath $BundleService).Length -gt 262144) {

    Fail "Android bundle service is unexpectedly large after sync. Refusing to build a likely corrupted APK."

}

$BundleServiceText = [System.IO.File]::ReadAllText(
    $BundleService,
    [System.Text.UTF8Encoding]::new($false)
)

if (-not $BundleServiceText.Contains("String get extensionVersion")) {
    Fail "Android sync removed JsBundleService.extensionVersion."
}
if (-not $BundleServiceText.Contains("__spicyChatQolBundledVersion")) {
    Fail "Android sync removed the JavaScript extension-version bridge."
}

Assert-AndroidPackageSource

Write-Host ""



$OriginalPubspec = [System.IO.File]::ReadAllText($Pubspec, [System.Text.UTF8Encoding]::new($false))

$VersionPattern = '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'

$VersionMatch = [regex]::Match($OriginalPubspec, $VersionPattern)



if (-not $VersionMatch.Success) {

    Fail "Could not read the Flutter version line in android_app\pubspec.yaml."

}



$CurrentMajor = [int]$VersionMatch.Groups[1].Value

$CurrentMinor = [int]$VersionMatch.Groups[2].Value

$CurrentPatch = [int]$VersionMatch.Groups[3].Value

$CurrentCode = [int]$VersionMatch.Groups[4].Value



$Next = Get-NextVersion -Major $CurrentMajor -Minor $CurrentMinor -Patch $CurrentPatch



$NextMajor = [int]$Next.Major

$NextMinor = [int]$Next.Minor

$NextPatch = [int]$Next.Patch

$NextCode = $CurrentCode + 1



$FlutterVersion = "$NextMajor.$NextMinor.$NextPatch"

$DisplayVersion = Get-DisplayVersion -Major $NextMajor -Minor $NextMinor -Patch $NextPatch



$Tag = "v$DisplayVersion"

$ApkFileName = "SpicyChat-QOL-Android-$Tag.apk"



$UpdatedPubspec = [regex]::Replace(

    $OriginalPubspec,

    $VersionPattern,

    "version: $FlutterVersion+$NextCode",

    1

)



[System.IO.File]::WriteAllText(

    $Pubspec,

    $UpdatedPubspec,

    [System.Text.UTF8Encoding]::new($false)

)



$BuildSucceeded = $false



try {

    Write-Host "Building SpicyChat QOL Android $Tag (Android versionCode $NextCode)..." -ForegroundColor Cyan



    Push-Location $Project

    try {

        Stop-Gradle

        # The app package changed from com.dragonscript.dragonscript_app to
        # uk.drache.spicychatqol. Clear native incremental caches so no stale
        # MainActivity class from the old package can survive the migration.
        foreach ($NativeCache in @(
            (Join-Path $Project "android\app\build"),
            (Join-Path $Project "android\.kotlin")
        )) {
            if (Test-Path -LiteralPath $NativeCache) {
                if (-not (Remove-DirectoryWithRetry -Path $NativeCache)) {
                    Fail "Could not clear stale Android build cache: $NativeCache"
                }
            }
        }

        Write-Host "Cleaning previous Flutter build..." -ForegroundColor DarkGray

        flutter clean

        if ($LASTEXITCODE -ne 0) {

            Fail "flutter clean failed."

        }



        flutter pub get

        if ($LASTEXITCODE -ne 0) {

            Fail "flutter pub get failed."

        }



        flutter build apk --release --no-pub

        if ($LASTEXITCODE -ne 0) {

            Write-Host ""

            Write-Host "First build failed. Retrying after locked-file cleanup..." -ForegroundColor Yellow



            Stop-Gradle

            $BuildFolder = Join-Path $Project "build"



            if (-not (Remove-DirectoryWithRetry -Path $BuildFolder)) {

                Fail "The Android build folder is still locked."

            }



            flutter build apk --release --no-pub

            if ($LASTEXITCODE -ne 0) {

                Fail "flutter build apk --release --no-pub failed again."

            }

        }

    }

    finally {

        Pop-Location

    }



    if (-not (Test-Path -LiteralPath $FlutterApk)) {

        Fail "Flutter reported success but app-release.apk was not found."

    }

    Assert-ApkPackageIdentity -ApkPath $FlutterApk

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null



    $VersionedApk = Join-Path $OutputDir $ApkFileName

    $LatestApk = Join-Path $OutputDir "SpicyChat-QOL.apk"

    $ShaFile = Join-Path $OutputDir "SHA256SUMS.txt"

    $UpdateJson = Join-Path $OutputDir "update.json"

    $CurrentVersionFile = Join-Path $OutputDir "current-version.txt"



    Copy-Item -LiteralPath $FlutterApk -Destination $VersionedApk -Force

    Copy-Item -LiteralPath $FlutterApk -Destination $LatestApk -Force



    $Hash = (Get-FileHash -LiteralPath $VersionedApk -Algorithm SHA256).Hash.ToLowerInvariant()



    # Avoid interactive Set-Content parameter binding in Windows PowerShell 5.1.
    # These files are build metadata, so write them deterministically through .NET.
    Write-AsciiFile -Path "$VersionedApk.sha256" -Content "$Hash  $ApkFileName`r`n"
    Write-AsciiFile -Path "$LatestApk.sha256" -Content "$Hash  SpicyChat-QOL.apk`r`n"
    Write-AsciiFile -Path $ShaFile -Content "$Hash  $ApkFileName`r`n"



    $DownloadUrl = "https://github.com/$GitHubRepository/releases/download/$Tag/$ApkFileName"

    $ReleaseUrl = "https://github.com/$GitHubRepository/releases/tag/$Tag"



    $Metadata = [ordered]@{

        app = "SpicyChat QOL"

        packageName = $AndroidPackageName

        versionName = $DisplayVersion

        versionCode = $NextCode

        tag = $Tag

        apkFile = $ApkFileName

        apkUrl = $DownloadUrl

        releaseUrl = $ReleaseUrl

        sha256 = $Hash

        minimumAndroidSdk = $MinimumAndroidSdk

        publishedAt = [DateTime]::UtcNow.ToString("o")

    }



    $MetadataJson = $Metadata | ConvertTo-Json -Depth 5
    Write-Utf8File -Path $UpdateJson -Content ($MetadataJson + "`r`n")

    $CurrentVersionText = @(
        "version=$DisplayVersion"
        "tag=$Tag"
        "versionCode=$NextCode"
        "apk=$ApkFileName"
    ) -join "`r`n"
    Write-AsciiFile -Path $CurrentVersionFile -Content ($CurrentVersionText + "`r`n")



    $BuildSucceeded = $true



    Write-Host ""

    Write-Host "Build complete." -ForegroundColor Green

    Write-Host "Version: $Tag"

    Write-Host "Android versionCode: $NextCode"

    Write-Host "APK: $VersionedApk"

    Write-Host "Latest copy: $LatestApk"

    Write-Host "SHA-256: $Hash"

}

finally {

    if (-not $BuildSucceeded) {

        [System.IO.File]::WriteAllText(

            $Pubspec,

            $OriginalPubspec,

            [System.Text.UTF8Encoding]::new($false)

        )



        Write-Host "Previous version restored because the build did not complete." -ForegroundColor Yellow

    }

}

