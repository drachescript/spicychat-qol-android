import 'dart:convert';

import 'package:flutter/services.dart';

/// Loads all JS and CSS assets from the bundle and provides
/// them as injectable strings for the WebView.
class JsBundleService {
  String _cssContent = '';
  String _jsBundle = '';
  String _extensionVersion = '0.1.9.928';

  String get cssContent => _cssContent;
  String get jsBundle => _jsBundle;
  String get extensionVersion => _extensionVersion;

  // Script injection order is generated from manifest.json by update_android.ps1.
  static const _jsFiles = [
    'assets/js/bridge.js',
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