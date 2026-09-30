/**
 * Chrome API shim for the Android copy of the real SpicyChat QOL options page.
 */
(() => {
  "use strict";

  if (window.__spicyChatQolOptionsBridgeInstalled) return;
  window.__spicyChatQolOptionsBridgeInstalled = true;

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
    largeLocalStorage: true,
    chromeStoragePromiseApi: true,
    nativeDownloadsApi: true,
    contentRuntimeMessaging: true,
    optionsRuntimeDiagnostics: true,
    syntheticActiveTabForOptions: true,
    nativeClipboard: true,
    generatedDownloadBridge: true
  });

  try {
    document.documentElement?.setAttribute("data-spicychat-qol-android", "1");
  } catch {}

  const call = (name, ...args) => new Promise((resolve, reject) => {
    const invoke = () => {
      const bridge = window.flutter_inappwebview;
      if (!bridge?.callHandler) {
        reject(new Error("Flutter bridge is unavailable"));
        return;
      }
      bridge.callHandler(name, ...args).then(resolve, reject);
    };

    if (window.flutter_inappwebview?.callHandler) {
      invoke();
      return;
    }

    let finished = false;
    const ready = () => {
      if (finished) return;
      finished = true;
      invoke();
    };

    window.addEventListener("flutterInAppWebViewPlatformReady", ready, { once: true });
    setTimeout(() => {
      if (finished) return;
      finished = true;
      invoke();
    }, 1500);
  });

  const nativeFetch = window.fetch.bind(window);

  const _storageListeners = [];

  function valuesEqual(a, b) {
    if (a === b) return true;
    try { return JSON.stringify(a) === JSON.stringify(b); }
    catch { return false; }
  }

  function emitStorageChanges(changes) {
    if (!changes || typeof changes !== "object" || !Object.keys(changes).length) return;
    for (const listener of [..._storageListeners]) {
      try { listener(changes, "local"); }
      catch (error) {
        console.warn("[DS Options Bridge] storage listener error", error);
      }
    }
  }


  // Android WebView does not reliably allow fetch(file://...) from a local
  // Flutter asset page. The desktop options page uses runtime.getURL() + fetch
  // for CHANGELOG.md, so serve known bundled text assets through Flutter.
  window.fetch = function (input, init) {
    const rawUrl = typeof input === "string" ? input : String(input?.url || "");
    let pathname = rawUrl;
    try {
      const resolved = new URL(rawUrl, location.href);
      pathname = resolved.pathname || rawUrl;
    } catch {}

    const name = pathname.split("/").pop()?.split(/[?#]/, 1)[0] || "";
    if (name === "CHANGELOG.md" || name === "features.md") {
      return call("optionsReadBundledText", name).then(text => {
        if (typeof text !== "string") {
          return new Response("", { status: 404, statusText: "Not Found" });
        }
        return new Response(text, {
          status: 200,
          headers: { "Content-Type": "text/plain; charset=utf-8" }
        });
      });
    }

    return nativeFetch(input, init);
  };

  function parseStored(raw) {
    try { return typeof raw === "string" ? JSON.parse(raw) : (raw || {}); }
    catch { return {}; }
  }

  const storageLocal = {
    get(keys, callback) {
      const promise = call("optionsStorageGet", JSON.stringify(keys ?? null))
        .then(raw => parseStored(raw))
        .catch(() => ({}));
      if (callback) promise.then(callback);
      return promise;
    },

    set(obj, callback) {
      const next = obj && typeof obj === "object" ? obj : {};
      const keys = Object.keys(next);
      const promise = storageLocal.get(keys).then(before =>
        call("optionsStorageSet", JSON.stringify(next)).then(() => {
          const changes = {};
          for (const key of keys) {
            const oldValue = before?.[key];
            const newValue = next[key];
            if (!valuesEqual(oldValue, newValue)) {
              changes[key] = { oldValue, newValue };
            }
          }
          emitStorageChanges(changes);
        })
      ).catch(() => {});
      if (callback) promise.then(() => callback());
      return promise;
    },

    remove(keys, callback) {
      const list = Array.isArray(keys)
        ? keys.map(String)
        : [String(keys ?? "")].filter(Boolean);
      const promise = storageLocal.get(list).then(before =>
        call("optionsStorageRemove", JSON.stringify(list)).then(() => {
          const changes = {};
          for (const key of list) {
            if (Object.prototype.hasOwnProperty.call(before || {}, key)) {
              changes[key] = { oldValue: before[key] };
            }
          }
          emitStorageChanges(changes);
        })
      ).catch(() => {});
      if (callback) promise.then(() => callback());
      return promise;
    },

    clear(callback) {
      const promise = storageLocal.get(null).then(before =>
        call("optionsStorageClear").then(() => {
          const changes = {};
          for (const [key, oldValue] of Object.entries(before || {})) {
            changes[key] = { oldValue };
          }
          emitStorageChanges(changes);
        })
      ).catch(() => {});
      if (callback) promise.then(() => callback());
      return promise;
    },

    getBytesInUse(keys, callback) {
      const promise = call("optionsStorageGetBytesInUse", JSON.stringify(keys ?? null))
        .then(bytes => Number(bytes) || 0)
        .catch(() => 0);
      if (callback) promise.then(callback);
      return promise;
    },

    getKeys(callback) {
      const promise = storageLocal.get(null).then(obj => Object.keys(obj || {}));
      if (callback) promise.then(callback);
      return promise;
    }
  };

  const storageOnChanged = {
    addListener(listener) {
      if (typeof listener === "function" && !_storageListeners.includes(listener)) {
        _storageListeners.push(listener);
      }
    },
    removeListener(listener) {
      const index = _storageListeners.indexOf(listener);
      if (index >= 0) _storageListeners.splice(index, 1);
    },
    hasListener(listener) {
      return _storageListeners.includes(listener);
    }
  };


  function androidPlatformInfo() {
    return {
      os: "android",
      arch: "arm64",
      nacl_arch: "arm64"
    };
  }

  function queryAndroidMainTab() {
    return call("optionsMainTabQuery")
      .then(tab => (tab && typeof tab === "object") ? tab : null)
      .catch(() => null);
  }

  function sendAndroidMainTabMessage(message) {
    return call(
      "optionsMainTabMessage",
      JSON.stringify(message ?? null)
    ).catch(() => null);
  }

  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

  function androidEnvironmentSnapshot() {
    return {
      android: true,
      webview: true,
      installedApp: true,
      displayMode: "standalone",
      firefox: false,
      waterfox: false,
      opera: false,
      chromium: true,
      dedicatedApp: true
    };
  }

  function normalizePageDiagnostics(raw) {
    let value = raw;

    if (typeof value === "string") {
      try { value = JSON.parse(value); }
      catch { return null; }
    }

    // Be tolerant of either a direct content response or a bridge envelope.
    if (
      value &&
      typeof value === "object" &&
      value.ok === true &&
      Object.prototype.hasOwnProperty.call(value, "response")
    ) {
      value = value.response;
    }

    if (!value || typeof value !== "object") return null;

    return {
      ...value,
      androidEnvironment: {
        ...(value.androidEnvironment || {}),
        ...androidEnvironmentSnapshot()
      }
    };
  }

  async function queryAndroidMainTabWithRetry() {
    const delays = [0, 80, 180, 320];
    for (const delay of delays) {
      if (delay) await wait(delay);
      const tab = await queryAndroidMainTab();
      if (tab?.url) return tab;
    }
    return null;
  }

  async function queryAndroidPageDiagnosticsWithRetry() {
    const delays = [0, 80, 180, 320];
    for (const delay of delays) {
      if (delay) await wait(delay);
      const response = normalizePageDiagnostics(
        await sendAndroidMainTabMessage({
          type: "DS_GET_PAGE_DIAGNOSTICS"
        })
      );
      if (response) return response;
    }
    return null;
  }

  function partialAndroidPageDiagnostics(tab) {
    return {
      androidEnvironment: androidEnvironmentSnapshot(),
      runtimePerformance: {},
      performance: [],
      androidPartialDiagnostics: true,
      androidNativeBridge: true,
      url: String(tab?.url || "")
    };
  }

  const runtime = {
    id: "spicychat-qol-android",
    lastError: null,

    getManifest() {
      return {
        name: "SpicyChat QOL",
        version: String(window.__spicyChatQolBundledVersion || "0.0.0")
      };
    },

    getPlatformInfo(callback) {
      const info = androidPlatformInfo();
      if (callback) queueMicrotask(() => callback(info));
      return Promise.resolve(info);
    },

    getURL(path) {
      return String(path || "");
    },

    sendMessage(message, callback) {
      const promise = (async () => {
        if (message?.type === "DS_GET_DIAGNOSTIC_CONTEXT") {
          const tab = await queryAndroidMainTabWithRetry();

          if (!tab?.url) {
            // Keep the Android identity visible even when the main WebView is
            // between navigations. This also lets the baseline UI save a
            // clearly marked Options-only partial snapshot instead of failing
            // with "No performance baseline saved yet".
            return {
              ok: false,
              runtimeAvailable: false,
              url: "",
              title: "",
              pageDiagnostics: partialAndroidPageDiagnostics(null),
              androidNativeBridge: true,
              androidPartialDiagnostics: true
            };
          }

          const liveDiagnostics =
            await queryAndroidPageDiagnosticsWithRetry();
          const pageDiagnostics =
            liveDiagnostics || partialAndroidPageDiagnostics(tab);

          return {
            ok: true,
            runtimeAvailable: !!liveDiagnostics,
            url: tab.url || "",
            title: tab.title || "",
            pageDiagnostics,
            androidNativeBridge: true,
            androidPartialDiagnostics: !liveDiagnostics
          };
        }

        return await sendAndroidMainTabMessage(message);
      })().catch(() => null);

      if (callback) promise.then(callback);
      return promise;
    },

    onMessage: {
      addListener() {},
      removeListener() {},
      hasListener() { return false; }
    }
  };

  const tabs = {
    query(_queryInfo, callback) {
      const promise = queryAndroidMainTab().then(tab => tab ? [tab] : []);
      if (callback) promise.then(callback);
      return promise;
    },

    get(tabId, callback) {
      const promise = queryAndroidMainTab().then(tab => {
        if (!tab || Number(tabId) !== Number(tab.id)) return null;
        return tab;
      });
      if (callback) promise.then(callback);
      return promise;
    },

    sendMessage(tabId, message, callback) {
      const promise = queryAndroidMainTab().then(tab => {
        if (!tab || Number(tabId) !== Number(tab.id)) return null;
        return sendAndroidMainTabMessage(message);
      });
      if (callback) promise.then(callback);
      return promise;
    },

    __spicyChatQolAndroidUnsupported: true,
    __spicyChatQolAndroidSyntheticActiveTabOnly: true
  };

  window.chrome = {
    storage: {
      local: storageLocal,
      onChanged: storageOnChanged
    },

    permissions: {
      // Host permissions are an extension concept. Android's native bridge
      // remains restricted to the app/local options and trusted SpicyChat URLs.
      request(_permission, callback) {
        const promise = Promise.resolve(true);
        if (callback) promise.then(callback);
        return promise;
      }
    },

    runtime,
    tabs,

    downloads: {
      download(options, callback) {
        const promise = (async () => {
          const filename = String(options?.filename || "spicychat-qol-export.json");
          const url = String(options?.url || "");
          if (!url) throw new Error("Missing download URL");
          const response = await fetch(url);
          const blob = await response.blob();
          const bytes = new Uint8Array(await blob.arrayBuffer());
          const result = await call("saveFile", JSON.stringify({
            filename,
            fileName: filename,
            mimeType: blob.type || "application/octet-stream",
            base64: bytesToBase64(bytes)
          }));
          if (result?.canceled) throw new Error("Download canceled");
          return 1;
        })();
        if (callback) {
          promise.then(id => callback(id)).catch(() => callback(undefined));
        }
        return promise;
      },
      onChanged: {
        addListener() {},
        removeListener() {},
        hasListener() { return false; }
      }
    }
  };


  // Browser-tab/session features cannot map 1:1 to the APK's lightweight
  // Android chat tabs. Keep saved desktop values intact, but make unsupported
  // controls visibly unavailable instead of letting them fail.
  const androidBrowserOnlySectionRules = [
    { re: /^Extension popup$/i, note: "The Android app uses its native QoL menu instead of the browser extension popup." },
    { re: /Inactive tab cleanup|Auto[- ]AFK/i, note: "Auto-AFK manages real browser tabs. Android uses one WebView plus lightweight chat-tab state." },
    { re: /Duplicate SpicyChat tab guard|Duplicate Tab Guard/i, note: "The browser duplicate-tab guard does not apply to Android's native chat tabs." },
    { re: /Tab cleanup|session analysis|Tab Session Library/i, note: "Browser tab/session analysis requires real browser tabs and background tab creation." }
  ];

  const androidBrowserOnlyFeatureRules = [
    /\bAuto[- ]AFK\b/i,
    /\bDuplicate tab guard\b/i,
    /\bDuplicate SpicyChat tab guard\b/i,
    /\bTab cleanup\b/i,
    /\bSession Analysis\b/i,
    /\bTab Session Library\b/i,
    /\bPer-tab QoL switch\b/i,
    /\bExtension popup\b/i
  ];

  const androidBrowserOnlyTextRules = [
    /Open selected in new window/i,
    /Collect open tabs/i,
    /Analyze\s*\/\s*enrich open bots/i,
    /Retry unresolved/i,
    /Save current session snapshot/i,
    /Check duplicate tabs now/i,
    /Run cleanup check now/i
  ];

  function androidText(node) {
    return String(node?.textContent || "").replace(/\s+/g, " ").trim();
  }

  function appendAndroidUnavailableNote(node, message) {
    if (!(node instanceof HTMLElement)) return;
    if (node.querySelector(":scope > .ds-android-browser-only-note")) return;
    const note = document.createElement("div");
    note.className = "ds-android-browser-only-note";
    note.textContent = message;
    note.style.cssText =
      "margin:8px 0 0;padding:8px 10px;border-radius:8px;" +
      "background:rgba(123,97,255,.11);color:#c7baff;font-size:11px;" +
      "line-height:1.4;";
    node.appendChild(note);
  }

  function disableAndroidBrowserOnlySection(section, message) {
    if (!(section instanceof HTMLElement)) return;
    if (section.dataset.dsAndroidBrowserOnly === "1") return;
    section.dataset.dsAndroidBrowserOnly = "1";
    section.style.opacity = "0.62";
    section.querySelectorAll("input, select, textarea, button").forEach(control => {
      if (control.matches(".settings-card-toggle, .settings-card-pin, .settings-card-reset")) return;
      control.disabled = true;
      control.setAttribute("aria-disabled", "true");
    });
    appendAndroidUnavailableNote(section.querySelector(".settings-card-body") || section, message);
  }

  function markAndroidBrowserOnlySections(root = document) {
    const pages = [];
    if (root.matches?.('[data-page="browser"]')) pages.push(root);
    root.querySelectorAll?.('[data-page="browser"]')?.forEach(page => pages.push(page));
    if (root === document) document.querySelectorAll('[data-page="browser"]').forEach(page => pages.push(page));

    for (const page of [...new Set(pages)]) {
      page.querySelectorAll("section.card").forEach(section => {
        const heading = androidText(section.querySelector("h2"));
        const rule = androidBrowserOnlySectionRules.find(item => item.re.test(heading));
        if (rule) disableAndroidBrowserOnlySection(section, rule.note);
      });
    }

    root.querySelectorAll?.("button, input, select")?.forEach(control => {
      if (!(control instanceof HTMLElement)) return;
      const text = androidText(control);
      if (!androidBrowserOnlyTextRules.some(re => re.test(text))) return;
      control.disabled = true;
      control.setAttribute("aria-disabled", "true");
      control.style.opacity = "0.58";
      control.title = "Unavailable in the Android app because it requires real browser tabs.";
    });
  }

  function markAndroidFeatureCatalog(root = document) {
    root.querySelectorAll?.(".feature-index-item, .feature-catalog-item")?.forEach(item => {
      if (!(item instanceof HTMLElement)) return;
      const title = androidText(item.querySelector(".feature-index-title") || item.querySelector("strong") || item);
      if (!androidBrowserOnlyFeatureRules.some(re => re.test(title))) return;
      if (item.dataset.dsAndroidBrowserOnly === "1") return;
      item.dataset.dsAndroidBrowserOnly = "1";
      item.style.opacity = "0.65";
      const button = item.querySelector("button");
      if (button) {
        button.disabled = true;
        button.textContent = "Unavailable on Android";
      }
      const badges = item.querySelector(".feature-index-badges") || item.querySelector(".feature-index-main");
      if (badges && !item.querySelector(".ds-android-feature-badge")) {
        const badge = document.createElement("span");
        badge.className = "feature-badge ds-android-feature-badge";
        badge.textContent = "Android: browser-only";
        badges.appendChild(badge);
      }
    });
  }

  function markAndroidSettingsSearchResults(root = document) {
    root.querySelectorAll?.(".settings-search-result")?.forEach(result => {
      if (!(result instanceof HTMLElement)) return;
      const text = androidText(result);
      if (!androidBrowserOnlyFeatureRules.some(re => re.test(text)) &&
          !androidBrowserOnlyTextRules.some(re => re.test(text))) return;
      result.hidden = true;
      result.dataset.dsAndroidBrowserOnly = "1";
    });
  }

  function updateAndroidEnvironmentCopy(root = document) {
    const status = root.querySelector?.("#androidEnvironmentStatus");
    if (status) {
      status.textContent =
        "Dedicated SpicyChat QoL Android app detected. Mobile / Compact settings use the Android-safe WebView path.";
    }
  }

  function installAndroidCommandPaletteHandoff(root = document) {
    const button = root.querySelector?.("#openCommandPaletteFromOptions");
    if (!button || button.dataset.dsAndroidMainAction === "1") return;
    button.dataset.dsAndroidMainAction = "1";
    button.title = "Close Settings and open the palette in the main SpicyChat view";
    button.addEventListener("click", event => {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      const status = document.querySelector("#commandPaletteStatus");
      if (status) status.textContent = "Opening Command Palette in SpicyChat…";
      call("optionsOpenMainAction", "commandPalette").catch(error => {
        console.warn("[DS Options Bridge] Could not open Command Palette", error);
        if (status) status.textContent = "Could not hand the Command Palette back to the Android app.";
      });
    }, true);
  }

  function applyAndroidOptionsCompatibility(root = document) {
    markAndroidBrowserOnlySections(root);
    markAndroidFeatureCatalog(root);
    markAndroidSettingsSearchResults(root);
    updateAndroidEnvironmentCopy(root);
    installAndroidCommandPaletteHandoff(root);
  }

  function installAndroidOptionsCompatibility() {
    applyAndroidOptionsCompatibility(document);
    const observer = new MutationObserver(records => {
      let needsFullPass = false;
      for (const record of records) {
        for (const node of record.addedNodes || []) {
          if (!(node instanceof Element)) continue;
          applyAndroidOptionsCompatibility(node);
          needsFullPass = true;
        }
      }
      if (needsFullPass) {
        markAndroidSettingsSearchResults(document);
        markAndroidFeatureCatalog(document);
        installAndroidCommandPaletteHandoff(document);
      }
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });

    document.addEventListener("input", event => {
      if (event.target?.id === "settingsSearch") {
        queueMicrotask(() => markAndroidSettingsSearchResults(document));
        setTimeout(() => markAndroidSettingsSearchResults(document), 0);
      }
    }, true);

    document.addEventListener("click", () => {
      setTimeout(() => applyAndroidOptionsCompatibility(document), 0);
      setTimeout(() => applyAndroidOptionsCompatibility(document), 80);
    }, true);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", installAndroidOptionsCompatibility, { once: true });
  } else {
    installAndroidOptionsCompatibility();
  }

  function bytesToBase64(bytes) {
    let binary = "";
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
  }

  window._dsSaveFile = function (content, filename, mimeType) {
    return call("saveFile", JSON.stringify({
      text: String(content ?? ""),
      content: String(content ?? ""),
      filename: String(filename || "spicychat-qol-export.txt"),
      fileName: String(filename || "spicychat-qol-export.txt"),
      mimeType: String(mimeType || "text/plain;charset=utf-8")
    }));
  };


  function acceptToExtensions(accept) {
    return String(accept || "")
      .split(",")
      .map(part => part.trim().toLowerCase())
      .filter(part => /^\.[a-z0-9]{1,12}$/.test(part))
      .map(part => part.slice(1));
  }

  function base64ToBytes(base64) {
    const binary = atob(String(base64 || ""));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // Local file:// Options pages do not get a reliable Android file chooser on
  // every WebView build. Route explicit file inputs through Flutter's picker.
  document.addEventListener("click", event => {
    const input = event.target?.closest?.('input[type="file"]');
    if (!input || input.dataset.dsAndroidNativePickerBusy === "1") return;

    event.preventDefault();
    event.stopPropagation();
    input.dataset.dsAndroidNativePickerBusy = "1";

    call("pickFiles", JSON.stringify({
      allowedExtensions: acceptToExtensions(input.accept)
    })).then(result => {
      if (!result?.base64) return;
      const bytes = base64ToBytes(result.base64);
      const name = String(result.name || result.fileName || "backup.json");
      const file = new File([bytes], name, { type: "application/octet-stream" });
      const transfer = new DataTransfer();
      transfer.items.add(file);
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }).catch(error => {
      console.warn("[DS Options Bridge] Native file picker failed", error);
    }).finally(() => {
      delete input.dataset.dsAndroidNativePickerBusy;
    });
  }, true);

  // Generic generated-download bridge for Android Options.
  // Handles detached/programmatic <a download>.click() in addition to normal
  // attached link clicks.
  const _androidGeneratedBlobs = new Map();
  const _optionsOriginalCreateObjectURL =
    typeof URL.createObjectURL === "function"
      ? URL.createObjectURL.bind(URL)
      : null;
  const _optionsOriginalRevokeObjectURL =
    typeof URL.revokeObjectURL === "function"
      ? URL.revokeObjectURL.bind(URL)
      : null;
  const _optionsOriginalAnchorClick = HTMLAnchorElement.prototype.click;

  function isAndroidGeneratedHref(href) {
    const value = String(href || "");
    return value.startsWith("blob:") || value.startsWith("data:");
  }

  function androidGeneratedFilename(link) {
    const requested = String(link?.download || "").trim();
    if (requested) return requested;
    return "spicychat-qol-export.txt";
  }

  async function saveAndroidGeneratedBlob(blob, filename) {
    const bytes = new Uint8Array(await blob.arrayBuffer());
    return call("saveFile", JSON.stringify({
      filename,
      fileName: filename,
      mimeType: blob.type || "application/octet-stream",
      base64: bytesToBase64(bytes)
    }));
  }

  async function saveAndroidGeneratedHref(href, filename) {
    const value = String(href || "");
    let blob = _androidGeneratedBlobs.get(value) || null;

    if (!blob) {
      const response = await fetch(value);
      blob = await response.blob();
    }

    return saveAndroidGeneratedBlob(blob, filename);
  }

  function routeOptionsGeneratedAnchor(link, source = "anchor") {
    if (!(link instanceof HTMLAnchorElement)) return false;

    const href = String(link.href || "");
    if (!link.hasAttribute("download") || !isAndroidGeneratedHref(href)) {
      return false;
    }

    if (link.dataset.dsAndroidNativeDownloadBusy === "1") {
      return true;
    }

    link.dataset.dsAndroidNativeDownloadBusy = "1";
    const filename = androidGeneratedFilename(link);

    saveAndroidGeneratedHref(href, filename)
      .then(result => {
        if (!result?.canceled) {
          console.log(
            `[DS Options Bridge] Native generated download saved (${source}): ${filename}`
          );
        }
      })
      .catch(error => {
        console.warn(
          `[DS Options Bridge] Native generated download failed (${source})`,
          error
        );
      })
      .finally(() => {
        delete link.dataset.dsAndroidNativeDownloadBusy;
      });

    return true;
  }

  if (_optionsOriginalCreateObjectURL) {
    URL.createObjectURL = function dsAndroidOptionsCreateObjectURL(object) {
      const url = _optionsOriginalCreateObjectURL(object);
      if (object instanceof Blob) {
        _androidGeneratedBlobs.set(url, object);
      }
      return url;
    };
  }

  if (_optionsOriginalRevokeObjectURL) {
    URL.revokeObjectURL = function dsAndroidOptionsRevokeObjectURL(url) {
      const value = String(url || "");
      const result = _optionsOriginalRevokeObjectURL(value);
      setTimeout(() => _androidGeneratedBlobs.delete(value), 0);
      return result;
    };
  }

  HTMLAnchorElement.prototype.click = function dsAndroidOptionsAnchorClick() {
    if (routeOptionsGeneratedAnchor(this, "programmatic-click")) {
      return;
    }
    return _optionsOriginalAnchorClick.call(this);
  };

  document.addEventListener("click", event => {
    const target =
      event.target instanceof Element
        ? event.target
        : event.target?.parentElement;
    const link = target?.closest?.("a[download]");
    if (!link) return;

    if (!routeOptionsGeneratedAnchor(link, "document-click")) return;

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
  }, true);

  window._dsSaveGeneratedDownload = async function (
    source,
    filename = "spicychat-qol-export.txt",
    mimeType = "application/octet-stream"
  ) {
    if (source instanceof Blob) {
      return saveAndroidGeneratedBlob(source, String(filename));
    }

    if (source instanceof ArrayBuffer) {
      return saveAndroidGeneratedBlob(
        new Blob([source], { type: String(mimeType) }),
        String(filename)
      );
    }

    if (ArrayBuffer.isView(source)) {
      return saveAndroidGeneratedBlob(
        new Blob(
          [source.buffer.slice(
            source.byteOffset,
            source.byteOffset + source.byteLength
          )],
          { type: String(mimeType) }
        ),
        String(filename)
      );
    }

    const value = String(source || "");
    if (isAndroidGeneratedHref(value)) {
      return saveAndroidGeneratedHref(value, String(filename));
    }

    return saveAndroidGeneratedBlob(
      new Blob([value], { type: String(mimeType) }),
      String(filename)
    );
  };

  document.addEventListener("click", event => {
    const link = event.target.closest?.("a[href]");
    if (!link) return;

    let url;
    try { url = new URL(link.href, location.href); }
    catch { return; }

    if (url.protocol !== "http:" && url.protocol !== "https:") return;

    event.preventDefault();
    event.stopPropagation();
    call("optionsOpenExternal", url.href).catch(() => {});
  }, true);
})();

// === DS QOL ANDROID ACCOUNT SYNC HOTFIX BEGIN ===
"use strict";

(() => {
  if (window.__dsQolAndroidSyncServiceInstalled) return;
  window.__dsQolAndroidSyncServiceInstalled = true;
  const IS_ANDROID_OPTIONS = !!window.__spicyChatQolOptionsBridgeInstalled;
  const API_BASE = "https://syncqol.drache.uk";
  const ANDROID_SYNC_BUILD = "0.2.25-android-hotfix-1";
  const STATE_KEY = "qolSyncStateV1";
  const AUTH_KEY = "qolSyncAuthV1";
  const GRANULAR_PREFIX = "dsSettingV1:";
  const INDEX_KEY = "dsSettingsIndexV1";
  const MIGRATION_KEY = "dsGranularSettingsV1";
  const REVISION_KEY = "dsSettingsRevisionV1";
  const ALARM_NAME = "ds-qol-account-sync-v1";
  const SYNC_INTERVAL_MINUTES = 5;
  const REQUEST_TIMEOUT_MS = 30000;
  const MAX_PUSH_KEYS = 20;

  let pendingLocalPatch = new Map();
  let pendingLocalDeleted = new Set();
  let pushTimer = null;
  let syncChain = Promise.resolve();
  const remoteExpectedWrites = new Map();

  function now() {
    return Date.now();
  }

  function randomUuid() {
    try {
      return crypto.randomUUID();
    } catch {
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = [...bytes].map(v => v.toString(16).padStart(2, "0")).join("");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }
  }

  function normalizeState(value) {
    const source = value && typeof value === "object" && !Array.isArray(value) ? value : {};
    return {
      schemaVersion: 1,
      deviceId: String(source.deviceId || "").trim(),
      deviceCreatedAt: Math.max(0, Number(source.deviceCreatedAt || 0)),
      accountId: String(source.accountId || "").trim(),
      linkedAt: Math.max(0, Number(source.linkedAt || 0)),
      automatic: source.automatic !== false,
      paused: source.paused === true,
      lastRevision: Math.max(0, Number(source.lastRevision || 0)),
      lastSyncAt: Math.max(0, Number(source.lastSyncAt || 0)),
      lastSyncAttemptAt: Math.max(0, Number(source.lastSyncAttemptAt || 0)),
      lastLocalStorageRevision: Math.max(0, Number(source.lastLocalStorageRevision || 0)),
      lastError: String(source.lastError || "").slice(0, 500),
      lastErrorAt: Math.max(0, Number(source.lastErrorAt || 0)),
      lastStatus: String(source.lastStatus || "").slice(0, 80)
    };
  }

  function normalizeAuth(value) {
    const source = value && typeof value === "object" && !Array.isArray(value) ? value : {};
    return {
      token: String(source.token || "").trim()
    };
  }

  function storageGet(keys) {
    return new Promise(resolve => {
      try {
        chrome.storage.local.get(keys, result => resolve(chrome.runtime.lastError ? {} : (result || {})));
      } catch {
        resolve({});
      }
    });
  }

  function storageSet(value) {
    return new Promise(resolve => {
      try {
        chrome.storage.local.set(value, () => resolve(!chrome.runtime.lastError));
      } catch {
        resolve(false);
      }
    });
  }

  function storageRemove(keys) {
    return new Promise(resolve => {
      try {
        chrome.storage.local.remove(keys, () => resolve(!chrome.runtime.lastError));
      } catch {
        resolve(false);
      }
    });
  }

  async function getStateAndAuth() {
    const data = await storageGet([STATE_KEY, AUTH_KEY]);
    const state = normalizeState(data[STATE_KEY]);
    const auth = normalizeAuth(data[AUTH_KEY]);
    if (!state.deviceId) {
      state.deviceId = randomUuid();
      state.deviceCreatedAt = now();
      await storageSet({ [STATE_KEY]: state });
    }
    return { state, auth };
  }

  async function saveStatePatch(patch) {
    const current = await storageGet([STATE_KEY]);
    const next = { ...normalizeState(current[STATE_KEY]), ...(patch || {}) };
    await storageSet({ [STATE_KEY]: next });
    return next;
  }

  function safeErrorMessage(error) {
    if (!error) return "Unknown sync error";
    if (typeof error === "string") return error.slice(0, 500);
    return String(error.message || error.error || error.statusText || error).slice(0, 500);
  }

  async function api(path, { method = "GET", token = "", body = null, timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Math.max(1000, Number(timeoutMs) || REQUEST_TIMEOUT_MS));
    try {
      const headers = { Accept: "application/json" };
      if (body !== null) headers["Content-Type"] = "application/json";
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await fetch(`${API_BASE}${path}`, {
        method,
        headers,
        body: body === null ? undefined : JSON.stringify(body),
        cache: "no-store",
        signal: controller.signal
      });
      let payload = null;
      try { payload = await response.json(); }
      catch { payload = null; }
      if (!response.ok) {
        const err = new Error(payload?.message || `Sync API returned HTTP ${response.status}`);
        err.code = payload?.error || `http_${response.status}`;
        err.status = response.status;
        err.payload = payload;
        throw err;
      }
      return payload || { ok: true };
    } finally {
      clearTimeout(timer);
    }
  }

  function equalValue(a, b) {
    if (Object.is(a, b)) return true;
    if (a == null || b == null || typeof a !== "object" || typeof b !== "object") return false;
    try { return JSON.stringify(a) === JSON.stringify(b); }
    catch { return false; }
  }

  async function currentLocalSettings() {
    const first = await storageGet([INDEX_KEY, REVISION_KEY]);
    const index = [...new Set((Array.isArray(first[INDEX_KEY]) ? first[INDEX_KEY] : [])
      .map(name => String(name || "").trim())
      .filter(Boolean))].sort();
    if (!index.length) return { settings: {}, index: [], localRevision: Number(first[REVISION_KEY] || 0) || 0 };
    const keys = index.map(name => `${GRANULAR_PREFIX}${name}`);
    const values = await storageGet(keys);
    const settings = {};
    for (const name of index) {
      const key = `${GRANULAR_PREFIX}${name}`;
      if (Object.prototype.hasOwnProperty.call(values, key)) settings[name] = values[key];
    }
    return { settings, index, localRevision: Number(first[REVISION_KEY] || 0) || 0 };
  }

  async function ensureSyncAlarm() {
    // Android has no extension background alarm service. The APK-owned bridge
    // keeps this sync engine alive in the active WebView and uses a timer below.
    return true;
  }

  function queued(task) {
    const run = syncChain.then(task, task);
    syncChain = run.catch(() => {});
    return run;
  }

  async function recordFailure(error, status = "Error") {
    const message = safeErrorMessage(error);
    await saveStatePatch({
      lastSyncAttemptAt: now(),
      lastError: message,
      lastErrorAt: now(),
      lastStatus: status
    });
    return { ok: false, error: error?.code || "sync_error", message };
  }

  async function pushPatch(changes, deletedKeys = [], options = {}) {
    const changeEntries = Object.entries(changes || {}).filter(([key]) => !!String(key || "").trim());
    const cleanDeleted = [...new Set((deletedKeys || []).map(key => String(key || "").trim()).filter(Boolean))];
    if (!changeEntries.length && !cleanDeleted.length) return { ok: true, applied: 0 };

    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token || state.paused || state.automatic === false) return { ok: false, skipped: true, reason: "not-linked-or-paused" };

    const payloadChanges = Object.fromEntries(changeEntries);
    try {
      const result = await api("/v1/sync", {
        method: "POST",
        token: auth.token,
        body: {
          changes: payloadChanges,
          deletedKeys: cleanDeleted,
          baseRevision: options.baseRevision == null ? state.lastRevision : Number(options.baseRevision || 0)
        }
      });
      const patch = {
        // Do not advance lastRevision here. A different device may have written
        // unrelated settings between our last pull and this accepted push. We
        // only advance the pull cursor after GET /v1/sync has actually delivered
        // every intervening revision, otherwise those remote changes could be
        // skipped forever.
        lastSyncAt: now(),
        lastSyncAttemptAt: now(),
        lastError: "",
        lastErrorAt: 0,
        lastStatus: `Uploaded ${Number(result.applied || changeEntries.length + cleanDeleted.length)} setting${Number(result.applied || changeEntries.length + cleanDeleted.length) === 1 ? "" : "s"}`
      };
      if (options.localRevision) patch.lastLocalStorageRevision = Math.max(state.lastLocalStorageRevision, Number(options.localRevision || 0));
      await saveStatePatch(patch);
      return { ok: true, ...result };
    } catch (error) {
      if (error?.status === 409 && error?.code === "sync_conflict") {
        await saveStatePatch({
          lastSyncAttemptAt: now(),
          lastError: "Settings changed on another device. Pulling the latest cloud values before retrying.",
          lastErrorAt: now(),
          lastStatus: "Conflict"
        });
        return { ok: false, conflict: true, revision: Number(error?.payload?.revision || 0), conflictKeys: error?.payload?.conflictKeys || [] };
      }
      return recordFailure(error, "Upload failed");
    }
  }

  function logicalPatchBatches(changes, deletedKeys = []) {
    const changeMap = new Map(Object.entries(changes || {}).filter(([key]) => !!String(key || "").trim()));
    const deleted = [...new Set((deletedKeys || []).map(key => String(key || "").trim()).filter(Boolean))]
      .filter(key => !changeMap.has(key));
    const ordered = [
      ...[...changeMap.keys()].map(key => ({ key, deleted: false })),
      ...deleted.map(key => ({ key, deleted: true }))
    ];
    const batches = [];
    for (let start = 0; start < ordered.length; start += MAX_PUSH_KEYS) {
      const slice = ordered.slice(start, start + MAX_PUSH_KEYS);
      const batchChanges = {};
      const batchDeleted = [];
      for (const item of slice) {
        if (item.deleted) batchDeleted.push(item.key);
        else batchChanges[item.key] = changeMap.get(item.key);
      }
      batches.push({ changes: batchChanges, deletedKeys: batchDeleted });
    }
    return batches;
  }

  async function pushPatchBatches(changes, deletedKeys = [], options = {}) {
    const batches = logicalPatchBatches(changes, deletedKeys);
    if (!batches.length) return { ok: true, applied: 0, revision: options.baseRevision ?? null };
    let revision = options.baseRevision == null ? null : Number(options.baseRevision || 0);
    let applied = 0;
    for (let index = 0; index < batches.length; index += 1) {
      const batch = batches[index];
      const isLast = index === batches.length - 1;
      const result = await pushPatch(batch.changes, batch.deletedKeys, {
        baseRevision: revision,
        // Only mark the local storage revision as synced after every logical
        // batch made it to the server.
        localRevision: isLast ? Number(options.localRevision || 0) : 0
      });
      if (!result?.ok) return result;
      applied += Number(result.applied || Object.keys(batch.changes).length + batch.deletedKeys.length);
      revision = Number(result.revision || revision || 0);
    }
    return { ok: true, applied, revision };
  }

  async function pushFullLocalSettings({ baseRevision = null } = {}) {
    const local = await currentLocalSettings();
    const entries = Object.entries(local.settings);
    if (!entries.length) {
      await saveStatePatch({ lastLocalStorageRevision: local.localRevision, lastSyncAt: now(), lastStatus: "Nothing to upload", lastError: "", lastErrorAt: 0 });
      return { ok: true, applied: 0 };
    }

    const result = await pushPatchBatches(local.settings, [], {
      baseRevision,
      localRevision: local.localRevision
    });
    if (!result?.ok) return result;
    const applied = Number(result.applied || entries.length);
    await saveStatePatch({ lastLocalStorageRevision: local.localRevision, lastStatus: `Uploaded ${applied} settings`, lastError: "", lastErrorAt: 0 });
    return { ok: true, applied, revision: result.revision };
  }

  async function applyRemotePayload(changes, deletedKeys) {
    const changeEntries = Object.entries(changes || {});
    const deletes = [...new Set((deletedKeys || []).map(key => String(key || "").trim()).filter(Boolean))];
    if (!changeEntries.length && !deletes.length) return { changed: 0 };

    const first = await storageGet([INDEX_KEY]);
    const index = new Set((Array.isArray(first[INDEX_KEY]) ? first[INDEX_KEY] : []).map(String).filter(Boolean));
    const setPayload = { [MIGRATION_KEY]: true };
    const removeKeys = [];

    for (const [name, value] of changeEntries) {
      const key = `${GRANULAR_PREFIX}${name}`;
      remoteExpectedWrites.set(key, { deleted: false, value });
      setPayload[key] = value;
      index.add(name);
    }
    for (const name of deletes) {
      const key = `${GRANULAR_PREFIX}${name}`;
      remoteExpectedWrites.set(key, { deleted: true });
      removeKeys.push(key);
      index.delete(name);
    }
    setPayload[INDEX_KEY] = [...index].sort();

    if (removeKeys.length) await storageRemove(removeKeys);
    await storageSet(setPayload);
    return { changed: changeEntries.length + deletes.length };
  }

  async function pullRemote({ since = null } = {}) {
    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token || state.paused || state.automatic === false) return { ok: false, skipped: true, reason: "not-linked-or-paused" };

    let cursor = since == null ? state.lastRevision : Math.max(0, Number(since || 0));
    let finalRevision = state.lastRevision;
    let changed = 0;
    try {
      for (let page = 0; page < 20; page += 1) {
        const result = await api(`/v1/sync?since=${encodeURIComponent(cursor)}`, { token: auth.token });
        await applyRemotePayload(result.changes || {}, result.deletedKeys || []);
        changed += Object.keys(result.changes || {}).length + (result.deletedKeys || []).length;
        finalRevision = Math.max(finalRevision, Number(result.revision || 0));
        if (!result.hasMore) break;
        const nextCursor = Math.max(cursor, Number(result.maxReturnedRevision || cursor));
        if (nextCursor <= cursor) break;
        cursor = nextCursor;
      }
      const local = await storageGet([REVISION_KEY]);
      await saveStatePatch({
        lastRevision: finalRevision,
        lastSyncAt: now(),
        lastSyncAttemptAt: now(),
        lastError: "",
        lastErrorAt: 0,
        lastStatus: changed ? `Downloaded ${changed} setting${changed === 1 ? "" : "s"}` : "Up to date",
        // A remote apply does not touch dsSettingsRevisionV1. Preserve the last
        // known local-only revision marker for crash recovery.
        lastLocalStorageRevision: state.lastLocalStorageRevision || Number(local[REVISION_KEY] || 0) || 0
      });
      return { ok: true, changed, revision: finalRevision };
    } catch (error) {
      return recordFailure(error, "Download failed");
    }
  }

  async function syncNowInternal({ forceFullRecovery = false } = {}) {
    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token) return { ok: false, error: "not_linked", message: "This device is not linked to a QoL account." };
    if (state.paused) return { ok: false, error: "paused", message: "Automatic sync is paused on this device." };

    // dsSettingsRevisionV1 can legitimately still be 0 on an existing profile
    // whose settings were migrated before account sync existed. That means it
    // cannot be the only signal that an initial upload is still required.
    // Keep a lightweight snapshot so a freshly-created account that is still at
    // cloud revision 0 can seed itself even after a previous initial upload
    // failed (for example because one logical setting exceeded an old limit).
    const localSnapshot = await currentLocalSettings();
    const localRevision = Number(localSnapshot.localRevision || 0) || 0;
    const localSettingCount = Object.keys(localSnapshot.settings || {}).length;
    const hadUnsyncedLocalRevision = localRevision > Number(state.lastLocalStorageRevision || 0);

    const pulled = await pullRemote();
    if (!pulled?.ok) return pulled;

    const cloudStillEmpty = Number(pulled.revision || 0) === 0 && localSettingCount > 0;
    if (forceFullRecovery || hadUnsyncedLocalRevision || cloudStillEmpty) {
      const afterPullState = (await getStateAndAuth()).state;
      const pushed = await pushFullLocalSettings({ baseRevision: afterPullState.lastRevision });
      if (!pushed?.ok) return pushed;
      const repulled = await pullRemote();
      if (!repulled?.ok) return repulled;
    }

    const finalState = (await getStateAndAuth()).state;
    // A non-empty local settings document plus cloud revision 0 is not a real
    // successful sync. Treat it as incomplete instead of showing the user a
    // false-positive "QoL settings synced" message.
    if (localSettingCount > 0 && Number(finalState.lastRevision || 0) === 0) {
      return recordFailure(new Error("Cloud sync finished without recording a settings revision. Retry Sync now."), "Sync incomplete");
    }

    return { ok: true, revision: finalState.lastRevision };
  }

  async function createAccount(meta = {}) {
    const current = await getStateAndAuth();
    if (current.state.accountId && current.auth.token) return { ok: false, error: "already_linked", message: "This device is already linked." };

    try {
      const result = await api("/v1/account", {
        method: "POST",
        body: {
          deviceName: String(meta.deviceName || "Android app / WebView").slice(0, 80),
          platform: String(meta.platform || "android").slice(0, 40),
          clientVersion: String(meta.clientVersion || "0.2.25").slice(0, 40)
        }
      });
      const state = {
        ...normalizeState(current.state),
        deviceId: String(result.deviceId || current.state.deviceId || randomUuid()),
        accountId: String(result.accountId || ""),
        linkedAt: now(),
        automatic: true,
        paused: false,
        lastRevision: Math.max(0, Number(result.revision || 0)),
        lastSyncAt: 0,
        lastSyncAttemptAt: now(),
        lastError: "",
        lastErrorAt: 0,
        lastStatus: "Account created"
      };
      await storageSet({
        [STATE_KEY]: state,
        [AUTH_KEY]: { token: String(result.deviceToken || "") }
      });
      await ensureSyncAlarm();
      const pushed = await pushFullLocalSettings({ baseRevision: state.lastRevision });
      if (!pushed?.ok) {
        return {
          ok: true,
          accountId: state.accountId,
          deviceId: state.deviceId,
          initialSyncOk: false,
          sync: pushed
        };
      }
      const pulled = await pullRemote({ since: 0 });
      return {
        ok: true,
        accountId: state.accountId,
        deviceId: state.deviceId,
        initialSyncOk: !!pulled?.ok,
        sync: pulled
      };
    } catch (error) {
      return recordFailure(error, "Account creation failed");
    }
  }

  async function linkAccount(code, meta = {}) {
    const normalizedCode = String(code || "").trim();
    if (!normalizedCode) return { ok: false, error: "missing_code", message: "Enter a link code first." };
    const current = await getStateAndAuth();
    if (current.state.accountId && current.auth.token) return { ok: false, error: "already_linked", message: "This device is already linked." };

    try {
      const result = await api("/v1/link", {
        method: "POST",
        body: {
          code: normalizedCode,
          deviceName: String(meta.deviceName || "Android app / WebView").slice(0, 80),
          platform: String(meta.platform || "android").slice(0, 40),
          clientVersion: String(meta.clientVersion || "0.2.25").slice(0, 40)
        }
      });
      const state = {
        ...normalizeState(current.state),
        deviceId: String(result.deviceId || current.state.deviceId || randomUuid()),
        accountId: String(result.accountId || ""),
        linkedAt: now(),
        automatic: true,
        paused: false,
        lastRevision: 0,
        lastSyncAt: 0,
        lastSyncAttemptAt: now(),
        lastError: "",
        lastErrorAt: 0,
        lastStatus: "Linked — downloading account settings"
      };
      await storageSet({ [STATE_KEY]: state, [AUTH_KEY]: { token: String(result.deviceToken || "") } });
      await ensureSyncAlarm();
      const pulled = await pullRemote({ since: 0 });
      const local = await storageGet([REVISION_KEY]);
      await saveStatePatch({ lastLocalStorageRevision: Number(local[REVISION_KEY] || 0) || 0 });
      return {
        ok: true,
        accountId: state.accountId,
        deviceId: state.deviceId,
        initialSyncOk: !!pulled?.ok,
        sync: pulled
      };
    } catch (error) {
      return recordFailure(error, "Link failed");
    }
  }

  async function createLinkCode() {
    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token) return { ok: false, error: "not_linked", message: "Create or link a QoL account first." };
    try {
      return await api("/v1/link-code", { method: "POST", token: auth.token, body: {} });
    } catch (error) {
      return recordFailure(error, "Could not create link code");
    }
  }

  async function listDevices() {
    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token) return { ok: false, error: "not_linked", message: "This device is not linked." };
    try {
      return await api("/v1/devices", { token: auth.token });
    } catch (error) {
      return recordFailure(error, "Could not load devices");
    }
  }

  async function revokeDevice(deviceId) {
    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token) return { ok: false, error: "not_linked", message: "This device is not linked." };
    const target = String(deviceId || "").trim();
    if (!target) return { ok: false, error: "missing_device", message: "Choose a device first." };
    try {
      const result = await api(`/v1/devices/${encodeURIComponent(target)}`, { method: "DELETE", token: auth.token });
      if (target === state.deviceId) {
        await disconnectLocal();
      }
      return result;
    } catch (error) {
      return recordFailure(error, "Could not unlink device");
    }
  }

  async function disconnectLocal() {
    const data = await storageGet([STATE_KEY]);
    const current = normalizeState(data[STATE_KEY]);
    const next = {
      ...current,
      deviceId: randomUuid(),
      deviceCreatedAt: now(),
      accountId: "",
      linkedAt: 0,
      automatic: true,
      paused: false,
      lastRevision: 0,
      lastSyncAt: 0,
      lastSyncAttemptAt: 0,
      lastLocalStorageRevision: 0,
      lastError: "",
      lastErrorAt: 0,
      lastStatus: "Not linked"
    };
    await storageRemove([AUTH_KEY]);
    await storageSet({ [STATE_KEY]: next });
    try { await chrome.alarms.clear(ALARM_NAME); } catch {}
    pendingLocalPatch.clear();
    pendingLocalDeleted.clear();
    return { ok: true };
  }

  async function setPaused(paused) {
    const { state, auth } = await getStateAndAuth();
    if (!state.accountId || !auth.token) return { ok: false, error: "not_linked", message: "This device is not linked." };
    await saveStatePatch({ paused: !!paused, lastStatus: paused ? "Paused" : "Resumed" });
    await ensureSyncAlarm();
    if (!paused) return syncNowInternal();
    return { ok: true, paused: true };
  }

  async function status() {
    const { state, auth } = await getStateAndAuth();
    return {
      ok: true,
      apiBase: API_BASE,
      linked: !!(state.accountId && auth.token),
      hasCredential: !!auth.token,
      state
    };
  }

  function schedulePatchPush(localRevision = 0) {
    clearTimeout(pushTimer);
    pushTimer = setTimeout(() => {
      pushTimer = null;
      const changes = Object.fromEntries(pendingLocalPatch);
      const deleted = [...pendingLocalDeleted];
      pendingLocalPatch.clear();
      pendingLocalDeleted.clear();
      queued(async () => {
        const first = await pushPatchBatches(changes, deleted, { localRevision });
        if (first?.conflict) {
          const pulled = await pullRemote();
          if (pulled?.ok) {
            const state = (await getStateAndAuth()).state;
            const retry = await pushPatchBatches(changes, deleted, { baseRevision: state.lastRevision, localRevision });
            if (retry?.ok) await pullRemote();
          }
          return;
        }
        if (first?.ok) await pullRemote();
      }).catch(() => {});
    }, 650);
  }

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== "local") return;

    let localRevision = Number(changes?.[REVISION_KEY]?.newValue || 0) || 0;
    let sawLocalSettingChange = false;

    for (const [storageKey, change] of Object.entries(changes || {})) {
      if (!storageKey.startsWith(GRANULAR_PREFIX)) continue;
      const settingKey = storageKey.slice(GRANULAR_PREFIX.length);
      if (!settingKey) continue;

      const expected = remoteExpectedWrites.get(storageKey);
      if (expected) {
        const matches = expected.deleted
          ? change?.newValue === undefined
          : equalValue(change?.newValue, expected.value);
        if (matches) {
          remoteExpectedWrites.delete(storageKey);
          continue;
        }
        remoteExpectedWrites.delete(storageKey);
      }

      sawLocalSettingChange = true;
      if (change?.newValue === undefined) {
        pendingLocalPatch.delete(settingKey);
        pendingLocalDeleted.add(settingKey);
      } else {
        pendingLocalDeleted.delete(settingKey);
        pendingLocalPatch.set(settingKey, change.newValue);
      }
    }

    if (sawLocalSettingChange) schedulePatchPush(localRevision || now());
  });

  async function handleAndroidSyncMessage(message) {
    const type = String(message?.type || "");
    if (!type.startsWith("DS_QOL_SYNC_")) {
      return { ok: false, error: "unknown_sync_action", message: "Unknown QoL sync action." };
    }

    switch (type) {
      case "DS_QOL_SYNC_STATUS": return status();
      case "DS_QOL_SYNC_CREATE_ACCOUNT": return queued(() => createAccount(message.meta || {}));
      case "DS_QOL_SYNC_LINK_ACCOUNT": return queued(() => linkAccount(message.code, message.meta || {}));
      case "DS_QOL_SYNC_CREATE_LINK_CODE": return queued(() => createLinkCode());
      case "DS_QOL_SYNC_NOW": return queued(() => syncNowInternal({ forceFullRecovery: !!message.forceFullRecovery }));
      case "DS_QOL_SYNC_LIST_DEVICES": return queued(() => listDevices());
      case "DS_QOL_SYNC_REVOKE_DEVICE": return queued(() => revokeDevice(message.deviceId));
      case "DS_QOL_SYNC_SET_PAUSED": return queued(() => setPaused(!!message.paused));
      case "DS_QOL_SYNC_DISCONNECT_LOCAL": return queued(() => disconnectLocal());
      default: return { ok: false, error: "unknown_sync_action", message: "Unknown QoL sync action." };
    }
  }

  window.__dsQolAndroidSyncHandleMessage = handleAndroidSyncMessage;
  console.log(`[DS Android Sync] ${ANDROID_SYNC_BUILD} installed (${IS_ANDROID_OPTIONS ? "options" : "main"})`);

  if (IS_ANDROID_OPTIONS) {
    // Android Options normally relays runtime messages to the live SpicyChat
    // WebView. Account sync can take much longer than that relay's short
    // diagnostics timeout while hundreds of settings are written. Handle sync
    // actions inside the Options WebView instead; both WebViews share the same
    // native chrome.storage.local backing store.
    const originalSendMessage = chrome.runtime.sendMessage.bind(chrome.runtime);
    chrome.runtime.sendMessage = function dsAndroidSyncSendMessage(message, callback) {
      const type = String(message?.type || "");
      if (!type.startsWith("DS_QOL_SYNC_")) {
        return originalSendMessage(message, callback);
      }

      const promise = Promise.resolve()
        .then(() => handleAndroidSyncMessage(message))
        .catch(error => ({
          ok: false,
          error: "sync_error",
          message: safeErrorMessage(error)
        }));

      if (typeof callback === "function") {
        promise.then(value => callback(value));
      }
      return promise;
    };
  } else {
    // The live SpicyChat WebView already provides a real in-page runtime
    // listener registry through bridge.js. Register here so any future native
    // caller can still reach sync actions directly.
    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      const type = String(message?.type || "");
      if (!type.startsWith("DS_QOL_SYNC_")) return false;

      handleAndroidSyncMessage(message)
        .then(sendResponse)
        .catch(error => sendResponse({
          ok: false,
          error: "sync_error",
          message: safeErrorMessage(error)
        }));
      return true;
    });

    // No Chrome extension service worker exists in the APK. Keep automatic
    // account sync alive with one lightweight timer in the active WebView.
    const runAutomaticSync = () => {
      queued(async () => {
        const { state, auth } = await getStateAndAuth();
        if (!state.accountId || !auth.token || state.paused || state.automatic === false) return;
        await syncNowInternal();
      }).catch(() => {});
    };

    setTimeout(runAutomaticSync, 1800);
    setInterval(runAutomaticSync, SYNC_INTERVAL_MINUTES * 60 * 1000);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") {
        setTimeout(runAutomaticSync, 1200);
      }
    }, { passive: true });
  }

})();

// === DS QOL ANDROID ACCOUNT SYNC HOTFIX END ===
