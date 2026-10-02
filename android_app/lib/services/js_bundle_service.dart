import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'qol_update_service.dart';

class JsBundleService extends ChangeNotifier {
  static const bundledExtensionVersion = '0.2.29';

  final QolUpdateService qolUpdates;

  String _cssContent = '';
  String _jsBundle = '';
  String _extensionVersion = bundledExtensionVersion;
  String _optionsHtml = '';
  final Map<String, String> _optionsSupportText = {};

  JsBundleService({required this.qolUpdates});

  String get cssContent => _cssContent;
  String get jsBundle => _jsBundle;
  String get extensionVersion => _extensionVersion;
  String get optionsHtml => _optionsHtml;

  static const _androidMainWorldBridgeFiles = [
    'content/generation-metadata-bridge.js',
    'content/exact-message-counts-bridge.js',
  ];

  static const _bundledJsFiles = [
    'assets/js/card-token-main.js',
    'assets/js/generation-metadata-loader.js',
    'assets/js/card-token-auth-loader.js',
    'assets/js/exact-message-counts-loader.js',
    'assets/js/build-profile.js',
    'assets/js/platform-capabilities.js',
    'assets/js/core.js',
    'assets/js/compatibility.js',
    'assets/js/auto-afk.js',
    'assets/js/dom.js',
    'assets/js/runtime-kernel.js',
    'assets/js/runtime-plan.js',
    'assets/js/diagnostic-protocol.js',
    'assets/js/tab-diagnostics.js',
    'assets/js/quick-panel.js',
    'assets/js/ui-layout-fixes.js',
    'assets/js/accessibility.js',
    'assets/js/command-palette.js',
    'assets/js/tag-aliases.js',
    'assets/js/listing-panel-position.js',
    'assets/js/soundscapes.js',
    'assets/js/opened-chats.js',
    'assets/js/tags-nsfw.js',
    'assets/js/premium-notifications.js',
    'assets/js/interface-runtime-tools.js',
    'assets/js/top-bar.js',
    'assets/js/chat-topbar.js',
    'assets/js/model-selector.js',
    'assets/js/generation-profiles.js',
    'assets/js/ad-banners.js',
    'assets/js/language-filter.js',
    'assets/js/creator-favorites.js',
    'assets/js/creator-following.js',
    'assets/js/favorite-bots.js',
    'assets/js/saved-lists-overlay.js',
    'assets/js/later-bots.js',
    'assets/js/recommendation-helpers.js',
    'assets/js/native-rating-helpers.js',
    'assets/js/cards.js',
    'assets/js/card-token-info.js',
    'assets/js/exact-message-counts.js',
    'assets/js/bot-archive.js',
    'assets/js/profile-export.js',
    'assets/js/bot-backup.js',
    'assets/js/creator-workspace.js',
    'assets/js/lorebook-filter.js',
    'assets/js/lorebook-search-filter.js',
    'assets/js/lorebook-tags.js',
    'assets/js/wiki-lorebook-importer.js',
    'assets/js/lorebook-backup.js',
    'assets/js/lorebook-workflow.js',
    'assets/js/smart-filter-presets.js',
    'assets/js/my-creations-view-memory.js',
    'assets/js/my-creations-filters.js',
    'assets/js/creation-audit.js',
    'assets/js/creator-writing-assistant.js',
    'assets/js/animation-control.js',
    'assets/js/bulk-blocking.js',
    'assets/js/bot-blocking.js',
    'assets/js/runtime-improvements.js',
    'assets/js/bot-organizer.js',
    'assets/js/card-workflow.js',
    'assets/js/chat-tags.js',
    'assets/js/chat-ui.js',
    'assets/js/chat-bookmarks.js',
    'assets/js/chat-search.js',
    'assets/js/focus-mode.js',
    'assets/js/character-qol-profiles.js',
    'assets/js/android-app.js',
    'assets/js/chat-bubbles.js',
    'assets/js/chat-backgrounds.js',
    'assets/js/formatting-toolbar.js',
    'assets/js/alternate-dialogue.js',
    'assets/js/lorebook-consistency.js',
    'assets/js/reply-instructions.js',
    'assets/js/rp-format-repair.js',
    'assets/js/auto-voice.js',
    'assets/js/bot-editor-snippets.js',
    'assets/js/bot-editor-history.js',
    'assets/js/bot-editor-actions.js',
    'assets/js/bot-editor-memory.js',
    'assets/js/creation-bulk-input.js',
    'assets/js/saved-snippets.js',
    'assets/js/story-day-tracker.js',
    'assets/js/rp-state-tracker.js',
    'assets/js/context-keeper.js',
    'assets/js/chat-nudges.js',
    'assets/js/selection-memory.js',
    'assets/js/message-options.js',
    'assets/js/memory-manager.js',
    'assets/js/text-replacements.js',
    'assets/js/translation.js',
    'assets/js/composer-control.js',
    'assets/js/chat-stability.js',
    'assets/js/delete-guard.js',
    'assets/js/failed-message-helper.js',
    'assets/js/performance-mode.js',
    'assets/js/scroll-to-top.js',
    'assets/js/sidebar.js',
    'assets/js/footer-manager.js',
    'assets/js/chat-list.js',
    'assets/js/chat-organizer.js',
    'assets/js/saved-chat-actions.js',
    'assets/js/pagination-tools.js',
    'assets/js/list-fill.js',
    'assets/js/my-creations-auto-load.js',
    'assets/js/personas.js',
    'assets/js/persona-organizer.js',
    'assets/js/lorebook-entries.js',
    'assets/js/moderation-warnings.js',
    'assets/js/chat-export.js',
    'assets/js/ooc.js',
    'assets/js/generation-metadata.js',
    'assets/js/update-toast.js',
    'assets/js/main.js',
  ];

