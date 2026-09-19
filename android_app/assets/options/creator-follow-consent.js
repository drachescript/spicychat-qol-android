(() => {
  "use strict";

  // Project-managed mirror of the creator opt-in list used by the QoL Discord
  // follow feature. Add creators here only after they have explicitly opted in.
  // Keeping the policy in one tiny shared file lets the page UI, Settings, and
  // background watcher all enforce the same consent decision.
  const RAW_CREATORS = [
    // Add a creator here only after the project has recorded their explicit opt-in.
  ];

  function normalizeHandle(value) {
    let text = String(value || "").trim();
    try { text = decodeURIComponent(text); } catch {}
    return text
      .replace(/^https?:\/\/[^/]+\/creator\//i, "")
      .replace(/^\/?creator\//i, "")
      .replace(/[?#].*$/g, "")
      .replace(/\/+$/g, "")
      .replace(/^@+/, "")
      .trim()
      .toLowerCase();
  }

  const entries = new Map();
  for (const raw of RAW_CREATORS) {
    const handle = normalizeHandle(raw?.handle);
    if (!handle) continue;
    entries.set(handle, Object.freeze({
      handle,
      name: String(raw?.name || `@${handle}`).trim() || `@${handle}`,
      follow: raw?.follow !== false,
      notify: raw?.notify !== false
    }));
  }

  const api = Object.freeze({
    version: 1,
    normalizeHandle,
    lookup(value) {
      return entries.get(normalizeHandle(value)) || null;
    },
    canFollow(value) {
      return !!entries.get(normalizeHandle(value))?.follow;
    },
    canNotify(value) {
      const row = entries.get(normalizeHandle(value));
      return !!(row?.follow && row?.notify);
    },
    list() {
      return [...entries.values()].map(row => ({ ...row }));
    }
  });

  globalThis.DragonScriptCreatorFollowConsent = api;
})();
