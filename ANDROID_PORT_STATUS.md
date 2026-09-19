# Android current status and backlog

Reviewed 2026-09-16. Read README.md, MERGE_NOTES.md, android-CHANGELOG.md, build/update scripts and [shared instructions](../spicychat-qol/AGENTS.md). Source: [AND and Q9](../spicychat-qol/docs/CONVERSATION_CONTEXT.md). The original port-status text is preserved below as historical information.

## Current component and source-inspected state

Flutter WebView wrapper plus a separate extension/ source snapshot. Native services live in android_app/lib/services; WebView/Options screens are under lib/screens; Android-only bridges and synced QoL assets live under android_app/assets. Keep shared QoL fixes in the primary extension and wrapper-specific fixes here.

- android_app/pubspec.yaml: 0.4.7+65.
- extension/manifest.json: QoL 0.1.9.120 / technical 0.1.9.920. js_bundle_service.dart also declares .920. Primary QoL is .121/.921; do not assume its Memory import patch is already bundled here.
- webview_screen.dart contains native Clipboard.setData and __dsAndroidDispatchRuntimeMessage handoff; bridge.js implements runtime listener registration/dispatch. options-bridge.js implements DS_GET_DIAGNOSTIC_CONTEXT and asks for DS_GET_PAGE_DIAGNOSTICS.
- settings_service.dart has a 32 KB large-value threshold for the hybrid storage path.
- webview_screen.dart contains an independent fixed gear overlay and saved-tab restoration logic; android_ui_service.dart exposes the top-bar position. Android changelog documents default launch-page selection and restoration precedence.
- build_android.ps1 performs extension sync before compiling and guards the extensionVersion getter. Do not run builds casually: versioning/sync/output can change.

These findings support the historical patch claims at source level. No APK/device test or full asset equivalence check was done.

## Enduring Android decisions

Keep app ID uk.drache.spicychatqol and compatibility namespace window.DragonScriptQoL. Signing identity must remain consistent for in-place updates; private signing material must not enter docs or public source.

Gear should visually sit left of Home's language/globe button and left of chat's rating button, with an independent hit target. Offer a default launch page; saved chat-tab restoration takes precedence when enabled. The actual Home route is / in existing documentation.

Use native clipboard/file/storage support where browser APIs do not map to WebView. Synthetic active-tab messaging is for Options/runtime diagnostics, not a claim of normal browser tabs/background automation. Preserve unsupported desktop settings in shared backups while disabling their Android controls. Lightweight Android chat tabs already have source support.

## Reported bugs / verification backlog

1. Q9 reports cog opening can take up to 20 seconds. Reproduce/profile on device; native clipboard and diagnostics patches do not prove the delay is fixed.
2. Confirm long-press Copy reaches Android clipboard; confirm Options support reports see the current WebView and identify Android/WebView correctly.
3. Verify gear tap isolation on Home/chat and after SPA navigation; check default page versus restored tabs.
4. Sync/review primary .121 Memory import changes through the existing pipeline when an implementation task is requested. Compare all required Options dependencies and Android-only bridges afterward.
5. Re-test Opened/Favorites/Later loaded identities, internal links, audio, native file import/export and large-storage migration/rollback on device.
6. Black-page/renderer recovery improvements are changelog claims backed by wrapper code presence, not device acceptance results in this task.

## Planned / deferred

Continue Android compatibility and performance work separately from browser release logic. More tab/mobile layout work may remain, but do not list basic app tabs as wholly unimplemented. No new public APK release number or deployment was confirmed.

## Documentation conflicts / limits

README and the original status below say bundled .1.8.21; MERGE_NOTES records initial .1.1+2. Both describe an old merge, not the current .4.7+65 / QoL .120 tree. Root primary android-CHANGELOG.md is another copy, not proof of synchronization. Running/installed APK, signing/build success, release feed and remote repository state were not checked. Files were already largely untracked in Git.

---

## Historical port status (original text retained)

# Android Port Status

The Android app bundles the mobile-compatible content scripts from browser extension build **0.1.8.21**.

## Included in this merge

- All current content scripts are bundled in manifest order.
- Native storage bridge, trusted-domain checks, file picker, external-link handling, and APK signing remain intact.
- Backup import/export supports both JSON files and copy/paste text.
- The native settings screen preserves newer settings it does not display, so opening and saving it will not erase options imported from the browser extension.
- Chat TXT downloads use the native Android file picker.

## Platform limitations

- Chrome background alarms and real background tabs are not available in a single Android WebView.
- The native settings screen is a practical mobile subset of the desktop options page. Settings not shown there can still be transferred using a full backup.
- Mobile DOM behaviour may differ from desktop after SpicyChat website updates, so new extension changes still need testing in the APK.
