$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Path = Join-Path $Root "android_app\lib\screens\webview_screen.dart"

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Could not find android_app\lib\screens\webview_screen.dart. Extract this ZIP into the repository root first."
}

$text = [System.IO.File]::ReadAllText(
    $Path,
    [System.Text.UTF8Encoding]::new($false)
)
$text = $text -replace "`r`n", "`n"

function Replace-Exact {
    param(
        [string]$Name,
        [string]$Old,
        [string]$New
    )

    if ($script:text.Contains($New)) {
        Write-Host "[already applied] $Name" -ForegroundColor DarkGray
        return
    }

    if (-not $script:text.Contains($Old)) {
        throw "Could not apply '$Name': expected source block was not found. The local file may differ from current main."
    }

    $script:text = $script:text.Replace($Old, $New)
    Write-Host "[patched] $Name" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 1. Options diagnostics: do not block on a busy long-chat renderer just to
#    describe the one synthetic Android tab.
# ---------------------------------------------------------------------------

$oldQueryMainTab = @'
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
'@

$newQueryMainTab = @'
  Future<Map<String, dynamic>?> _queryAndroidMainTab() async {
    final controller = _webController;
    if (controller == null) return null;

    try {
      // _lastKnownUrl is updated by both full navigation and SPA route
      // changes. Prefer it here so opening Diagnostics/Performance does not
      // wait for WebView.getUrl() while a large chat renderer is busy.
      var currentUrl = _lastKnownUrl;
      var parsed = Uri.tryParse(currentUrl);

      if (parsed == null || !_isSpicyChat(parsed)) {
        final current = await controller
            .getUrl()
            .timeout(const Duration(milliseconds: 650));
        if (current == null || !_isSpicyChat(current)) return null;

        currentUrl = current.toString();
        _lastKnownUrl = currentUrl;
      }

      // The title is cosmetic for the synthetic one-tab bridge. Do not call
      // WebView.getTitle() here: that can stall behind long-chat main-thread
      // work and used to make Android Options report the live page as unknown.
      var title = 'SpicyChat';
      try {
        final tabsService = Provider.of<AndroidTabsService>(
          context,
          listen: false,
        );
        final tabTitle = tabsService.activeTab?.title.trim() ?? '';
        if (tabTitle.isNotEmpty) title = tabTitle;
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
        'url': currentUrl,
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
'@

Replace-Exact `
    -Name "fast Android Options live-tab query" `
    -Old $oldQueryMainTab `
    -New $newQueryMainTab

# ---------------------------------------------------------------------------
# 2. Android Focus Mode safety.
# ---------------------------------------------------------------------------

$focusSafetyMethod = @'
  Future<void> _installAndroidFocusSafetyGuard(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(
        source: r'''(() => {
  const STATE_KEY = "__dsAndroidFocusSafety";
  const SAFE_HIDE_CLASS = "ds-android-focus-safe-hide";
  const STYLE_ID = "ds-android-focus-safe-style";

  const ROOT_ACTIVE = "ds-focus-mode-active";
  const ROOT_HIDE_TOPBAR = "ds-focus-hide-topbar";
  const ROOT_HIDE_CHAT_HEADER = "ds-focus-hide-chat-header";

  const previous = window[STATE_KEY];
  if (previous?.refresh) {
    previous.refresh();
    return;
  }

  let applying = false;
  let observer = null;

  const ensureStyle = () => {
    if (document.getElementById(STYLE_ID)) return;

    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      .${SAFE_HIDE_CLASS} {
        display: none !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  };

  const clearSafeTargets = () => {
    document
      .querySelectorAll(`.${SAFE_HIDE_CLASS}`)
      .forEach(element => element.classList.remove(SAFE_HIDE_CLASS));
  };

  const markAll = selectors => {
    for (const selector of selectors) {
      try {
        document
          .querySelectorAll(selector)
          .forEach(element => element.classList.add(SAFE_HIDE_CLASS));
      } catch {}
    }
  };

  const refresh = () => {
    if (applying) return;
    applying = true;

    try {
      const root = document.documentElement;
      const DS = window.DragonScriptQoL;
      const settings = DS?.state?.settings || {};
      const active =
        root.classList.contains(ROOT_ACTIVE) &&
        !!DS?.isFocusModeActive?.();

      clearSafeTargets();

      if (!active) {
        return;
      }

      // Never allow shared mobile target discovery to hide a large ancestor
      // containing the conversation or composer. Android hides only known
      // leaf/header controls instead.
      root.classList.remove(
        ROOT_HIDE_TOPBAR,
        ROOT_HIDE_CHAT_HEADER
      );

      if (settings.focusHideTopBar !== false) {
        markAll([
          "a[aria-label='avatar']",
          "[data-testid='LocaleSelector']",
          "button[aria-label='notifications']",
          "button[aria-label='theme']"
        ]);
      }

      if (settings.focusHideChatHeader !== false) {
        markAll([
          "a[aria-label='chatbot-profile']",
          "button[aria-label='chat-dropdown']",
          "button[aria-label='ThumbsUp-button']",
          "[data-testid='ChatModelTierCapabilityGate']"
        ]);
      }
    } finally {
      applying = false;
    }
  };

  ensureStyle();

  observer = new MutationObserver(records => {
    if (
      records.some(
        record =>
          record.type === "attributes" &&
          record.attributeName === "class"
      )
    ) {
      queueMicrotask(refresh);
    }
  });

  observer.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["class"]
  });

  window[STATE_KEY] = {
    refresh,
    disconnect() {
      observer?.disconnect();
      observer = null;
      clearSafeTargets();
      document.getElementById(STYLE_ID)?.remove();
      delete window[STATE_KEY];
    }
  };

  refresh();
})()''',
      );
    } catch (e, stackTrace) {
      if (_shouldPersistDiagnostic('android-focus-safety-install')) {
        unawaited(
          _appLog.log(
            'AndroidFocusMode',
            'Could not install Android Focus Mode safety guard',
            level: 'WARN',
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

'@

$injectMarker = @'
  Future<void> _injectScripts(InAppWebViewController controller) async {
'@

Replace-Exact `
    -Name "Android Focus Mode safety guard" `
    -Old $injectMarker `
    -New ($focusSafetyMethod + $injectMarker)

$oldBundleInjection = @'
      await controller.evaluateJavascript(source: widget.bundleService.jsBundle);

      // Android-only Save & Stay marker. Delegated click handling keeps
'@

$newBundleInjection = @'
      await controller.evaluateJavascript(source: widget.bundleService.jsBundle);

      // Shared Focus Mode uses desktop-oriented ancestor targeting. Install a
      // lightweight Android guard after the shared bundle exists so mobile
      // Focus Mode cannot hide the entire chat/composer container.
      await _installAndroidFocusSafetyGuard(controller);

      // Android-only Save & Stay marker. Delegated click handling keeps
'@

Replace-Exact `
    -Name "install Focus safety after shared QoL bundle" `
    -Old $oldBundleInjection `
    -New $newBundleInjection

$oldFocusToggle = @'
  DS.toggleFocusMode();

  return JSON.stringify({
'@

$newFocusToggle = @'
  DS.toggleFocusMode();
  window.__dsAndroidFocusSafety?.refresh?.();

  return JSON.stringify({
'@

Replace-Exact `
    -Name "refresh Focus safety after native toggle" `
    -Old $oldFocusToggle `
    -New $newFocusToggle

# ---------------------------------------------------------------------------
# 3. Explicit response for shared features that require a real background tab.
# ---------------------------------------------------------------------------

$oldRuntimeCases = @'
      case 'DS_LOAD_ALL_CHATS_START':
      case 'DS_LOAD_ALL_CHATS_STOP':
      case 'DS_LOAD_ALL_CHATS_RESCHEDULE':
      case 'DS_LOAD_ALL_CHATS_DONE':
        // These are handled by the JS-side loop in WebView
        return {'ok': true};

      default:
        return {'ok': false, 'error': 'unknown message type'};
'@

$newRuntimeCases = @'
      case 'DS_LOAD_ALL_CHATS_START':
      case 'DS_LOAD_ALL_CHATS_STOP':
      case 'DS_LOAD_ALL_CHATS_RESCHEDULE':
      case 'DS_LOAD_ALL_CHATS_DONE':
        // These are handled by the JS-side loop in WebView
        return {'ok': true};

      case 'DS_LOREBOOK_EXPORT_HELPER':
        // The desktop exporter opens the opposite Lorebook page in a
        // background browser tab. Android intentionally owns one live WebView.
        // Return a useful capability error instead of pretending a hidden tab
        // exists or leaving the shared feature with "unknown message type".
        return {
          'ok': false,
          'android': true,
          'error': 'android-background-tabs-unavailable',
          'message':
              'Full Lorebook helper-tab export is not available in the '
              'single-WebView Android app.',
        };

      case 'DS_CLOSE_CURRENT_TAB':
        return {
          'ok': false,
          'android': true,
          'error': 'android-single-webview',
        };

      default:
        return {'ok': false, 'error': 'unknown message type'};
'@

Replace-Exact `
    -Name "explicit browser-tab capability response" `
    -Old $oldRuntimeCases `
    -New $newRuntimeCases

[System.IO.File]::WriteAllText(
    $Path,
    $text,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "Android WebView fixes applied successfully." -ForegroundColor Cyan
Write-Host "No Git operations were performed." -ForegroundColor DarkGray