  Future<void> loadAssets() async {
    final remoteActive = qolUpdates.hasDownloadedBundle;

    final remoteCssPath = remoteActive && qolUpdates.runtimeCssPaths.isNotEmpty
        ? qolUpdates.runtimeCssPaths.first
        : null;

    _cssContent = remoteCssPath == null
        ? await rootBundle.loadString('assets/css/content.css')
        : (await qolUpdates.readDownloadedText(remoteCssPath) ??
            await rootBundle.loadString('assets/css/content.css'));

    _extensionVersion = remoteActive && qolUpdates.activeVersion.isNotEmpty
        ? qolUpdates.activeVersion
        : bundledExtensionVersion;

    final bridge = await rootBundle.loadString('assets/js/bridge.js');
    final buffer = StringBuffer()
      ..writeln('// SpicyChat QOL Android bundled injection')
      ..writeln('// Shared QoL source may be overlaid by the in-app updater.')
      ..writeln(
        'window.__spicyChatQolBundledVersion = ${jsonEncode(_extensionVersion)};',
      )
      ..writeln('// === Android native bridge (APK-owned) ===')
      ..writeln(bridge)
      ..writeln();

    // Android does not have chrome-extension:// web-accessible-resource URLs.
    // Install the two MAIN-world network bridges directly before the normal
    // extension loaders run. The APK-owned runtime guard below makes those
    // loaders treat the already-installed bridge as successfully loaded, so
    // they still send their normal enabled/disabled control state without
    // making broken page-relative /content/*.js requests.
    for (final relative in _androidMainWorldBridgeFiles) {
      String? source;
      if (remoteActive) {
        source = await qolUpdates.readDownloadedText(relative);
      }
      source ??= await rootBundle.loadString(
        'assets/js/${_baseName(relative)}',
      );
      buffer
        ..writeln('// === Android MAIN-world bridge $relative ===')
        ..writeln(source)
        ..writeln();
    }

    // APK-owned compatibility/touch guard. Keep this inline so the normal
    // extension-to-Android sync cannot delete it as an unlisted JS asset.
    buffer
      ..writeln('// === Android runtime fixes (APK-owned) ===')
      ..writeln(r'''(() => {
  "use strict";

  if (window.__dsQolAndroidRuntimeFixesInstalled) return;
  window.__dsQolAndroidRuntimeFixesInstalled = true;

  // -------------------------------------------------------------------------
  // Android MAIN-world bridge loader compatibility
  // -------------------------------------------------------------------------
  //
  // The normal browser extension loads these files through chrome-extension://
  // web-accessible-resource URLs. Android injects the bridge source directly
  // before the shared extension bundle instead. When the normal loader later
  // appends its <script src="content/...-bridge.js">, treat that exact request
  // as already loaded so its normal load callback still sends control state.
  // This avoids page-relative /chat/.../content/*.js requests and MIME errors.

  const preinstalledBridgeMarkers = new Map([
    ["generation-metadata-bridge.js", "__DSQ_GENERATION_METADATA_BRIDGE__"],
    ["exact-message-counts-bridge.js", "__DSQ_EXACT_MESSAGE_COUNTS_BRIDGE__"]
  ]);

  const nativeAppendChild = Node.prototype.appendChild;
  Node.prototype.appendChild = function dsAndroidAppendChild(child) {
    if (child instanceof HTMLScriptElement) {
      const raw = String(child.getAttribute("src") || child.src || "");
      let name = "";
      try {
        name = new URL(raw, location.href).pathname.split("/").pop() || "";
      } catch {
        name = raw.split(/[/?#]/).filter(Boolean).pop() || "";
      }

      const marker = preinstalledBridgeMarkers.get(name.toLowerCase());
      if (marker && window[marker]) {
        queueMicrotask(() => {
          try {
            child.dispatchEvent(new Event("load"));
          } catch {}
        });
        return child;
      }
    }

    return nativeAppendChild.call(this, child);
  };

  // -------------------------------------------------------------------------
  // Touch tooltip / hold timing
  // -------------------------------------------------------------------------
  //
  // Android WebView can leave a CSS/React hover state active after a normal
  // tap. On Like/Favorite controls that makes tooltips such as "Unlike" appear
  // even though the user never deliberately held the button. Convert touch
  // tooltips into a real hold gesture: short taps stay tooltip-free; a tooltip
  // may become visible only after a deliberate hold.

  const TOOLTIP_HOLD_MS = 850;
  const TOOLTIP_MOVE_CANCEL_PX = 16;
  const TOOLTIP_SUPPRESS_CLASS = "ds-android-touch-tooltip-suppress";
  const TOOLTIP_STYLE_ID = "ds-android-touch-tooltip-guard-style";

  let tooltipTouch = null;
  let tooltipTimer = 0;

  function ensureTooltipStyle() {
    if (document.getElementById(TOOLTIP_STYLE_ID)) return;

    const style = document.createElement("style");
    style.id = TOOLTIP_STYLE_ID;
    style.textContent = `
      html.${TOOLTIP_SUPPRESS_CLASS} [role="tooltip"],
      html.${TOOLTIP_SUPPRESS_CLASS} [data-radix-tooltip-content],
      html.${TOOLTIP_SUPPRESS_CLASS} [data-slot="tooltip-content"],
      html.${TOOLTIP_SUPPRESS_CLASS} .react-aria-Tooltip,
      html.${TOOLTIP_SUPPRESS_CLASS} [class*="tooltip" i] {
        opacity: 0 !important;
        visibility: hidden !important;
        pointer-events: none !important;
      }

      html.${TOOLTIP_SUPPRESS_CLASS} [data-tooltip-content]::before,
      html.${TOOLTIP_SUPPRESS_CLASS} [data-tooltip-content]::after {
        content: none !important;
        opacity: 0 !important;
        visibility: hidden !important;
        pointer-events: none !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  }

  function suppressTouchTooltips() {
    ensureTooltipStyle();
    document.documentElement?.classList.add(TOOLTIP_SUPPRESS_CLASS);
  }

  function allowTouchTooltips() {
    document.documentElement?.classList.remove(TOOLTIP_SUPPRESS_CLASS);
  }

  function tooltipHostFromTarget(target) {
    if (!(target instanceof Element)) return null;

    const interactive = target.closest(
      "button, a, [role='button'], input, select, textarea"
    );
    if (!interactive) return null;

    return interactive.closest?.("[data-tooltip-content]") ||
      target.closest?.("[data-tooltip-content]") ||
      null;
  }

  function clearTooltipTimer() {
    if (tooltipTimer) {
      clearTimeout(tooltipTimer);
      tooltipTimer = 0;
    }
  }

  function cancelTooltipHold(pointerId = null) {
    if (
      tooltipTouch &&
      pointerId != null &&
      tooltipTouch.pointerId !== pointerId
    ) {
      return;
    }

    clearTooltipTimer();
    tooltipTouch = null;
    suppressTouchTooltips();
  }

  ensureTooltipStyle();

  document.addEventListener("pointerdown", event => {
    if (event.pointerType && !["touch", "pen"].includes(event.pointerType)) {
      return;
    }

    const host = tooltipHostFromTarget(event.target);
    if (!host) return;

    clearTooltipTimer();
    suppressTouchTooltips();

    tooltipTouch = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      host,
      held: false
    };

    tooltipTimer = window.setTimeout(() => {
      if (!tooltipTouch || tooltipTouch.pointerId !== event.pointerId) return;
      tooltipTouch.held = true;
      tooltipTimer = 0;
      allowTouchTooltips();
    }, TOOLTIP_HOLD_MS);
  }, true);

  document.addEventListener("pointermove", event => {
    if (!tooltipTouch || tooltipTouch.pointerId !== event.pointerId) return;

    const dx = event.clientX - tooltipTouch.startX;
    const dy = event.clientY - tooltipTouch.startY;
    if (Math.hypot(dx, dy) > TOOLTIP_MOVE_CANCEL_PX) {
      cancelTooltipHold(event.pointerId);
    }
  }, true);

  document.addEventListener("pointerup", event => {
    if (!tooltipTouch || tooltipTouch.pointerId !== event.pointerId) return;

    const wasHeld = tooltipTouch.held;
    clearTooltipTimer();
    tooltipTouch = null;

    // Keep the short-tap state suppressed so Android's sticky touch-hover cannot
    // make the tooltip appear a moment after the finger has already lifted.
    if (wasHeld) {
      setTimeout(suppressTouchTooltips, 160);
    } else {
      suppressTouchTooltips();
    }
  }, true);

  document.addEventListener("pointercancel", event => {
    cancelTooltipHold(event.pointerId);
  }, true);

  document.addEventListener("contextmenu", event => {
    if (!tooltipTouch || tooltipTouch.held) return;
    if (!tooltipHostFromTarget(event.target)) return;

    event.preventDefault();
    event.stopPropagation();
  }, true);

  console.log(
    `[DS Android] runtime fixes ready; touch tooltip hold=${TOOLTIP_HOLD_MS}ms`
  );
})();''')
      ..writeln();

    if (remoteActive) {
      for (final relative in qolUpdates.runtimeJsPaths) {
        final source = await qolUpdates.readDownloadedText(relative);
        if (source == null) {
          throw StateError(
            'Active QoL update is missing runtime file: $relative',
          );
        }
        buffer
          ..writeln('// === downloaded $relative ===')
          ..writeln(source)
          ..writeln();
      }
    } else {
      for (final path in _bundledJsFiles) {
        final source = await rootBundle.loadString(path);
        buffer
          ..writeln('// === $path ===')
          ..writeln(source)
          ..writeln();
      }
    }

    _jsBundle = buffer.toString();
    await _loadOptions(remoteActive: remoteActive);
    notifyListeners();
  }

