(() => {
  "use strict";

  if (window.__spicyChatQolAndroidMessageLongPressInstalled) return;
  window.__spicyChatQolAndroidMessageLongPressInstalled = true;

  const DS = window.DragonScriptQoL;
  const LONG_PRESS_MS = 560;
  const MOVE_CANCEL_PX = 14;
  const SELECT_TEXT_WINDOW_MS = 10000;
  const BRIDGE_ATTR = "data-ds-message-action-bridge";

  let active = null;
  let longPressTimer = 0;
  let suppressClickUntil = 0;
  let suppressContextMenuUntil = 0;
  let selectTextUntil = 0;

  const clean = value => String(value || "").trim();

  function isInteractiveTarget(target) {
    if (!(target instanceof Element)) return false;
    return !!target.closest(
      "button, a, input, textarea, select, [contenteditable='true'], " +
      ".ds-message-quick-actions, #ds-qol-panel"
    );
  }

  function findMessageContext(target) {
    if (!(target instanceof Element)) return null;
    if (isInteractiveTarget(target)) return null;

    let node = target;
    for (let i = 0; node && i < 14; i++, node = node.parentElement) {
      if (node === document.body || node.id === "root") break;

      const dropdown = node.querySelector?.("button[aria-label='message-dropdown']");
      if (!dropdown) continue;

      const hasBody = !!node.querySelector?.(
        "div[class*='overflow-wrap'], span.leading-6, p"
      );
      if (!hasBody) continue;

      const root =
        node.closest?.("div[id^='message-']") ||
        node;

      return {
        root,
        dropdown: root.querySelector?.("button[aria-label='message-dropdown']") || dropdown
      };
    }
    return null;
  }

  function isAiMessage(context) {
    return !!context?.root?.querySelector?.(
      "a[href*='/chatbot/'], a[aria-label='chatbot-profile']"
    );
  }

  function getQuickActionLabels(context) {
    if (!context?.root) return [];
    return Array.from(
      context.root.querySelectorAll(
        ".ds-message-quick-actions button[data-ds-message-action]"
      )
    )
      .map(button => clean(button.dataset.dsMessageAction || button.getAttribute("aria-label") || ""))
      .map(label => label.replace(/^QoL\s+/i, ""))
      .filter(Boolean);
  }

  function buildActions(context) {
    const quick = new Set(getQuickActionLabels(context));
    const ai = isAiMessage(context);
    const actions = [];

    // Copy/Edit are the core Android long-hold use case. If the visible QoL
    // quick-action button is disabled, the fallback uses SpicyChat's own menu.
    actions.push("Copy", "Edit");

    if (ai) {
      actions.push("Report");
    } else {
      if (quick.has("Resend")) actions.push("Resend");
      if (quick.has("Remove Image")) actions.push("Remove Image");
    }

    actions.push("Select text");
    return [...new Set(actions)];
  }

  function rememberMessageRoot(root) {
    if (!root) return "";
    if (!root.dataset.dsAndroidLongPressKey) {
      root.dataset.dsAndroidLongPressKey =
        "dsalp-" + Math.random().toString(36).slice(2, 10);
    }
    return root.dataset.dsAndroidLongPressKey;
  }

  function findRememberedMessage(key) {
    if (!key) return null;
    return document.querySelector(
      `[data-ds-android-long-press-key="${CSS.escape(key)}"]`
    );
  }

  function contextFromRememberedRoot(root) {
    if (!root) return null;
    const dropdown = root.querySelector("button[aria-label='message-dropdown']");
    return dropdown ? { root, dropdown } : null;
  }

  function temporarilyDisableSelection(root) {
    if (!root) return () => {};
    const previousUserSelect = root.style.userSelect;
    const previousWebkitUserSelect = root.style.webkitUserSelect;

    root.style.setProperty("user-select", "none", "important");
    root.style.setProperty("-webkit-user-select", "none", "important");

    return () => {
      if (previousUserSelect) root.style.userSelect = previousUserSelect;
      else root.style.removeProperty("user-select");

      if (previousWebkitUserSelect) root.style.webkitUserSelect = previousWebkitUserSelect;
      else root.style.removeProperty("-webkit-user-select");
    };
  }

  function cancelActive() {
    if (longPressTimer) {
      clearTimeout(longPressTimer);
      longPressTimer = 0;
    }
    if (active?.restoreSelection) {
      try { active.restoreSelection(); } catch {}
    }
    active = null;
  }

  function directMessageText(context) {
    const bodyHost = context?.root?.querySelector?.("div[class*='overflow-wrap']");
    if (!bodyHost) return "";

    const lines = Array.from(bodyHost.querySelectorAll("span.leading-6"))
      .filter(span => !span.closest(
        ".ds-translation-output, .ds-message-quick-actions, [data-ds-translation-output]"
      ))
      .map(span => clean(span.textContent))
      .filter(Boolean);

    return lines.join("\n");
  }

  async function writeClipboard(text) {
    const value = clean(text);
    if (!value) return false;

    // WebView clipboard APIs can reject or silently no-op. The dedicated APK
    // owns this action, so use Flutter's native Android Clipboard first.
    try {
      const nativeResult = await window.flutter_inappwebview?.callHandler(
        "copyToClipboard",
        value
      );
      if (nativeResult === true || nativeResult?.ok === true) {
        return true;
      }
    } catch {}

    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {}

    try {
      const textarea = document.createElement("textarea");
      textarea.value = value;
      textarea.setAttribute("readonly", "");
      textarea.style.cssText =
        "position:fixed!important;left:-10000px!important;top:-10000px!important;";
      document.body.appendChild(textarea);
      textarea.select();
      const ok = document.execCommand("copy");
      textarea.remove();
      return !!ok;
    } catch {
      return false;
    }
  }

  function clickQuickAction(context, label) {
    if (!context?.root) return false;
    const buttons = Array.from(
      context.root.querySelectorAll(
        ".ds-message-quick-actions button[data-ds-message-action]"
      )
    );
    const button = buttons.find(
      item => clean(item.dataset.dsMessageAction).toLowerCase() === label.toLowerCase()
    );
    if (!button) return false;

    try {
      button.click();
      return true;
    } catch {
      return false;
    }
  }

  function menuButtons(label, context) {
    if (!context?.dropdown) return [];
    const sourceRect = context.dropdown.getBoundingClientRect();

    return Array.from(document.querySelectorAll("button"))
      .filter(button => {
        if (button.closest("#ds-qol-panel, .ds-message-quick-actions")) return false;
        return clean(button.getAttribute("aria-label")) === label;
      })
      .sort((a, b) => {
        const ar = a.getBoundingClientRect();
        const br = b.getBoundingClientRect();
        const ad = Math.abs(ar.top - sourceRect.top) + Math.abs(ar.left - sourceRect.left);
        const bd = Math.abs(br.top - sourceRect.top) + Math.abs(br.left - sourceRect.left);
        return ad - bd;
      });
  }

  async function runSpicyChatMenuAction(context, label) {
    if (!context?.dropdown) return false;

    document.documentElement.setAttribute(BRIDGE_ATTR, "1");

    try {
      try { context.dropdown.click(); } catch {}

      let actionButton = null;
      for (let i = 0; i < 16; i++) {
        actionButton = menuButtons(label, context)[0] || null;
        if (actionButton) break;
        await new Promise(resolve => setTimeout(resolve, 60));
      }

      if (!actionButton) return false;
      try {
        actionButton.click();
        return true;
      } catch {
        return false;
      }
    } finally {
      setTimeout(() => {
        document.documentElement.removeAttribute(BRIDGE_ATTR);
      }, 140);
    }
  }

  async function performAction(rootKey, action) {
    const root = findRememberedMessage(rootKey);
    const context = contextFromRememberedRoot(root);
    if (!context) {
      DS?.setQuickStatus?.("That message changed before the action could run.");
      return;
    }

    if (action === "Select text") {
      selectTextUntil = Date.now() + SELECT_TEXT_WINDOW_MS;
      DS?.setQuickStatus?.(
        "Text selection enabled for 10 seconds. Long-press the message again."
      );
      return;
    }

    if (clickQuickAction(context, action)) return;

    if (action === "Copy") {
      const copied = await writeClipboard(directMessageText(context));
      if (copied) {
        DS?.setQuickStatus?.("Copied message.");
        return;
      }
    }

    const ok = await runSpicyChatMenuAction(context, action);
    if (!ok) {
      DS?.setQuickStatus?.(`${action} is not available on this message.`);
    }
  }

  async function fireLongPress(context) {
    if (!context?.root) return;

    const rootKey = rememberMessageRoot(context.root);
    const actions = buildActions(context);

    suppressClickUntil = Date.now() + 900;
    suppressContextMenuUntil = Date.now() + 1100;

    try {
      const selected = await window.flutter_inappwebview?.callHandler(
        "androidMessageLongPress",
        JSON.stringify({
          actions,
          ai: isAiMessage(context)
        })
      );

      if (typeof selected === "string" && selected) {
        await performAction(rootKey, selected);
      }
    } catch (error) {
      console.warn("[DS Android LongPress] Native menu failed", error);
    }
  }

  document.addEventListener("pointerdown", event => {
    if (Date.now() < selectTextUntil) return;
    if (event.pointerType && !["touch", "pen"].includes(event.pointerType)) return;
    if (active) cancelActive();

    const context = findMessageContext(event.target);
    if (!context) return;

    const restoreSelection = temporarilyDisableSelection(context.root);
    active = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      context,
      restoreSelection,
      fired: false
    };

    suppressContextMenuUntil = Date.now() + LONG_PRESS_MS + 350;

    longPressTimer = window.setTimeout(() => {
      if (!active || active.pointerId !== event.pointerId) return;

      const current = active;
      current.fired = true;
      try { window.getSelection()?.removeAllRanges(); } catch {}
      try { current.restoreSelection?.(); } catch {}
      active = null;
      longPressTimer = 0;

      void fireLongPress(current.context);
    }, LONG_PRESS_MS);
  }, true);

  document.addEventListener("pointermove", event => {
    if (!active || active.pointerId !== event.pointerId) return;
    const dx = event.clientX - active.startX;
    const dy = event.clientY - active.startY;
    if (Math.hypot(dx, dy) > MOVE_CANCEL_PX) cancelActive();
  }, true);

  document.addEventListener("pointerup", event => {
    if (!active || active.pointerId !== event.pointerId) return;
    cancelActive();
  }, true);

  document.addEventListener("pointercancel", event => {
    if (!active || active.pointerId !== event.pointerId) return;
    cancelActive();
  }, true);

  document.addEventListener("contextmenu", event => {
    if (Date.now() < selectTextUntil) return;
    if (Date.now() > suppressContextMenuUntil) return;
    if (!findMessageContext(event.target)) return;

    event.preventDefault();
    event.stopPropagation();
  }, true);

  document.addEventListener("click", event => {
    if (Date.now() > suppressClickUntil) return;
    if (!findMessageContext(event.target)) return;

    event.preventDefault();
    event.stopPropagation();
  }, true);

  console.log("[DS Android] Message long-press actions ready");
})();
