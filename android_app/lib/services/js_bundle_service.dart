import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'qol_update_service.dart';

class JsBundleService extends ChangeNotifier {
  static const bundledExtensionVersion = '0.2.0';

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

  static const _bundledJsFiles = [
    'assets/js/generation-metadata-loader.js',
    'assets/js/card-token-auth-loader.js',
    'assets/js/exact-message-counts-loader.js',
    'assets/js/build-profile.js',
    'assets/js/core.js',
    'assets/js/compatibility.js',
    'assets/js/auto-afk.js',
    'assets/js/dom.js',
    'assets/js/runtime-kernel.js',
    'assets/js/runtime-plan.js',
    'assets/js/diagnostic-protocol.js',
    'assets/js/tab-diagnostics.js',
    'assets/js/quick-panel.js',
    'assets/js/accessibility.js',
    'assets/js/command-palette.js',
    'assets/js/tag-aliases.js',
    'assets/js/rc87-panel-position.js',
    'assets/js/soundscapes.js',
    'assets/js/opened-chats.js',
    'assets/js/tags-nsfw.js',
    'assets/js/premium-notifications.js',
    'assets/js/rc83-ui.js',
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
    'assets/js/rc86-bulk-block.js',
    'assets/js/bot-blocking.js',
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
    'assets/js/rc88-chat-stability.js',
    'assets/js/delete-guard.js',
    'assets/js/failed-message-helper.js',
    'assets/js/performance-mode.js',
    'assets/js/scroll-to-top.js',
    'assets/js/sidebar.js',
    'assets/js/footer-manager.js',
    'assets/js/chat-list.js',
    'assets/js/chat-organizer.js',
    'assets/js/saved-chat-actions.js',
    'assets/js/list-fill.js',
    'assets/js/rc87-fixes.js',
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
    Future<String> load(String remotePath, String bundledPath) async {
      if (remoteActive) {
        final remote = await qolUpdates.readDownloadedText(remotePath);
        if (remote != null) return remote;
      }
      return rootBundle.loadString(bundledPath);
    }

    var html = await load('options.html', 'assets/options/options.html');
    var css = await load('options.css', 'assets/options/options.css');
    final featureRegistry = await load(
      'feature-registry.js',
      'assets/options/feature-registry.js',
    );
    final optionsJs = await load('options.js', 'assets/options/options.js');

    final bundledCss =
        await rootBundle.loadString('assets/options/options.css');
    const mobileMarker = '/* Android WebView / phone layout */';
    final markerAt = bundledCss.indexOf(mobileMarker);
    if (markerAt >= 0 && !css.contains(mobileMarker)) {
      css = '$css\n\n${bundledCss.substring(markerAt)}';
    }

    final androidBridge =
        await rootBundle.loadString('assets/options/options-bridge.js');

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

    html = html.replaceFirst(
      RegExp(
        r'''<link[^>]+href=["']options\.css["'][^>]*>''',
        caseSensitive: false,
      ),
      '<style id="ds-android-options-css">${_safeStyle(css)}</style>',
    );

    html = html.replaceFirst(
      RegExp(
        r'''<script\s+src=["']feature-registry\.js["']\s*></script>''',
        caseSensitive: false,
      ),
      '<script>${_safeScript(featureRegistry)}</script>',
    );

    html = html.replaceAll(
      RegExp(
        r'''<script\s+src=["']options-bridge\.js["']\s*></script>''',
        caseSensitive: false,
      ),
      '',
    );

    html = html.replaceFirst(
      RegExp(
        r'''<script\s+src=["']options\.js["']\s*></script>''',
        caseSensitive: false,
      ),
      '<script>${_safeScript(androidBridge)}</script>\n'
      '<script>${_safeScript(optionsJs)}</script>',
    );

    _optionsHtml = html;

    _optionsSupportText.clear();
    for (final name in const ['CHANGELOG.md', 'features.md']) {
      _optionsSupportText[name] = await load(name, 'assets/options/$name');
    }
  }

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
