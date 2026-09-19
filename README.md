# SpicyChat QoL Android

SpicyChat QoL Android is the official Android wrapper for **SpicyChat QoL**.

It runs SpicyChat inside a Flutter/WebView app and provides the native Android pieces that a normal browser extension cannot provide reliably on mobile, while the shared QoL JavaScript/CSS remains maintained in the main extension project.

## Repositories

- **Android wrapper:** https://github.com/drachescript/spicychat-qol-android
- **Main extension / shared QoL source:** https://github.com/drachescript/spicychat-qol-extension
- **Website / Android downloads:** https://spicychatqol.drache.uk/android/
- **Website source:** https://github.com/drachescript/spicychat-qol-website

## Bug reports and feature requests

Android issues are tracked in the main SpicyChat QoL issue tracker so extension-side and Android-wrapper bugs stay in one place:

**https://github.com/drachescript/spicychat-qol-extension/issues**

Please add the existing **`android`** label when the problem is specific to the APK/WebView wrapper.

Useful reports normally include:

- Android device/model and Android version
- SpicyChat QoL version
- Android app version
- affected SpicyChat page/route
- expected behavior
- actual behavior
- reproduction steps
- screenshot/video when useful
- **Copy all support info** / diagnostics from QoL Settings when available

Do not post authentication tokens, API keys, Discord webhook URLs, private chat exports, or other sensitive account data in public issues.

## What lives in this repository

This repository contains the **native Android wrapper**, including:

- Flutter application code
- Android WebView configuration and recovery logic
- Android-only settings
- native storage/file bridges
- native clipboard support
- Android file picker / Save As handling
- Android navigation integration
- Android chat-tab state
- Android diagnostics/runtime bridges
- Android-specific long-press controls
- Android build/release tooling
- the bundled known-good QoL fallback used by the APK

The normal QoL feature source is maintained separately in:

https://github.com/drachescript/spicychat-qol-extension

Do not duplicate normal extension feature development in this repository unless the behavior specifically requires Android/Flutter/WebView integration.

## Application identity

Public Android application ID:

```text
uk.drache.spicychatqol
```

The JavaScript namespace remains:

```text
window.DragonScriptQoL
```

The JavaScript namespace is intentionally shared with the browser extension so existing QoL data and shared runtime calls remain compatible.

Older private/test APKs that used a different Android application ID are separate apps and cannot be updated in place by this package.

## Versioning

Android uses two version values:

```text
versionName = public/user-facing version
versionCode = Android's internal monotonically increasing build number
```

The public stable version line starts at:

```text
0.1.0
```

and uses normal three-part versions through:

```text
100.99.99
```

Example:

```yaml
version: 0.1.0+71
```

In that example:

- `0.1.0` is the visible Android version.
- `71` is the Android `versionCode`.

`versionCode` must always increase. It must **not** be reset when the public `versionName` is restarted or changed.

Stable Git tags use:

```text
v0.1.0
v0.1.1
v1.0.0
...
v100.99.99
```

## Update model

The Android app and the QoL extension have separate update lifecycles.

### Extension-only update

Normal QoL JavaScript/CSS/features:

```text
SpicyChat QoL extension release
        ↓
Android-compatible QoL bundle
        ↓
website manifest
        ↓
installed Android app
```

A compatible extension-only update should **not require a new APK**.

### Native Android update

Changes to Flutter/native Android behavior, for example:

- WebView configuration
- Android Settings
- native clipboard
- Android file picker
- native notifications
- Android chat tabs
- native bridge APIs
- APK updater behavior

require a new Android APK release.

The planned stable update endpoint is:

```text
https://spicychatqol.drache.uk/android/manifest.json
```

The app will check for updates on launch only when at least **12 hours** have passed since the previous automatic check. A manual **Check for updates** action may bypass that timer.

For native APK updates, the first public updater will direct users to:

https://spicychatqol.drache.uk/android/

A later updater may download the APK in-app, verify its checksum, and hand it to Android's package installer.

## Bundle compatibility

The remote QoL bundle/update channel is designed around a native bridge version.

Conceptually:

```text
bundle minBridgeVersion <= installed bridgeVersion
→ bundle may be used

bundle minBridgeVersion > installed bridgeVersion
→ do not load incompatible bundle
→ Android APK update required
```

The APK should always retain:

```text
downloaded current bundle
        ↓ fallback
previous known-good bundle
        ↓ fallback
bundle embedded in APK
```

so a broken or incompatible remote QoL release cannot leave the Android app unusable.

## Building locally

### Requirements

Install:

- Git
- Flutter SDK
- Android Studio / Android SDK
- Android SDK command-line tools
- Java 17