  Future<void> reloadAfterQolUpdate() => loadAssets();

  Future<void> _loadOptions({required bool remoteActive}) async {
    Future<String?> loadOptional(
      String remotePath,
      String bundledPath,
    ) async {
      if (remoteActive) {
        final remote = await qolUpdates.readDownloadedText(remotePath);
        if (remote != null) return remote;
      }

      try {
        return await rootBundle.loadString(bundledPath);
      } catch (_) {
        return null;
      }
    }

    final htmlSource = await loadOptional(
      'options.html',
      'assets/options/options.html',
    );
    if (htmlSource == null || htmlSource.trim().isEmpty) {
      throw StateError('Android Options HTML is unavailable.');
    }

    var html = htmlSource;

    if (!html.contains('name="viewport"')) {
      html = html.replaceFirst(
        RegExp(
          r'''(<meta\s+charset=["'][^"']+["']\s*/?>)''',
          caseSensitive: false,
        ),
        r'''$1
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">''',
      );
    }

    final bundledBaseCss = await loadOptional(
      'options.css',
      'assets/options/options.css',
    );
    const mobileMarker = '/* Android WebView / phone layout */';
    String mobileCss = '';
    if (bundledBaseCss != null) {
      final markerAt = bundledBaseCss.indexOf(mobileMarker);
      if (markerAt >= 0) {
        mobileCss = bundledBaseCss.substring(markerAt);
      }
    }

    final stylesheetRegex = RegExp(
      r'''<link\b[^>]*\bhref=["']([^"']+\.css(?:[?#][^"']*)?)["'][^>]*>''',
      caseSensitive: false,
    );

    final stylesheetMatches =
        stylesheetRegex.allMatches(html).toList().reversed.toList();

    for (final match in stylesheetMatches) {
      final rawPath = match.group(1) ?? '';
      final relative = _cleanLocalOptionPath(rawPath);
      if (relative == null) continue;

      var css = await loadOptional(
        relative,
        'assets/options/${_baseName(relative)}',
      );

      if (css == null) {
        if (_baseName(relative).toLowerCase() == 'options.css') {
          throw StateError('Required Android Options stylesheet is missing.');
        }
        html = html.replaceRange(match.start, match.end, '');
        continue;
      }

      if (_baseName(relative).toLowerCase() == 'options.css' &&
          mobileCss.isNotEmpty &&
          !css.contains(mobileMarker)) {
        css = '$css\n\n$mobileCss';
      }

      html = html.replaceRange(
        match.start,
        match.end,
        '<style data-ds-options-source="${_htmlAttr(relative)}">'
        '${_safeStyle(css)}</style>',
      );
    }

    final androidBridge =
        await rootBundle.loadString('assets/options/options-bridge.js');

    final scriptRegex = RegExp(
      r'''<script\b[^>]*\bsrc=["']([^"']+\.js(?:[?#][^"']*)?)["'][^>]*>\s*</script>''',
      caseSensitive: false,
    );

    final scriptMatches =
        scriptRegex.allMatches(html).toList().reversed.toList();

    for (final match in scriptMatches) {
      final rawPath = match.group(1) ?? '';
      final relative = _cleanLocalOptionPath(rawPath);
      if (relative == null) continue;

      final name = _baseName(relative).toLowerCase();

      if (name == 'options-bridge.js') {
        html = html.replaceRange(match.start, match.end, '');
        continue;
      }

      var source = await loadOptional(
        relative,
        'assets/options/${_baseName(relative)}',
      );

      if (source == null) {
        if (name == 'options.js' || name == 'feature-registry.js') {
          throw StateError(
            'Required Android Options script is missing: $relative',
          );
        }
        html = html.replaceRange(match.start, match.end, '');
        continue;
      }

      if (name == 'options.js') {
        source = _androidCompatOptionsScript(source);
      }

      final prefix = name == 'options.js'
          ? '<script>${_safeScript(androidBridge)}</script>\n'
          : '';
      final suffix = name == 'options.js'
          ? '\n<script>${_safeScript(_androidOptionsRecoveryScript())}</script>'
          : '';

      html = html.replaceRange(
        match.start,
        match.end,
        '$prefix'
        '<script data-ds-options-source="${_htmlAttr(relative)}">'
        '${_safeScript(source)}</script>'
        '$suffix',
      );
    }

    _optionsHtml = html;

    _optionsSupportText.clear();
    for (final name in const ['CHANGELOG.md', 'features.md']) {
      final text = await loadOptional(name, 'assets/options/$name');
      if (text != null) {
        _optionsSupportText[name] = text;
      }
    }
  }

