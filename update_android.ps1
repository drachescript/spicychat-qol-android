param(
    [string]$SourceRoot = "D:\Documents\extentions\spicychat-qol"
)

$ErrorActionPreference = "Stop"

$TargetRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetExtension = Join-Path $TargetRoot "extension"
$AndroidApp = Join-Path $TargetRoot "android_app"
$AndroidJs = Join-Path $AndroidApp "assets\js"
$AndroidCss = Join-Path $AndroidApp "assets\css"
$AndroidOptions = Join-Path $AndroidApp "assets\options"
$BundleService = Join-Path $AndroidApp "lib\services\js_bundle_service.dart"

function Fail([string]$Message) {
    throw $Message
}

function Read-Utf8Text([string]$Path) {
    return [System.IO.File]::ReadAllText(
        $Path,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Resolve-ExtensionRoot([string]$RequestedRoot) {
    if (Test-Path -LiteralPath (Join-Path $RequestedRoot "manifest.json")) {
        return (Resolve-Path -LiteralPath $RequestedRoot).Path
    }

    if (-not (Test-Path -LiteralPath $RequestedRoot)) {
        Fail "Extension source folder was not found: $RequestedRoot"
    }

    $Candidates = @(
        Get-ChildItem -LiteralPath $RequestedRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "manifest.json") }
    )

    if ($Candidates.Count -eq 1) {
        return $Candidates[0].FullName
    }

    Fail "Could not find one clear extension root containing manifest.json inside: $RequestedRoot"
}

function Ordered-Unique([object[]]$Items) {
    $Seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $Result = [System.Collections.Generic.List[string]]::new()

    foreach ($Item in $Items) {
        $Text = [string]$Item
        if ($Text -and $Seen.Add($Text)) {
            $Result.Add($Text)
        }
    }

    return @($Result)
}

function Copy-IfChanged {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Fail "Required source file was not found: $Source"
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null

    $Copy = $true
    if (Test-Path -LiteralPath $Destination) {
        $Copy = (
            (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        )
    }

    if ($Copy) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        Write-Host "Updated: $Destination" -ForegroundColor Green
        $script:ChangedCount++
    }
}

