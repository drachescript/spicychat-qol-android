(() => {
  "use strict";

  if (window.__spicyChatQolAndroidMessageLongPressInstalled) return;
  window.__spicyChatQolAndroidMessageLongPressInstalled = true;

  const DS = window.DragonScriptQoL;
  const LONG_PRESS_MS = 560;
  const MOVE_CANCEL_PX = 14;
  const SELECT_TEXT_WINDOW_MS = 10000;
  const BRIDGE_ATTR = "data-ds-message-action-bridge";

  const HEADER_GEAR_ID = "ds-android-native-header-settings";
  const LEGACY_COPY_ID = "ds-android-editable-copy-button";

  let active = null;
  let longPressTimer = 0;
  let suppressClickUntil = 0;
  let suppressContextMenuUntil = 0;
  let selectTextUntil = 0;

  const clean = value => String(value || "").trim();

  // ---------------------------------------------------------------------------
  // Android UI cleanup
  //
  // Keep Android-specific code functional, not layout-owning. The shared QoL
  // extension owns mobile composer/message-edit fixes. This layer only:
  //   * docks the native cog into SpicyChat's existing header action row;
  //   * removes the obsolete duplicate Copy pill;
  //   * applies a narrow send-wrapper fallback if SpicyChat/React replaced the
  //     wrapper before shared QoL could tag it.
  // ---------------------------------------------------------------------------

  function visible(element) {
    if (!(element instanceof HTMLElement)) return false;
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.display !== "none" &&
      style.visibility !== "hidden";
  }

  function elementText(element) {
    return [
      element?.getAttribute?.("aria-label"),
      element?.getAttribute?.("title"),
      element?.getAttribute?.("data-testid"),
      element?.textContent
    ]
      .filter(Boolean)
      .join(" ")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();
  }

  function topActions() {
    const vw = Math.max(1, window.innerWidth || 1);

    return Array.from(
      document.querySelectorAll(
        'button, a[role="button"], [role="button"]'
      )
    )
      .filter(element => {
        if (element.id === HEADER_GEAR_ID) return false;
        if (!visible(element)) return false;

        const rect = element.getBoundingClientRect();
        return rect.top >= -2 &&
          rect.top <= 135 &&
          rect.bottom <= 180 &&
          rect.left >= vw * 0.35 &&
          rect.width >= 26 &&
          rect.width <= 120 &&
          rect.height >= 26 &&
          rect.height <= 100;
      })
      .sort(
        (a, b) =>
          a.getBoundingClientRect().left -
          b.getBoundingClientRect().left
      );
  }

  function preferredHeaderAnchor() {
    const actions = topActions();
    if (!actions.length) return null;

    const chatPage =
      location.pathname === "/chat" ||
      location.pathname.startsWith("/chat/");

    if (chatPage) {
      const rating = actions.find(element => {
        const text = elementText(element);
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
      if (rating) return rating;
    }

    const locale = actions.find(element => {
      const text = elementText(element);
      const svg = element.querySelector?.("svg");
      const svgClass = String(
        svg?.getAttribute?.("class") || ""
      ).toLowerCase();
      const shortText = String(element.textContent || "")
        .replace(/\s+/g, "")
        .trim();

      return /language|locale|globe|translate/.test(text) ||
        /globe|language|translate/.test(svgClass) ||
        /^[A-Z]{2,3}$/.test(shortText);
    });

    return locale || actions[0] || null;
  }

  function actionRowFor(anchor) {
    if (!(anchor instanceof HTMLElement)) return null;

    let node = anchor.parentElement;
    for (let depth = 0; node && depth < 6; depth++, node = node.parentElement) {
      if (!(node instanceof HTMLElement)) continue;

      const rect = node.getBoundingClientRect();
      if (
        rect.top < -8 ||
        rect.top > 150 ||
        rect.height < 28 ||
        rect.height > 125 ||
        rect.width < 80
      ) {
        continue;
      }

      const display = getComputedStyle(node).display;
      if (!["flex", "inline-flex"].includes(display)) continue;

      const actionCount = Array.from(
        node.querySelectorAll(
          'button, a[role="button"], [role="button"]'
        )
      ).filter(item => item.id !== HEADER_GEAR_ID && visible(item)).length;

      if (actionCount >= 2) return node;
    }

    return null;
  }

  function directChildInside(row, element) {
    let node = element;
    while (
      node?.parentElement &&
      node.parentElement !== row
    ) {
      node = node.parentElement;
    }
    return node?.parentElement === row ? node : null;
  }

  function styleDockedGear(gear) {
    const styles = {
      "all": "unset",
      "position": "relative",
      "display": "inline-flex",
      "align-items": "center",
      "justify-content": "center",
      "flex": "0 0 42px",
      "width": "42px",
      "height": "42px",
      "min-width": "42px",
      "min-height": "42px",
      "max-width": "42px",
      "max-height": "42px",
      "padding": "0",
      "margin": "0",
      "border": "1px solid rgba(255,255,255,.28)",
      "border-radius": "999px",
      "background": "#6d36d9",
      "background-image": "none",
      "color": "#fff",
      "box-shadow": "0 2px 8px rgba(0,0,0,.28)",
      "box-sizing": "border-box",
      "overflow": "hidden",
      "appearance": "none",
      "-webkit-appearance": "none",
      "opacity": "1",
      "cursor": "pointer",
      "pointer-events": "auto",
      "touch-action": "manipulation",
      "user-select": "none",
      "-webkit-user-select": "none",
      "-webkit-tap-highlight-color": "transparent",
      "z-index": "2",
      "font": "inherit",
      "line-height": "1",
      "text-decoration": "none",
      "outline": "none"
    };

    for (const [name, value] of Object.entries(styles)) {
      gear.style.setProperty(name, value, "important");
    }

    gear.style.removeProperty("left");
    gear.style.removeProperty("right");
    gear.style.removeProperty("top");
    gear.style.removeProperty("bottom");
    gear.dataset.dsAndroidDocked = "1";

    const svg = gear.querySelector("svg");
    if (svg instanceof SVGElement) {
      svg.style.setProperty("display", "block", "important");
      svg.style.setProperty("width", "22px", "important");
      svg.style.setProperty("height", "22px", "important");
      svg.style.setProperty("min-width", "22px", "important");
      svg.style.setProperty("min-height", "22px", "important");
      svg.style.setProperty("margin", "0", "important");
      svg.style.setProperty("padding", "0", "important");
      svg.style.setProperty("color", "#fff", "important");
      svg.style.setProperty("stroke", "currentColor", "important");
      svg.style.setProperty("background", "transparent", "important");
      svg.style.setProperty("box-shadow", "none", "important");
      svg.style.setProperty("pointer-events", "none", "important");
    }
  }

  function styleFallbackGear(gear) {
    const styles = {
      "all": "unset",
      "position": "fixed",
      "display": "flex",
      "align-items": "center",
      "justify-content": "center",
      "width": "42px",
      "height": "42px",
      "min-width": "42px",
      "min-height": "42px",
      "padding": "0",
      "margin": "0",
      "right": "12px",
      "bottom": "92px",
      "left": "auto",
      "top": "auto",
      "border": "1px solid rgba(255,255,255,.28)",
      "border-radius": "999px",
      "background": "#6d36d9",
      "color": "#fff",
      "box-shadow": "0 3px 10px rgba(0,0,0,.32)",
      "box-sizing": "border-box",
      "appearance": "none",
      "-webkit-appearance": "none",
      "pointer-events": "auto",
      "touch-action": "manipulation",
      "z-index": "2147483646"
    };

    for (const [name, value] of Object.entries(styles)) {
      gear.style.setProperty(name, value, "important");
    }
    delete gear.dataset.dsAndroidDocked;
  }

  function dockAndroidGear() {
    const gear = document.getElementById(HEADER_GEAR_ID);
    if (!(gear instanceof HTMLButtonElement)) return false;

    const anchor = preferredHeaderAnchor();
    const row = actionRowFor(anchor);

    if (!anchor || !row) {
      styleFallbackGear(gear);
      return false;
    }

    const slot = directChildInside(row, anchor);
    if (!slot) {
      styleFallbackGear(gear);
      return false;
    }

    if (gear.parentElement !== row || gear.nextSibling !== slot) {
      row.insertBefore(gear, slot);
    }

    styleDockedGear(gear);
    return true;
  }

  function normalizeSendWrapper() {
    const send = document.querySelector(
      'button[aria-label="send-message"]'
    );
    if (!(send instanceof HTMLElement) || !visible(send)) return false;

    send.classList.add("ds-mobile-chat-send-button");

    const wrapper = send.parentElement;
    if (!(wrapper instanceof HTMLElement)) return false;

    // Never collapse the real composer. Only normalize a dedicated wrapper
    // which does not itself contain the textarea/contenteditable input.
    if (
      wrapper.querySelector(
        'textarea, input[type="text"], [contenteditable="true"], ' +
        '[contenteditable="plaintext-only"]'
      )
    ) {
      return false;
    }

    wrapper.classList.add("ds-mobile-chat-send-wrapper");
    wrapper.dataset.dsAndroidSendWrapperNormalized = "1";

    const styles = {
      "width": "fit-content",
      "min-width": "0",
      "max-width": "fit-content",
      "flex": "0 0 auto",
      "padding": "0",
      "margin": "0",
      "background": "transparent",
      "background-image": "none",
      "border": "0",
      "box-shadow": "none",
      "overflow": "visible"
    };

    for (const [name, value] of Object.entries(styles)) {
      wrapper.style.setProperty(name, value, "important");
    }

    return true;
  }

  let cleanupScheduled = false;

  function runAndroidUiCleanup() {
    cleanupScheduled = false;

    // The native Android text-selection toolbar is now the only visible copy
    // UI. The Flutter clipboard bridge still handles the actual copy event.
    document.getElementById(LEGACY_COPY_ID)?.remove();

    dockAndroidGear();
    normalizeSendWrapper();
  }

  function scheduleAndroidUiCleanup() {
    if (cleanupScheduled) return;
    cleanupScheduled = true;
    requestAnimationFrame(runAndroidUiCleanup);
  }

  const cleanupObserver = new MutationObserver(() => {
    const gear = document.getElementById(HEADER_GEAR_ID);
    const send = document.querySelector(
      'button[aria-label="send-message"]'
    );
    const legacyCopy = document.getElementById(LEGACY_COPY_ID);

    if (
      legacyCopy ||
      !gear ||
      gear.dataset.dsAndroidDocked !== "1" ||
      (send &&
        send.parentElement?.dataset?.dsAndroidSendWrapperNormalized !== "1")
    ) {
      scheduleAndroidUiCleanup();
    }
  });

  cleanupObserver.observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  window.addEventListener("resize", scheduleAndroidUiCleanup, {
    passive: true
  });
  window.visualViewport?.addEventListener(
    "resize",
    scheduleAndroidUiCleanup,
    { passive: true }
  );

  scheduleAndroidUiCleanup();

  // ---------------------------------------------------------------------------
  // Native Android message long-press actions
  // ---------------------------------------------------------------------------

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

      const dropdown = node.querySelector?.(
        "button[aria-label='message-dropdown']"
      );
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
        dropdown:
          root.querySelector?.("button[aria-label='message-dropdown']") ||
          dropdown
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
      .map(button =>
        clean(
          button.dataset.dsMessageAction ||
          button.getAttribute("aria-label") ||
          ""
        )
      )
      .map(label => label.replace(/^QoL\s+/i, ""))
      .filter(Boolean);
  }

  function buildActions(context) {
    const quick = new Set(getQuickActionLabels(context));
    const ai = isAiMessage(context);
    const actions = ["Copy", "Edit"];

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
    const dropdown = root.querySelector(
      "button[aria-label='message-dropdown']"
    );
    return dropdown ? { root, dropdown } : null;
  }

  function temporarilyDisableSelection(root) {
    if (!root) return () => {};

    const previousUserSelect = root.style.userSelect;
    const previousWebkitUserSelect = root.style.webkitUserSelect;

    root.style.setProperty("user-select", "none", "important");
    root.style.setProperty("-webkit-user-select", "none", "important");

    return () => {
      if (previousUserSelect) {
        root.style.userSelect = previousUserSelect;
      } else {
        root.style.removeProperty("user-select");
      }

      if (previousWebkitUserSelect) {
        root.style.webkitUserSelect = previousWebkitUserSelect;
      } else {
        root.style.removeProperty("-webkit-user-select");
      }
    };
  }

  function cancelActive() {
    if (longPressTimer) {
      clearTimeout(longPressTimer);
      longPressTimer = 0;
    }

    if (active?.restoreSelection) {
      try {
        active.restoreSelection();
      } catch {}
    }

    active = null;
  }

  function directMessageText(context) {
    const bodyHost = context?.root?.querySelector?.(
      "div[class*='overflow-wrap']"
    );
    if (!bodyHost) return "";

    const lines = Array.from(
      bodyHost.querySelectorAll("span.leading-6")
    )
      .filter(
        span =>
          !span.closest(
            ".ds-translation-output, .ds-message-quick-actions, " +
            "[data-ds-translation-output]"
          )
      )
      .map(span => clean(span.textContent))
      .filter(Boolean);

    return lines.join("\n");
  }

  async function writeClipboard(text) {
    const value = clean(text);
    if (!value) return false;

    try {
      const nativeResult =
        await window.flutter_inappwebview?.callHandler(
          "copyToClipboard",
          value
        );
      if (
        nativeResult === true ||
        nativeResult?.ok === true
      ) {
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
        "position:fixed!important;" +
        "left:-10000px!important;" +
        "top:-10000px!important;";
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
      item =>
        clean(item.dataset.dsMessageAction).toLowerCase() ===
        label.toLowerCase()
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
        if (
          button.closest(
            "#ds-qol-panel, .ds-message-quick-actions"
          )
        ) {
          return false;
        }

        return clean(button.getAttribute("aria-label")) === label;
      })
      .sort((a, b) => {
        const ar = a.getBoundingClientRect();
        const br = b.getBoundingClientRect();

        const ad =
          Math.abs(ar.top - sourceRect.top) +
          Math.abs(ar.left - sourceRect.left);
        const bd =
          Math.abs(br.top - sourceRect.top) +
          Math.abs(br.left - sourceRect.left);

        return ad - bd;
      });
  }

  async function runSpicyChatMenuAction(context, label) {
    if (!context?.dropdown) return false;

    document.documentElement.setAttribute(BRIDGE_ATTR, "1");

    try {
      try {
        context.dropdown.click();
      } catch {}

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
      DS?.setQuickStatus?.(
        "That message changed before the action could run."
      );
      return;
    }

    if (action === "Select text") {
      selectTextUntil = Date.now() + SELECT_TEXT_WINDOW_MS;
      DS?.setQuickStatus?.(
        "Text selection enabled for 10 seconds. " +
        "Long-press the message again."
      );
      return;
    }

    if (clickQuickAction(context, action)) return;

    if (action === "Copy") {
      const copied = await writeClipboard(
        directMessageText(context)
      );

      if (copied) {
        DS?.setQuickStatus?.("Copied message.");
        return;
      }
    }

    const ok = await runSpicyChatMenuAction(context, action);
    if (!ok) {
      DS?.setQuickStatus?.(
        `${action} is not available on this message.`
      );
    }
  }

  async function fireLongPress(context) {
    if (!context?.root) return;

    const rootKey = rememberMessageRoot(context.root);
    const actions = buildActions(context);

    suppressClickUntil = Date.now() + 900;
    suppressContextMenuUntil = Date.now() + 1100;

    try {
      const selected =
        await window.flutter_inappwebview?.callHandler(
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
      console.warn(
        "[DS Android LongPress] Native menu failed",
        error
      );
    }
  }

  document.addEventListener(
    "pointerdown",
    event => {
      if (Date.now() < selectTextUntil) return;
      if (
        event.pointerType &&
        !["touch", "pen"].includes(event.pointerType)
      ) {
        return;
      }

      if (active) cancelActive();

      const context = findMessageContext(event.target);
      if (!context) return;

      const restoreSelection =
        temporarilyDisableSelection(context.root);

      active = {
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        context,
        restoreSelection,
        fired: false
      };

      suppressContextMenuUntil =
        Date.now() + LONG_PRESS_MS + 350;

      longPressTimer = window.setTimeout(() => {
        if (
          !active ||
          active.pointerId !== event.pointerId
        ) {
          return;
        }

        const current = active;
        current.fired = true;

        try {
          window.getSelection()?.removeAllRanges();
        } catch {}

        try {
          current.restoreSelection?.();
        } catch {}

        active = null;
        longPressTimer = 0;

        void fireLongPress(current.context);
      }, LONG_PRESS_MS);
    },
    true
  );

  document.addEventListener(
    "pointermove",
    event => {
      if (
        !active ||
        active.pointerId !== event.pointerId
      ) {
        return;
      }

      const dx = event.clientX - active.startX;
      const dy = event.clientY - active.startY;

      if (
        Math.hypot(dx, dy) > MOVE_CANCEL_PX
      ) {
        cancelActive();
      }
    },
    true
  );

  document.addEventListener(
    "pointerup",
    event => {
      if (
        !active ||
        active.pointerId !== event.pointerId
      ) {
        return;
      }

      cancelActive();
    },
    true
  );

  document.addEventListener(
    "pointercancel",
    event => {
      if (
        !active ||
        active.pointerId !== event.pointerId
      ) {
        return;
      }

      cancelActive();
    },
    true
  );

  document.addEventListener(
    "contextmenu",
    event => {
      if (Date.now() < selectTextUntil) return;
      if (Date.now() > suppressContextMenuUntil) return;
      if (!findMessageContext(event.target)) return;

      event.preventDefault();
      event.stopPropagation();
    },
    true
  );

  document.addEventListener(
    "click",
    event => {
      if (Date.now() > suppressClickUntil) return;
      if (!findMessageContext(event.target)) return;

      event.preventDefault();
      event.stopPropagation();
    },
    true
  );

  console.log(
    "[DS Android] Message long-press + UI cleanup ready"
  );
})();