  /// The desktop Options script historically ran a long list of setup helpers
  /// directly at top-level. One browser-only helper throwing in Android WebView
  /// therefore prevented setupTabs() and load() from ever running, leaving the
  /// page stuck on "Version loading..." and showing uninitialized defaults.
  ///
  /// Guard only that startup block for Android. The shared extension source is
  /// left untouched and each helper still runs in its original order.
  String _androidCompatOptionsScript(String source) {
    const blockStartMarker = '\nreorderOptionsUi();\n';
    const blockEndMarker = 'setupControlCenterControls();\n';

    final startMarkerAt = source.indexOf(blockStartMarker);
    if (startMarkerAt >= 0) {
      final blockStart = startMarkerAt + 1;
      final endCallAt = source.indexOf(blockEndMarker, blockStart);
      if (endCallAt >= 0) {
        final blockEnd = endCallAt + blockEndMarker.length;
        final originalBlock = source.substring(blockStart, blockEnd);
        final guarded = <String>[];

        for (final rawLine in originalBlock.split('\n')) {
          final line = rawLine.trim();
          if (line.isEmpty) continue;
          guarded.add(
            'try { $line } catch (error) { '
            'console.error("[DS Android Options] startup helper failed", '
            '${jsonEncode(line)}, error); '
            '(window.__dsAndroidOptionsBootErrors ||= []).push({'
            'step: ${jsonEncode(line)}, error: String(error?.stack || error)'
            '}); }',
          );
        }

        source = source.replaceRange(
          blockStart,
          blockEnd,
          '${guarded.join('\n')}\n',
        );
      }
    }

    const bootBlock = '\nsetupTabs();\nload();\n';
    if (source.contains(bootBlock)) {
      source = source.replaceFirst(
        bootBlock,
        '''
try {
  setupTabs();
} catch (error) {
  console.error("[DS Android Options] setupTabs failed", error);
  (window.__dsAndroidOptionsBootErrors ||= []).push({
    step: "setupTabs()",
    error: String(error?.stack || error)
  });
}
window.__dsAndroidOptionsLoadStarted = true;
Promise.resolve()
  .then(() => load())
  .catch(error => {
    window.__dsAndroidOptionsLoadError = String(error?.stack || error);
    console.error("[DS Android Options] load failed", error);
  });
''',
      );
    }

    return source;
  }

