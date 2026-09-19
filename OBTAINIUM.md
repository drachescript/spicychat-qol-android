# Optional Obtainium updates

SpicyChat QOL is intended to use its **own in-app update checker** as the main update method once the update endpoint is connected.

Obtainium remains an optional alternative for users who already use it or prefer a separate updater.

Repository:

```text
https://github.com/drachescript/spicychat-qol-android
```

## Add the app

1. Open Obtainium.
2. Choose **Add App**.
3. Paste the repository URL above.
4. Confirm that GitHub is detected as the source.
5. Use this APK filename filter:

   ```regex
   ^SpicyChat-QOL-Android-v[0-9.]+\.apk$
   ```

6. Keep prereleases disabled unless test builds are desired.
7. Add the app.

Obtainium will watch GitHub Releases for matching APK files.

## Signing requirement

Every update must retain the same Android package ID and signing key. Keep these files private and backed up:

```text
android_app/android/upload-keystore.jks
android_app/android/key.properties
```
