# SpicyChat QOL own update channel

The preferred update experience is an update checker built into the SpicyChat QOL Android app. Obtainium is only an optional fallback.

## Prepared now

Every Android build already creates:

```text
output\update.json
output\SHA256SUMS.txt
output\SpicyChat-QOL-Android-vVERSION.apk
```

`update.json` contains the information needed by an app updater:

- app/package name
- public version name
- numeric Android version code
- GitHub release tag
- APK filename and download URL
- SHA-256 checksum
- minimum Android SDK

The APK itself remains hosted as a GitHub Release asset, while the update checker can be controlled through your own site.

## Planned primary endpoint

When `spicychatqol.drache.uk` is ready, the app can check:

```text
https://spicychatqol.drache.uk/android/update.json
```

After publishing each GitHub Release, copy the generated `update.json` to that website path. The JSON can continue pointing to the APK hosted on GitHub Releases, so the website does not need to host the large APK itself.

## Planned app behaviour

The in-app updater should:

1. Check the website JSON on app start, no more than once per chosen interval.
2. Also provide a manual **Check for updates** button.
3. Compare numeric `versionCode`, not just the visible version text.
4. Show release/version information when an update exists.
5. Download or open the signed APK.
6. Verify the APK SHA-256 before installation when downloaded inside the app.
7. Let Android handle installation permission and confirmation.
8. Never force an update unless a future JSON flag explicitly marks a version as required.

## Current status

The build/release metadata is prepared. The current app does **not yet** contain the full in-app download/install updater.

That app-side updater is best connected after the website/update URL is final, so its endpoint does not need to be changed immediately afterward.
