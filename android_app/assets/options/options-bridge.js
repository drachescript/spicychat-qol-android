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
          const tab = await queryAndroidMainTab();
          if (!tab?.url) {
            return {
              ok: false,
              url: "",
              title: "",
              pageDiagnostics: null,
              androidNativeBridge: true
            };
          }

          const pageDiagnostics = await sendAndroidMainTabMessage({
            type: "DS_GET_PAGE_DIAGNOSTICS"
          });

          return {
            ok: true,
            url: tab.url || "",
            title: tab.title || "",
            pageDiagnostics: pageDiagnostics || null,
            androidNativeBridge: true
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
