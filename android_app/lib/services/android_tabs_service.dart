import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/android_chat_tab.dart';

/// Android-only lightweight chat-tab state.
///
/// Only one WebView remains alive. Inactive tabs are URL + scroll metadata, so
/// enabling tabs does not create multiple SpicyChat/extension runtimes.
class AndroidTabsService extends ChangeNotifier {
  static const _enabledKey = 'android.chatTabs.enabled';
  static const _restoreKey = 'android.chatTabs.restoreAfterRestart';
  static const _maxTabsKey = 'android.chatTabs.maxChatTabs';
  static const _tabsKey = 'android.chatTabs.savedTabs';
  static const _activeKey = 'android.chatTabs.activeTabId';

  static const homeId = 'home';
  static const homeUrl = 'https://spicychat.ai/';

  SharedPreferences? _prefs;

  bool _enabled = false;
  bool _restoreAfterRestart = true;
  int _maxChatTabs = 8;
  final List<AndroidChatTab> _tabs = <AndroidChatTab>[];
  String _activeTabId = homeId;
  String? _previousTabId;

  bool get enabled => _enabled;
  bool get restoreAfterRestart => _restoreAfterRestart;
  int get maxChatTabs => _maxChatTabs;
  List<AndroidChatTab> get tabs => List.unmodifiable(_tabs);
  String get activeTabId => _activeTabId;
  int get chatTabCount => _tabs.where((tab) => !tab.isHome).length;

  AndroidChatTab? get activeTab => tabById(_activeTabId);

  AndroidChatTab? get previousTab {
    final previous = _previousTabId;
    if (previous == null) return null;
    return tabById(previous);
  }

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _enabled = _prefs?.getBool(_enabledKey) ?? false;
      _restoreAfterRestart = _prefs?.getBool(_restoreKey) ?? true;
      _maxChatTabs = _normalizeMax(_prefs?.getInt(_maxTabsKey) ?? 8);

