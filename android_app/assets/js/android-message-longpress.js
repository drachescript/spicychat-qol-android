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
  const UI_STYLE_ID = "ds-android-native-ui-cleanup-style";

  let active = null;
  let longPressTimer = 0;
  let suppressClickUntil = 0;
  let suppressContextMenuUntil = 0;
  let selectTextUntil = 0;

  let cleanupQueued = false;
  let cleanupApplying = false;
  let gearStyleObserver = null;
  let lastGear = null;

  const clean = value => String(value || "").trim();

  // ---------------------------------------------------------------------------
  // Android visual cleanup
  //
  // Shared QoL owns mobile composer/message-edit sizing. Android only removes
  // wrapper/pseudo-element artifacts around the APK-owned cog and SpicyChat's
  // send control. Do not style the editor/composer itself.
  // ---------------------------------------------------------------------------

  function ensureCleanupStyle() {
    let style = document.getElementById(UI_STYLE_ID);
    if (style) return style;

    style = document.createElement("style");
    style.id = UI_STYLE_ID;
    style.textContent = `
      #${HEADER_GEAR_ID}::before,
      #${HEADER_GEAR_ID}::after,
      #${HEADER_GEAR_ID} *::before,
      #${HEADER_GEAR_ID} *::after {
        content: none !important;
        display: none !important;
        background: transparent !important;
        background-image: none !important;
        box-shadow: none !important;
      }

      [data-ds-android-send-shell="1"],
      [data-ds-android-send-shell="1"]::before,
      [data-ds-android-send-shell="1"]::after,
      .ds-mobile-chat-send-wrapper,
      .ds-mobile-chat-send-wrapper::before,
      .ds-mobile-chat-send-wrapper::after {
        background: transparent !important;
        background-image: none !important;
        border: 0 !important;
        box-shadow: none !important;
      }

      [data-ds-android-send-shell="1"]::before,
      [data-ds-android-send-shell="1"]::after,
      .ds-mobile-chat-send-wrapper::before,
      .ds-mobile-chat-send-wrapper::after,
      .ds-mobile-chat-send-button::before,
      .ds-mobile-chat-send-button::after {
        content: none !important;
        display: none !important;
      }

      /* Android-only message-edit typography. Height is managed below from
         the textarea's natural scrollHeight so new lines appear immediately. */
      textarea[data-ds-android-message-edit="1"] {
        line-height: 1.45 !important;
        padding-top: 8px !important;
        padding-bottom: 10px !important;
        box-sizing: border-box !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
    return style;
  }

  function visible(element) {
    if (!(element instanceof HTMLElement)) return false;
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return (
      rect.width > 0 &&
      rect.height > 0 &&
      style.display !== "none" &&
      style.visibility !== "hidden"
    );
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
    const viewportWidth = Math.max(1, window.innerWidth || 1);

    return Array.from(
      document.querySelectorAll(
        'button, a[role="button"], [role="button"]'
      )
    )
      .filter(element => {
        if (element.id === HEADER_GEAR_ID) return false;
        if (!visible(element)) return false;

        const rect = element.getBoundingClientRect();
        return (
          rect.top >= -2 &&
          rect.top <= 135 &&
          rect.bottom <= 180 &&
          rect.left >= viewportWidth * 0.32 &&
          rect.width >= 26 &&
          rect.width <= 120 &&
          rect.height >= 26 &&
          rect.height <= 100
        );
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

        return (
          /rating|rate\b|thumb|like\b/.test(text) ||
          /thumb|like/.test(svgClass) ||
          /thumb|like/.test(svgLabel) ||
          !!element.querySelector?.(
            'svg[class*="thumb"], svg[data-lucide*="thumb"], ' +
            '[data-icon*="thumb"], [class*="thumb"]'
          )
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

      return (
        /language|locale|globe|translate/.test(text) ||
        /globe|language|translate/.test(svgClass) ||
        /^[A-Z]{2,3}$/.test(shortText)
      );
    });

    return locale || actions[0] || null;
  }

  function actionRowFor(anchor) {
    if (!(anchor instanceof HTMLElement)) return null;

    const viewportWidth = Math.max(1, window.innerWidth || 1);
    const maxRowWidth = Math.min(460, viewportWidth * 0.72);
    let best = null;
    let bestWidth = Infinity;
    let node = anchor.parentElement;

    for (
      let depth = 0;
      node && depth < 7;
      depth++, node = node.parentElement
    ) {
      if (!(node instanceof HTMLElement)) continue;

      const rect = node.getBoundingClientRect();
      if (
        rect.top < -8 ||
        rect.top > 150 ||
        rect.height < 28 ||
        rect.height > 125 ||
        rect.width < 80 ||
        rect.width > maxRowWidth
      ) {
        continue;
      }

      // Prefer the smallest ancestor that actually contains the header action
      // controls. Do not require display:flex: SpicyChat currently wraps the
      // action group in a non-flex shell. Requiring flex made us climb to the
      // whole header and insert the cog between the title and action group,
      // creating the dark-blue rectangular gap seen on Android.
      const actionCount = Array.from(
        node.querySelectorAll(
          'button, a[role="button"], [role="button"]'
        )
      ).filter(item => {
        if (item.id === HEADER_GEAR_ID || !visible(item)) return false;
        const itemRect = item.getBoundingClientRect();
        return itemRect.top >= -2 && itemRect.bottom <= 180;
      }).length;

      if (actionCount >= 2 && rect.width < bestWidth) {
        best = node;
        bestWidth = rect.width;
      }
    }

    return best;
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

  function styleGearSvg(gear) {
    const svg = gear.querySelector("svg");
    if (!(svg instanceof SVGElement)) return;

    const styles = {
      display: "block",
      width: "22px",
      height: "22px",
      "min-width": "22px",
      "min-height": "22px",
      margin: "0",
      padding: "0",
      color: "#fff",
      stroke: "currentColor",
      background: "transparent",
      "background-image": "none",
      "box-shadow": "none",
      "pointer-events": "none"
    };

    for (const [name, value] of Object.entries(styles)) {
      svg.style.setProperty(name, value, "important");
    }
  }

  function styleDockedGear(gear) {
    gear.style.cssText = [
      "all:unset!important",
      "position:relative!important",
      "display:inline-flex!important",
      "align-items:center!important",
      "justify-content:center!important",
      "flex:0 0 42px!important",
      "width:42px!important",
      "height:42px!important",
      "min-width:42px!important",
      "min-height:42px!important",
      "max-width:42px!important",
      "max-height:42px!important",
      "padding:0!important",
      "margin:0!important",
      "border:1px solid rgba(255,255,255,.28)!important",
      "border-radius:999px!important",
      "background:#6d36d9!important",
      "background-image:none!important",
      "color:#fff!important",
      "box-shadow:0 2px 8px rgba(0,0,0,.28)!important",
      "box-sizing:border-box!important",
      "overflow:hidden!important",
      "appearance:none!important",
      "-webkit-appearance:none!important",
      "opacity:1!important",
      "cursor:pointer!important",
      "pointer-events:auto!important",
      "touch-action:manipulation!important",
      "user-select:none!important",
      "-webkit-user-select:none!important",
      "-webkit-tap-highlight-color:transparent!important",
      "z-index:2!important",
      "font:inherit!important",
      "line-height:1!important",
      "text-decoration:none!important",
      "outline:none!important"
    ].join(";");

    gear.dataset.dsAndroidDocked = "1";
    styleGearSvg(gear);
  }

  function styleFallbackGear(gear) {
    gear.style.cssText = [
      "all:unset!important",
      "position:fixed!important",
      "display:flex!important",
      "align-items:center!important",
      "justify-content:center!important",
      "width:42px!important",
      "height:42px!important",
      "min-width:42px!important",
      "min-height:42px!important",
      "max-width:42px!important",
      "max-height:42px!important",
      "padding:0!important",
      "margin:0!important",
      "right:12px!important",
      "bottom:92px!important",
      "left:auto!important",
      "top:auto!important",
      "border:1px solid rgba(255,255,255,.28)!important",
      "border-radius:999px!important",
      "background:#6d36d9!important",
      "background-image:none!important",
      "color:#fff!important",
      "box-shadow:0 3px 10px rgba(0,0,0,.32)!important",
      "box-sizing:border-box!important",
      "overflow:hidden!important",
      "appearance:none!important",
      "-webkit-appearance:none!important",
      "pointer-events:auto!important",
      "touch-action:manipulation!important",
      "z-index:2147483646!important"
    ].join(";");

    delete gear.dataset.dsAndroidDocked;
    styleGearSvg(gear);
  }

  function watchGearStyle(gear) {
    if (lastGear === gear && gearStyleObserver) return;

    gearStyleObserver?.disconnect?.();
    gearStyleObserver = null;
    lastGear = gear;

    if (!(gear instanceof HTMLElement)) return;

    gearStyleObserver = new MutationObserver(() => {
      if (cleanupApplying) return;

      const docked = gear.dataset.dsAndroidDocked === "1";
      if (!docked) return;

      const style = getComputedStyle(gear);
      const inlinePosition = gear.style.getPropertyValue("position");
      const contaminated =
        inlinePosition !== "relative" ||
        style.position !== "relative" ||
        gear.style.getPropertyValue("left") ||
        gear.style.getPropertyValue("right") ||
        gear.style.getPropertyValue("top") ||
        gear.style.getPropertyValue("bottom");

      if (contaminated) scheduleCleanup();
    });

    gearStyleObserver.observe(gear, {
      attributes: true,
      attributeFilter: ["style", "class"]
    });
  }

  function dockAndroidGear() {
    const gear = document.getElementById(HEADER_GEAR_ID);
    if (!(gear instanceof HTMLButtonElement)) return false;

    watchGearStyle(gear);

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

  function isMessageEditTextarea(textarea) {
    if (!(textarea instanceof HTMLTextAreaElement)) return false;
    if (textarea.dataset.dsAndroidMessageEdit === "1") return true;
    if (textarea.closest('div[id^="message-"]')) return true;

    // Fallback for site builds where the message wrapper no longer exposes an
    // id. A real edit form has nearby Save + Cancel controls; the normal chat
    // composer does not.
    let node = textarea.parentElement;
    for (let depth = 0; node && depth < 5; depth++, node = node.parentElement) {
      const labels = Array.from(node.querySelectorAll("button"))
        .map(button => String(button.textContent || "").trim().toLowerCase());
      if (labels.includes("save") && labels.includes("cancel")) return true;
    }

    return false;
  }

  function resizeMessageEditTextarea(textarea) {
    if (!isMessageEditTextarea(textarea) || !textarea.isConnected) return false;

    textarea.dataset.dsAndroidMessageEdit = "1";

    const viewportHeight = Math.max(320,
      window.visualViewport?.height || window.innerHeight || 640);
    const maxHeight = Math.max(180, Math.min(440, viewportHeight * 0.46));
    const minHeight = 96;

    // Measure natural content height from a clean baseline. This is the key
    // difference from the old growing-every-keystroke bug: never measure while
    // the previous explicit height is still applied.
    textarea.style.setProperty("height", "0px", "important");
    const naturalHeight = Math.ceil(textarea.scrollHeight + 2);
    const wanted = Math.max(minHeight, Math.min(maxHeight, naturalHeight));

    textarea.style.setProperty("height", `${wanted}px`, "important");
    textarea.style.setProperty("min-height", `${minHeight}px`, "important");
    textarea.style.setProperty("max-height", `${maxHeight}px`, "important");
    textarea.style.setProperty(
      "overflow-y",
      naturalHeight > maxHeight ? "auto" : "hidden",
      "important"
    );

    return true;
  }

  function normalizeMessageEditTextareas() {
    document.querySelectorAll("textarea").forEach(textarea => {
      if (isMessageEditTextarea(textarea)) resizeMessageEditTextarea(textarea);
    });
  }

  function clearOldSendShellMarkers() {
    document
      .querySelectorAll('[data-ds-android-send-shell="1"]')
      .forEach(element => {
        element.removeAttribute("data-ds-android-send-shell");
        element.style.removeProperty("background");
        element.style.removeProperty("background-image");
        element.style.removeProperty("border");
        element.style.removeProperty("box-shadow");
      });
  }

  function safeSendShells(send) {
    const result = [];
    let node = send.parentElement;

    for (let depth = 0; node && depth < 3; depth++, node = node.parentElement) {
      if (!(node instanceof HTMLElement)) break;

      // Never alter the composer/editor container itself.
      if (
        node.querySelector(
          'textarea, input[type="text"], [contenteditable="true"], ' +
          '[contenteditable="plaintext-only"]'
        )
      ) {
        break;
      }

      const rect = node.getBoundingClientRect();
      const buttonCount = node.querySelectorAll("button").length;

      // Dedicated send wrappers on SpicyChat are small. Stop as soon as the
      // ancestor starts looking like a general layout container.
      if (
        rect.width > 150 ||
        rect.height > 130 ||
        buttonCount > 1
      ) {
        break;
      }

      result.push(node);
    }

    return result;
  }

  function normalizeSendWrapper() {
    const send = document.querySelector(
      'button[aria-label="send-message"]'
    );

    clearOldSendShellMarkers();

    if (!(send instanceof HTMLElement) || !visible(send)) {
      return false;
    }

    send.classList.add("ds-mobile-chat-send-button");

    const shells = safeSendShells(send);
    if (!shells.length) return false;

    for (const shell of shells) {
      shell.dataset.dsAndroidSendShell = "1";
      shell.style.setProperty(
        "background",
        "transparent",
        "important"
      );
      shell.style.setProperty(
        "background-image",
        "none",
        "important"
      );
      shell.style.setProperty("border", "0", "important");
      shell.style.setProperty("box-shadow", "none", "important");
      shell.style.setProperty("overflow", "visible", "important");
    }

    const immediate = shells[0];
    immediate.classList.add("ds-mobile-chat-send-wrapper");
    immediate.dataset.dsAndroidSendWrapperNormalized = "1";
    immediate.style.setProperty("width", "fit-content", "important");
    immediate.style.setProperty("min-width", "0", "important");
    immediate.style.setProperty("max-width", "fit-content", "important");
    immediate.style.setProperty("flex", "0 0 auto", "important");
    immediate.style.setProperty("padding", "0", "important");
    immediate.style.setProperty("margin", "0", "important");

    return true;
  }

  function runCleanup() {
    cleanupQueued = false;
    cleanupApplying = true;

    try {
      ensureCleanupStyle();

      document.getElementById(LEGACY_COPY_ID)?.remove();

      dockAndroidGear();
      normalizeSendWrapper();
      normalizeMessageEditTextareas();
    } finally {
      cleanupApplying = false;
    }
  }

  function scheduleCleanup() {
    if (cleanupQueued) return;
    cleanupQueued = true;
    requestAnimationFrame(runCleanup);
  }

  function scheduleSettledCleanup() {
    scheduleCleanup();
    setTimeout(scheduleCleanup, 80);
    setTimeout(scheduleCleanup, 240);
  }

  const cleanupObserver = new MutationObserver(records => {
    if (cleanupApplying) return;

    const changed = records.some(
      record =>
        record.addedNodes?.length ||
        record.removedNodes?.length
    );

    if (changed) scheduleCleanup();
  });

  cleanupObserver.observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  document.addEventListener("focusin", event => {
    const textarea = event.target;
    if (!isMessageEditTextarea(textarea)) return;
    requestAnimationFrame(() => resizeMessageEditTextarea(textarea));
    setTimeout(() => resizeMessageEditTextarea(textarea), 80);
  }, true);

  document.addEventListener("input", event => {
    const textarea = event.target;
    if (!isMessageEditTextarea(textarea)) return;
    requestAnimationFrame(() => resizeMessageEditTextarea(textarea));
  }, true);

  window.addEventListener("resize", scheduleSettledCleanup, {
    passive: true
  });

  window.visualViewport?.addEventListener(
    "resize",
    scheduleSettledCleanup,
    { passive: true }
  );

  window.addEventListener(
    "popstate",
    () => setTimeout(scheduleCleanup, 0),
    { passive: true }
  );

  scheduleSettledCleanup();

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
    for (
      let i = 0;
      node && i < 14;
      i++, node = node.parentElement
    ) {
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
          root.querySelector?.(
            "button[aria-label='message-dropdown']"
          ) || dropdown
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
      if (quick.has("Remove Image")) {
        actions.push("Remove Image");
      }
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
    const previousWebkitUserSelect =
      root.style.webkitUserSelect;

    root.style.setProperty("user-select", "none", "important");
    root.style.setProperty(
      "-webkit-user-select",
      "none",
      "important"
    );

    return () => {
      if (previousUserSelect) {
        root.style.userSelect = previousUserSelect;
      } else {
        root.style.removeProperty("user-select");
      }

      if (previousWebkitUserSelect) {
        root.style.webkitUserSelect =
          previousWebkitUserSelect;
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

    const button = Array.from(
      context.root.querySelectorAll(
        ".ds-message-quick-actions button[data-ds-message-action]"
      )
    ).find(
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

    const sourceRect =
      context.dropdown.getBoundingClientRect();

    return Array.from(document.querySelectorAll("button"))
      .filter(button => {
        if (
          button.closest(
            "#ds-qol-panel, .ds-message-quick-actions"
          )
        ) {
          return false;
        }

        return (
          clean(button.getAttribute("aria-label")) === label
        );
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

    document.documentElement.setAttribute(
      BRIDGE_ATTR,
      "1"
    );

    try {
      try {
        context.dropdown.click();
      } catch {}

      let actionButton = null;

      for (let i = 0; i < 16; i++) {
        actionButton =
          menuButtons(label, context)[0] || null;
        if (actionButton) break;
        await new Promise(
          resolve => setTimeout(resolve, 60)
        );
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
        document.documentElement.removeAttribute(
          BRIDGE_ATTR
        );
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
      selectTextUntil =
        Date.now() + SELECT_TEXT_WINDOW_MS;
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

    const ok =
      await runSpicyChatMenuAction(context, action);

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

      if (
        typeof selected === "string" &&
        selected
      ) {
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

      const context =
        findMessageContext(event.target);
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
      if (
        Date.now() > suppressContextMenuUntil
      ) {
        return;
      }
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
    "[DS Android] Message long-press + visual cleanup ready"
  );
})();
