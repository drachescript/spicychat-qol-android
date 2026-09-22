import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import '../services/settings_service.dart';
import '../services/js_bundle_service.dart';
import '../services/app_log_service.dart';
import '../services/android_tabs_service.dart';
import '../services/android_ui_service.dart';
import '../models/android_chat_tab.dart';
import 'options_screen.dart';
import 'android_settings_screen.dart';

class _AndroidOptionsRouteGate {
  static bool _openOrOpening = false;
  static DateTime? _lastRequestAt;

  static bool tryAcquire() {
    final now = DateTime.now();
    final last = _lastRequestAt;

    // A process-wide guard prevents duplicate Options routes even if a laggy
    // WebView dispatches the same request through more than one bridge path or
    // WebViewScreen instance. Keep a tiny cooldown for delayed duplicate taps.
    if (_openOrOpening ||
        (last != null &&
            now.difference(last) < const Duration(milliseconds: 750))) {
      return false;
    }

    _openOrOpening = true;
    _lastRequestAt = now;
    return true;
  }

  static void release() {
    _openOrOpening = false;
  }
}

class _NativeFilePayload {
  final String filename;
  final Uint8List bytes;

  const _NativeFilePayload({required this.filename, required this.bytes});
}

class WebViewScreen extends StatefulWidget {
  final JsBundleService bundleService;

  const WebViewScreen({super.key, required this.bundleService});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WidgetsBindingObserver {
  InAppWebViewController? _webController;
  bool _isLoading = true;
  double _progress = 0;
  bool _optionsPageOpen = false;
  bool _quickMenuOpen = false;
  Key _webViewKey = UniqueKey();
  WebUri _initialWebUri = WebUri('https://spicychat.ai/');
  Timer? _healthTimer;
  DateTime? _loadStartedAt;
  DateTime? _lastLoadStopAt;
  DateTime? _lastRecoveryAt;
  DateTime? _lastSpaRouteAt;
  DateTime? _lastVisualGuardAt;
  String _lastKnownUrl = 'https://spicychat.ai/';
  String? _lastSpaRouteUrl;
  String? _lastInjectedDocumentToken;
  String? _injectionInProgressToken;
  int _blankHealthFailures = 0;
  int _routeHealthGeneration = 0;
  int _visualGuardGeneration = 0;
  int _lastProgressPercent = -1;
  bool _recoveringWebView = false;
  bool _appIsResumed = true;
  bool _messageLongPressMenuOpen = false;
  String? _androidMessageLongPressSource;
  double _lastScrollY = 0;
  final Map<String, double> _scrollByUrl = <String, double>{};
  String? _pendingTabSwitchId;
  double? _pendingTabRestoreScrollY;
  bool _switchingAndroidTab = false;
  bool _tabsEnabledAtSettingsOpen = false;

  // Android Save & Stay history repair.
  DateTime? _androidSaveStayStartedAt;
  String? _androidSaveStayEditorId;
  bool _androidSaveStayBackRepairArmed = false;
  bool _androidSaveStayBackRepairInProgress = false;
  bool _androidSaveStayBackSawNonEditor = false;
  Timer? _androidSaveStayBackRepairTimer;

  final Map<String, DateTime> _diagnosticCooldowns = <String, DateTime>{};
  final AppLogService _appLog = AppLogService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final androidUi = Provider.of<AndroidUiService>(
      context,
      listen: false,
    );
    _lastKnownUrl = androidUi.defaultStartUrl;
    _initialWebUri = WebUri(androidUi.defaultStartUrl);

    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (tabsService.enabled &&
        tabsService.restoreAfterRestart &&
        tabsService.activeTab != null) {
      final restored = tabsService.activeTab!;
      _lastKnownUrl = restored.url;
      _initialWebUri = WebUri(restored.url);
      _pendingTabSwitchId = restored.id;
      _pendingTabRestoreScrollY = restored.scrollY;
    }

    unawaited(_appLog.log('WebView', 'WebView screen created'));
    // Fallback watchdog only. Route/resume checks handle the fast path.
    // The old 20-second probe also walked body.innerText, which gets expensive
    // in long chats.
    _healthTimer = Timer.periodic(
      const Duration(seconds: 90),
      (_) => unawaited(_runWebViewHealthCheck(trigger: 'periodic')),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    _androidSaveStayBackRepairTimer?.cancel();
    unawaited(_appLog.log('WebView', 'WebView screen disposed'));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsResumed = state == AppLifecycleState.resumed;
    unawaited(_appLog.log('Lifecycle', 'App lifecycle changed to $state'));
    if (_appIsResumed) {
      _scheduleHealthCheck('app-resumed', delay: const Duration(seconds: 2));
      _scheduleVisualGuardForCurrentPage('app-resumed');
    } else {
      _routeHealthGeneration++;
      _visualGuardGeneration++;
      unawaited(_saveActiveAndroidTabState());
    }
  }

  void _scheduleHealthCheck(
    String trigger, {
    Duration delay = const Duration(seconds: 5),
  }) {
    final generation = ++_routeHealthGeneration;
    Future<void>.delayed(delay, () async {
      if (!mounted ||
          !_appIsResumed ||
          generation != _routeHealthGeneration) {
        return;
      }
      await _runWebViewHealthCheck(trigger: trigger);
    });
  }

  bool _shouldPersistDiagnostic(
    String key, {
    Duration cooldown = const Duration(seconds: 30),
  }) {
    final now = DateTime.now();
    final previous = _diagnosticCooldowns[key];
    if (previous != null && now.difference(previous) < cooldown) {
      return false;
    }
    _diagnosticCooldowns[key] = now;

    if (_diagnosticCooldowns.length > 120) {
      final cutoff = now.subtract(const Duration(minutes: 10));
      _diagnosticCooldowns.removeWhere((_, value) => value.isBefore(cutoff));
    }
    return true;
  }

  static String _normalizedSpicyChatPath(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return '';

    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    path = path.replaceFirst(
      RegExp(r'^/[a-z]{2}(?=/)', caseSensitive: false),
      '',
    );
    return path.isEmpty ? '/' : path;
  }

  static String? _botEditorIdFromUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !_isSpicyChat(uri)) return null;

    final path = _normalizedSpicyChatPath(raw);

    var match = RegExp(
      r'^/chatbot/([^/]+)/edit$',
      caseSensitive: false,
    ).firstMatch(path);
    if (match != null) {
      final value = Uri.decodeComponent(match.group(1) ?? '').trim();
      return value.isEmpty ? null : value.toLowerCase();
    }

    match = RegExp(
      r'^/chatbot/edit/([^/]+)$',
      caseSensitive: false,
    ).firstMatch(path);
    if (match != null) {
      final value = Uri.decodeComponent(match.group(1) ?? '').trim();
      return value.isEmpty ? null : value.toLowerCase();
    }

    if (path == '/chatbot/edit') {
      final value = (
        uri.queryParameters['id'] ??
        uri.queryParameters['chatbotId'] ??
        uri.queryParameters['characterId'] ??
        ''
      ).trim();
      return value.isEmpty ? null : value.toLowerCase();
    }