      if (_enabled && _restoreAfterRestart) {
        _loadSavedTabs();
      }
    } catch (e) {
      debugPrint('[AndroidTabs] Could not load preferences: $e');
    }

    _ensureHome();

    if (!_enabled || !_restoreAfterRestart) {
      _tabs
        ..clear()
        ..add(_newHome());
      _activeTabId = homeId;
      _previousTabId = null;
    }
  }

  static bool isSpicyChatUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == 'spicychat.ai' || host.endsWith('.spicychat.ai');
  }

  static bool isChatUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !isSpicyChatUrl(raw)) return false;
    return uri.path == '/chat' || uri.path.startsWith('/chat/');
  }

  static String normalizedRoute(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    return uri.replace(fragment: '').toString();
  }

  static List<String> _chatIdentityParts(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return const <String>[];
    final parts = uri.pathSegments;
    if (parts.isEmpty || parts.first != 'chat') return const <String>[];

    final identity = <String>[];
    if (parts.length >= 2) identity.add(parts[1]);
    if (parts.length >= 3) identity.add(parts[2]);
    return identity;
  }

  static bool sameChat(String a, String b) {
    final aa = _chatIdentityParts(a);
    final bb = _chatIdentityParts(b);
    if (aa.isEmpty || bb.isEmpty) return false;
    if (aa.first != bb.first) return false;

    // A temporary /chat/<bot> route can become the full conversation route
    // after navigation. It is safe to match a temporary tab to a resolved
    // conversation, but not to collapse two already-resolved conversations.
    if (aa.length == 1 || bb.length == 1) return true;
    return aa[1] == bb[1];
  }

  static bool _hasConversationId(String raw) {
    return _chatIdentityParts(raw).length >= 2;
  }

  AndroidChatTab _newHome() => AndroidChatTab(
        id: homeId,
        title: 'Home',
        url: homeUrl,
        isHome: true,
      );

  void _ensureHome() {
    final existing =
        _tabs.where((tab) => tab.isHome || tab.id == homeId).toList();
    if (existing.isEmpty) {
      _tabs.insert(0, _newHome());
      return;
    }

    final home = existing.first;
    home.id = homeId;
    home.isHome = true;
    home.title = 'Home';
    _tabs.removeWhere(
      (tab) => tab != home && (tab.isHome || tab.id == homeId),
    );
    if (_tabs.first != home) {
      _tabs.remove(home);
      _tabs.insert(0, home);
    }
  }

  AndroidChatTab? tabById(String id) {
    for (final tab in _tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  int _normalizeMax(int value) {
    const allowed = <int>[3, 5, 8, 12];
    return allowed.contains(value) ? value : 8;
  }

  void _loadSavedTabs() {
    final raw = _prefs?.getString(_tabsKey);
    if (raw == null || raw.trim().isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;

      _tabs.clear();
      for (final item in decoded) {
        if (item is! Map) continue;
        final tab = AndroidChatTab.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (tab.id.isEmpty || !isSpicyChatUrl(tab.url)) continue;
        _tabs.add(tab);
      }

      _ensureHome();
      _trimToLimit();

      final savedActive = _prefs?.getString(_activeKey);
      if (savedActive != null && tabById(savedActive) != null) {
        _activeTabId = savedActive;
      } else {
        _activeTabId = homeId;
      }
    } catch (e) {
      debugPrint('[AndroidTabs] Could not parse saved tabs: $e');
      _tabs
        ..clear()
        ..add(_newHome());
      _activeTabId = homeId;
    }
  }

  Future<void> _persistPreferences() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.setBool(_enabledKey, _enabled);
      await prefs.setBool(_restoreKey, _restoreAfterRestart);
      await prefs.setInt(_maxTabsKey, _maxChatTabs);
    } catch (e) {
      debugPrint('[AndroidTabs] Could not save preferences: $e');
    }
  }

  Future<void> _persistTabs() async {
    if (!_enabled || !_restoreAfterRestart) return;
    final prefs = _prefs;
    if (prefs == null) return;

    try {
      await prefs.setString(
        _tabsKey,
        jsonEncode(_tabs.map((tab) => tab.toJson()).toList()),
      );
      await prefs.setString(_activeKey, _activeTabId);
    } catch (e) {
      debugPrint('[AndroidTabs] Could not save tab state: $e');
    }
  }

  void _persistSoon() {
    unawaited(_persistPreferences());
    unawaited(_persistTabs());
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;

    _enabled = value;
    _previousTabId = null;
    _tabs
      ..clear()
      ..add(_newHome());
    _activeTabId = homeId;

    if (!value) {
      // Opt-out is clean: no stale tab state is kept behind the scenes.
      try {
        await _prefs?.remove(_tabsKey);
        await _prefs?.remove(_activeKey);
      } catch (_) {}
    }

    await _persistPreferences();
    notifyListeners();
  }

  Future<void> setRestoreAfterRestart(bool value) async {
    if (_restoreAfterRestart == value) return;
    _restoreAfterRestart = value;

    if (!value) {
      try {
        await _prefs?.remove(_tabsKey);
        await _prefs?.remove(_activeKey);
      } catch (_) {}
    } else {
      await _persistTabs();
    }

    await _persistPreferences();
    notifyListeners();
  }

  Future<void> setMaxChatTabs(int value) async {
    final normalized = _normalizeMax(value);
    if (_maxChatTabs == normalized) return;

    _maxChatTabs = normalized;
    _trimToLimit();
    await _persistPreferences();
    await _persistTabs();
    notifyListeners();
  }

  void _trimToLimit() {
    while (chatTabCount > _maxChatTabs) {
      final candidates = _tabs
          .where((tab) => !tab.isHome && tab.id != _activeTabId)
          .toList()
        ..sort((a, b) => a.lastUsedAtMs.compareTo(b.lastUsedAtMs));

      if (candidates.isEmpty) break;
      _tabs.remove(candidates.first);
    }
  }

  void _makeRoomForNewChat() {
    if (chatTabCount < _maxChatTabs) return;

    final candidates = _tabs
        .where((tab) => !tab.isHome && tab.id != _activeTabId)
        .toList()
      ..sort((a, b) => a.lastUsedAtMs.compareTo(b.lastUsedAtMs));

    if (candidates.isNotEmpty) {
      _tabs.remove(candidates.first);
      return;
    }

    final active = activeTab;
    if (active != null && !active.isHome) {
      _tabs.remove(active);
      _activeTabId = homeId;
    }
  }

  String _newTabId() => 'chat-${DateTime.now().microsecondsSinceEpoch}';

  String _fallbackChatTitle() => 'Chat ${chatTabCount + 1}';

  void _setActive(String id) {
    if (_activeTabId == id) {
      tabById(id)?.lastUsedAtMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }

    if (tabById(_activeTabId) != null) {
      _previousTabId = _activeTabId;
    }
    _activeTabId = id;
    tabById(id)?.lastUsedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  void adoptCurrentPage({
    required String url,
    required double scrollY,
    String? title,
  }) {
    if (!_enabled || !isSpicyChatUrl(url)) return;

    if (isChatUrl(url)) {
      final existing = _findChat(url);
      if (existing != null) {
        existing.url = normalizedRoute(url);
        existing.scrollY = scrollY;
        if (title != null && title.trim().isNotEmpty) {
          existing.title = title.trim();
        }
        _setActive(existing.id);
      } else {
        _makeRoomForNewChat();
        final tab = AndroidChatTab(
          id: _newTabId(),
          title: title?.trim().isNotEmpty == true
              ? title!.trim()
              : _fallbackChatTitle(),
          url: normalizedRoute(url),
          scrollY: scrollY,
        );
        _tabs.add(tab);
        _setActive(tab.id);
      }
    } else {
      final home = tabById(homeId)!;
      home.url = normalizedRoute(url);
      home.scrollY = scrollY;
      _setActive(homeId);
    }

    _persistSoon();
    notifyListeners();
  }

  AndroidChatTab? _findChat(String url) {
    final incomingHasConversation = _hasConversationId(url);

    for (final tab in _tabs) {
      if (tab.isHome) continue;

      // A bot-only temporary route is ambiguous if there are already full
      // conversations for that bot. Only reuse another temporary tab here.
      if (!incomingHasConversation && _hasConversationId(tab.url)) {
        continue;
      }

      if (sameChat(tab.url, url)) return tab;
    }
    return null;
  }

  AndroidTabRouteResult? handleRouteChange({
    required String previousUrl,
    required String newUrl,
    required double previousScrollY,
  }) {
    if (!_enabled || !isSpicyChatUrl(newUrl)) return null;

    final beforeId = _activeTabId;
    final previousActive = activeTab;

    if (previousActive != null &&
        isSpicyChatUrl(previousUrl) &&
        previousUrl != newUrl) {
      previousActive.url = normalizedRoute(previousUrl);
      previousActive.scrollY = previousScrollY;
      previousActive.lastUsedAtMs = DateTime.now().millisecondsSinceEpoch;
    }

    bool created = false;
    AndroidChatTab target;

    if (isChatUrl(newUrl)) {
      final incomingHasConversation = _hasConversationId(newUrl);
      final activeHasConversation = previousActive != null &&
          _hasConversationId(previousActive.url);

      if (previousActive != null &&
          !previousActive.isHome &&
          sameChat(previousActive.url, newUrl) &&
          // Going from a resolved conversation back to /chat/<bot> may be
          // the start of a different conversation. Keep the old tab intact
          // and create a temporary tab instead.
          !(!incomingHasConversation && activeHasConversation)) {
        target = previousActive;
        target.url = normalizedRoute(newUrl);
      } else {
        final existing = _findChat(newUrl);
        if (existing != null) {
          target = existing;
        } else {
          _makeRoomForNewChat();
          target = AndroidChatTab(
            id: _newTabId(),
            title: _fallbackChatTitle(),
            url: normalizedRoute(newUrl),
          );
          _tabs.add(target);
          created = true;
        }
      }
    } else {
      target = tabById(homeId)!;
      target.url = normalizedRoute(newUrl);
    }

    _setActive(target.id);
    _persistSoon();
    notifyListeners();

    return AndroidTabRouteResult(
      tab: target,
      activeTabChanged: beforeId != target.id,
      created: created,
    );
  }

  Future<void> updateActiveState({
    required String url,
    required double scrollY,
    String? title,
    bool notify = false,
  }) async {
    if (!_enabled) return;
    final tab = activeTab;
    if (tab == null || !isSpicyChatUrl(url)) return;

    tab.url = normalizedRoute(url);
    tab.scrollY = scrollY;

    final cleanedTitle = title?.trim() ?? '';
    if (!tab.isHome && cleanedTitle.isNotEmpty) {
      tab.title = cleanedTitle;
    }

    tab.lastUsedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _persistTabs();
    if (notify) notifyListeners();
  }

  AndroidChatTab? activateTab(String id) {
    if (!_enabled) return null;
    final tab = tabById(id);
    if (tab == null) return null;

    _setActive(id);
    _persistSoon();
    notifyListeners();
    return tab;
  }

  AndroidChatTab? closeTab(String id) {
    if (!_enabled || id == homeId) return activeTab;

    final wasActive = _activeTabId == id;
    _tabs.removeWhere((tab) => tab.id == id);

    if (wasActive) {
      final previous = _previousTabId;
      if (previous != null && tabById(previous) != null) {
        _activeTabId = previous;
      } else {
        _activeTabId = homeId;
      }
      _previousTabId = null;
    } else if (_previousTabId == id) {
      _previousTabId = null;
    }

    _persistSoon();
    notifyListeners();
    return activeTab;
  }

  void closeOtherChatTabs(String keepId) {
    if (!_enabled) return;

    _tabs.removeWhere(
      (tab) => !tab.isHome && tab.id != keepId,
    );

    if (tabById(_activeTabId) == null) {
      _activeTabId = homeId;
    }
    if (_previousTabId != null && tabById(_previousTabId!) == null) {
      _previousTabId = null;
    }

    _persistSoon();
    notifyListeners();
  }

  Future<void> clearTabs() async {
    _tabs
      ..clear()
      ..add(_newHome());
    _activeTabId = homeId;
    _previousTabId = null;

    try {
      await _prefs?.remove(_tabsKey);
      await _prefs?.remove(_activeKey);
    } catch (_) {}

    if (_enabled && _restoreAfterRestart) {
      await _persistTabs();
    }
    notifyListeners();
  }
}