  /// Final APK-owned safety net. If an unexpected future extension change
  /// aborts options.js before its normal boot block, run the two core boot
  /// functions from a separate script and always replace the placeholder
  /// version text with the active shared-QoL version.
  ///
  /// It also owns one bounded Android-only Changelog fallback. The extension
  /// still gets first chance to render CHANGELOG.md normally; if the Options
  /// WebView is still stuck on "Loading changelog...", Android reads the same
  /// active/bundled text through the native handler and renders a simple,
  /// readable fallback instead of leaving the page loading forever.
  String _androidOptionsRecoveryScript() {
    final version = jsonEncode(_extensionVersion);
    return '''
(() => {
  const activeVersion = $version;

  const applyVersionFallback = () => {
    const node = document.getElementById("versionText");
    if (!node) return;
    const text = String(node.textContent || "");
    if (!text.trim() || /version\\s+loading/i.test(text)) {
      node.textContent = "v" + activeVersion;
    }
  };

  const changelogStillLoading = host => {
    if (!host || host.dataset.loaded === "1") return false;
    const text = String(host.textContent || "").trim();
    return !text || /loading\\s+changelog/i.test(text);
  };

  const waitForFlutterBridge = (timeoutMs = 1800) => new Promise(resolve => {
    const started = Date.now();
    const poll = () => {
      if (window.flutter_inappwebview?.callHandler) {
        resolve(window.flutter_inappwebview);
        return;
      }
      if (Date.now() - started >= timeoutMs) {
        resolve(null);
        return;
      }
      setTimeout(poll, 50);
    };
    poll();
  });

  const renderChangelogFallback = text => {
    const host = document.getElementById("changelogContent");
    if (!changelogStillLoading(host)) return true;

    const source = String(text || "").trim();
    if (!source) return false;

    host.replaceChildren();
    host.dataset.loaded = "1";
    host.dataset.dsAndroidFallback = "1";

    const blocks = source
      .split(/\\n(?=##\\s+)/g)
      .map(block => block.trim())
      .filter(Boolean);

    for (const block of blocks) {
      const lines = block.split(/\\r?\\n/);
      const headingLine = String(lines.shift() || "").trim();
      const card = document.createElement("section");
      card.className = "card ds-android-changelog-fallback-card";
      card.style.cssText =
        "padding:12px 14px;margin:10px 0;border-radius:10px;" +
        "background:rgba(255,255,255,.035);" +
        "border:1px solid rgba(255,255,255,.08);";

      const heading = document.createElement("h3");
      heading.textContent = headingLine.replace(/^#+\\s*/, "") || "Changelog";
      heading.style.cssText = "margin:0 0 8px;font-size:16px;";
      card.appendChild(heading);

      let list = null;
      const flushList = () => {
        if (!list) return;
        card.appendChild(list);
        list = null;
      };

      for (const rawLine of lines) {
        const line = String(rawLine || "").trim();
        if (!line) {
          flushList();
          continue;
        }

        if (/^-\\s+/.test(line)) {
          list ??= document.createElement("ul");
          list.style.cssText = "margin:6px 0 0;padding-left:20px;";
          const item = document.createElement("li");
          item.textContent = line.replace(/^-\\s+/, "");
          item.style.cssText = "margin:4px 0;line-height:1.45;";
          list.appendChild(item);
          continue;
        }

        flushList();
        const paragraph = document.createElement("p");
        paragraph.textContent = line.replace(/^#+\\s*/, "");
        paragraph.style.cssText = "margin:6px 0;line-height:1.45;";
        card.appendChild(paragraph);
      }

      flushList();
      host.appendChild(card);
    }

    return host.childElementCount > 0;
  };

  const recoverChangelog = async () => {
    const host = document.getElementById("changelogContent");
    if (!changelogStillLoading(host)) return;

    const bridge = await waitForFlutterBridge();
    if (!bridge?.callHandler) {
      if (changelogStillLoading(host)) {
        host.textContent = "Could not load changelog.";
        host.dataset.dsAndroidFallback = "error";
      }
      return;
    }

    let text = null;
    try {
      text = await Promise.race([
        bridge.callHandler("optionsReadBundledText", "CHANGELOG.md"),
        new Promise(resolve => setTimeout(() => resolve(null), 2200))
      ]);
    } catch (error) {
      console.warn("[DS Android Options] Changelog fallback read failed", error);
    }

    if (!renderChangelogFallback(text) && changelogStillLoading(host)) {
      host.textContent = "Could not load changelog.";
      host.dataset.dsAndroidFallback = "error";
    }
  };

  queueMicrotask(async () => {
    if (!window.__dsAndroidOptionsLoadStarted) {
      try {
        if (typeof setupTabs === "function") setupTabs();
      } catch (error) {
        console.error("[DS Android Options] recovery setupTabs failed", error);
      }

      try {
        if (typeof load === "function") {
          window.__dsAndroidOptionsLoadStarted = true;
          await load();
        }
      } catch (error) {
        window.__dsAndroidOptionsLoadError = String(error?.stack || error);
        console.error("[DS Android Options] recovery load failed", error);
      }
    }

    applyVersionFallback();
  });

  setTimeout(applyVersionFallback, 500);
  setTimeout(applyVersionFallback, 1500);

  // Let the extension's own loadChangelog() win when it works. Only take over
  // after a bounded delay if Android is still showing the placeholder.
  setTimeout(() => { void recoverChangelog(); }, 1400);
})();
''';
  }

