# Merge Notes

- Kept the final Android source as the mobile base.
- Kept the fuller browser extension as a separate desktop target.
- Ported the final `cards.js` group-detection and recycled-card unhide fixes into the desktop extension without replacing its newer desktop-only filtering features.
- Renamed user-visible branding to **SpicyChat QOL**.
- Changed the Android application ID to `uk.drache.spicychatqol` before the public release. Older private/test builds using `com.dragonscript.dragonscript_app` are treated by Android as a separate app.
- Retained `window.DragonScriptQoL` as an internal compatibility namespace.
- Removed generated build caches, machine-specific paths, IDE metadata, and macOS metadata.
- Bumped the Flutter version to `0.1.1+2` for the first renamed update build.
- Removed the obsolete `WRITE_EXTERNAL_STORAGE` permission.

The project was structurally checked, but a fresh APK could not be compiled in the merge environment because the Flutter SDK was not installed there. Build it on a Windows machine using the root README and included PowerShell script.