    return null;
  }

  void _clearAndroidSaveStayBackRepair() {
    _androidSaveStayBackRepairTimer?.cancel();
    _androidSaveStayBackRepairTimer = null;
    _androidSaveStayStartedAt = null;
    _androidSaveStayEditorId = null;
    _androidSaveStayBackRepairArmed = false;
    _androidSaveStayBackRepairInProgress = false;
    _androidSaveStayBackSawNonEditor = false;
  }

  void _armAndroidSaveStayBackRepair() {
    final editorId = _botEditorIdFromUrl(_lastKnownUrl);
    if (editorId == null) return;

    _androidSaveStayBackRepairTimer?.cancel();
    _androidSaveStayStartedAt = DateTime.now();
    _androidSaveStayEditorId = editorId;
    _androidSaveStayBackRepairArmed = true;
    _androidSaveStayBackRepairInProgress = false;
    _androidSaveStayBackSawNonEditor = false;

    unawaited(
      _appLog.log(
        'AndroidNavigation',
        'Save & Stay armed Android Back history repair for editor=$editorId',
      ),
    );
  }

  void _observeAndroidSaveStayNavigation(
    String previousUrl,
    String nextUrl,
  ) {
    final editorId = _androidSaveStayEditorId;
    if (editorId == null) return;

    final nextEditorId = _botEditorIdFromUrl(nextUrl);

    if (_androidSaveStayBackRepairInProgress) {
      if (nextEditorId == null) {
        _androidSaveStayBackSawNonEditor = true;
        return;
      }

      if (
        nextEditorId == editorId &&
        _androidSaveStayBackSawNonEditor
      ) {
        unawaited(_finishAndroidSaveStayDuplicateBack());
        return;
      }

      if (nextEditorId != editorId) {
        _clearAndroidSaveStayBackRepair();
      }
      return;
    }

    if (!_androidSaveStayBackRepairArmed) return;

    if (nextEditorId != null && nextEditorId != editorId) {
      _clearAndroidSaveStayBackRepair();
      return;
    }

    final started = _androidSaveStayStartedAt;
    final withinSaveWindow = started != null &&
        DateTime.now().difference(started) < const Duration(seconds: 12);

    final previousEditorId = _botEditorIdFromUrl(previousUrl);
    if (
      previousEditorId == editorId &&
      nextEditorId == null &&
      !withinSaveWindow
    ) {
      _clearAndroidSaveStayBackRepair();
    }
  }

  Future<void> _finishAndroidSaveStayDuplicateBack() async {
    if (!_androidSaveStayBackRepairInProgress) return;

    final controller = _webController;
    final editorId = _androidSaveStayEditorId;
    if (controller == null || editorId == null) {
      _clearAndroidSaveStayBackRepair();
      return;
    }

    _androidSaveStayBackRepairTimer?.cancel();
    _androidSaveStayBackRepairTimer = null;

    try {
      final current = await controller.getUrl();
      final currentEditorId =
          current == null ? null : _botEditorIdFromUrl(current.toString());

      if (currentEditorId == editorId && await controller.canGoBack()) {
        unawaited(
          _appLog.log(
            'AndroidNavigation',
            'Save & Stay duplicate editor history detected; applying second Back',
          ),
        );
        await controller.goBack();
      }
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('save-stay-back-repair')) {
        unawaited(
          _appLog.log(
            'AndroidNavigation',
            'Save & Stay Back repair failed',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
    } finally {
      _clearAndroidSaveStayBackRepair();
    }
  }

  Future<void> _handleAndroidSaveStayBack(
    InAppWebViewController controller,
  ) async {
    final editorId = _androidSaveStayEditorId;
    if (
      !_androidSaveStayBackRepairArmed ||
      _androidSaveStayBackRepairInProgress ||
      editorId == null ||
      _botEditorIdFromUrl(_lastKnownUrl) != editorId
    ) {
      await controller.goBack();
      return;
    }

    _androidSaveStayBackRepairArmed = false;
    _androidSaveStayBackRepairInProgress = true;
    _androidSaveStayBackSawNonEditor = false;

    _androidSaveStayBackRepairTimer?.cancel();
    _androidSaveStayBackRepairTimer = Timer(
      const Duration(milliseconds: 1200),
      () => unawaited(_finishAndroidSaveStayDuplicateBack()),
    );

    await controller.goBack();
  }

  static bool _isChatUrl(String raw) {
    final uri = Uri.tryParse(raw);
    return uri != null &&
        _isSpicyChat(uri) &&
        (uri.path == '/chat' || uri.path.startsWith('/chat/'));
  }

  /// Check whether the URL is a SpicyChat domain (for script injection)
  static bool _isSpicyChat(Uri url) {
    final host = url.host.toLowerCase();
    return host == 'spicychat.ai' || host.endsWith('.spicychat.ai');
  }

  /// Check whether the URL is an authentication provider (for navigation)
  static bool _isAuthDomain(Uri url) {
    final host = url.host.toLowerCase();
    bool isDomain(String d) => host == d || host.endsWith('.$d');

    return isDomain('kinde.com') ||
        isDomain('accounts.google.com') ||
        isDomain('apple.com') ||
        (isDomain('discord.com') && url.path.contains('oauth2'));
  }

  /// Verify the current WebView URL is allowed to access the native JS bridge.
  ///
  /// Most bridge calls originate from scripts that are already running inside
  /// the current SpicyChat document. Use the Flutter-side route cache first so
  /// opening a native control does not have to wait for WebView.getUrl().
  /// Long active chats can keep the renderer busy enough for getUrl() to take
  /// noticeably longer than it does on lightweight pages.
  Future<bool> _isCurrentUrlTrusted(InAppWebViewController controller) async {
    final cached = Uri.tryParse(_lastKnownUrl);
    if (cached != null && _isSpicyChat(cached)) {
      return true;
    }

    final url = await controller.getUrl();
    if (url == null || !_isSpicyChat(url)) {
      return false;
    }

    _lastKnownUrl = url.toString();
    return true;
  }

  Future<void> _syncAndroidChatHeaderGear() async {
    final controller = _webController;
    if (controller == null || !mounted) return;

    final androidUi = Provider.of<AndroidUiService>(
      context,
      listen: false,
    );
    final uri = Uri.tryParse(_lastKnownUrl);
    final path = uri?.path ?? '';
    final isHome =
        path == '/' || path == '/home' || path.startsWith('/home/');
    final isChat = _isChatUrl(_lastKnownUrl);
    final enabled =
        androidUi.controlsInSpicyChatTopBar && (isHome || isChat);

    try {
      await controller.evaluateJavascript(
        source: r'''(() => {
  const BUTTON_ID = "ds-android-native-header-settings";
  const STATE_KEY = "__dsAndroidTopBarOverlayState";
  const enabled = __ENABLED__;

  const removeButton = () => {
    document.getElementById(BUTTON_ID)?.remove();
  };

  const isVisible = element => {
    if (!(element instanceof HTMLElement)) return false;
    const r = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return r.width > 0 &&
      r.height > 0 &&
      style.display !== "none" &&
      style.visibility !== "hidden";
  };

  const textFor = element => [
    element.getAttribute?.("aria-label"),
    element.getAttribute?.("title"),
    element.getAttribute?.("data-testid"),
    element.textContent
  ]
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();

  const currentKind = () => {
    const path = location.pathname;
    if (path === "/" || path === "/home" || path.startsWith("/home/")) {
      return "home";
    }
    if (path === "/chat" || path.startsWith("/chat/")) {
      return "chat";
    }
    return "other";
  };

  const topActions = () => {
    const vw = Math.max(1, window.innerWidth || 1);

    return Array.from(
      document.querySelectorAll(
        'button, a[role="button"], [role="button"]'
      )
    )
      .filter(element => {
        if (element.id === BUTTON_ID) return false;
        if (!isVisible(element)) return false;

        const r = element.getBoundingClientRect();
        if (
          r.top < 0 ||
          r.top > 130 ||
          r.bottom > 180 ||
          r.left < vw * 0.40
        ) {
          return false;
        }

        return r.width >= 28 &&
          r.width <= 100 &&
          r.height >= 28 &&
          r.height <= 100;
      })
      .sort(
        (a, b) =>
          a.getBoundingClientRect().left -
          b.getBoundingClientRect().left
      );
  };

  const findHomeAnchor = () => {
    const actions = topActions();

    const explicit = actions.find(element => {
      const text = textFor(element);
      const svg = element.querySelector?.("svg");
      const svgClass = String(
        svg?.getAttribute?.("class") || ""
      ).toLowerCase();
      const svgLabel = String(
        svg?.getAttribute?.("aria-label") || ""
      ).toLowerCase();
      const shortText = String(element.textContent || "")
        .replace(/\s+/g, "")
        .trim();

      return /language|locale|globe|translate/.test(text) ||
        /globe|language|translate/.test(svgClass) ||
        /globe|language/.test(svgLabel) ||
        /^[A-Z]{2,3}$/.test(shortText);
    });

    return explicit || actions[0] || null;
  };

  const findChatAnchor = () => {
    const actions = topActions();

    const explicit = actions.find(element => {
      const text = textFor(element);
      const svg = element.querySelector?.("svg");
      const svgClass = String(
        svg?.getAttribute?.("class") || ""
      ).toLowerCase();
      const svgLabel = String(
        svg?.getAttribute?.("aria-label") || ""
      ).toLowerCase();

      return /rating|rate\b|thumb|like\b/.test(text) ||
        /thumb|like/.test(svgClass) ||
        /thumb|like/.test(svgLabel) ||
        !!element.querySelector?.(
          'svg[class*="thumb"], svg[data-lucide*="thumb"], ' +
          '[data-icon*="thumb"], [class*="thumb"]'
        );
    });

    return explicit || actions[0] || null;
  };

  const ensureButton = reason => {
    const kind = currentKind();

    if (!enabled || kind === "other") {
      removeButton();
      return false;
    }

    const anchor =
      kind === "chat"
        ? findChatAnchor()
        : findHomeAnchor();

    if (!anchor) {
      removeButton();
      return false;
    }

    const anchorRect = anchor.getBoundingClientRect();
    const size = 42;
    const gap = 8;
    const vw = Math.max(1, window.innerWidth || 1);

    let left = anchorRect.left - size - gap;
    left = Math.max(8, Math.min(left, vw - size - 8));

    let top =
      anchorRect.top +
      ((anchorRect.height - size) / 2);
    top = Math.max(4, top);

    let button = document.getElementById(BUTTON_ID);

    if (!button) {
      button = document.createElement("button");
      button.id = BUTTON_ID;
      button.type = "button";
      button.className = "ds-android-native-topbar-overlay";
      button.setAttribute("aria-label", "Android QoL settings");
      button.setAttribute("title", "SpicyChat QoL");

      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg"
             width="22" height="22" viewBox="0 0 24 24"
             fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round"
             aria-hidden="true">
          <circle cx="12" cy="12" r="3"></circle>
          <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06-2.83 2.83-.06-.06A1.65 1.65 0 0 0 15 19.4a1.65 1.65 0 0 0-1 .6 1.65 1.65 0 0 0-.4 1.08V21h-4v-.09A1.65 1.65 0 0 0 8.6 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06-2.83-2.83.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-.6-1 1.65 1.65 0 0 0-1.08-.4H3v-4h.09A1.65 1.65 0 0 0 4.6 8.6a1.65 1.65 0 0 0-.33-1.82l-.06-.06 2.83-2.83.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-.6A1.65 1.65 0 0 0 10.4 2.92V3h4v.09A1.65 1.65 0 0 0 15.4 4.6a1.65 1.65 0 0 0 1.82-.33l.06-.06 2.83 2.83-.06.06A1.65 1.65 0 0 0 19.4 9c.14.38.36.72.65 1 .29.28.67.43 1.08.4H21v4h-.09A1.65 1.65 0 0 0 19.4 15Z"></path>
        </svg>
      `;

      button.style.cssText = [
        "position:fixed",
        "display:flex",
        "align-items:center",
        "justify-content:center",
        "width:42px",
        "height:42px",
        "min-width:42px",
        "min-height:42px",
        "padding:0",
        "margin:0",
        "border:1px solid rgba(255,255,255,.28)",
        "border-radius:999px",
        "background:#6d36d9",
        "color:white",
        "box-shadow:0 4px 14px rgba(0,0,0,.35)",
        "z-index:2147483646",
        "box-sizing:border-box",
        "pointer-events:auto",
        "touch-action:manipulation",
        "user-select:none",
        "-webkit-user-select:none",
        "-webkit-tap-highlight-color:transparent"
      ].join(";");

      let armedPointerId = null;

      const consume = event => {
        if (event.cancelable) event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
      };

      button.addEventListener("pointerdown", event => {
        armedPointerId = event.pointerId;
        consume(event);
        try {
          button.setPointerCapture?.(event.pointerId);
        } catch {}
      }, true);

      button.addEventListener("pointerup", event => {
        const shouldOpen =
          armedPointerId === event.pointerId;
        armedPointerId = null;
        consume(event);

        if (!shouldOpen) return;

        window.flutter_inappwebview
          ?.callHandler("androidOpenQuickMenu", {
            tappedAt: Date.now(),
            route: location.pathname,
            kind: currentKind()
          })
          .catch(error => {
            console.warn(
              "[DS Android] Could not open native QoL menu",
              error
            );
          });
      }, true);

      button.addEventListener("pointercancel", event => {
        armedPointerId = null;
        consume(event);
      }, true);

      button.addEventListener("click", event => {
        consume(event);

        // Accessibility/keyboard activation only. Normal touch already opens
        // from pointerup and this synthetic click must never reach SpicyChat.
        if (event.detail === 0) {
          window.flutter_inappwebview
            ?.callHandler("androidOpenQuickMenu", {
            tappedAt: Date.now(),
            route: location.pathname,
            kind: currentKind()
          })
            .catch(() => {});
        }
      }, true);

      button.addEventListener("touchstart", consume, {
        capture: true,
        passive: false
      });
      button.addEventListener("touchend", consume, {
        capture: true,
        passive: false
      });
      button.addEventListener("contextmenu", consume, true);

      // Append to body, NOT beside/inside SpicyChat's language/rating button.
      // It is its own independent hit target.
      document.body.appendChild(button);
    }

    button.style.left = `${Math.round(left)}px`;
    button.style.top = `${Math.round(top)}px`;
    button.dataset.dsAndroidTopBarKind = kind;
    button.dataset.dsAndroidTopBarReason = String(reason || "");

    return true;
  };

  window[STATE_KEY] ||= {};
  const state = window[STATE_KEY];

  // Kill observers left by the older DOM-sibling implementation.
  window.__dsAndroidHeaderGearState?.observer?.disconnect?.();
  window.__dsAndroidTopBarGearState?.observer?.disconnect?.();

  state.enabled = enabled;
  state.ensure = ensureButton;
  state.remove = removeButton;

  if (!enabled) {
    removeButton();
    state.observer?.disconnect?.();
    state.observer = null;

    if (state.resizeHandler) {
      window.removeEventListener(
        "resize",
        state.resizeHandler,
        true
      );
      state.resizeHandler = null;
    }

    if (state.scrollHandler) {
      window.removeEventListener(
        "scroll",
        state.scrollHandler,
        true
      );
      state.scrollHandler = null;
    }

    return false;
  }

  let scheduled = false;
  const schedule = reason => {
    if (scheduled) return;
    scheduled = true;

    requestAnimationFrame(() => {
      scheduled = false;
      if (!window[STATE_KEY]?.enabled) return;
      ensureButton(reason);
    });
  };

  ensureButton("sync");

  if (!state.observer) {
    const observer = new MutationObserver(() => {
      schedule("mutation");
    });

    observer.observe(document.documentElement, {
      childList: true,
      subtree: true
    });

    state.observer = observer;
  }

  if (!state.resizeHandler) {
    state.resizeHandler = () => schedule("resize");
    window.addEventListener(
      "resize",
      state.resizeHandler,
      true
    );
  }

  if (!state.scrollHandler) {
    state.scrollHandler = () => schedule("scroll");
    window.addEventListener(
      "scroll",
      state.scrollHandler,
      true
    );
  }

  return true;
})()'''
          .replaceFirst('__ENABLED__', enabled ? 'true' : 'false'),
      );
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('android-topbar-overlay-button')) {
        unawaited(
          _appLog.log(
            'AndroidUI',
            'Could not synchronize independent SpicyChat top-bar QoL button',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

  FloatingActionButtonLocation _androidControlsLocation(
    String position,
  ) {
    switch (position) {
      case AndroidUiService.topRight:
        return FloatingActionButtonLocation.endTop;
      case AndroidUiService.topLeft:
        return FloatingActionButtonLocation.startTop;
      case AndroidUiService.bottomLeft:
        return FloatingActionButtonLocation.startFloat;
      case AndroidUiService.bottomRight:
      default:
        return FloatingActionButtonLocation.endFloat;
    }
  }

  @override
  Widget build(BuildContext context) {
    final androidTabs = context.watch<AndroidTabsService>();
    final androidUi = context.watch<AndroidUiService>();
    final currentUri = Uri.tryParse(_lastKnownUrl);
    final currentPath = currentUri?.path ?? '';
    final isHomeTopBarRoute =
        currentPath == '/' ||
        currentPath == '/home' ||
        currentPath.startsWith('/home/');
    final useSpicyChatTopBarGear =
        androidUi.controlsInSpicyChatTopBar &&
        (isHomeTopBarRoute || _isChatUrl(_lastKnownUrl));

    return Scaffold(
      body: SafeArea(
        child: PopScope(
          canPop: false,
          onPopInvoked: (didPop) async {
            if (didPop) return;

            final tabsService = Provider.of<AndroidTabsService>(
              context,
              listen: false,
            );
            if (tabsService.enabled) {
              final active = tabsService.activeTab;
              final previous = tabsService.previousTab;
              if (active != null && !active.isHome && previous != null) {
                await _switchToAndroidTab(previous);
                return;
              }
            }

            if (_webController != null) {
              final canGoBack = await _webController!.canGoBack();
              if (canGoBack) {
                await _handleAndroidSaveStayBack(_webController!);
                return;
              }
            }
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Stack(
            children: [
              InAppWebView(
                key: _webViewKey,
                initialUrlRequest: URLRequest(url: _initialWebUri),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  supportMultipleWindows: true,
                  useShouldOverrideUrlLoading: true,
                  // Auto Voice / Auto TTS is started by JavaScript after an
                  // incoming message, not by a direct tap on the audio player.
                  // Android WebView otherwise treats that as autoplay and can
                  // silently block playback even though voice generation works.
                  mediaPlaybackRequiresUserGesture: false,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  // Only allow HTTPS content — no mixed HTTP resources
                  mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                  // Enable wide viewport for better mobile experience
                  useWideViewPort: true,
                  loadWithOverviewMode: true,
                  // Manual page zoom is Android-only and opt-in.
                  supportZoom: androidUi.zoomEnabled,
                  builtInZoomControls: androidUi.zoomEnabled,
                  displayZoomControls: false,
                  // Keep SpicyChat on its normal mobile-browser UI path.
                  // A later build exposed the raw Android WebView UA and the
                  // site's native navigation menu could disappear. QoL itself
                  // still gets explicit Android-app capability markers below.
                  userAgent:
                      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                  // Allow file access
                  allowFileAccess: true,
                  allowContentAccess: true,
                  // Cache
                  cacheEnabled: true,
                  cacheMode: CacheMode.LOAD_DEFAULT,
                  // Third-party cookies (needed for auth)
                  thirdPartyCookiesEnabled: true,
                ),
                onWebViewCreated: (controller) {
                  _webController = controller;
                  _lastInjectedDocumentToken = null;
                  _injectionInProgressToken = null;
                  _lastProgressPercent = -1;
                  _registerJsHandlers(controller);
                  unawaited(
                    _appLog.log(
                      'WebView',
                      'Native WebView created for $_lastKnownUrl',
                    ),
                  );
                },
                onLoadStart: (controller, url) {
                  _loadStartedAt = DateTime.now();
                  _lastProgressPercent = -1;
                  _lastSpaRouteUrl = null;
                  _lastSpaRouteAt = null;
                  if (url != null) {
                    final nextUrl = url.toString();
                    final previousUrl = _lastKnownUrl;
                    final previousScroll =
                        _scrollByUrl[previousUrl] ?? _lastScrollY;
                    _observeAndroidSaveStayNavigation(
                      previousUrl,
                      nextUrl,
                    );
                    _lastKnownUrl = nextUrl;

                    if (!_switchingAndroidTab && previousUrl != nextUrl) {
                      unawaited(
                        _handleAndroidTabRouteChange(
                          previousUrl: previousUrl,
                          newUrl: nextUrl,
                          previousScrollY: previousScroll,
                        ),
                      );
                    }
                  }
                  _blankHealthFailures = 0;
                  unawaited(
                    _appLog.log(
                      'Navigation',
                      'Load started: ${url ?? _lastKnownUrl}',
                    ),
                  );
                  if (mounted) {
                    setState(() {
                      _isLoading = true;
                    });
                  }
                },
                onLoadStop: (controller, url) async {
                  if (url != null) {
                    _lastKnownUrl = url.toString();
                    _initialWebUri = url;
                  }
                  _loadStartedAt = null;
                  _lastLoadStopAt = DateTime.now();
                  _blankHealthFailures = 0;
                  if (mounted && (_isLoading || _progress < 1)) {
                    setState(() {
                      _isLoading = false;
                      _progress = 1;
                    });
                  }

                  // Android can fire onLoadStop several times for the same
                  // document. _injectScripts now skips duplicate documents.
                  try {
                    await _injectScripts(controller);
                  } catch (e, stackTrace) {
                    unawaited(
                      _appLog.log(
                        'Injection',
                        'QoL injection failed on ${url ?? _lastKnownUrl}',
                        level: 'ERROR',
                        error: e,
                        stackTrace: stackTrace,
                      ),
                    );
                  }

                  _scheduleHealthCheck(
                    'post-load',
                    delay: const Duration(seconds: 5),
                  );
                  _scheduleVisualGuardForCurrentPage('post-load');
                  _restorePendingAndroidTabScroll(controller);
                  _scheduleActiveAndroidTabTitleRefresh();
                  unawaited(_syncAndroidChatHeaderGear());
                  unawaited(
                    controller.evaluateJavascript(
                      source:
                          'window.__dsAndroidListingIdentitySchedule?.("load-stop");',
                    ),
                  );
                },
                onUpdateVisitedHistory: (controller, url, androidIsReload) {
                  final route = url?.toString() ?? _lastKnownUrl;
                  final previousRoute = _lastKnownUrl;
                  final previousScroll =
                      _scrollByUrl[previousRoute] ?? _lastScrollY;
                  final now = DateTime.now();
                  final duplicate = _lastSpaRouteUrl == route &&
                      _lastSpaRouteAt != null &&
                      now.difference(_lastSpaRouteAt!) <
                          const Duration(milliseconds: 1200);

                  _observeAndroidSaveStayNavigation(
                    previousRoute,
                    route,
                  );
                  _lastKnownUrl = route;
                  _blankHealthFailures = 0;
                  if (duplicate) return;

                  _lastSpaRouteUrl = route;
                  _lastSpaRouteAt = now;

                  if (!_switchingAndroidTab && previousRoute != route) {
                    unawaited(
                      _handleAndroidTabRouteChange(
                        previousUrl: previousRoute,
                        newUrl: route,
                        previousScrollY: previousScroll,
                      ),
                    );
                  }

                  _scheduleActiveAndroidTabTitleRefresh();
                  unawaited(_syncAndroidChatHeaderGear());
                  unawaited(
                    controller.evaluateJavascript(
                      source:
                          'window.__dsAndroidListingIdentitySchedule?.("spa-route");',
                    ),
                  );

                  if (mounted) {
                    final ui = Provider.of<AndroidUiService>(
                      context,
                      listen: false,
                    );
                    if (ui.controlsInSpicyChatTopBar) {
                      setState(() {});
                    }
                  }

                  if (kDebugMode) {
                    debugPrint(
                      '[Navigation] SPA route: $route; reload=$androidIsReload',
                    );
                  }

                  // SPA navigation keeps the same document/QoL runtime.
                  _scheduleHealthCheck(
                    'history-route',
                    delay: const Duration(seconds: 6),
                  );
                  _scheduleVisualGuardForCurrentPage('history-route');
                },
                onScrollChanged: (controller, x, y) {
                  final tabsService = Provider.of<AndroidTabsService>(
                    context,
                    listen: false,
                  );
                  if (!tabsService.enabled) return;

                  _lastScrollY = y.toDouble();
                  _scrollByUrl[_lastKnownUrl] = _lastScrollY;
                },
                onProgressChanged: (controller, progress) {
                  // Chromium often emits the same progress value twice.
                  if (progress == _lastProgressPercent) return;
                  _lastProgressPercent = progress;

                  final next = progress / 100;
                  final meaningfulStep =
                      (next - _progress).abs() >= 0.05 || progress >= 100;
                  if (mounted && meaningfulStep) {
                    setState(() {
                      _progress = next;
                    });
                  }
                },
                onReceivedError: (controller, request, error) {
                  final key =
                      'resource:${request.url.host}:${error.type.toString()}';
                  if (_shouldPersistDiagnostic(key)) {
                    unawaited(
                      _appLog.log(
                        'WebViewError',
                        'Resource error: ${request.url} | ${error.type} | ${error.description}',
                        level: 'WARN',
                      ),
                    );
                  }
                },
                onReceivedHttpError: (controller, request, errorResponse) {
                  final key =
                      'http:${request.url.host}:${request.url.path}:${errorResponse.statusCode}';
                  if (_shouldPersistDiagnostic(key)) {
                    unawaited(
                      _appLog.log(
                        'WebViewHttp',
                        'HTTP error: ${request.url} | status=${errorResponse.statusCode}',
                        level: 'WARN',
                      ),
                    );
                  }
                },
                onRenderProcessUnresponsive: (controller, url) async {
                  if (_shouldPersistDiagnostic(
                    'renderer-unresponsive',
                    cooldown: const Duration(seconds: 45),
                  )) {
                    unawaited(
                      _appLog.log(
                        'Renderer',
                        'Android WebView renderer became unresponsive; url=${url ?? _lastKnownUrl}',
                        level: 'WARN',
                      ),
                    );
                  }
                  // Do not kill it automatically; SpicyChat/large JS tasks can
                  // recover on their own and termination would lose page state.
                  return null;
                },
                onRenderProcessResponsive: (controller, url) async {
                  unawaited(
                    _appLog.log(
                      'Renderer',
                      'Android WebView renderer responsive again; url=${url ?? _lastKnownUrl}',
                    ),
                  );
                  return null;
                },
                onRenderProcessGone: (controller, detail) {
                  unawaited(
                    _appLog.log(
                      'Renderer',
                      'Android WebView renderer exited; didCrash=${detail.didCrash}, priority=${detail.rendererPriorityAtExit}',
                      level: 'ERROR',
                    ),
                  );
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _recoverWebView(
                      reason: 'Android WebView renderer exited',
                      useController: false,
                    );
                  });
                },
                // Extension helpers sometimes use target="_blank" or window.open()
                // for bot/profile links. Android WebView treats those as a new
                // window and can otherwise hand them to the system browser.
                // Keep SpicyChat-owned destinations inside this same WebView.
                onCreateWindow: (controller, createWindowAction) async {
                  final url = createWindowAction.request.url;
                  if (url == null || url.toString().isEmpty) {
                    if (_shouldPersistDiagnostic('new-window:no-url')) {
                      unawaited(
                        _appLog.log(
                          'Navigation',
                          'Blocked empty Android WebView new-window request',
                          level: 'WARN',
                        ),
                      );
                    }
                    return false;
                  }

                  if (_isSpicyChat(url)) {
                    unawaited(
                      _appLog.log(
                        'Navigation',
                        'Keeping SpicyChat new-window navigation in app: $url',
                      ),
                    );
                    try {
                      await controller.loadUrl(
                        urlRequest: URLRequest(url: url),
                      );
                    } catch (e, stackTrace) {
                      unawaited(
                        _appLog.log(
                          'Navigation',
                          'Could not open SpicyChat new-window URL in app: $url',
                          level: 'ERROR',
                          error: e,
                          stackTrace: stackTrace,
                        ),
                      );
                    }
                    // We intentionally reject creation of a second WebView:
                    // the destination has already been loaded in the main one.
                    return false;
                  }

                  // Authentication and genuinely external popups keep using the
                  // platform/browser flow instead of spawning hidden WebViews.
                  unawaited(
                    _appLog.log(
                      'Navigation',
                      'Opening popup/new-window URL outside WebView: $url',
                    ),
                  );
                  try {
                    await launchUrl(
                      url,
                      mode: LaunchMode.externalApplication,
                    );
                  } catch (e, stackTrace) {
                    unawaited(
                      _appLog.log(
                        'Navigation',
                        'Could not launch popup URL externally: $url',
                        level: 'WARN',
                        error: e,
                        stackTrace: stackTrace,
                      ),
                    );
                  }
                  return false;
                },

                // Handle navigation — only allow SpicyChat and Auth domains in WebView
                shouldOverrideUrlLoading:
                    (controller, navigationAction) async {
                  final url = navigationAction.request.url;
                  if (url != null) {
                    if (_isSpicyChat(url) || _isAuthDomain(url)) {
                      if (kDebugMode) {
                        debugPrint('[Navigation] Allow navigation: $url');
                      }
                      return NavigationActionPolicy.ALLOW;
                    }
                    // Open external links (Google login, etc.) in system browser
                    unawaited(
                      _appLog.log(
                        'Navigation',
                        'Opening external URL outside WebView: $url',
                      ),
                    );
                    try {
                      await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      );
                    } catch (e) {
                      debugPrint('[WebView] Could not launch URL: $url — $e');
                    }
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onConsoleMessage: (controller, consoleMessage) {
                  final message = consoleMessage.message;
                  final level = consoleMessage.messageLevel.toString();
                  if (kDebugMode) {
                    debugPrint('[WebView Console] $level: $message');
                  }
                  final lower = level.toLowerCase();
                  if (lower.contains('error') ||
                      lower.contains('warning') ||
                      message.contains('DragonScript') ||
                      message.contains('[DS')) {
                    final normalized = message.length > 180
                        ? message.substring(0, 180)
                        : message;
                    final key = 'console:$level:$normalized';
                    if (_shouldPersistDiagnostic(key)) {
                      unawaited(
                        _appLog.log(
                          'Console',
                          '$level: $message',
                          level: lower.contains('error') ? 'ERROR' : 'WARN',
                        ),
                      );
                    }
                  }
                },
              ),

              // Loading progress bar
              if (_isLoading)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.deepPurpleAccent,
                    ),
                    minHeight: 3,
                  ),
                ),
            ],
          ),
        ),
      ),

      // Floating Android controls. Their location is wrapper-only and can
      // be customized from Android Settings. Bottom-right remains the default.
      floatingActionButtonLocation:
          _androidControlsLocation(
            useSpicyChatTopBarGear
                ? AndroidUiService.bottomRight
                : androidUi.controlsPosition,
          ),
      floatingActionButton:
          (useSpicyChatTopBarGear && !androidTabs.enabled)
              ? null
              : Padding(
        padding: androidUi.controlsAtTop
            ? const EdgeInsets.only(top: 58)
            : const EdgeInsets.only(bottom: 100),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (androidTabs.enabled) ...[
              FloatingActionButton(
                heroTag: 'android-chat-tabs',
                mini: true,
                backgroundColor: Colors.deepPurple.withValues(alpha: 0.9),
                onPressed: _showAndroidTabs,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.tab, color: Colors.white, size: 20),
                    Positioned(
                      right: -9,
                      top: -9,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 17),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          '${androidTabs.chatTabCount}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (!useSpicyChatTopBarGear)
              FloatingActionButton(
                heroTag: 'android-qol-menu',
                mini: true,
                backgroundColor: Colors.deepPurple.withValues(alpha: 0.9),
                onPressed: () {
                  unawaited(
                    _showQuickMenu(
                      requestedAt: DateTime.now(),
                      source: 'floating-fab',
                    ),
                  );
                },
                child: const Icon(Icons.settings, color: Colors.white, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _readAndroidTabTitle() async {
    final controller = _webController;
    if (controller == null) return null;

    try {
      final value = await controller.evaluateJavascript(
        source: r'''(() => {
          const title = String(document.title || '').trim();
          if (!title) return '';
          return title
            .replace(/\s*[|–—-]\s*SpicyChat.*$/i, '')
            .replace(/^SpicyChat\s*[|–—-]\s*/i, '')
            .trim();
        })()''',
      );

      final title = value?.toString().trim() ?? '';
      if (title.isEmpty || title.toLowerCase() == 'spicychat') {
        return null;
      }
      return title.length > 80 ? title.substring(0, 80) : title;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveActiveAndroidTabState() async {
    if (!mounted) return;

    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (!tabsService.enabled) return;

    final title = await _readAndroidTabTitle();
    await tabsService.updateActiveState(
      url: _lastKnownUrl,
      scrollY: _scrollByUrl[_lastKnownUrl] ?? _lastScrollY,
      title: title,
    );
  }

  void _scheduleActiveAndroidTabTitleRefresh() {
    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (!tabsService.enabled) return;

    Future<void>.delayed(const Duration(milliseconds: 900), () async {
      if (!mounted || !tabsService.enabled) return;
      final title = await _readAndroidTabTitle();
      if (title == null) return;
      await tabsService.updateActiveState(
        url: _lastKnownUrl,
        scrollY: _scrollByUrl[_lastKnownUrl] ?? _lastScrollY,
        title: title,
        notify: true,
      );
    });
  }

  Future<void> _handleAndroidTabRouteChange({
    required String previousUrl,
    required String newUrl,
    required double previousScrollY,
  }) async {
    if (!mounted) return;

    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (!tabsService.enabled || _switchingAndroidTab) return;

    final result = tabsService.handleRouteChange(
      previousUrl: previousUrl,
      newUrl: newUrl,
      previousScrollY: previousScrollY,
    );
    if (result == null) return;

    if (result.activeTabChanged && !result.created && result.tab.scrollY > 0) {
      final targetId = result.tab.id;
      final restoreY = result.tab.scrollY;
      Future<void>.delayed(const Duration(milliseconds: 850), () async {
        if (!mounted ||
            tabsService.activeTabId != targetId ||
            _switchingAndroidTab) {
          return;
        }
        try {
          await _webController?.evaluateJavascript(
            source: 'window.scrollTo(0, ${restoreY.round()});',
          );
        } catch (_) {}
      });
    }
  }

  void _restorePendingAndroidTabScroll(
    InAppWebViewController controller,
  ) {
    final tabId = _pendingTabSwitchId;
    final restoreY = _pendingTabRestoreScrollY;
    if (tabId == null) return;

    _pendingTabSwitchId = null;
    _pendingTabRestoreScrollY = null;

    Future<void>.delayed(const Duration(milliseconds: 700), () async {
      if (!mounted) return;

      final tabsService = Provider.of<AndroidTabsService>(
        context,
        listen: false,
      );
      if (!tabsService.enabled || tabsService.activeTabId != tabId) {
        _switchingAndroidTab = false;
        return;
      }

      if (restoreY != null && restoreY > 0) {
        try {
          await controller.evaluateJavascript(
            source: 'window.scrollTo(0, ${restoreY.round()});',
          );
        } catch (_) {}
      }

      _lastScrollY = restoreY ?? 0;
      _scrollByUrl[_lastKnownUrl] = _lastScrollY;
      _switchingAndroidTab = false;
      _scheduleActiveAndroidTabTitleRefresh();
    });
  }

  Future<void> _switchToAndroidTab(
    AndroidChatTab tab, {
    bool alreadyActivated = false,
  }) async {
    if (!mounted) return;

    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (!tabsService.enabled) return;

    final controller = _webController;
    if (controller == null) return;

    if (!alreadyActivated &&
        tabsService.activeTabId == tab.id &&
        AndroidTabsService.normalizedRoute(_lastKnownUrl) ==
            AndroidTabsService.normalizedRoute(tab.url)) {
      return;
    }

    if (!alreadyActivated) {
      await _saveActiveAndroidTabState();
    }

    final target = alreadyActivated
        ? tabsService.tabById(tab.id)
        : tabsService.activateTab(tab.id);
    if (target == null) return;

    _switchingAndroidTab = true;
    _pendingTabSwitchId = target.id;
    _pendingTabRestoreScrollY = target.scrollY;
    _lastKnownUrl = target.url;
    _initialWebUri = WebUri(target.url);
    _lastScrollY = 0;

    try {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(target.url)),
      );
    } catch (e, stackTrace) {
      _switchingAndroidTab = false;
      _pendingTabSwitchId = null;
      _pendingTabRestoreScrollY = null;
      unawaited(
        _appLog.log(
          'AndroidTabs',
          'Could not switch to ${target.url}',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<void> _adoptCurrentPageIntoAndroidTabs() async {
    if (!mounted) return;

    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (!tabsService.enabled) return;

    final title = await _readAndroidTabTitle();
    tabsService.adoptCurrentPage(
      url: _lastKnownUrl,
      scrollY: _scrollByUrl[_lastKnownUrl] ?? _lastScrollY,
      title: title,
    );
  }

  Future<void> _applyAndroidZoomPreference() async {
    final controller = _webController;
    if (controller == null || !mounted) return;

    final androidUi = Provider.of<AndroidUiService>(
      context,
      listen: false,
    );

    try {
      await controller.setSettings(
        settings: InAppWebViewSettings(
          supportZoom: androidUi.zoomEnabled,
          builtInZoomControls: androidUi.zoomEnabled,
          displayZoomControls: false,
        ),
      );

      if (_shouldPersistDiagnostic('android-zoom-setting')) {
        unawaited(
          _appLog.log(
            'AndroidUI',
            androidUi.zoomEnabled
                ? 'Manual WebView zoom enabled'
                : 'Manual WebView zoom disabled',
          ),
        );
      }
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('android-zoom-setting-failed')) {
        unawaited(
          _appLog.log(
            'AndroidUI',
            'Could not apply Android zoom preference',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

  void _openAndroidSettingsPage() {
    if (!mounted) return;

    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    _tabsEnabledAtSettingsOpen = tabsService.enabled;

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const AndroidSettingsScreen(),
          ),
        )
        .whenComplete(() async {
          if (!mounted) return;

          final current = Provider.of<AndroidTabsService>(
            context,
            listen: false,
          );

          if (!_tabsEnabledAtSettingsOpen && current.enabled) {
            await _adoptCurrentPageIntoAndroidTabs();
          }

          if (_tabsEnabledAtSettingsOpen && !current.enabled) {
            _pendingTabSwitchId = null;
            _pendingTabRestoreScrollY = null;
            _switchingAndroidTab = false;
          }

          await _applyAndroidZoomPreference();
          await _syncAndroidChatHeaderGear();
          if (mounted) setState(() {});
        });
  }

  void _showAndroidTabs() {
    final tabsService = Provider.of<AndroidTabsService>(
      context,
      listen: false,
    );
    if (!tabsService.enabled) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Consumer<AndroidTabsService>(
          builder: (context, tabs, _) {
            final entries = tabs.tabs;
            return SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.78,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Android Chat Tabs',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            '${tabs.chatTabCount}/${tabs.maxChatTabs}',
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.add_circle_outline,
                        color: Colors.deepPurpleAccent,
                      ),
                      title: const Text(
                        'Browse for another chat',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        'Returns to Home. Opening a chat creates or activates '
                        'its Android tab.',
                      ),
                      onTap: () {
                        final home = tabs.tabById(AndroidTabsService.homeId);
                        Navigator.pop(sheetContext);
                        if (home != null) {
                          _switchToAndroidTab(home);
                        }
                      },
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final tab = entries[index];
                          final active = tab.id == tabs.activeTabId;
                          final uri = Uri.tryParse(tab.url);
                          final subtitle = tab.isHome
                              ? ((uri?.path.isNotEmpty ?? false)
                                  ? uri!.path
                                  : '/')
                              : (uri?.path ?? tab.url);

                          return ListTile(
                            selected: active,
                            leading: Icon(
                              tab.isHome
                                  ? Icons.home_outlined
                                  : Icons.chat_bubble_outline,
                              color: active
                                  ? Colors.deepPurpleAccent
                                  : Colors.white70,
                            ),
                            title: Text(
                              tab.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight:
                                    active ? FontWeight.w700 : FontWeight.w400,
                              ),
                            ),
                            subtitle: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: tab.isHome
                                ? (active
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.deepPurpleAccent,
                                      )
                                    : null)
                                : IconButton(
                                    tooltip: 'Close tab',
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      final wasActive =
                                          tabs.activeTabId == tab.id;
                                      final next = tabs.closeTab(tab.id);

                                      if (wasActive && next != null) {
                                        Navigator.pop(sheetContext);
                                        _switchToAndroidTab(
                                          next,
                                          alreadyActivated: true,
                                        );
                                      }
                                    },
                                  ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _switchToAndroidTab(tab);
                            },
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.filter_1_outlined),
                      title: const Text('Close other chat tabs'),
                      subtitle: const Text('Home is always kept'),
                      onTap: () {
                        tabs.closeOtherChatTabs(tabs.activeTabId);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.settings_outlined),
                      title: const Text('Android tab settings'),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _openAndroidSettingsPage();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openAndroidCommandPalette() async {
    final controller = _webController;
    if (controller == null || !mounted) return;

    try {
      final rawResult = await controller.evaluateJavascript(
        source: r'''(async () => {
          const visiblePalette = () => !!document.querySelector(
            '#ds-command-palette:not([hidden]), ' +
            '.ds-command-palette:not([hidden]), ' +
            '[data-ds-command-palette]:not([hidden]), ' +
            '[role=\"dialog\"][data-ds-palette-open=\"1\"]'
          );

          if (visiblePalette()) {
            return JSON.stringify({ ok: true, via: \"already-open\" });
          }

          const DS = window.DragonScriptQoL;
          const directAttempts = [
            [\"DS.openCommandPalette\", () => DS?.openCommandPalette?.()],
            [\"DS.showCommandPalette\", () => DS?.showCommandPalette?.()],
            [\"DS.commandPalette.open\", () => DS?.commandPalette?.open?.()],
            [\"DS.commandPalette.show\", () => DS?.commandPalette?.show?.()]
          ];

          for (const [name, fn] of directAttempts) {
            try {
              if (typeof fn !== \"function\") continue;
              const result = fn();
              if (result && typeof result.then === \"function\") await result;
              await new Promise(resolve => setTimeout(resolve, 30));
              if (visiblePalette()) return JSON.stringify({ ok: true, via: name });
            } catch {}
          }

          const shortcuts = [
            { key: \"k\", code: \"KeyK\", ctrlKey: true, metaKey: false, shiftKey: false, altKey: false },
            { key: \"k\", code: \"KeyK\", ctrlKey: true, metaKey: false, shiftKey: true, altKey: false },
            { key: \"k\", code: \"KeyK\", ctrlKey: false, metaKey: false, shiftKey: false, altKey: true },
            { key: \"k\", code: \"KeyK\", ctrlKey: false, metaKey: true, shiftKey: false, altKey: false },
            { key: \"k\", code: \"KeyK\", ctrlKey: false, metaKey: true, shiftKey: true, altKey: false }
          ];

          for (const init of shortcuts) {
            try {
              document.dispatchEvent(new KeyboardEvent(\"keydown\", { ...init, bubbles: true, cancelable: true }));
              window.dispatchEvent(new KeyboardEvent(\"keydown\", { ...init, bubbles: true, cancelable: true }));
              await new Promise(resolve => setTimeout(resolve, 45));
              if (visiblePalette()) return JSON.stringify({ ok: true, via: \"shortcut\" });
            } catch {}
          }

          try {
            window.dispatchEvent(new CustomEvent(\"spicychat-qol:open-command-palette\"));
            document.dispatchEvent(new CustomEvent(\"spicychat-qol:open-command-palette\"));
            await new Promise(resolve => setTimeout(resolve, 50));
            if (visiblePalette()) return JSON.stringify({ ok: true, via: \"custom-event\" });
          } catch {}

          return JSON.stringify({ ok: false });
        })()''',
      );

      var opened = false;
      if (rawResult is String && rawResult.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawResult);
          opened = decoded is Map && decoded['ok'] == true;
        } catch (_) {}
      } else if (rawResult is Map) {
        opened = rawResult['ok'] == true;
      }

      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Command Palette could not be opened. Make sure it is enabled in QoL Settings.',
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'AndroidOptions',
          'Could not open QoL Command Palette from Android',
          level: 'WARN',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<Map<String, dynamic>?> _queryAndroidMainTab() async {
    final controller = _webController;
    if (controller == null) return null;

    try {
      final current = await controller.getUrl();
      if (current == null || !_isSpicyChat(current)) return null;

      String title = 'SpicyChat';
      try {
        final currentTitle = (await controller.getTitle())?.trim() ?? '';
        if (currentTitle.isNotEmpty) title = currentTitle;
      } catch (_) {}

      return <String, dynamic>{
        'id': 1,
        'index': 0,
        'windowId': 1,
        'active': true,
        'highlighted': true,
        'pinned': false,
        'audible': false,
        'discarded': false,
        'autoDiscardable': true,
        'status': 'complete',
        'url': current.toString(),
        'title': title,
        'lastAccessed': DateTime.now().millisecondsSinceEpoch,
        '__spicyChatQolAndroidSynthetic': true,
      };
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('android-options-main-tab-query')) {
        unawaited(
          _appLog.log(
            'AndroidDiagnostics',
            'Could not describe the live SpicyChat WebView for Options',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
      return null;
    }
  }

  Future<dynamic> _sendAndroidMainTabMessage(dynamic message) async {
    final controller = _webController;
    if (controller == null) return null;

    try {
      if (!await _isCurrentUrlTrusted(controller)) return null;

      final encodedMessage = jsonEncode(message);
      final rawResult = await controller.evaluateJavascript(
        source: '''(async () => {
          const dispatch = window.__dsAndroidDispatchRuntimeMessage;
          if (typeof dispatch !== "function") {
            return JSON.stringify({
              ok: false,
              error: "runtime-dispatch-unavailable"
            });
          }

          const sender = {
            id: "spicychat-qol-android",
            url: location.href,
            tab: {
              id: 1,
              index: 0,
              windowId: 1,
              active: true,
              highlighted: true,
              pinned: false,
              discarded: false,
              status: "complete",
              url: location.href,
              title: document.title || "SpicyChat",
              __spicyChatQolAndroidSynthetic: true
            }
          };

          try {
            const response = await dispatch($encodedMessage, sender);
            return JSON.stringify({
              ok: true,
              response: response === undefined ? null : response
            });
          } catch (error) {
            return JSON.stringify({
              ok: false,
              error: String(error?.message || error || "runtime-message-failed")
            });
          }
        })()''',
      );

      dynamic decoded = rawResult;
      if (rawResult is String && rawResult.isNotEmpty) {
        try {
          decoded = jsonDecode(rawResult);
        } catch (_) {}
      }

      if (decoded is Map && decoded['ok'] == true) {
        return decoded['response'];
      }

      return null;
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('android-options-main-runtime-message')) {
        unawaited(
          _appLog.log(
            'AndroidDiagnostics',
            'Could not relay Options runtime message to live SpicyChat WebView',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
      return null;
    }
  }

  bool _requestOpenOptionsPage() {
    if (!mounted || _optionsPageOpen) return false;
    if (!_AndroidOptionsRouteGate.tryAcquire()) {
      if (_shouldPersistDiagnostic('android-options-duplicate-open')) {
        unawaited(
          _appLog.log(
            'AndroidOptions',
            'Ignored duplicate Android Options open request',
          ),
        );
      }
      return false;
    }

    // Lock synchronously before Navigator can push anything. Repeated taps
    // during a UI/WebView stall therefore collapse into one Options route.
    _optionsPageOpen = true;
    unawaited(_openOptionsPageLocked());
    return true;
  }

  Future<void> _openOptionsPageLocked() async {
    String? requestedSpicyChatUrl;

    try {
      requestedSpicyChatUrl = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => OptionsScreen(
            onSettingsChanged: _pushSettingsToWebView,
            extensionVersion: widget.bundleService.extensionVersion,
            onQueryMainTab: _queryAndroidMainTab,
            onSendMainTabMessage: _sendAndroidMainTabMessage,
          ),
        ),
      );
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'AndroidOptions',
          'Android Options route failed to open',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    } finally {
      _optionsPageOpen = false;
      _AndroidOptionsRouteGate.release();
      if (mounted) {
        try {
          await _pushSettingsToWebView();
        } catch (e, stackTrace) {
          unawaited(
            _appLog.log(
              'AndroidOptions',
              'Could not refresh settings after Android Options closed',
              level: 'WARN',
              error: e,
              stackTrace: stackTrace,
            ),
          );
        }
      }
    }

    if (!mounted ||
        requestedSpicyChatUrl == null ||
        requestedSpicyChatUrl.trim().isEmpty) {
      return;
    }

    if (requestedSpicyChatUrl == 'ds-action:command-palette') {
      await _openAndroidCommandPalette();
      return;
    }

    final target = WebUri(requestedSpicyChatUrl);
    if (!_isSpicyChat(target)) return;

    final controller = _webController;
    if (controller == null) return;

    unawaited(
      _appLog.log(
        'Navigation',
        'Opening SpicyChat URL from Android Options inside app: $target',
      ),
    );

    try {
      await controller.loadUrl(
        urlRequest: URLRequest(url: target),
      );
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'Navigation',
          'Could not open SpicyChat URL returned by Android Options: $target',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<void> _toggleAndroidFocusMode() async {
    final controller = _webController;
    if (!mounted || controller == null) return;

    try {
      final raw = await controller.evaluateJavascript(
        source: r"""(() => {
  const DS = window.DragonScriptQoL;
  if (!DS?.toggleFocusMode || !DS?.isFocusModeActive) {
    return JSON.stringify({ ok: false, error: "focus-mode-unavailable" });
  }

  const settings = DS.state?.settings || {};
  const onChat = !!DS.isSingleChatPage?.();
  const enabled = !!settings.enabled && !!settings.enableFocusMode && onChat;

  DS.toggleFocusMode();

  return JSON.stringify({
    ok: true,
    enabled,
    onChat,
    active: !!DS.isFocusModeActive?.()
  });
})()""",
      );

      dynamic decoded = raw;
      if (raw is String && raw.isNotEmpty) {
        try {
          decoded = jsonDecode(raw);
        } catch (_) {}
      }

      if (!mounted) return;

      if (decoded is! Map || decoded['ok'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Focus Mode is not available in this QoL build.'),
          ),
        );
        return;
      }

      if (decoded['enabled'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enable Focus / Immersive Mode in QoL Options first.',
            ),
          ),
        );
        return;
      }

      final active = decoded['active'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(active ? 'Focus Mode enabled' : 'Focus Mode disabled'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'AndroidFocusMode',
          'Could not toggle Focus / Immersive Mode from Android',
          level: 'WARN',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  void _registerJsHandlers(InAppWebViewController controller) {
    final settingsService = Provider.of<SettingsService>(
      context,
      listen: false,
    );

    // Handle chrome.storage.local.get()
    controller.addJavaScriptHandler(
      handlerName: 'storageGet',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return '{}';
        try {
          final keys = args.isNotEmpty ? jsonDecode(args[0].toString()) : null;
          final result = await settingsService.storageGet(keys);
          return jsonEncode(result);
        } catch (e) {
          debugPrint('[Bridge] storageGet error: $e');
          return '{}';
        }
      },
    );

    // Handle chrome.storage.local.set()
    controller.addJavaScriptHandler(
      handlerName: 'storageSet',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return null;
        try {
          final obj = jsonDecode(args[0].toString()) as Map<String, dynamic>;
          await settingsService.storageSet(obj);
        } catch (e) {
          debugPrint('[Bridge] storageSet error: $e');
        }
        return null;
      },
    );

    // Handle chrome.storage.local.remove()
    controller.addJavaScriptHandler(
      handlerName: 'storageRemove',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return null;
        try {
          final rawKeys = args.isNotEmpty ? args[0].toString() : '[]';
          await settingsService.storageRemove(jsonDecode(rawKeys));
        } catch (e) {
          debugPrint('[Bridge] storageRemove error: $e');
        }
        return null;
      },
    );

    // Handle chrome.storage.local.getBytesInUse()
    controller.addJavaScriptHandler(
      handlerName: 'storageGetBytesInUse',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return 0;
        try {
          final rawKeys = args.isNotEmpty ? args[0].toString() : 'null';
          return await settingsService.storageGetBytesInUse(
            jsonDecode(rawKeys),
          );
        } catch (e) {
          debugPrint('[Bridge] storageGetBytesInUse error: $e');
          return 0;
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'storageClear',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return null;
        try {
          await settingsService.storageClear();
        } catch (e) {
          debugPrint('[Bridge] storageClear error: $e');
        }
        return null;
      },
    );

    // Handle chrome.runtime.sendMessage()
    controller.addJavaScriptHandler(
      handlerName: 'runtimeMessage',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return jsonEncode({'ok': false});
        try {
          final message = jsonDecode(args[0].toString());
          return jsonEncode(_handleRuntimeMessage(message));
        } catch (e) {
          debugPrint('[Bridge] runtimeMessage error: $e');
          return jsonEncode({'ok': false});
        }
      },
    );

    // Android-only chat-header gear.
    controller.addJavaScriptHandler(
      handlerName: 'androidOpenQuickMenu',
      callback: (args) async {
        final bridgeReceivedAt = DateTime.now();
        DateTime? tappedAt;
        String reportedRoute = _normalizedSpicyChatPath(_lastKnownUrl);
        String reportedKind = _isChatUrl(_lastKnownUrl) ? 'chat' : 'other';

        if (args.isNotEmpty && args.first is Map) {
          final payload = Map<String, dynamic>.from(args.first as Map);
          final tappedAtRaw = payload['tappedAt'];
          final tappedAtMs = tappedAtRaw is num
              ? tappedAtRaw.toInt()
              : int.tryParse(tappedAtRaw?.toString() ?? '');

          if (tappedAtMs != null && tappedAtMs > 0) {
            tappedAt = DateTime.fromMillisecondsSinceEpoch(tappedAtMs);
          }

          final route = (payload['route'] ?? '').toString().trim();
          if (route.isNotEmpty) {
            reportedRoute = route;
          }

          final kind = (payload['kind'] ?? '').toString().trim();
          if (kind.isNotEmpty) {
            reportedKind = kind;
          }
        }

        if (!mounted || !await _isCurrentUrlTrusted(controller)) {
          return false;
        }

        final tapToBridgeMs = tappedAt == null
            ? null
            : bridgeReceivedAt.millisecondsSinceEpoch -
                tappedAt.millisecondsSinceEpoch;

        unawaited(
          _appLog.log(
            'QuickMenuTiming',
            'Native gear bridge received: '
                'route=$reportedRoute kind=$reportedKind '
                'tapToBridgeMs=${tapToBridgeMs ?? 'unknown'}',
          ),
        );

        // Do not wait for another Flutter frame before starting the native
        // route. The old post-frame hop was unnecessary and made a busy chat
        // page feel even slower.
        unawaited(
          _showQuickMenu(
            requestedAt: tappedAt ?? bridgeReceivedAt,
            bridgeReceivedAt: bridgeReceivedAt,
            source: 'header-gear',
          ),
        );
        return true;
      },
    );

    // Android-only Save & Stay history repair marker.
    controller.addJavaScriptHandler(
      handlerName: 'androidSaveStayStarted',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller) || !mounted) {
          return false;
        }
        _armAndroidSaveStayBackRepair();
        return true;
      },
    );

    // Handle opening options/settings page
    controller.addJavaScriptHandler(
      handlerName: 'openOptions',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return null;
        _requestOpenOptionsPage();
        return null;
      },
    );

    // Handle chat export (file download)
    controller.addJavaScriptHandler(
      handlerName: 'exportChat',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) return null;
        try {
          final data = jsonDecode(args[0].toString());
          await _exportChatText(
            data['text'] ?? '',
            data['filename'] ?? 'spicychat-chat.txt',
          );
        } catch (e) {
          debugPrint('[Bridge] exportChat error: $e');
        }
        return null;
      },
    );

    // Generic Android file saver for extension features that normally use
    // browser-only <a download> / Blob downloads.
    controller.addJavaScriptHandler(
      handlerName: 'saveFile',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) {
          return {'ok': false, 'error': 'untrusted URL'};
        }
        try {
          final data = _decodeNativeFilePayload(args);
          if (data == null) {
            return {'ok': false, 'error': 'invalid payload'};
          }

          final saved = await _saveNativeFile(
            bytes: data.bytes,
            filename: data.filename,
            dialogTitle: 'Save File',
          );
          return {'ok': saved};
        } catch (e) {
          debugPrint('[Bridge] saveFile error: $e');
          return {'ok': false, 'error': e.toString()};
        }
      },
    );

    // Native Android clipboard bridge. navigator.clipboard / execCommand can
    // silently fail in WebView even when the long-press action itself worked.
    controller.addJavaScriptHandler(
      handlerName: 'copyToClipboard',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller)) {
          return {'ok': false, 'error': 'untrusted URL'};
        }

        final text = args.isNotEmpty ? args.first.toString() : '';
        if (text.isEmpty) {
          return {'ok': false, 'error': 'empty text'};
        }

        try {
          await Clipboard.setData(ClipboardData(text: text));
          return {'ok': true};
        } catch (e) {
          debugPrint('[Bridge] native clipboard error: $e');
          return {'ok': false, 'error': e.toString()};
        }
      },
    );

    // Android-only long-hold message menu. The WebView script sends only the
    // available action labels; message text never crosses this handler.
    controller.addJavaScriptHandler(
      handlerName: 'androidMessageLongPress',
      callback: (args) async {
        if (!await _isCurrentUrlTrusted(controller) ||
            !mounted ||
            _messageLongPressMenuOpen) {
          return null;
        }

        try {
          final raw = args.isNotEmpty ? args[0].toString() : '{}';
          final decoded = jsonDecode(raw);
          if (decoded is! Map) return null;

          const allowedActions = <String>{
            'Copy',
            'Edit',
            'Report',
            'Resend',
            'Remove Image',
            'Select text',
          };

          final requested = decoded['actions'];
          if (requested is! List) return null;

          final actions = <String>[];
          for (final value in requested) {
            final action = value.toString();
            if (allowedActions.contains(action) && !actions.contains(action)) {
              actions.add(action);
            }
          }
          if (actions.isEmpty) return null;

          _messageLongPressMenuOpen = true;
          await HapticFeedback.mediumImpact();

          if (!mounted) return null;
          final selected = await showModalBottomSheet<String>(
            context: context,
            useRootNavigator: true,
            useSafeArea: true,
            showDragHandle: true,
            builder: (sheetContext) {
              IconData iconFor(String action) {
                switch (action) {
                  case 'Copy':
                    return Icons.copy_outlined;
                  case 'Edit':
                    return Icons.edit_outlined;
                  case 'Report':
                    return Icons.flag_outlined;
                  case 'Resend':
                    return Icons.replay_outlined;
                  case 'Remove Image':
                    return Icons.image_not_supported_outlined;
                  case 'Select text':
                    return Icons.text_fields_outlined;
                  default:
                    return Icons.more_horiz;
                }
              }

              return SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Message actions',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    for (final action in actions) ...[
                      if (action == 'Select text')
                        const Divider(height: 1),
                      ListTile(
                        leading: Icon(iconFor(action)),
                        title: Text(action),
                        onTap: () => Navigator.of(sheetContext).pop(action),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          );

          return selected;
        } catch (e, stackTrace) {
          unawaited(
            _appLog.log(
              'AndroidGesture',
              'Message long-press menu failed',
              level: 'ERROR',
              error: e,
              stackTrace: stackTrace,
            ),
          );
          return null;
        } finally {
          _messageLongPressMenuOpen = false;
        }
      },
    );
  }

  Map<String, dynamic> _handleRuntimeMessage(dynamic message) {
    if (message is! Map) return {'ok': false};

    final type = message['type'];

    switch (type) {
      case 'DS_OPEN_OPTIONS':
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _requestOpenOptionsPage();
        });
        return {'ok': true};

      case 'DS_LOAD_ALL_CHATS_START':
      case 'DS_LOAD_ALL_CHATS_STOP':
      case 'DS_LOAD_ALL_CHATS_RESCHEDULE':
      case 'DS_LOAD_ALL_CHATS_DONE':
        // These are handled by the JS-side loop in WebView
        return {'ok': true};

      default:
        return {'ok': false, 'error': 'unknown message type'};
    }
  }

  Future<void> _installAndroidListingIdentityHelper(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(
        source: r'''(() => {
  if (window.__dsAndroidListingIdentityInstalled) {
    window.__dsAndroidListingIdentityRun?.("recheck");
    return;
  }

  window.__dsAndroidListingIdentityInstalled = true;

  const UUID_RE =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  const normalizeId = value => {
    const text = String(value || "").trim();
    return UUID_RE.test(text) ? text.toLowerCase() : "";
  };

  const idFromHref = href => {
    try {
      const url = new URL(href, location.href);
      if (!/(^|\.)spicychat\.ai$/i.test(url.hostname)) return "";

      const parts = url.pathname
        .split("/")
        .map(part => decodeURIComponent(part || "").trim())
        .filter(Boolean);

      if (parts[0] === "chatbot" && parts[1]) {
        return normalizeId(parts[1]);
      }

      if (parts[0] === "chat" && parts[1]) {
        return normalizeId(parts[1]);
      }
    } catch {}

    return "";
  };

  const likelyCardRoot = anchor => {
    const selectors = [
      '[data-testid*="Chatbot"]',
      '[data-testid*="chatbot"]',
      '[data-chatbot-id]',
      '[data-bot-id]',
      'article',
      'li',
      '[class*="chatbot-card"]',
      '[class*="ChatbotCard"]',
      '[class*="character-card"]',
      '[class*="CharacterCard"]'
    ];

    for (const selector of selectors) {
      const node = anchor.closest?.(selector);
      if (node) return node;
    }

    let node = anchor.parentElement;
    for (
      let depth = 0;
      node && depth < 4;
      depth++, node = node.parentElement
    ) {
      const linkCount =
        node.querySelectorAll?.(
          'a[href*="/chat/"], a[href*="/chatbot/"]'
        ).length || 0;
      const imageCount = node.querySelectorAll?.("img").length || 0;
      if (linkCount >= 1 && imageCount >= 1) return node;
    }

    return null;
  };

  let scheduled = false;
  let lastSummary = "";

  const run = reason => {
    scheduled = false;

    const anchors = Array.from(
      document.querySelectorAll(
        'a[href*="/chat/"], a[href*="/chatbot/"]'
      )
    );

    let usableAnchors = 0;
    let normalizedAnchors = 0;
    let normalizedRoots = 0;
    const uniqueIds = new Set();

    for (const anchor of anchors) {
      const id =
        normalizeId(anchor.dataset?.chatbotId) ||
        normalizeId(anchor.dataset?.botId) ||
        normalizeId(anchor.getAttribute?.("data-chatbot-id")) ||
        normalizeId(anchor.getAttribute?.("data-bot-id")) ||
        idFromHref(anchor.href);

      if (!id) continue;

      usableAnchors++;
      uniqueIds.add(id);

      if (!anchor.getAttribute("data-chatbot-id")) {
        anchor.setAttribute("data-chatbot-id", id);
        normalizedAnchors++;
      }
      if (!anchor.getAttribute("data-bot-id")) {
        anchor.setAttribute("data-bot-id", id);
      }
      anchor.setAttribute("data-ds-android-chatbot-id", id);

      const root = likelyCardRoot(anchor);
      if (root) {
        const before =
          root.getAttribute("data-chatbot-id") ||
          root.getAttribute("data-bot-id");

        if (!root.getAttribute("data-chatbot-id")) {
          root.setAttribute("data-chatbot-id", id);
        }
        if (!root.getAttribute("data-bot-id")) {
          root.setAttribute("data-bot-id", id);
        }
        root.setAttribute("data-ds-android-chatbot-id", id);

        if (!before) normalizedRoots++;
      }
    }

    const summary = JSON.stringify({
      path: location.pathname,
      anchors: anchors.length,
      usableAnchors,
      uniqueIds: uniqueIds.size,
      normalizedAnchors,
      normalizedRoots
    });

    if (summary !== lastSummary) {
      lastSummary = summary;
      console.log("[DS Android Identity] " + summary);
    }

    if (normalizedAnchors || normalizedRoots) {
      try {
        window.dispatchEvent(
          new CustomEvent(
            "spicychat-qol:android-identities-ready",
            {
              detail: {
                reason,
                uniqueIds: uniqueIds.size
              }
            }
          )
        );
      } catch {}
    }
  };

  const schedule = reason => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => run(reason));
  };

  window.__dsAndroidListingIdentityRun = run;
  window.__dsAndroidListingIdentitySchedule = schedule;

  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type !== "childList") continue;
      if (
        record.addedNodes?.length ||
        record.removedNodes?.length
      ) {
        schedule("mutation");
        break;
      }
    }
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  run("install");
})()''',
      );
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('android-listing-identity-helper')) {
        unawaited(
          _appLog.log(
            'AndroidIdentity',
            'Could not install Android listing identity helper',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

  Future<void> _injectScripts(InAppWebViewController controller) async {
    final url = await controller.getUrl();
    if (url == null || !_isSpicyChat(url)) return;

    // A page-global document token survives SPA navigation but disappears on
    // a true reload/new document. This prevents repeated evaluation of the
    // full 80+ script bundle when Android fires duplicate onLoadStop events.
    final rawToken = await controller.evaluateJavascript(
      source: r'''(() => {
        if (!window.__spicyChatQolAndroidDocumentToken) {
          const origin = Math.round(
            performance.timeOrigin ||
            performance.timing?.navigationStart ||
            Date.now()
          );
          window.__spicyChatQolAndroidDocumentToken =
            String(origin) + '-' + Math.random().toString(36).slice(2, 9);
        }
        const token = window.__spicyChatQolAndroidDocumentToken;
        return JSON.stringify({
          token,
          alreadyInjected: window.__spicyChatQolAndroidInjected === token
        });
      })()''',
    );

    Map<String, dynamic>? tokenInfo;
    if (rawToken is String && rawToken.isNotEmpty) {
      final decoded = jsonDecode(rawToken);
      if (decoded is Map) tokenInfo = Map<String, dynamic>.from(decoded);
    } else if (rawToken is Map) {
      tokenInfo = Map<String, dynamic>.from(rawToken);
    }

    final token = tokenInfo?['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw StateError('Could not determine WebView document token');
    }

    if (tokenInfo?['alreadyInjected'] == true ||
        _lastInjectedDocumentToken == token ||
        _injectionInProgressToken == token) {
      return;
    }

    _injectionInProgressToken = token;
    final started = DateTime.now();
    try {
      // Publish Android wrapper identity/capabilities before any normal QoL
      // script executes. The real WebView UA is also left intact.
      await controller.evaluateJavascript(
        source: r'''(() => {
          window.__spicyChatQolAndroidApp = true;
          window.__spicyChatQolAndroidWebView = true;
          window.__spicyChatQolAndroidCapabilities = Object.freeze({
            dedicatedApp: true,
            singleWebView: true,
            browserTabs: false,
            backgroundTabs: false,
            backgroundAlarms: false,
            nativeFileSave: true,
            nativeFilePicker: true,
            androidChatTabs: true,
            listingIdentityNormalization: true
          });
          try {
            document.documentElement?.setAttribute(
              "data-spicychat-qol-android",
              "1"
            );
          } catch {}
        })();''',
      );

      await _installAndroidListingIdentityHelper(controller);

      await controller.evaluateJavascript(
        source: widget.bundleService.cssInjectionScript,
      );
      await controller.evaluateJavascript(source: widget.bundleService.jsBundle);

      // Android-only Save & Stay marker. Delegated click handling keeps
      // working when QoL recreates the editor toolbar dynamically.
      await controller.evaluateJavascript(
        source: r'''(() => {
          if (window.__dsAndroidSaveStayHistoryHookInstalled) return;
          window.__dsAndroidSaveStayHistoryHookInstalled = true;

          document.addEventListener("click", event => {
            const target =
              event.target instanceof Element
                ? event.target
                : event.target?.parentElement;
            const button = target?.closest?.(
              ".ds-bot-editor-save-actions button"
            );
            if (!button) return;

            const text = String(button.textContent || "")
              .replace(/\s+/g, " ")
              .trim();

            if (!/^Save\s*&\s*Stay$/i.test(text)) return;

            window.flutter_inappwebview
              ?.callHandler("androidSaveStayStarted")
              .catch(() => {});
          }, true);
        })()''',
      );

      // Android-owned gesture layer. This stays outside the extension bundle
      // so desktop releases never need Android-specific touch handling.
      try {
        _androidMessageLongPressSource ??= await rootBundle.loadString(
          'assets/js/android-message-longpress.js',
        );
        await controller.evaluateJavascript(
          source: _androidMessageLongPressSource!,
        );
      } catch (e, stackTrace) {
        unawaited(
          _appLog.log(
            'AndroidGesture',
            'Could not inject Android message long-press support',
            level: 'ERROR',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }

      await controller.evaluateJavascript(
        source:
            "window.__spicyChatQolAndroidInjected = ${jsonEncode(token)};",
      );

      _lastInjectedDocumentToken = token;
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      unawaited(
        _appLog.log(
          'Injection',
          'QoL bundle injected once for document=$token in ${elapsed}ms; url=$url',
        ),
      );
    } finally {
      if (_injectionInProgressToken == token) {
        _injectionInProgressToken = null;
      }
    }
  }

  void _scheduleVisualGuardForCurrentPage(String trigger) {
    if (!_appIsResumed || !_isChatUrl(_lastKnownUrl)) return;

    final now = DateTime.now();
    if (_lastVisualGuardAt != null &&
        now.difference(_lastVisualGuardAt!) <
            const Duration(milliseconds: 900)) {
      return;
    }
    _lastVisualGuardAt = now;

    final generation = ++_visualGuardGeneration;
    for (final delay in const [
      Duration(milliseconds: 900),
      Duration(seconds: 3),
    ]) {
      Future<void>.delayed(delay, () async {
        if (!mounted ||
            !_appIsResumed ||
            generation != _visualGuardGeneration ||
            !_isChatUrl(_lastKnownUrl)) {
          return;
        }
        await _runVisualGuard(trigger: '$trigger-${delay.inMilliseconds}ms');
      });
    }
  }

  Future<void> _runVisualGuard({required String trigger}) async {
    final controller = _webController;
    if (controller == null) return;

    try {
      final raw = await controller.evaluateJavascript(
        source: r'''(() => {
          const vw = Math.max(1, window.innerWidth || 1);
          const vh = Math.max(1, window.innerHeight || 1);
          const all = Array.from(document.querySelectorAll('img[src*="/avatars/"]'));
          const visible = all.filter(img => {
            const r = img.getBoundingClientRect();
            return r.width > 1 && r.height > 1;
          });

          const suspicious = visible.filter(img => {
            const r = img.getBoundingClientRect();
            return r.width > vw * 1.15 ||
              r.height > Math.max(700, vh * 0.9);
          });

          const rows = suspicious.slice(0, 6).map(img => {
            const before = img.getBoundingClientRect();
            let path = '';
            try {
              path = new URL(img.currentSrc || img.src, location.href).pathname;
            } catch (_) {
              path = String(img.currentSrc || img.src || '').slice(0, 180);
            }

            const sameLargeSourceCount = suspicious.filter(other =>
              (other.currentSrc || other.src) === (img.currentSrc || img.src)
            ).length;

            // Only clamp clearly impossible avatar geometry. Normal profile
            // heroes/cards stay untouched.
            img.dataset.dsAndroidVisualGuard = '1';
            img.style.setProperty('max-width', 'min(100%, 420px)', 'important');
            img.style.setProperty('max-height', '55vh', 'important');
            img.style.setProperty('width', 'auto', 'important');
            img.style.setProperty('height', 'auto', 'important');
            img.style.setProperty('object-fit', 'cover', 'important');

            const after = img.getBoundingClientRect();
            return {
              path: path.slice(0, 180),
              beforeWidth: Math.round(before.width),
              beforeHeight: Math.round(before.height),
              afterWidth: Math.round(after.width),
              afterHeight: Math.round(after.height),
              sameLargeSourceCount
            };
          });

          return JSON.stringify({
            href: location.href,
            viewportWidth: Math.round(vw),
            viewportHeight: Math.round(vh),
            avatarCount: all.length,
            suspiciousCount: suspicious.length,
            rows
          });
        })()''',
      );

      Map<String, dynamic>? result;
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) result = Map<String, dynamic>.from(decoded);
      } else if (raw is Map) {
        result = Map<String, dynamic>.from(raw);
      }

      if (result == null) return;
      final count = result['suspiciousCount'];
      if (count is num && count > 0) {
        unawaited(
          _appLog.log(
            'VisualGuard',
            'Oversized avatar geometry detected/fixed ($trigger): ${jsonEncode(result)}',
            level: 'WARN',
          ),
        );
      }
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('visual-guard-error')) {
        unawaited(
          _appLog.log(
            'VisualGuard',
            'Visual guard check failed ($trigger)',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

  Future<void> _pushSettingsToWebView() async {
    final controller = _webController;
    if (controller == null) return;

    // The old bridge sent { settings: { newValue: true } }, but QoL expects the
    // actual settings object. Reload all local state so settings, personas,
    // local persona copies, blocked/saved lists and other storage stay in sync.
    try {
      await controller.evaluateJavascript(
        source: r'''
          (async () => {
            const DS = window.DragonScriptQoL;
            if (!DS) return;
            if (typeof DS.loadState === "function") await DS.loadState();
            DS.state.openedImportRevision = -1;
            DS.scheduleRun?.({
              immediate: true,
              priority: "critical",
              source: "android-native-storage-sync"
            });
          })();
        ''',
      );
    } catch (e) {
      debugPrint('[Bridge] Could not refresh WebView state: $e');
    }
  }

  _NativeFilePayload? _decodeNativeFilePayload(List<dynamic> args) {
    if (args.isEmpty) return null;

    dynamic raw = args.first;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    if (raw is! Map) return null;

    final data = Map<String, dynamic>.from(raw);
    final filename = _safeNativeFilename(
      data['filename'] ?? data['fileName'],
      fallback: 'spicychat-qol-export.txt',
    );

    Uint8List bytes;
    final encoded = data['base64'];
    if (encoded is String && encoded.trim().isNotEmpty) {
      try {
        final clean = encoded.contains(',')
            ? encoded.substring(encoded.indexOf(',') + 1)
            : encoded;
        bytes = Uint8List.fromList(base64Decode(clean));
      } catch (_) {
        bytes = Uint8List.fromList(
          utf8.encode('${data['text'] ?? data['content'] ?? ''}'),
        );
      }
    } else {
      bytes = Uint8List.fromList(
        utf8.encode('${data['text'] ?? data['content'] ?? ''}'),
      );
    }

    return _NativeFilePayload(filename: filename, bytes: bytes);
  }

  String _safeNativeFilename(dynamic value, {required String fallback}) {
    var filename = (value ?? '').toString().trim();
    if (filename.isEmpty) filename = fallback;

    filename = filename
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (filename.isEmpty) return fallback;
    if (filename.length > 140) {
      final dot = filename.lastIndexOf('.');
      final suffix = dot > 0 && filename.length - dot <= 12
          ? filename.substring(dot)
          : '';
      final keep = 140 - suffix.length;
      filename = '${filename.substring(0, keep)}$suffix';
    }
    return filename;
  }

  Future<bool> _saveNativeFile({
    required Uint8List bytes,
    required String filename,
    required String dialogTitle,
  }) async {
    try {
      final dot = filename.lastIndexOf('.');
      final extension = dot >= 0 && dot < filename.length - 1
          ? filename.substring(dot + 1).toLowerCase()
          : null;
      final safeExtension = extension != null &&
              RegExp(r'^[a-z0-9]{1,12}$').hasMatch(extension)
          ? extension
          : null;

      final outputFile = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: filename,
        type: safeExtension == null ? FileType.any : FileType.custom,
        allowedExtensions: safeExtension == null ? null : [safeExtension],
        bytes: bytes,
      );

      if (outputFile == null) return false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${outputFile.split("/").last}')),
        );
      }
      return true;
    } catch (e) {
      debugPrint('[Native Save] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
      return false;
    }
  }

  Future<void> _exportChatText(String text, String filename) async {
    await _saveNativeFile(
      bytes: Uint8List.fromList(utf8.encode(text)),
      filename: _safeNativeFilename(
        filename,
        fallback: 'spicychat-chat.txt',
      ),
      dialogTitle: 'Save Export',
    );
  }

  // ── Backup Import ──────────────────────────────────────────

  Future<void> _restoreBackupText(String content, {required String source}) async {
    try {
      final decoded = jsonDecode(content.trim());
      if (decoded is! Map) {
        throw const FormatException('The backup must be a JSON object.');
      }

      final backup = Map<String, dynamic>.from(decoded);
      final settingsService = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      await settingsService.importFullBackup(backup);
      await _pushSettingsToWebView();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Backup restored from $source (${backup.keys.length} keys imported)',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Import] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt', 'qol', 'backup'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      String content;
      if (picked.bytes != null) {
        content = utf8.decode(picked.bytes!);
      } else if (picked.path != null) {
        content = await File(picked.path!).readAsString();
      } else {
        throw const FileSystemException('The selected file could not be read.');
      }

      await _restoreBackupText(content, source: 'file');
    } catch (e) {
      debugPrint('[File Import] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File import failed: $e')),
        );
      }
    }
  }

  Future<void> _pasteBackup() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final controller = TextEditingController(text: clipboard?.text ?? '');

    if (!mounted) return;
    final pasted = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Paste Backup JSON'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            minLines: 8,
            maxLines: 16,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: 'Paste the full backup JSON here',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (pasted == null || pasted.trim().isEmpty) return;
    await _restoreBackupText(pasted, source: 'pasted text');
  }

  Future<void> _copyFullBackup() async {
    try {
      final settingsService = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      await Clipboard.setData(
        ClipboardData(text: settingsService.exportFullBackup()),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Full backup copied to clipboard')),
        );
      }
    } catch (e) {
      debugPrint('[Backup Copy] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copy failed: $e')),
        );
      }
    }
  }

  // ── Backup Export ──────────────────────────────────────────

  Future<void> _exportFullBackup() async {
    try {
      final settingsService = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      final jsonStr = settingsService.exportFullBackup();

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final defaultFilename = 'spicychat-qol-backup-$timestamp.json';

      final outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Full Backup',
        fileName: defaultFilename,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
      );

      if (outputFile == null) return; // User canceled

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup saved to ${outputFile.split("/").last}')),
        );
      }
    } catch (e) {
      debugPrint('[Backup Export] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Backup export failed: $e')));
      }
    }
  }

  Future<Map<String, dynamic>?> _probeWebView() async {
    final controller = _webController;
    if (controller == null) return null;

    final raw = await controller.evaluateJavascript(
      source: r'''(() => {
        const body = document.body;
        const html = document.documentElement;
        const style = body ? getComputedStyle(body) : null;
        const bodyRect = body ? body.getBoundingClientRect() : null;
        const bodyChildren = body ? body.children.length : -1;
        const hasUi = !!document.querySelector(
          'main, nav, header, button, input, textarea, img, [role="main"], [role="button"]'
        );
        const meaningful = !!body && (bodyChildren > 0 || hasUi);
        return JSON.stringify({
          href: location.href,
          title: document.title || '',
          readyState: document.readyState,
          bodyChildren,
          display: style ? style.display : '',
          visibility: style ? style.visibility : '',
          opacity: style ? style.opacity : '',
          bodyWidth: bodyRect ? Math.round(bodyRect.width) : 0,
          bodyHeight: bodyRect ? Math.round(bodyRect.height) : 0,
          htmlWidth: html ? html.scrollWidth : 0,
          htmlHeight: html ? html.scrollHeight : 0,
          meaningful
        });
      })()''',
    );

    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  Future<void> _runWebViewHealthCheck({String trigger = 'timer'}) async {
    final controller = _webController;
    if (!mounted ||
        !_appIsResumed ||
        _recoveringWebView ||
        controller == null) {
      return;
    }

    if (_isLoading) {
      final startedAt = _loadStartedAt;
      if (startedAt == null ||
          DateTime.now().difference(startedAt) < const Duration(seconds: 15)) {
        return;
      }
      // A load that never reaches onLoadStop used to disable the watchdog
      // forever. After 15 seconds, probe it like any other page.
    }

    try {
      final current = await controller.getUrl();
      if (current != null && !_isSpicyChat(current)) {
        _blankHealthFailures = 0;
        return;
      }
    } catch (_) {
      // A broken renderer may not answer getUrl().
    }

    final stoppedAt = _lastLoadStopAt;
    if (stoppedAt != null &&
        DateTime.now().difference(stoppedAt) < const Duration(seconds: 4)) {
      return;
    }

    try {
      final probe = await _probeWebView();
      if (probe == null) {
        _blankHealthFailures++;
        unawaited(
          _appLog.log(
            'Health',
            'WebView health probe returned no data ($trigger), failure=$_blankHealthFailures',
            level: 'WARN',
          ),
        );
      } else {
        final href = (probe['href'] ?? '').toString();
        if (href.isNotEmpty) _lastKnownUrl = href;

        final meaningful = probe['meaningful'] == true;
        final hidden = probe['display'] == 'none' ||
            probe['visibility'] == 'hidden' ||
            probe['opacity'] == '0';
        final width = probe['htmlWidth'];
        final height = probe['htmlHeight'];
        final tinyDocument = (width is num ? width : 0) <= 1 ||
            (height is num ? height : 0) <= 1;
        final blank = !meaningful || hidden || tinyDocument;

        if (blank) {
          _blankHealthFailures++;
          unawaited(
            _appLog.log(
              'Health',
              'Possible blank WebView ($trigger), failure=$_blankHealthFailures, probe=${jsonEncode(probe)}',
              level: 'WARN',
            ),
          );
        } else {
          if (_blankHealthFailures > 0) {
            unawaited(
              _appLog.log(
                'Health',
                'WebView recovered/healthy after $_blankHealthFailures failed probe(s)',
              ),
            );
          }
          _blankHealthFailures = 0;
        }
      }
    } catch (e, stackTrace) {
      _blankHealthFailures++;
      unawaited(
        _appLog.log(
          'Health',
          'WebView health probe threw ($trigger), failure=$_blankHealthFailures',
          level: 'WARN',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }

    if (_blankHealthFailures >= 2) {
      await _recoverWebView(reason: 'automatic blank-screen watchdog ($trigger)');
    }
  }

  Future<void> _recoverWebView({
    required String reason,
    bool useController = true,
  }) async {
    if (!mounted || _recoveringWebView) return;

    final previousRecovery = _lastRecoveryAt;
    if (previousRecovery != null &&
        DateTime.now().difference(previousRecovery) <
            const Duration(seconds: 12)) {
      return;
    }

    _recoveringWebView = true;
    _lastRecoveryAt = DateTime.now();
    _routeHealthGeneration++;

    var target = _lastKnownUrl;
    final controller = useController ? _webController : null;
    if (controller != null) {
      try {
        final current = await controller.getUrl();
        if (current != null && current.toString().isNotEmpty) {
          target = current.toString();
        }
      } catch (_) {
        // A crashed renderer can make getUrl fail; the last known URL is fine.
      }
    }

    if (!target.startsWith('https://')) {
      target = 'https://spicychat.ai/';
    }

    unawaited(
      _appLog.log(
        'Recovery',
        'Recreating WebView because of $reason; target=$target',
        level: 'WARN',
      ),
    );

    try {
      try {
        await controller?.stopLoading();
      } catch (_) {}

      _webController = null;
      _blankHealthFailures = 0;
      _loadStartedAt = null;
      _lastLoadStopAt = null;
      _lastInjectedDocumentToken = null;
      _injectionInProgressToken = null;
      _lastProgressPercent = -1;
      _visualGuardGeneration++;
      _initialWebUri = WebUri(target);

      if (mounted) {
        setState(() {
          _webViewKey = UniqueKey();
          _isLoading = true;
          _progress = 0;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('WebView recovery started'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'Recovery',
          'Could not recreate WebView',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('WebView recovery failed: $e')),
        );
      }
    } finally {
      _recoveringWebView = false;
    }
  }

  Future<void> _copyDiagnosticLog() async {
    try {
      final log = await _appLog.readAll();
      await Clipboard.setData(
        ClipboardData(text: log.isEmpty ? 'No app log entries yet.' : log),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('App diagnostic log copied')),
        );
      }
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'Diagnostics',
          'Copy log failed',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<void> _exportDiagnosticLog() async {
    try {
      final log = await _appLog.readAll();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = 'spicychat-qol-android-log-$timestamp.txt';

      final outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Save App Diagnostic Log',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: Uint8List.fromList(utf8.encode(log)),
      );

      if (outputFile == null) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('App log saved to ${outputFile.split('/').last}'),
          ),
        );
      }
    } catch (e, stackTrace) {
      unawaited(
        _appLog.log(
          'Diagnostics',
          'Export log failed',
          level: 'ERROR',
          error: e,
          stackTrace: stackTrace,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('App log export failed: $e')),
        );
      }
    }
  }

  Future<void> _clearDiagnosticLog() async {
    try {
      await _appLog.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('App diagnostic log cleared')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not clear app log: $e')),
        );
      }
    }
  }

  // ── Quick Menu ─────────────────────────────────────────────

  Future<void> _showQuickMenu({
    DateTime? requestedAt,
    DateTime? bridgeReceivedAt,
    String source = 'native',
  }) async {
    if (!mounted || _quickMenuOpen) return;

    final route = _normalizedSpicyChatPath(_lastKnownUrl);
    final openStartedAt = DateTime.now();
    _quickMenuOpen = true;

    final requestToOpenMs = requestedAt == null
        ? null
        : openStartedAt.millisecondsSinceEpoch -
            requestedAt.millisecondsSinceEpoch;
    final bridgeToOpenMs = bridgeReceivedAt == null
        ? null
        : openStartedAt.millisecondsSinceEpoch -
            bridgeReceivedAt.millisecondsSinceEpoch;

    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF1A1A2E),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) {
        final sheetBuiltAt = DateTime.now();
        final openToBuildMs =
            sheetBuiltAt.millisecondsSinceEpoch -
            openStartedAt.millisecondsSinceEpoch;

        unawaited(
          _appLog.log(
            'QuickMenuTiming',
            'Native QoL menu built: '
                'source=$source route=$route '
                'requestToOpenMs=${requestToOpenMs ?? 'unknown'} '
                'bridgeToOpenMs=${bridgeToOpenMs ?? 'unknown'} '
                'openToBuildMs=$openToBuildMs',
          ),
        );

        final tabsService = Provider.of<AndroidTabsService>(
          context,
          listen: false,
        );
        return _QuickMenuSheet(
          tabsEnabled: tabsService.enabled,
          isChatPage: _isChatUrl(_lastKnownUrl),
          onAndroidSettings: () {
          Navigator.pop(sheetContext);
          _openAndroidSettingsPage();
        },
        onChatTabs: () {
          Navigator.pop(sheetContext);
          _showAndroidTabs();
        },
        onCommandPalette: () {
          Navigator.pop(sheetContext);
          _openAndroidCommandPalette();
        },
        onFocusMode: () {
          Navigator.pop(sheetContext);
          _toggleAndroidFocusMode();
        },
        onSettings: () {
          Navigator.pop(sheetContext);
          _requestOpenOptionsPage();
        },
        onExportChat: () {
          Navigator.pop(sheetContext);
          _webController?.evaluateJavascript(
            source: 'window.DragonScriptQoL?.exportCurrentChat?.();',
          );
        },
        onBlockCurrentBot: () {
          Navigator.pop(sheetContext);
          _webController?.evaluateJavascript(
            source: 'window.DragonScriptQoL?.blockCurrentBot?.();',
          );
        },
        onReloadScripts: () async {
          final messenger = ScaffoldMessenger.of(context);
          Navigator.pop(sheetContext);
          if (_webController != null) {
            await _injectScripts(_webController!);
            messenger.showSnackBar(
              const SnackBar(
                content: Text('Scripts re-injected'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        },
        onRecoverWebView: () {
          Navigator.pop(sheetContext);
          _recoverWebView(reason: 'manual quick-menu recovery');
        },
        onCopyLog: () {
          Navigator.pop(sheetContext);
          _copyDiagnosticLog();
        },
        onExportLog: () {
          Navigator.pop(sheetContext);
          _exportDiagnosticLog();
        },
        onClearLog: () {
          Navigator.pop(sheetContext);
          _clearDiagnosticLog();
        },
        onRefresh: () {
          Navigator.pop(sheetContext);
          _webController?.reload();
        },
      );
        },
      );
    } finally {
      _quickMenuOpen = false;
    }
  }
}