  String? _cleanLocalOptionPath(String source) {
    final raw = source.trim();
    if (raw.isEmpty) return null;

    final lower = raw.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('//') ||
        lower.startsWith('data:') ||
        lower.startsWith('blob:')) {
      return null;
    }

    final clean = raw.split(RegExp(r'[?#]')).first.trim();
    if (clean.isEmpty ||
        clean.startsWith('/') ||
        clean.contains('../') ||
        clean == '..') {
      return null;
    }

    return clean.replaceAll('\\', '/');
  }

  String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final at = normalized.lastIndexOf('/');
    return at < 0 ? normalized : normalized.substring(at + 1);
  }

  String _htmlAttr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _safeScript(String value) =>
      value.replaceAll(RegExp(r'</script', caseSensitive: false), r'<\/script');

  String _safeStyle(String value) =>
      value.replaceAll(RegExp(r'</style', caseSensitive: false), r'<\/style');

  String? optionsSupportText(String name) => _optionsSupportText[name];

  String get cssInjectionScript {
    final escaped = _cssContent
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '');

    return '''
      (function() {
        var style = document.getElementById('ds-qol-injected-css');
        if (!style) {
          style = document.createElement('style');
          style.id = 'ds-qol-injected-css';
          document.head.appendChild(style);
        }
        style.textContent = '$escaped';
      })();
    ''';
  }
}
