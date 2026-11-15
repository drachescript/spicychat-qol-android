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
