import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android-wrapper-only UI preferences.
///
/// These settings do not live in the extension settings object because they
/// control Flutter/native overlay placement rather than SpicyChat page code.
class AndroidUiService extends ChangeNotifier {
  static const _controlsPositionKey = 'android.ui.controlsPosition';
  static const _defaultStartPageKey = 'android.ui.defaultStartPage';
  static const _zoomEnabledKey = 'android.ui.zoomEnabled';

  static const bottomRight = 'bottomRight';
  static const bottomLeft = 'bottomLeft';
  static const topRight = 'topRight';
  static const topLeft = 'topLeft';
  static const chatHeader = 'chatHeader';

  static const allowedPositions = <String>[
    bottomRight,
    chatHeader,
    topRight,
    topLeft,
    bottomLeft,
  ];

  // Keep these aligned with SpicyChat's current native sidebar routes.
  // Home is `/` on the current site (not `/home`).
  static const startPages = <String, String>{
    '/': 'Home',
    '/chats': 'Chats',
    '/favorite-bots': 'Favorites',
    '/recommended-bots': 'Recommended',
    '/personas': 'Personas',
    '/my-creations/chatbots': 'My Bots',
    '/my-creations/lorebooks': 'My Lorebooks',
    '/my-creations/groups': 'My Groups',
    '/creators/leaderboard': 'Creator Leaderboard',
    '/blocked-creators': 'Blocked Creators',
  };

  SharedPreferences? _prefs;
  String _controlsPosition = bottomRight;
  String _defaultStartPage = '/';
  bool _zoomEnabled = false;

  String get controlsPosition => _controlsPosition;
  String get defaultStartPage => _defaultStartPage;
  String get defaultStartUrl => 'https://spicychat.ai$_defaultStartPage';
  bool get zoomEnabled => _zoomEnabled;

  bool get controlsAtTop =>
      _controlsPosition == topRight || _controlsPosition == topLeft;

  bool get controlsInSpicyChatTopBar => _controlsPosition == chatHeader;

  // Compatibility alias for builds that used the older chat-only name.
  bool get controlsInChatHeader => controlsInSpicyChatTopBar;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final saved = _prefs?.getString(_controlsPositionKey);
      if (saved != null && allowedPositions.contains(saved)) {
        _controlsPosition = saved;
      }

      final savedStartPage = _prefs?.getString(_defaultStartPageKey);
      if (savedStartPage != null && startPages.containsKey(savedStartPage)) {
        _defaultStartPage = savedStartPage;
      }

      // Manual page zoom is opt-in for the dedicated Android app.
      _zoomEnabled = _prefs?.getBool(_zoomEnabledKey) ?? false;
    } catch (e) {
      debugPrint('[AndroidUI] Could not load UI preferences: $e');
    }
  }

  Future<void> setControlsPosition(String value) async {
    if (!allowedPositions.contains(value) || value == _controlsPosition) {
      return;
    }

    _controlsPosition = value;
    notifyListeners();

    try {
      await _prefs?.setString(_controlsPositionKey, value);
    } catch (e) {
      debugPrint('[AndroidUI] Could not save controls position: $e');
    }
  }

  Future<void> setZoomEnabled(bool value) async {
    if (_zoomEnabled == value) return;

    _zoomEnabled = value;
    notifyListeners();

    try {
      await _prefs?.setBool(_zoomEnabledKey, value);
    } catch (e) {
      debugPrint('[AndroidUI] Could not save zoom preference: $e');
    }
  }

  Future<void> setDefaultStartPage(String value) async {
    if (!startPages.containsKey(value) || value == _defaultStartPage) {
      return;
    }

    _defaultStartPage = value;
    notifyListeners();

    try {
      await _prefs?.setString(_defaultStartPageKey, value);
    } catch (e) {
      debugPrint('[AndroidUI] Could not save default start page: $e');
    }
  }

  static String labelForStartPage(String value) {
    final label = startPages[value] ?? value;
    return '$label  ($value)';
  }

  static String labelFor(String value) {
    switch (value) {
      case chatHeader:
        return 'SpicyChat top bar (recommended)';
      case topRight:
        return 'Top right / banner';
      case topLeft:
        return 'Top left / banner';
      case bottomLeft:
        return 'Bottom left';
      case bottomRight:
      default:
        return 'Bottom right (current)';
    }
  }
}