Then verify the environment:

```powershell
flutter doctor
flutter doctor --android-licenses
```

For detailed Windows setup instructions, see:

[`ANDROID_STUDIO_SETUP_WINDOWS.md`](ANDROID_STUDIO_SETUP_WINDOWS.md)

### Extension source

Current local builds synchronize shared QoL assets from the separate extension source before compiling the APK.

Clone both repositories locally and make sure `build_android.ps1` points `$ExtensionSourceRoot` at your extension checkout.

Example layout:

```text
D:\Projects\
├─ spicychat-qol-android\
└─ spicychat-qol-extension\
```

The release/CI workflow will provide the extension checkout automatically when GitHub Actions builds a tagged release.

### Build

From the Android repository root:

```bat
build_android.bat
```

or:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build_android.ps1
```

The build performs the extension → Android sync, validates the Android package/activity, builds the release APK, verifies the package identity, generates hashes/update metadata, and places generated artifacts under `output\`.

Generated APKs and release output are intentionally ignored by Git.

## Signing

The public application is signed. Never commit signing credentials.

Local release signing uses:

```text
android_app\android\upload-keystore.jks
android_app\android\key.properties
```

Both are ignored by Git.

`key.properties` uses:

```properties
storePassword=...
keyPassword=...
keyAlias=...
storeFile=...
```

Keep secure backups of the signing keystore and credentials. Losing the signing identity can prevent future APKs from updating the installed public app.

GitHub Actions releases should reconstruct the keystore from repository secrets rather than storing it in source control.

## GitHub release model

The stable Android source branch is:

```text
main
```

Normal pushes/PRs may run validation, but stable APK publication should be triggered by an Android version tag:

```text
v0.1.0
```

The intended release workflow is:

```text
prepare release/version
        ↓
commit to main
        ↓
create + push version tag
        ↓
GitHub Actions
        ↓
sync extension source from main
        ↓
build signed APK
        ↓
verify package
        ↓
generate SHA-256/update metadata
        ↓
publish GitHub Release
```

Android APK releases are published at:

https://github.com/drachescript/spicychat-qol-android/releases

## Repository policy

The Android repository intentionally keeps GitHub Issues disabled.

Use the main extension issue tracker instead:

https://github.com/drachescript/spicychat-qol-extension/issues

Pull requests may remain enabled for source contributions.

The repository `.gitignore` intentionally excludes:

- signing keys and `key.properties`
- local extension checkout
- Flutter/Dart build state
- Gradle caches
- Android `local.properties`
- IDE files
- logs
- generated APK/release output

The Gradle wrapper files are source and **should be committed**.

## Android-specific features

The Android wrapper currently includes Android-specific compatibility/features such as:

- native WebView recovery and navigation handling
- internal SpicyChat link routing
- Android-only app settings
- configurable default launch page
- optional pinch-to-zoom
- optional lightweight Android chat tabs
- native clipboard support
- native file saving / file picking
- generated Blob/data-URL download handling
- Android-compatible QoL diagnostics/runtime messaging
- Android-only long-press message actions
- Android media/autoplay compatibility
- Android listing/card identity normalization
- configurable native QoL control placement

See [`android-CHANGELOG.md`](android-CHANGELOG.md) for Android-specific changes.

## Data and privacy

SpicyChat QoL is designed to keep local QoL data local wherever practical.

Android-native bridges are restricted to the app/SpicyChat context and exist to provide platform functionality such as storage, files, clipboard, navigation, and diagnostics.

QoL support diagnostics are designed to avoid chat text, memory text, Persona text, API keys, webhook secrets, and similar private content.

For the extension privacy and permission documentation, see:

- https://github.com/drachescript/spicychat-qol-extension/blob/main/PRIVACY.md
- https://github.com/drachescript/spicychat-qol-extension/blob/main/PERMISSIONS.md

## Support the project

SpicyChat QoL is developed by **DragonGRaf** under **DragonScript**.

Optional project support:

https://paypal.me/dragongraf

The repository also includes `.github/FUNDING.yml` so GitHub can display the Sponsor button.

## Project links

- Website: https://spicychatqol.drache.uk
- Android: https://spicychatqol.drache.uk/android/
- Extension repository: https://github.com/drachescript/spicychat-qol-extension
- Android repository: https://github.com/drachescript/spicychat-qol-android
- Discord: https://discord.gg/XTMdWvuVSU
- Contact: `@dragongraf` on Discord

## Testers

Special thanks to everyone testing the Android wrapper, including:

- **jarek1132** — Android testing
- **Lilith Rose** — Android testing · 🐛 Bug Hunter

Additional project/tester credits are maintained in the main SpicyChat QoL repository.
