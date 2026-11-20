# SpicyChat QoL Android changelog

## Current status

- Latest verified public Android release: **v0.1.46** (`0.1.46+122`), published **November 19, 2026 (US Eastern; November 20 UTC)**.
- Release and APK: [Android v0.1.46 on GitHub](https://github.com/drachescript/spicychat-qol-android/releases/tag/v0.1.46). The signed APK, SHA-256 checksum, and update metadata are available in the release assets.
- Latest shared desktop QoL release checked: **v0.2.88**. The Android wrapper and the shared extension have separate release/version lifecycles.
- The Android app can download compatible shared QoL JavaScript, styles, Options, and assets **without requiring another APK**. Native Flutter/Android bridge changes still require an APK release.
- Shared QoL and Android APK updates are each checked automatically about **every 12 hours**, with separate manual actions in **Android Settings**.
- The shared QoL updater defaults to **published stable releases**; the optional experimental channel follows the extension's `main` branch. Downloaded bundles are checked for compatibility with the installed Android bridge.
- **Multiple Android Chat Tabs** remains experimental, opt-in, and disabled by default.
- The new **Cog-wheel menu** visibility controls and **Clear App Log** confirmation are **already released in v0.1.46**, not pending work.

## Recent Android releases

### v0.1.46 — Configurable cog-wheel shortcuts and safer log clearing

- **Clear App Log** now asks for confirmation before deleting the on-device diagnostic log, with **Ask before clearing App Log** enabled by default. The confirmation can be disabled in **Android Settings → Cog-wheel menu**.
- Added **14 individually configurable shortcuts** in the native cog, including Move Android cog, Chat Tabs, Command Palette, Focus Mode, Export Chat, Block Current Bot, Custom Pictures, Re-inject Scripts, the quick/detailed scroll checks, Copy/Export/Clear App Log, and Refresh Page.
- **Android Settings**, **QoL Options**, and **Recover Black Screen** always remain accessible even if every optional shortcut is hidden.
- Added **Show all cog shortcuts** to restore the normal menu without resetting unrelated settings.
- Cog preferences are Android-only and are retained using local app preferences; this does not change shared desktop QoL settings.
- Added the current `PRIVACY.md` file to the Android repository in the changes leading to this release.
- Released as `0.1.46+122`. [Compare v0.1.45…v0.1.46](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.45...v0.1.46).

### v0.1.45 — Newer shared QoL compatibility and Archive Blocking Presets

- Extended the Android optional-module support policy for shared QoL **v0.2.86 and v0.2.87**, including the further on-demand chat, editor, Persona, Lorebook, filtering, Focus Mode, and Rulebook helper modules.
- Added verification of downloaded QoL's actual optional-loader source and module map **before bundle activation**, with existing downloaded bundles rechecked during startup. Incompatible bundles are rejected rather than silently enabling broken optional features.
- Added an Android-native, cached Archive Blocking Presets catalog bridge, allowing the optional feature to get its catalog without the desktop background service worker.
- Made Android's `chrome.runtime.sendMessage` bridge return a Promise as well as supporting traditional callbacks, which newer optional modules require.
- Preserved in-page Chat Nudges behavior without relying on the desktop-only background sync handler.
- Kept desktop-only Bulk Research Export helper-tab work and Archive Community Themes background lookups excluded where Android does not provide an equivalent runtime.
- Kept a small limit on simultaneous Android lazy-module evaluations to protect startup responsiveness.
- Released as `0.1.45+121`. [Compare v0.1.44…v0.1.45](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.44...v0.1.45).

### v0.1.44 — Performance and validated Android releases

- Reduced unnecessary resume-time health/visual diagnostics after a short switch away from the app when the WebView is healthy.
- Improved QoL startup by reading asset files in small concurrent batches **without changing script or stylesheet injection order**.
- Reduced redundant tab-state writes, diagnostic-cache work, and temporary scroll-position history; batched routine logs while retaining error and recovery diagnostics.
- Changed the stable Android release workflow to depend on **successful validation of the exact source commit**, rather than publishing an unvalidated or stale commit.
- Added build-time checks that detect when the upstream desktop QoL optional-loader contract changes in ways Android has not reviewed.
- Released as `0.1.44+120`. [Compare v0.1.43…v0.1.44](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.43...v0.1.44).

### v0.1.43 — Lazy optional-module bridge

- Added a native WebView handler for supported shared QoL modules loaded only when a matching route/setting needs them.
- Restricted optional modules to a reviewed Android allowlist and checked the live WebView, trusted URL, and document token before running module source.
- Adjusted desktop dynamic imports for the Android single-WebView runtime while retaining an explicit desktop-only feature policy.
- Preserved manual recovery for renderer loss/black-screen conditions rather than silently recreating a page with an active draft.
- Released as `0.1.43+119`. [Compare v0.1.42…v0.1.43](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.42...v0.1.43).

### v0.1.42 — WebView and build reliability

- Updated WebView and shared-bundle integration, including further recovery and Android-specific Settings compatibility work.
- Added a toolchain-check helper and improved GitHub Actions validation/release workflow checks.
- [Compare v0.1.41…v0.1.42](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.41...v0.1.42).

### v0.1.41 — Android message and native controls improvements

- Updated Android message long-press handling and native actions.
- Updated the native Settings screen and WebView controls for Android-specific behavior.
- [Compare v0.1.40…v0.1.41](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.40...v0.1.41).

### v0.1.40, v0.1.39, v0.1.38 — Runtime compatibility iterations

- **v0.1.40:** Updated both the in-page JavaScript bridge and Android Options bridge. [Compare](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.39...v0.1.40).
- **v0.1.39:** Updated Options bridge and WebView integration. [Compare](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.38...v0.1.39).
- **v0.1.38:** Extended the bundled JavaScript loader for newer shared QoL behavior. [Compare](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.37...v0.1.38).

### v0.1.8–v0.1.37 — Intermediate public releases

The versions between the original v0.1.7 changelog and v0.1.38 were **published**. They contain many incremental changes to WebView reliability, native bridges, Android Options, file saving, diagnostics, and shared QoL integration. Because the published GitHub release bodies for these versions mostly link to their commit comparisons rather than providing feature-by-feature notes, this document does **not** assign unverified individual features to those releases.

- [v0.1.7…v0.1.17 history](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.7...v0.1.17)
- [v0.1.17…v0.1.27 history](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.17...v0.1.27)
- [v0.1.27…v0.1.37 history](https://github.com/drachescript/spicychat-qol-android/compare/v0.1.27...v0.1.37)
- Individual signed APK releases are available in [GitHub Releases](https://github.com/drachescript/spicychat-qol-android/releases).

## Original early release notes

## v0.1.7

- Continued cleanup of the native Android cog and mobile control placement.
- Improved Android-specific long-press and clipboard behavior.
- Added automatic website update-manifest synchronization after a successful Android release.
- Released as `0.1.7+79`.

## v0.1.6

- Improved Android Options startup so one incompatible Options helper cannot leave the page stuck on **Version loading…**.
- Improved the shared QoL bundle loader and updater.
- Added support for rebuilding the same visible Android version as a hotfix while increasing the internal Android `versionCode`.
- Same-version hotfix releases keep the normal APK filename for the newest build and can keep the previous APK as `_old`.
- Updated the release helper so future version bumps continue from the newest published Android `versionCode`, including same-version hotfix builds.
- Continued cleanup of Android clipboard and cog behavior.
- Released as `0.1.6+78`.

## v0.1.5

- Added the real **shared QoL updater** for Android.
- Android can now download newer extension runtime files, CSS, Options files, and support files without requiring a new APK for normal QoL changes.
- Added **QoL updates** to Android Settings with automatic 12-hour checks and a manual **Check QoL updates now** button.
- Added separate **Android app updates** with automatic checks and a manual **Check for updates now** button.
- Improved Android Options loading so current extension Options dependencies can be used inside the app.
- Improved extension-to-Android synchronization and stopped the sync process from overwriting Android-only bundle-loader behavior.
- Continued compatibility updates for current shared QoL features.

## v0.1.4

- Large WebView reliability pass.
- Improved Android page recovery, route handling, and native/WebView communication.
- Continued work on the Android cog, Focus Mode, clipboard handling, and mobile interaction fixes.
- Reduced unnecessary Android-side work around page navigation and long chats.

## v0.1.3

- Improved Android update detection and release metadata handling.
- Improved WebView navigation/recovery behavior.
- Improved Android build/update synchronization.
- Continued native bridge fixes for current QoL features.

## v0.1.2

- Added native Android APK update checking.
- Added an Android Settings update section showing the installed version, last check, and update status.
- Added manual update checks that bypass the normal automatic-check timer.
- Added native app-version information from Android through the Flutter bridge.
- Improved Android startup/update handling.

## v0.1.1

- Improved the GitHub Actions Android release workflow.
- Added the newer local **release_next_android** helper.
- Continued Android diagnostics/runtime compatibility and WebView fixes.
- Synced newer shared QoL changes into the packaged fallback.

## v0.1.0

- First public Android APK release.
- Signed release APK with checksum and update metadata.
- Persistent SpicyChat login/session inside the app.
- Embedded SpicyChat QoL runtime with Android-specific native bridges.
- Native file saving/import support for QoL exports and backups.
- Android diagnostics, recovery, storage compatibility, long-press actions, media support, configurable controls, and experimental chat tabs were established around the initial public release.

## Android features

### Updates and compatibility

- **Shared QoL updates and native Android APK updates are separate.** Compatible extension content can update without installing a new APK; native Android/Flutter code changes still require one.
- Both channels normally check for updates about every 12 hours; manual checks are available in Android Settings.
- Stable QoL updates follow published extension releases. The opt-in **Experimental QoL updates** setting follows `main`.
- Downloaded QoL resources, settings dependencies, and web-accessible assets are verified before the new bundle is activated.
- Optional-module mappings and the desktop import-adapter contract are checked against the installed Android bridge. Unsupported updates do not silently replace working shared QoL code.
- The app retains a previous downloaded bundle for recovery, and has a bundled APK fallback; shared QoL changes take effect on the next full page load/restart rather than force-reloading an active chat.

### Android Settings and cog-wheel controls

- Configurable default launch page, optional pinch-to-zoom, and configurable native cog placement (including the SpicyChat top-bar position).
- Native cog quick menu with **14 optional individual visibility switches** in Android Settings → Cog-wheel menu.
- **Android Settings**, **QoL Options**, and **Recover Black Screen** are always available so hidden actions can be restored safely.
- **Show all cog shortcuts** resets the visibility of optional actions without wiping other preferences.
- **Clear App Log** requires confirmation by default; **Ask before clearing App Log** is configurable.
- Menu actions include chat export, current-bot blocking, optional Chat Tabs, Command Palette, Focus Mode, Custom Pictures, Re-inject Scripts, quick/detailed chat-scroll checks, log tools, and refresh.
- Single-instance protection prevents duplicate native menus and Options routes from repeated taps.

### Diagnostics, performance and recovery

- Android Options can communicate with the live SpicyChat WebView for diagnostics and runtime state.
- App Log actions support Copy, native verified Export, and optionally confirmed Clear; log handling batches routine events and retains important warnings/errors.
- Renderer, stalled-load, blank/black-page, route, and visual health/recovery checks; **manual Recover Black Screen** remains available.
- Short background/resume transitions can skip redundant health checks when the page is healthy.
- Avoids injecting the entire QoL runtime twice into the same document; optional modules are loaded only when needed and with bounded native concurrency.
- Limits temporary diagnostic caches and scroll metadata while preserving real chat contents and draft state.
- Android capability information is provided to shared QoL so background/helper-tab-only features can be explicitly excluded.

### Storage, backup and files

- Android-compatible `chrome.storage.local` bridge plus support for larger stored QoL values.
- Native Save As, file pickers, and verified file exports, including generated blob/data-URL downloads and diagnostic logs.
- Downloaded QoL bundles have compatibility/integrity checks and fallback paths.
- **Archive Blocking Presets** can retrieve and cache its catalog through an Android-native bridge; a desktop extension service worker is not required for that supported feature.
- **Experimental GitHub Backup** was added to desktop QoL v0.2.88, but its background-worker backup/authorization flow is **not yet implemented as an Android-native backup provider**. Do not treat the corresponding Android Options controls as working mobile GitHub backup.
- Existing QoL Cloud and local backup/import/export behavior remain separate from experimental GitHub Backup.

### Chat interaction

- Native Android message long-press menu with compatible actions such as Copy, Edit, Report, Resend, Remove Image, and Select text.
- Android clipboard and temporary native text-selection handling.
- Shared QoL supplies the regular mobile composer and message-edit layout fixes; Android-specific overrides are limited where possible.
- Native quick-menu access to Focus/Immersive Mode, scrolling checks, and current-page actions.

### Multiple Android Chat Tabs

- Experimental and **disabled by default**.
- Uses one active WebView, with inactive tabs represented by lightweight URL/title/scroll/last-used state rather than multiple running WebViews.
- Supports separate conversations with the same chatbot, switching/closing tabs, local scroll restoration, and optional restoration after restart.
- Disabling the feature returns to normal single-WebView navigation without deleting actual SpicyChat conversations.

## Release workflow

- Local patch scripts modify only the relevant source files; **do not increase `version` in `android_app/pubspec.yaml` unless a new version is intentionally being prepared**.
- `release_next_android.bat` / `release_next_android.ps1` are separate helpers used when preparing a new visible release; they do not commit/push/publish by themselves.
- Stable Android releases are gated by a successful **Android Validate** run for the exact source commit being released; manual hotfixes also require matching validation.
- GitHub Actions builds and publishes the signed APK, SHA-256 checksums, and `update.json` metadata.
- A same-visible-version hotfix may replace the normal APK asset while increasing Android's **internal `versionCode`**. Older APKs may be retained as `_old`.
- On successful release, a workflow notifies/synchronizes the website's Android update metadata.
- Latest verified workflow results for **v0.1.46**: Android Validate **success**, Android Stable Release **success**, website notification **success**.

## Current testing and verification

- GitHub CI validation and signed APK release succeeded for v0.1.46. This does **not** by itself prove every behavior works on a physical Android device.
- Check Clear App Log confirmation in both settings states, the cog visibility switches, and the Show all reset action on-device.
- Check manual black-screen recovery and verify hiding optional shortcuts never removes access to Android Settings, QoL Options, or recovery.
- Check long-chat resume performance, scroll quick/detailed diagnostics, renderer recovery, keyboard/composer behavior, and native verified exports/imports.
- Check Archive Blocking Presets and current compatible downloaded QoL bundles after a fresh full page load.
- Check experimental Android Chat Tabs with same-bot multiple conversations and restore-after-restart behavior, if enabled.

## Planned / deferred

- Continue improving large-chat/WebView performance and safe recovery without forcing chat reloads or losing drafts.
- Improve Android chat-tab restoration (message anchor/draft support where safe) and reduce redundant Android-side layout overrides.
- Continue making Android Settings and cog shortcuts configurable when practical; preserve access to safety/recovery controls.
- Continue file backup/import/export robustness and local-data recovery safeguards.
- **Defer Android-native GitHub Backup integration** while the desktop feature is experimental; do not describe it as supported in Android until it has a secure native implementation.
- Recheck optional-module and native bridge compatibility whenever shared QoL changes its module map or desktop-only service requirements.

## Verification links

- [Android v0.1.46 published release](https://github.com/drachescript/spicychat-qol-android/releases/tag/v0.1.46)
- [Android validation run](https://github.com/drachescript/spicychat-qol-android/actions/runs/44653989605)
- [Android stable APK release run](https://github.com/drachescript/spicychat-qol-android/actions/runs/44654377582)
- [Android website notification run](https://github.com/drachescript/spicychat-qol-android/actions/runs/44655669679)
- [Shared QoL v0.2.88 release](https://github.com/drachescript/spicychat-qol-extension/releases/tag/v0.2.88)

*Updated against the published GitHub releases on November 19, 2026 (US Eastern; November 20 UTC).*