class _QuickMenuSheet extends StatelessWidget {
  final bool tabsEnabled;
  final bool isChatPage;
  final VoidCallback onAndroidSettings;
  final VoidCallback onChatTabs;
  final VoidCallback onCommandPalette;
  final VoidCallback onFocusMode;
  final VoidCallback onSettings;
  final VoidCallback onExportChat;
  final VoidCallback onBlockCurrentBot;
  final VoidCallback onReloadScripts;
  final VoidCallback onRecoverWebView;
  final VoidCallback onCopyLog;
  final VoidCallback onExportLog;
  final VoidCallback onClearLog;
  final VoidCallback onRefresh;

  const _QuickMenuSheet({
    required this.tabsEnabled,
    required this.isChatPage,
    required this.onAndroidSettings,
    required this.onChatTabs,
    required this.onCommandPalette,
    required this.onFocusMode,
    required this.onSettings,
    required this.onExportChat,
    required this.onBlockCurrentBot,
    required this.onReloadScripts,
    required this.onRecoverWebView,
    required this.onCopyLog,
    required this.onExportLog,
    required this.onClearLog,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'SpicyChat QOL',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          _QuickMenuItem(
            icon: Icons.phone_android,
            label: 'Android Settings',
            onTap: onAndroidSettings,
          ),
          if (tabsEnabled)
            _QuickMenuItem(
              icon: Icons.tab,
              label: 'Android Chat Tabs',
              onTap: onChatTabs,
            ),
          _QuickMenuItem(
            icon: Icons.search,
            label: 'Command Palette',
            onTap: onCommandPalette,
          ),
          if (isChatPage)
            _QuickMenuItem(
              icon: Icons.center_focus_strong,
              label: 'Focus / Immersive Mode',
              onTap: onFocusMode,
            ),
          _QuickMenuItem(
            icon: Icons.settings,
            label: 'QOL Options',
            onTap: onSettings,
          ),
          _QuickMenuItem(
            icon: Icons.download,
            label: 'Export Chat',
            onTap: onExportChat,
          ),
          _QuickMenuItem(
            icon: Icons.block,
            label: 'Block Current Bot',
            onTap: onBlockCurrentBot,
          ),
          _QuickMenuItem(
            icon: Icons.code,
            label: 'Re-inject Scripts',
            onTap: onReloadScripts,
          ),
          _QuickMenuItem(
            icon: Icons.healing,
            label: 'Recover Black Screen',
            onTap: onRecoverWebView,
          ),
          _QuickMenuItem(
            icon: Icons.copy,
            label: 'Copy App Log',
            onTap: onCopyLog,
          ),
          _QuickMenuItem(
            icon: Icons.description_outlined,
            label: 'Export App Log',
            onTap: onExportLog,
          ),
          _QuickMenuItem(
            icon: Icons.delete_sweep_outlined,
            label: 'Clear App Log',
            onTap: onClearLog,
          ),
          _QuickMenuItem(
            icon: Icons.refresh,
            label: 'Refresh Page',
            onTap: onRefresh,
          ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.deepPurpleAccent),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onTap: onTap,
    );
  }
}
