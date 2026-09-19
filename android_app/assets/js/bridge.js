/**
 * bridge.js — Chrome Extension API shim for Flutter InAppWebView
 */
(() => {
  "use strict";

  if (window.__dsBridgeInstalled) return;
  window.__dsBridgeInstalled = true;

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
    nativeClipboard: true,
    generatedDownloadBridge: true
  });

  try {
    document.documentElement?.setAttribute("data-spicychat-qol-android", "1");
  } catch {}

  const _storageListeners = [];
  const _runtimeMessageListeners = [];

  function emitStorageChanges(changes) {
    if (!changes || typeof changes !== "object" || !Object.keys(changes).length) return;
    for (const fn of [..._storageListeners]) {
      try { fn(changes, "local"); }
      catch (error) { console.warn("[DS Bridge] storage listener error", error); }
    }
  }

  function parseStored(raw) {
    try { return typeof raw === "string" ? JSON.parse(raw) : (raw || {}); }
    catch { return {}; }
  }

  function valuesEqual(a, b) {
    if (a === b) return true;
    try { return JSON.stringify(a) === JSON.stringify(b); }
    catch { return false; }
  }

  const storageLocal = {
    get(keys, callback) {
      const promise = window.flutter_inappwebview
        .callHandler("storageGet", JSON.stringify(keys ?? null))
        .then(raw => parseStored(raw))
        .catch(() => ({}));
      if (callback) promise.then(callback);
      return promise;
    },

    set(obj, callback) {
      const next = obj && typeof obj === "object" ? obj : {};
      const keys = Object.keys(next);
      const promise = storageLocal.get(keys).then(before =>
        window.flutter_inappwebview
          .callHandler("storageSet", JSON.stringify(next))
          .then(() => {
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
        window.flutter_inappwebview
          .callHandler("storageRemove", JSON.stringify(list))
          .then(() => {
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
        window.flutter_inappwebview.callHandler("storageClear").then(() => {
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
      const promise = window.flutter_inappwebview
        .callHandler("storageGetBytesInUse", JSON.stringify(keys ?? null))
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
    addListener(fn) {
      if (typeof fn === "function" && !_storageListeners.includes(fn)) {
        _storageListeners.push(fn);
      }
    },
    removeListener(fn) {
      const index = _storageListeners.indexOf(fn);
      if (index >= 0) _storageListeners.splice(index, 1);
    },
    hasListener(fn) {
      return _storageListeners.includes(fn);
    }
  };


  function invokeRuntimeListener(listener, message, sender) {
    return new Promise(resolve => {
      let settled = false;
      let timeoutId = 0;

      const finish = (handled, value) => {
        if (settled) return;
        settled = true;
        if (timeoutId) clearTimeout(timeoutId);
        resolve({ handled: !!handled, value });
      };

      const sendResponse = value => {
        finish(true, value);
      };

      let returned;
      try {
        returned = listener(message, sender, sendResponse);
      } catch (error) {
        console.warn("[DS Bridge] runtime message listener failed", error);
        finish(false, null);
        return;
      }

      if (returned && typeof returned.then === "function") {
        timeoutId = setTimeout(() => finish(false, null), 8000);
        Promise.resolve(returned)
          .then(value => {
            if (settled) return;
            if (value !== undefined) finish(true, value);
            else finish(false, null);
          })
          .catch(error => {
            console.warn("[DS Bridge] async runtime listener failed", error);
            finish(false, null);
          });
        return;
      }

      if (returned === true) {
        timeoutId = setTimeout(() => finish(false, null), 8000);
        return;
      }

      if (settled) return;

      if (returned !== undefined && returned !== false) {
        finish(true, returned);
        return;
      }

      finish(false, null);
    });
  }

  async function dispatchRuntimeMessage(message, sender = {}) {
    const listeners = [..._runtimeMessageListeners];
    for (const listener of listeners) {
      const result = await invokeRuntimeListener(listener, message, sender);
      if (result.handled) return result.value;
    }
    return null;
  }

  // Flutter/Android Options uses this to deliver browser-style messages to
  // the one live SpicyChat content runtime.
  window.__dsAndroidDispatchRuntimeMessage = dispatchRuntimeMessage;

  const runtime = {
    id: "spicychat-qol-android",
    lastError: null,

    getManifest() {
      return {
        name: "SpicyChat QOL",
        version: String(window.__spicyChatQolBundledVersion || "0.0.0")
      };
    },

    sendMessage(message, callback) {
      if (message?.type === "DS_OPEN_OPTIONS") {
        window.flutter_inappwebview
          .callHandler("openOptions")
          .then(() => { if (callback) callback({ ok: true }); })
          .catch(() => { if (callback) callback({ ok: false }); });
        return;
      }

      window.flutter_inappwebview
        .callHandler("runtimeMessage", JSON.stringify(message))
        .then(raw => {
          try {
            const resp = typeof raw === "string" ? JSON.parse(raw) : (raw || {});
            if (callback) callback(resp);
          } catch {
            if (callback) callback(null);
          }
        })
        .catch(() => { if (callback) callback(null); });
    },

    onMessage: {
      addListener(listener) {
        if (
          typeof listener === "function" &&
          !_runtimeMessageListeners.includes(listener)
        ) {
          _runtimeMessageListeners.push(listener);
        }
      },
      removeListener(listener) {
        const index = _runtimeMessageListeners.indexOf(listener);
        if (index >= 0) _runtimeMessageListeners.splice(index, 1);
      },
      hasListener(listener) {
        return _runtimeMessageListeners.includes(listener);
      }
    },

    getPlatformInfo(callback) {
      const info = {
        os: "android",
        arch: "arm64",
        nacl_arch: "arm64"
      };
      if (callback) queueMicrotask(() => callback(info));
      return Promise.resolve(info);
    },

    getURL(path) {
      return String(path || "");
    },

    openOptionsPage(callback) {
      window.flutter_inappwebview
        .callHandler("openOptions")
        .then(() => { if (callback) callback(); })
        .catch(() => { if (callback) callback(); });
    }
  };

  const alarms = {
    create() {},
    clear() {},
    onAlarm: { addListener() {}, removeListener() {} }
  };

  const tabs = {
    // The dedicated Android app intentionally has one real WebView. Keep only
    // harmless compatibility methods here; do not fake chrome.tabs.create(),
    // because QoL features can use its absence to choose an Android-safe fallback.
    query(opts, cb) {
      const result = [];
      if (cb) cb(result);
      return Promise.resolve(result);
    },
    sendMessage(tabId, msg, cb) {
      if (cb) cb(null);
      return Promise.resolve(null);
    },
    __spicyChatQolAndroidUnsupported: true
  };


  async function nativeDownload(options = {}) {
    const filename = String(options.filename || "spicychat-qol-export.json");
    const url = String(options.url || "");
    if (!url) throw new Error("Missing download URL");

    const response = await fetch(url);
    const blob = await response.blob();
    const bytes = new Uint8Array(await blob.arrayBuffer());
    const result = await window.flutter_inappwebview.callHandler(
      "saveFile",
      JSON.stringify({
        filename,
        fileName: filename,
        mimeType: blob.type || "application/octet-stream",
        base64: bytesToBase64(bytes)
      })
    );
    if (result?.canceled) throw new Error("Download canceled");
    return 1;
  }

  const downloads = {
    download(options, callback) {
      const promise = nativeDownload(options);
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
  };

  window.chrome = {
    storage: { local: storageLocal, onChanged: storageOnChanged },
    runtime,
    alarms,
    tabs,
    downloads
  };

  window._dsNotifyStorageChanged = function (changesJson) {
    let changes;
    try {
      changes = typeof changesJson === "string" ? JSON.parse(changesJson) : changesJson;
    } catch {
      changes = {};
    }
    emitStorageChanges(changes);
  };

  window._dsRequestExport = function (text, filename) {
    return window.flutter_inappwebview
      .callHandler("exportChat", JSON.stringify({ text, filename }));
  };

  window._dsSaveFile = function (content, filename, mimeType) {
    return window.flutter_inappwebview.callHandler("saveFile", JSON.stringify({
      text: String(content ?? ""),
      content: String(content ?? ""),
      filename: String(filename || "spicychat-qol-export.txt"),
      fileName: String(filename || "spicychat-qol-export.txt"),
      mimeType: String(mimeType || "text/plain;charset=utf-8")
    }));
  };

  function bytesToBase64(bytes) {
    let binary = "";
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
  }

  // Generic Android generated-download bridge.
  //
  // Many QoL features use:
  //   Blob -> URL.createObjectURL(blob) -> detached <a download>.click()
  //
  // A document-level click listener cannot see a detached anchor, which is why
  // features such as Chat Export can appear to work but never produce a file in
  // Android WebView. Keep a temporary Blob registry and intercept BOTH attached
  // clicks and HTMLAnchorElement.click().
  const _nativeGeneratedBlobs = new Map();
  const _originalCreateObjectURL =
    typeof URL.createObjectURL === "function"
      ? URL.createObjectURL.bind(URL)
      : null;
  const _originalRevokeObjectURL =
    typeof URL.revokeObjectURL === "function"
      ? URL.revokeObjectURL.bind(URL)
      : null;
  const _originalAnchorClick = HTMLAnchorElement.prototype.click;

  function generatedDownloadFilename(link, fallback = "spicychat-qol-export.txt") {
    const requested = String(link?.download || "").trim();
    if (requested) return requested;

    try {
      const url = new URL(String(link?.href || ""), location.href);
      const leaf = decodeURIComponent(url.pathname.split("/").pop() || "").trim();
      if (leaf) return leaf;
    } catch {}

    return fallback;
  }

  function isGeneratedDownloadHref(href) {
    const value = String(href || "");
    return value.startsWith("blob:") || value.startsWith("data:");
  }

  async function saveGeneratedBlob(blob, filename) {
    if (!(blob instanceof Blob)) {
      throw new TypeError("Expected Blob");
    }

    const bytes = new Uint8Array(await blob.arrayBuffer());
    const result = await window.flutter_inappwebview.callHandler(
      "saveFile",
      JSON.stringify({
        filename,
        fileName: filename,
        mimeType: blob.type || "application/octet-stream",
        base64: bytesToBase64(bytes)
      })
    );

    if (result?.canceled) return { ok: false, canceled: true };
    if (result?.ok === false) {
      throw new Error(String(result?.error || "Native save failed"));
    }
    return result || { ok: true };
  }

  async function saveGeneratedHref(href, filename) {
    const value = String(href || "");
    let blob = _nativeGeneratedBlobs.get(value) || null;

    if (!blob) {
      const response = await fetch(value);
      blob = await response.blob();
    }

    return saveGeneratedBlob(blob, filename);
  }

  function routeGeneratedAnchorToNative(link, source = "anchor") {
    if (!(link instanceof HTMLAnchorElement)) return false;

    const href = String(link.href || "");
    if (!link.hasAttribute("download") || !isGeneratedDownloadHref(href)) {
      return false;
    }

    if (link.dataset.dsAndroidNativeDownloadBusy === "1") {
      return true;
    }

    link.dataset.dsAndroidNativeDownloadBusy = "1";
    const filename = generatedDownloadFilename(link);

    saveGeneratedHref(href, filename)
      .then(result => {
        if (!result?.canceled) {
          console.log(
            `[DS Bridge] Native generated download saved (${source}): ${filename}`
          );
        }
      })
      .catch(error => {
        console.warn(
          `[DS Bridge] Native generated download failed (${source})`,
          error
        );
      })
      .finally(() => {
        delete link.dataset.dsAndroidNativeDownloadBusy;
      });

    return true;
  }

  if (_originalCreateObjectURL) {
    URL.createObjectURL = function dsAndroidCreateObjectURL(object) {
      const url = _originalCreateObjectURL(object);
      if (object instanceof Blob) {
        _nativeGeneratedBlobs.set(url, object);
      }
      return url;
    };
  }

  if (_originalRevokeObjectURL) {
    URL.revokeObjectURL = function dsAndroidRevokeObjectURL(url) {
      const value = String(url || "");
      const result = _originalRevokeObjectURL(value);

      // Saving already holds its own Blob reference. Delay registry cleanup by
      // one task so create -> click -> immediate revoke patterns stay reliable.
      setTimeout(() => _nativeGeneratedBlobs.delete(value), 0);
      return result;
    };
  }

  HTMLAnchorElement.prototype.click = function dsAndroidAnchorClick() {
    if (routeGeneratedAnchorToNative(this, "programmatic-click")) {
      return;
    }
    return _originalAnchorClick.call(this);
  };

  document.addEventListener("click", event => {
    const target =
      event.target instanceof Element
        ? event.target
        : event.target?.parentElement;
    const link = target?.closest?.("a[download]");
    if (!link) return;

    if (!routeGeneratedAnchorToNative(link, "document-click")) return;

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
  }, true);

  // Optional stable hook for future QoL features. Existing features do not
  // need to change; this simply avoids another APK update if an extension-side
  // feature wants to explicitly use the Android-native generated-file saver.
  window._dsSaveGeneratedDownload = async function (
    source,
    filename = "spicychat-qol-export.txt",
    mimeType = "application/octet-stream"
  ) {
    if (source instanceof Blob) {
      return saveGeneratedBlob(source, String(filename));
    }

    if (source instanceof ArrayBuffer) {
      return saveGeneratedBlob(
        new Blob([source], { type: String(mimeType) }),
        String(filename)
      );
    }

    if (ArrayBuffer.isView(source)) {
      return saveGeneratedBlob(
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
    if (isGeneratedDownloadHref(value)) {
      return saveGeneratedHref(value, String(filename));
    }

    return saveGeneratedBlob(
      new Blob([value], { type: String(mimeType) }),
      String(filename)
    );
  };

  console.log("[DS Bridge] Chrome API shim installed for Flutter WebView");
})();