function Write-IfChanged {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Content
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null

    $Old = $null
    if (Test-Path -LiteralPath $Destination) {
        $Old = Read-Utf8Text $Destination
    }

    if ($Old -cne $Content) {
        [System.IO.File]::WriteAllText(
            $Destination,
            $Content,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "Updated: $Destination" -ForegroundColor Green
        $script:ChangedCount++
    }
}

function Get-AndroidChatExport([string]$SourceFile) {
    $Content = Read-Utf8Text $SourceFile

    if ($Content.Contains("window._dsRequestExport")) {
        return $Content
    }

    $Pattern = '(?ms)^(?<indent>[ \t]*)a\.href\s*=\s*url;\s*\r?\n\k<indent>a\.download\s*=\s*(?<filename>[^;]+);\s*\r?\n\k<indent>a\.click\(\);'
    $Regex = [regex]::new($Pattern)
    $Matches = $Regex.Matches($Content)

    if ($Matches.Count -ne 1) {
        Fail "Could not safely add Android export support to content\chat-export.js. Its download block changed."
    }

    $Match = $Matches[0]
    $Indent = $Match.Groups["indent"].Value
    $FilenameExpression = $Match.Groups["filename"].Value.Trim()

    $Replacement = @(
        $Indent + "const dsExportFilename = $FilenameExpression;"
        ""
        $Indent + "// Android app: use the native file export bridge when available."
        $Indent + 'if (typeof window._dsRequestExport === "function") {'
        $Indent + "  URL.revokeObjectURL(url);"
        $Indent + "  window._dsRequestExport(textarea.value, dsExportFilename);"
        $Indent + "  return;"
        $Indent + "}"
        ""
        $Indent + "a.href = url;"
        $Indent + "a.download = dsExportFilename;"
        $Indent + "a.click();"
    ) -join "`r`n"

    return $Regex.Replace($Content, $Replacement, 1)
}

function Get-AndroidOptionsHtml([string]$SourceFile) {
    $Html = Read-Utf8Text $SourceFile
    $NewLine = if ($Html.Contains("`r`n")) { "`r`n" } else { "`n" }

    if (-not $Html.Contains('name="viewport"')) {
        $CharsetRegex = [regex]::new(
            '(<meta\s+charset=["''][^"'']+["'']\s*/?>)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $CharsetRegex.IsMatch($Html)) {
            Fail "Could not find the charset tag in options.html."
        }

        $Html = $CharsetRegex.Replace(
            $Html,
            '$1' + $NewLine + '  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
            1
        )
    }

    if (-not $Html.Contains('options-bridge.js')) {
        $ScriptRegex = [regex]::new(
            '<script\s+src=["'']options\.js["'']\s*></script>',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $ScriptRegex.IsMatch($Html)) {
            Fail "Could not find the options.js script tag in options.html."
        }

        $Html = $ScriptRegex.Replace(
            $Html,
            '<script src="options-bridge.js"></script>' + $NewLine + '  <script src="options.js"></script>',
            1
        )
    }

    return $Html
}

function Get-LocalOptionsScriptSources([string]$OptionsHtmlFile) {
    $Html = Read-Utf8Text $OptionsHtmlFile
    $Matches = [regex]::Matches(
        $Html,
        '<script\s+[^>]*src=["''][^"'']+["''][^>]*></script>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $Result = [System.Collections.Generic.List[string]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Match in $Matches) {
        $SourceMatch = [regex]::Match(
            $Match.Value,
            'src=["''](?<src>[^"'']+)["'']',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $SourceMatch.Success) { continue }

        $Source = $SourceMatch.Groups['src'].Value.Trim()
        if (-not $Source) { continue }

        # Only mirror local extension JavaScript. Remote/data/blob URLs are not
        # part of the Android options asset bundle.
        if ($Source -match '^(?i:https?:|data:|blob:|//)') { continue }

        $Clean = ($Source -split '[?#]', 2)[0]
        if ($Clean -and $Clean -match '(?i)\.js$' -and $Seen.Add($Clean)) {
            $Result.Add($Clean)
        }
    }

    return @($Result)
}

function Get-AndroidOptionsCss {
    param(
        [string]$SourceFile,
        [string]$ExistingAndroidFile
    )

    $DesktopCss = (Read-Utf8Text $SourceFile).TrimEnd()
    $Marker = "/* Android WebView / phone layout */"
    $MobileBlock = $null

    if (Test-Path -LiteralPath $ExistingAndroidFile) {
        $Existing = Read-Utf8Text $ExistingAndroidFile
        $Index = $Existing.IndexOf($Marker)
        if ($Index -ge 0) {
            $MobileBlock = $Existing.Substring($Index).Trim()
        }
    }

    if (-not $MobileBlock) {
        $MobileBlock = @'
/* Android WebView / phone layout */
@media (max-width: 700px) {
  html { -webkit-text-size-adjust: 100%; }

  main {
    width: calc(100vw - 20px);
    padding: 16px 0 calc(90px + env(safe-area-inset-bottom));
  }

  h1 { font-size: 24px; }
  h2 { font-size: 17px; }

  .tabs {
    position: sticky;
    top: 0;
    z-index: 10;
    flex-wrap: nowrap;
    overflow-x: auto;
    overscroll-behavior-x: contain;
    scrollbar-width: none;
    background: rgba(15, 15, 16, 0.97);
    padding: 8px 0 10px;
  }

  .tabs::-webkit-scrollbar { display: none; }
  .tab-button { flex: 0 0 auto; white-space: nowrap; }

  .card {
    border-radius: 11px;
    padding: 13px;
    margin: 11px 0;
  }

  .row { align-items: flex-start; }
  .row input[type="checkbox"] { margin-top: 3px; flex: 0 0 auto; }

  input, select, textarea, button { font-size: 16px; }

  .manager-add-row,
  .bot-manager-list { grid-template-columns: 1fr; }

  footer {
    padding: 10px 0 max(10px, env(safe-area-inset-bottom));
    flex-wrap: wrap;
  }

  #save { min-height: 44px; }
}
'@
    }

    return $DesktopCss + "`r`n`r`n" + $MobileBlock.Trim() + "`r`n"
}

function Update-BundleList {
    param(
        [string]$DartFile,
        [string[]]$ManifestScripts,
        [string]$ManifestVersion
    )

    # Generate this file deterministically so PowerShell 5.1 cannot corrupt it
    # on repeated syncs. Keep all Android-only bridge fields in the template.
    $Entries = [System.Collections.Generic.List[string]]::new()
    $Entries.Add("    'assets/js/bridge.js',")

    foreach ($ScriptPath in $ManifestScripts) {
        $FileName = [System.IO.Path]::GetFileName(($ScriptPath -replace '/', '\'))
        $Entries.Add("    'assets/js/$FileName',")
    }

    $EntriesText = $Entries -join "`r`n"
    $Template = @'
import 'dart:convert';

import 'package:flutter/services.dart';

/// Loads all JS and CSS assets from the bundle and provides
/// them as injectable strings for the WebView.
class JsBundleService {
  String _cssContent = '';
  String _jsBundle = '';
  String _extensionVersion = '__EXTENSION_VERSION__';

  String get cssContent => _cssContent;
  String get jsBundle => _jsBundle;
  String get extensionVersion => _extensionVersion;

  // Script injection order is generated from manifest.json by update_android.ps1.
  static const _jsFiles = [
__JS_ENTRIES__
  ];

  Future<void> loadAssets() async {
    _cssContent = await rootBundle.loadString('assets/css/content.css');

    final buffer = StringBuffer();
    buffer.writeln('// SpicyChat QOL Android bundled injection');
    buffer.writeln('// Injected by Flutter InAppWebView');
    buffer.writeln(
      'window.__spicyChatQolBundledVersion = ${jsonEncode(_extensionVersion)};',
    );
    buffer.writeln('');

    for (final path in _jsFiles) {
      try {
        final source = await rootBundle.loadString(path);
        buffer.writeln('// === $path ===');
        buffer.writeln(source);
        buffer.writeln('');
      } catch (e) {
        buffer.writeln('// ERROR loading $path: $e');
      }
    }

    _jsBundle = buffer.toString();
  }

  String get cssInjectionScript {
    final escaped = _cssContent
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '');

    return '''
      (function() {
        if (document.getElementById('ds-qol-injected-css')) return;
        var style = document.createElement('style');
        style.id = 'ds-qol-injected-css';
        style.textContent = '$escaped';
        document.head.appendChild(style);
      })();
    ''';
  }
}
'@

    $Content = $Template.Replace('__JS_ENTRIES__', $EntriesText)
    $Content = $Content.Replace('__EXTENSION_VERSION__', $ManifestVersion)
    Write-IfChanged -Destination $DartFile -Content $Content
}

$script:ChangedCount = 0
$ResolvedSource = Resolve-ExtensionRoot $SourceRoot

if (-not (Test-Path -LiteralPath $AndroidApp)) {
    Fail "Android project was not found: $AndroidApp"
}

$ManifestPath = Join-Path $ResolvedSource "manifest.json"
$Manifest = Read-Utf8Text $ManifestPath | ConvertFrom-Json

$ContentJsRaw = [System.Collections.Generic.List[string]]::new()
$ContentCssRaw = [System.Collections.Generic.List[string]]::new()
$WebResourcesRaw = [System.Collections.Generic.List[string]]::new()

foreach ($Group in @($Manifest.content_scripts)) {
    foreach ($Item in @($Group.js)) {
        if ($Item) { $ContentJsRaw.Add([string]$Item) }
    }

    foreach ($Item in @($Group.css)) {
        if ($Item) { $ContentCssRaw.Add([string]$Item) }
    }
}

foreach ($Group in @($Manifest.web_accessible_resources)) {
    foreach ($Item in @($Group.resources)) {
        if ($Item) { $WebResourcesRaw.Add([string]$Item) }
    }
}

$ContentScripts = Ordered-Unique $ContentJsRaw
$ContentStyles = Ordered-Unique $ContentCssRaw
$WebResources = Ordered-Unique $WebResourcesRaw
$WebResourceJs = @($WebResources | Where-Object { $_ -match '\.js$' })

if ($ContentScripts.Count -eq 0) {
    Fail "manifest.json contains no content JavaScript."
}

Write-Host ""
Write-Host "FULL Android sync: SpicyChat QOL extension -> Android app" -ForegroundColor Cyan
Write-Host "From: $ResolvedSource"
Write-Host "To:   $TargetRoot"
Write-Host ""

# 1) Mirror the complete current extension source for the Android repository.
New-Item -ItemType Directory -Path $TargetExtension -Force | Out-Null

$RoboArgs = @(
    $ResolvedSource,
    $TargetExtension,
    "/MIR",
    "/FFT",
    "/R:2",
    "/W:1",
    "/NFL",
    "/NDL",
    "/NJH",
    "/NJS",
    "/NP",
    "/XD",
    ".git",
    ".github",
    "node_modules",
    "build",
    "dist",
    "/XF",
    "*.zip",
    "*.apk",
    "*.crx"
)

& robocopy @RoboArgs | Out-Null
$RoboCopyExitCode = $LASTEXITCODE

if ($RoboCopyExitCode -ge 8) {
    Fail "Could not mirror the extension folder. Robocopy exit code: $RoboCopyExitCode"
}

# Robocopy uses non-zero success codes (for example 1 means files were copied).
# GitHub Actions' PowerShell wrapper propagates the final native-process
# LASTEXITCODE, so a successful sync could otherwise be reported as exit code 1.
$global:LASTEXITCODE = 0

# 2) Copy every JS content script from every manifest content_scripts block.
New-Item -ItemType Directory -Path $AndroidJs -Force | Out-Null

$AllowedJs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
[void]$AllowedJs.Add("bridge.js")
[void]$AllowedJs.Add("android-message-longpress.js")

$SeenFileNames = @{}

foreach ($RelativePath in $ContentScripts) {
    $SourceFile = Join-Path $ResolvedSource ($RelativePath -replace '/', '\')
    $FileName = [System.IO.Path]::GetFileName($SourceFile)

    if ($SeenFileNames.ContainsKey($FileName) -and $SeenFileNames[$FileName] -ne $RelativePath) {
        Fail "Two extension scripts use the same filename '$FileName'. Android's flat JS asset folder cannot safely represent both."
    }
    $SeenFileNames[$FileName] = $RelativePath
    [void]$AllowedJs.Add($FileName)

    $Destination = Join-Path $AndroidJs $FileName

    if ($FileName -ieq "chat-export.js") {
        Write-IfChanged -Destination $Destination -Content (Get-AndroidChatExport $SourceFile)
    }
    else {
        Copy-IfChanged -Source $SourceFile -Destination $Destination
    }
}

# 3) Copy current JS web_accessible_resources too.
# These are not automatically injected; they are kept available for loader scripts.
foreach ($RelativePath in $WebResourceJs) {
    $SourceFile = Join-Path $ResolvedSource ($RelativePath -replace '/', '\')
    $FileName = [System.IO.Path]::GetFileName($SourceFile)

    if ($SeenFileNames.ContainsKey($FileName) -and $SeenFileNames[$FileName] -ne $RelativePath) {
        Fail "A web-accessible script conflicts with another Android JS filename: $FileName"
    }

    $SeenFileNames[$FileName] = $RelativePath
    [void]$AllowedJs.Add($FileName)

    Copy-IfChanged -Source $SourceFile -Destination (Join-Path $AndroidJs $FileName)
}

# Remove JS assets that were removed from the current extension, preserving Android bridge.js.
Get-ChildItem -LiteralPath $AndroidJs -Filter "*.js" -File | ForEach-Object {
    if (-not $AllowedJs.Contains($_.Name)) {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Host "Removed stale Android JS: $($_.Name)" -ForegroundColor Yellow
        $script:ChangedCount++
    }
}

$AndroidLongPress = Join-Path $AndroidJs "android-message-longpress.js"
if (-not (Test-Path -LiteralPath $AndroidLongPress)) {
    Fail "Android-only message long-press asset is missing: $AndroidLongPress"
}

# 4) Copy every CSS file declared by content_scripts.
New-Item -ItemType Directory -Path $AndroidCss -Force | Out-Null

$AllowedCss = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($RelativePath in $ContentStyles) {
    $SourceFile = Join-Path $ResolvedSource ($RelativePath -replace '/', '\')
    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    [void]$AllowedCss.Add($FileName)

    Copy-IfChanged -Source $SourceFile -Destination (Join-Path $AndroidCss $FileName)
}

Get-ChildItem -LiteralPath $AndroidCss -Filter "*.css" -File | ForEach-Object {
    if (-not $AllowedCss.Contains($_.Name)) {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Host "Removed stale Android CSS: $($_.Name)" -ForegroundColor Yellow
        $script:ChangedCount++
    }
}

# 5) Sync the extension options UI while retaining the Android bridge/mobile additions.
$OptionsPage = if ($Manifest.options_page) {
    [string]$Manifest.options_page
}
elseif ($Manifest.options_ui -and $Manifest.options_ui.page) {
    [string]$Manifest.options_ui.page
}
else {
    $null
}

if ($OptionsPage) {
    New-Item -ItemType Directory -Path $AndroidOptions -Force | Out-Null

    $SourceOptionsHtml = Join-Path $ResolvedSource ($OptionsPage -replace '/', '\')
    Write-IfChanged `
        -Destination (Join-Path $AndroidOptions "options.html") `
        -Content (Get-AndroidOptionsHtml $SourceOptionsHtml)

    $SourceOptionsCss = Join-Path $ResolvedSource "options.css"
    if (Test-Path -LiteralPath $SourceOptionsCss) {
        $AndroidOptionsCss = Join-Path $AndroidOptions "options.css"
        Write-IfChanged `
            -Destination $AndroidOptionsCss `
            -Content (Get-AndroidOptionsCss -SourceFile $SourceOptionsCss -ExistingAndroidFile $AndroidOptionsCss)
    }

    # Mirror every local JavaScript dependency referenced by options.html.
    # Newer QoL versions split the Features catalogue into feature-registry.js;
    # copying only options.js made Android show 0/0 features.
    $OptionsScriptSources = Get-LocalOptionsScriptSources $SourceOptionsHtml
    foreach ($RelativeScript in $OptionsScriptSources) {
        $NormalizedScript = $RelativeScript -replace '/', [System.IO.Path]::DirectorySeparatorChar
        $SourceFile = Join-Path (Split-Path -Parent $SourceOptionsHtml) $NormalizedScript
        if (-not (Test-Path -LiteralPath $SourceFile)) {
            Fail "Options page references a local script that does not exist: $RelativeScript"
        }

        $Destination = Join-Path $AndroidOptions ([System.IO.Path]::GetFileName($NormalizedScript))
        Copy-IfChanged -Source $SourceFile -Destination $Destination
    }

    # Text resources read by the options UI through the Android native bridge.
    foreach ($Name in @("CHANGELOG.md", "features.md")) {
        $SourceFile = Join-Path $ResolvedSource $Name
        if (Test-Path -LiteralPath $SourceFile) {
            Copy-IfChanged -Source $SourceFile -Destination (Join-Path $AndroidOptions $Name)
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $AndroidOptions "options-bridge.js"))) {
        Fail "Android-only options-bridge.js is missing."
    }

    # Verify every options dependency before building. This catches future
    # options-page splits instead of silently shipping a broken Android tab.
    foreach ($RelativeScript in $OptionsScriptSources) {
        $FileName = [System.IO.Path]::GetFileName(($RelativeScript -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath (Join-Path $AndroidOptions $FileName))) {
            Fail "Verification failed: Android Options is missing $RelativeScript"
        }
    }

    if ($OptionsScriptSources -contains "feature-registry.js") {
        $RegistryFile = Join-Path $AndroidOptions "feature-registry.js"
        $RegistryText = Read-Utf8Text $RegistryFile
        if (-not $RegistryText.Contains("SpicyChatQoLFeatureRegistry")) {
            Fail "Verification failed: feature-registry.js does not define SpicyChatQoLFeatureRegistry."
        }
    }
}

# 6) Register every current content script for Android injection in manifest order.
Update-BundleList -DartFile $BundleService -ManifestScripts $ContentScripts -ManifestVersion ([string]$Manifest.version)

# Guard against the old PowerShell encoding-corruption failure mode.
$BundleSize = (Get-Item -LiteralPath $BundleService).Length
if ($BundleSize -gt 262144) {
    Fail "js_bundle_service.dart is unexpectedly large ($BundleSize bytes). Refusing to build a likely corrupted Android app."
}

# 7) Verify the complete current manifest set before allowing a build.
foreach ($RelativePath in $ContentScripts) {
    $SourceFile = Join-Path $ResolvedSource ($RelativePath -replace '/', '\')
    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    $Destination = Join-Path $AndroidJs $FileName

    if (-not (Test-Path -LiteralPath $Destination)) {
        Fail "Verification failed: Android is missing $RelativePath"
    }

    if ($FileName -ine "chat-export.js") {
        if (
            (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        ) {
            Fail "Verification failed: Android copy differs from extension source: $RelativePath"
        }
    }
    else {
        $AndroidExport = Read-Utf8Text $Destination
        if (-not $AndroidExport.Contains("window._dsRequestExport")) {
            Fail "Verification failed: Android chat-export.js lost native export handling."
        }
    }
}

foreach ($RelativePath in $WebResourceJs) {
    $SourceFile = Join-Path $ResolvedSource ($RelativePath -replace '/', '\')
    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    $Destination = Join-Path $AndroidJs $FileName

    if (-not (Test-Path -LiteralPath $Destination)) {
        Fail "Verification failed: Android is missing web-accessible resource $RelativePath"
    }
}

foreach ($RelativePath in $ContentStyles) {
    $SourceFile = Join-Path $ResolvedSource ($RelativePath -replace '/', '\')
    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    $Destination = Join-Path $AndroidCss $FileName

    if (
        -not (Test-Path -LiteralPath $Destination) -or
        (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    ) {
        Fail "Verification failed: Android CSS is missing/outdated: $RelativePath"
    }
}

$BundleText = Read-Utf8Text $BundleService

if (-not $BundleText.Contains("String get extensionVersion")) {
    Fail "Verification failed: js_bundle_service.dart lost the Android extensionVersion bridge."
}
if (-not $BundleText.Contains("__spicyChatQolBundledVersion")) {
    Fail "Verification failed: js_bundle_service.dart lost the JavaScript extension-version bridge."
}

foreach ($RelativePath in $ContentScripts) {
    $FileName = [System.IO.Path]::GetFileName(($RelativePath -replace '/', '\'))
    if (-not $BundleText.Contains("assets/js/$FileName")) {
        Fail "Verification failed: $FileName is not registered in js_bundle_service.dart."
    }
}

Write-Host ""
Write-Host "FULL Android sync verified." -ForegroundColor Green
Write-Host "Extension version: $($Manifest.version)"
Write-Host "Content JavaScript: $($ContentScripts.Count)/$($ContentScripts.Count)"
Write-Host "Web-accessible JS: $($WebResourceJs.Count)/$($WebResourceJs.Count)"
Write-Host "Content CSS: $($ContentStyles.Count)/$($ContentStyles.Count)"
Write-Host "Changed Android files: $script:ChangedCount"
