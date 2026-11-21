# SpicyChat QoL Android

**SpicyChat QoL Android** is the Android app for [SpicyChat QoL](https://github.com/drachescript/spicychat-qol-extension). It runs SpicyChat in a Flutter WebView and adds native Android controls, downloads, storage, recovery, and other mobile-specific integration. Most QoL features still come from the shared extension project.

[![Latest Android release](https://img.shields.io/github/v/release/drachescript/spicychat-qol-android?label=Android%20APK)](https://github.com/drachescript/spicychat-qol-android/releases/latest)
[![Android Validate](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-validate.yml/badge.svg)](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-validate.yml)
[![Android Stable Release](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-release.yml/badge.svg)](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-release.yml)
[![VirusTotal APK Check](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-virustotal.yml/badge.svg)](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-virustotal.yml)

**[Download latest APK](https://github.com/drachescript/spicychat-qol-android/releases/latest)** · **[Android download page](https://spicychatqol.drache.uk/android/)** · **[VirusTotal checks](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-virustotal.yml)** · **[Changelog](android-CHANGELOG.md)** · **[Report an issue](https://github.com/drachescript/spicychat-qol-extension/issues)**

## Install

1. Open the [latest Android release](https://github.com/drachescript/spicychat-qol-android/releases/latest), or use the [project's Android download page](https://spicychatqol.drache.uk/android/).
2. Download **SpicyChat-QOL-Android-vX.Y.Z.apk** to your Android phone.
3. Open the APK and allow installation from that source if Android prompts you.
4. Open the app, sign in to SpicyChat, and configure QoL from its settings.

The app's package ID is **`uk.drache.spicychatqol`** (minimum Android API 24 / Android 7.0). Older private/test builds with a different application ID are separate apps and do not upgrade in place.

Download APKs from the linked project release or website. An APK downloaded from elsewhere may not be the same signed build.

## Features

Most features are shared with the [main SpicyChat QoL extension](https://github.com/drachescript/spicychat-qol-extension). Android adds or adapts:

- **Native controls:** configurable cog position, individual cog-menu shortcut visibility, Focus / Immersive Mode, and mobile settings.
- **Chat interaction:** Android long-press actions, reliable clipboard/text selection, message editing and mobile composer compatibility.
- **Downloads and data:** Android file picker, Save As, export/download handling, storage bridges, and backup/import support.
- **Reliability:** WebView recovery, blank-screen recovery, route handling, renderer diagnostics, and App Log copy/export.
- **Safer controls:** an optional *Clear App Log?* confirmation, enabled by default.
- **Mobile navigation:** optional lightweight Android Chat Tabs (experimental and **off by default**).
- **QoL compatibility:** shared extension updates, optional module loading, native capabilities, and rollback to a previous compatible bundle.

Some desktop-only features require browser helper tabs or extension background workers and are not available in Android's single-WebView runtime. Android will not pretend an unsupported background action succeeded.

See [Android release notes](android-CHANGELOG.md) for changes specific to the APK and the [extension features](https://github.com/drachescript/spicychat-qol-extension/blob/main/features.md) for the broader feature catalogue.

## Updates: Android APK vs. shared QoL

There are **two independent update channels**:

| Channel | Changes | How to update |
| --- | --- | --- |
| **Shared QoL** | Compatible extension JavaScript, CSS, and Settings | App checks roughly every **12 hours**, or use **Android Settings → QoL updates → Check QoL updates now** |
| **Android APK** | Flutter, WebView, native bridge, Android settings, and built-in app behavior | Check **Android Settings → Android app updates** or install the [latest APK](https://github.com/drachescript/spicychat-qol-android/releases/latest) |

A shared QoL update normally **does not** require reinstalling the APK. Downloaded changes take effect after a full page load or app restart rather than interrupting an active chat.

The Android updater validates required files and compatibility before activation. If a bundle is incompatible or corrupted, it can use the previous saved bundle or the APK's bundled fallback. A new native bridge feature still needs a new APK.

## Build locally on Windows

**The easiest path is the included `build_android.bat`.** You do **not** need to create a new Android Studio project.

### 1. Install the tools

- [Git for Windows](https://git-scm.com/downloads/win)
- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows/mobile) — the project's tested CI version is **Flutter 3.47.9**
- [Android Studio](https://developer.android.com/studio) with Android SDK Platform **API 36**, SDK Build-Tools, Command-line Tools, and Platform-Tools
- **Java 17** (JDK)
- **Python 3**, for the included toolchain check

The tested native build stack is **Gradle 8.14**, **Android Gradle Plugin 8.11.1**, and **Kotlin Gradle Plugin 2.2.20**. Avoid updating Flutter or Gradle independently without validating the complete toolchain.

Open PowerShell and run:

```powershell
flutter --version
flutter doctor -v
flutter doctor --android-licenses
```

For screenshots and more detailed setup, read [ANDROID_STUDIO_SETUP_WINDOWS.md](ANDROID_STUDIO_SETUP_WINDOWS.md).

### 2. Get both repositories

The Android APK bundles a snapshot of the separately maintained extension source. Clone them **beside one another**:

```powershell
git clone https://github.com/drachescript/spicychat-qol-extension.git
git clone https://github.com/drachescript/spicychat-qol-android.git
cd spicychat-qol-android
```

Recommended folder layout:

```text
Projects/
  spicychat-qol-extension/
  spicychat-qol-android/
```

For a reproducible build, use a compatible published **extension tag** instead of an arbitrary untested development commit. GitHub Actions selects the latest published stable extension release automatically.

### 3. Set up signing (signed release builds only)

The project's **release** build script requires your existing release signing files:

```text
android_app/android/upload-keystore.jks
android_app/android/key.properties
```

Example `key.properties` format (placeholders only):

```properties
storePassword=YOUR_KEYSTORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=YOUR_KEY_ALIAS
storeFile=../upload-keystore.jks
```

**Never commit either signing file or share the passwords.** To install a locally built APK *over the public app*, you must use the original signing identity. Contributors without that key can compile/test a **debug build** instead; they cannot produce an APK signed as the official release.

### 4. Build with one double-click

From the Android repository folder, double-click:

**`build_android.bat`**

It finds the sibling extension checkout, synchronizes the shared assets, validates native compatibility, builds a signed release APK, and writes the output and checksums to **`output/`**. This BAT intentionally **does not bump your Android version**.

Alternatively, in PowerShell:

```powershell
.\build_android.ps1 -NoVersionBump
```

If the extension is stored somewhere else, set its path explicitly:

```powershell
.\build_android.ps1 -NoVersionBump -ExtensionSourceRoot "D:\Projects\spicychat-qol-extension"
```

Typical outputs include:

- `output/SpicyChat-QOL-Android-vX.Y.Z.apk` — versioned signed APK
- `output/SpicyChat-QOL.apk` — convenient latest copy
- `output/SHA256SUMS.txt` and APK `.sha256` — checksums
- `output/update.json` and `output/current-version.txt` — update metadata

If the script stops, fix the reported toolchain, signing, or extension-compatibility error rather than bypassing its safety checks.

### No release signing key? Run a debug build

After syncing assets from a compatible extension checkout, you can build a **debug APK** for personal testing without the official release key:

```powershell
.\update_android.ps1 -SourceRoot "D:\Projects\spicychat-qol-extension"
cd android_app
flutter pub get
flutter build apk --debug
```

The debug APK is in `android_app/build/app/outputs/flutter-apk/`. It is not the official signed release and may not install over your existing public app. Back up app data before experimenting with alternate builds.

### Troubleshooting builds

- **`flutter` not found:** install the SDK, add its `bin` folder to your PATH, and reopen PowerShell.
- **Missing extension source:** keep the repositories beside one another or pass `-ExtensionSourceRoot` to the PowerShell build script.
- **Missing keystore / `key.properties`:** signed release builds require the existing private signing credentials; use a debug build for unsigned development.
- **Wrong Flutter/Gradle versions:** run `python tools/check_android_toolchain.py --check-flutter` and follow [the setup guide](ANDROID_STUDIO_SETUP_WINDOWS.md).
- **New unsupported QoL module:** update the Android compatibility mapping before building; do not silently bypass the guard.

## Publishing an Android release

You don't have to build or upload the signed APK by hand when publishing through GitHub.

1. Run **`release_next_android.bat`** to prepare the next visible version in `android_app/pubspec.yaml`. This helper does **not** commit, tag, push, or publish anything.
2. Review the changes in GitHub Desktop, then commit and push `main`.
3. [Android Validate](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-validate.yml) checks the commit.
4. After successful validation, [Android Stable Release](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-release.yml) builds the signed APK using the latest stable extension release, verifies it, creates the version tag if needed, and publishes the GitHub release.
5. The website is notified of the release; [Android VirusTotal Check](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-virustotal.yml) independently checks the newly published APK.

**Same-version hotfix:** an appropriately named `vX.Y.Z ...` commit (or the workflow's explicit manual hotfix option) can publish a replacement APK with a higher internal `versionCode` while preserving the visible version. The previous release APK may be kept as `_old`.

A documentation-only commit should not trigger an unnecessary APK rebuild or scan. The release workflow verifies that the exact source commit passed validation.

## VirusTotal APK scans

**[Latest scan workflow and results](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-virustotal.yml)** · **[Latest APK and attached scan reports](https://github.com/drachescript/spicychat-qol-android/releases/latest)** · **[VirusTotal file lookup](https://www.virustotal.com/gui/home/search)**

GitHub Actions checks the SHA-256 of the **published signed APK**, then looks up the file on VirusTotal or uploads it when appropriate. APKs above 32 MB use VirusTotal's large-file upload endpoint (up to 650 MB). This uses the repository secret `VIRUSTOTAL_API_KEY`; the secret is never included in the README or reports.

For completed checks, the workflow writes the detection counts and **direct VirusTotal report link** to its run summary. When the API key is configured, it also attempts to attach **`VirusTotal-Android-vX.Y.Z.json`** to that Android release; the JSON contains `reportUrl` for the specific APK hash.

**Important:** a green VirusTotal workflow badge does **not necessarily mean an APK was scanned**. If a release run published no new APK, the workflow legitimately skips scanning. Check the workflow's steps or the attached JSON, and distinguish **completed**, **pending**, **unavailable**, and **not configured**. There is no verified direct report URL to pin here until a scan for the current APK actually completes.

To scan an already published APK, open **[Android VirusTotal Check](https://github.com/drachescript/spicychat-qol-android/actions/workflows/android-virustotal.yml) → Run workflow** and enter a release tag such as `v0.1.47`. No APK rebuild is needed. Uploaded files may be shared with VirusTotal's security community; do not use this scanner for private application data or signing material.

VirusTotal results are security signals, **not a guarantee of safety**. Scanning is intentionally separate from APK publication so an unavailable API cannot block a working release.

## Data, privacy, and support

Android's storage/clipboard/download bridges run inside the app. QoL settings, saved lists, backups, and other private data generally remain on the device unless you explicitly enable a feature that transfers them. App Log and Support diagnostics are intended for troubleshooting; review exports before sharing.

Read [Android privacy information](PRIVACY.md) and the main extension's [privacy](https://github.com/drachescript/spicychat-qol-extension/blob/main/PRIVACY.md) and [permissions](https://github.com/drachescript/spicychat-qol-extension/blob/main/PERMISSIONS.md) documents.

**Bug reports and feature requests:** use the [SpicyChat QoL issue tracker](https://github.com/drachescript/spicychat-qol-extension/issues), adding the `android` label for Android-specific problems. Useful details are device model, Android and APK versions, active QoL version, the affected page, reproduction steps, and a safe Support/App Log excerpt. **Do not publish authentication tokens, API keys, private chats, or keystore data.**

## Project files

- `android_app/` — Flutter application, Android native code, WebView bridges, and bundled QoL fallback
- `build_android.bat` / `build_android.ps1` — local full sync and signed APK build
- `update_android.ps1` — sync and validate shared extension assets
- `release_next_android.bat` / `.ps1` — prepare the next Android version (no automatic push)
- `tools/check_android_toolchain.py` — verify the pinned build toolchain
- `tools/virustotal_scan.py` — check a published signed APK using VirusTotal
- `.github/workflows/` — validation, signed release, and VirusTotal automation
- `android-CHANGELOG.md` — Android-specific release history
- `ANDROID_STUDIO_SETUP_WINDOWS.md` — Windows setup walkthrough
- `PRIVACY.md` — Android privacy information

## Developer, community, and testers

SpicyChat QoL is developed by **DragonGRaf** under **DragonScript**.

- **Main extension:** https://github.com/drachescript/spicychat-qol-extension
- **Android repository:** https://github.com/drachescript/spicychat-qol-android
- **Project website:** https://spicychatqol.drache.uk
- **Discord community:** https://discord.gg/XTMdWvuVSU
- **Contact:** `@dragongraf` on Discord
- **Optional project support:** https://paypal.me/dragongraf

Thanks to Android testers **jarek1132** and **Lilith Rose** (Bug Hunter), and everyone who contributes bug reports and feedback. Additional credits are listed in the main extension project.
