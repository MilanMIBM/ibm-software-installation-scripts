/*
 * cpd-pane-autoheal: retries Elyra common-properties panels that crashed into
 * "Oops, the pane didn't load." by pressing their Revert button. Revert only
 * resets the error boundary and re-mounts the panel from the same Redux store,
 * so the user's values are kept and the failed render is simply redone.
 *
 * Served by ibm-nginx (ZenExtension cpd-pane-autoheal), injected into HTML pages.
 * Disable per browser: localStorage.setItem("cpdPaneAutoheal", "off")
 */
(function () {
  "use strict";
  var VERSION = "@@VERSION@@";
  var REPORT_URL = "/cpd-pane-autoheal/report";
  var DELAYS = [300, 1000, 2500];  // ms before attempt 1, 2, 3
  var WINDOW_MS = 60000;           // attempts are counted per panel per minute
  var RECOVER_CHECK_MS = 3000;

  function install(win) {
    try {
      if (win.__cpdPaneAutoheal) return;
      win.__cpdPaneAutoheal = VERSION;
      if (win.localStorage && win.localStorage.getItem("cpdPaneAutoheal") === "off") return;
    } catch (e) { return; }  // cross-origin frame

    var doc = win.document;
    var handled = new WeakSet();
    var attempts = {};  // panel key -> [timestamps]
    var lastError = null;

    // Elyra logs the caught render error via console.error right before the fallback shows.
    var origError = win.console.error;
    win.console.error = function () {
      for (var i = 0; i < arguments.length; i++) {
        var a = arguments[i];
        if (a instanceof win.Error || (a && a.stack && a.message)) {
          lastError = { message: String(a.message).slice(0, 300), stack: String(a.stack || "").slice(0, 1500), ts: Date.now() };
          break;
        }
      }
      return origError.apply(this, arguments);
    };

    function report(event, key, attempt) {
      try {
        var err = lastError && Date.now() - lastError.ts < 10000 ? lastError : null;
        var body = JSON.stringify({
          v: VERSION, event: event, attempt: attempt || 0, panel: key,
          url: win.location.pathname + win.location.hash.slice(0, 80),
          error: err ? err.message : null, stack: err ? err.stack : null
        });
        var blob = new win.Blob([body], { type: "text/plain" });
        if (!(win.navigator.sendBeacon && win.navigator.sendBeacon(REPORT_URL, blob))) {
          win.fetch(REPORT_URL, { method: "POST", body: body, keepalive: true, credentials: "same-origin" });
        }
      } catch (e) { /* never break the page */ }
    }

    function fallbackParts(heading) {
      // Walk up from .properties-error-heading to the fallback container holding the buttons.
      var node = heading;
      for (var i = 0; i < 6 && node; i++) {
        var revert = node.querySelector && node.querySelector(".properties-cancel-button");
        var close = node.querySelector && node.querySelector(".properties-apply-button, .properties-error-display-close-button button");
        if (revert || (close && i >= 2)) return { box: node, revert: revert };
        node = node.parentElement;
      }
      return { box: heading.parentElement || heading, revert: null };
    }

    function panelKey(box) {
      var labelled = box.closest("[aria-label]");
      return win.location.pathname + "|" + (labelled ? labelled.getAttribute("aria-label").slice(0, 80) : "panel");
    }

    function recent(key) {
      var now = Date.now();
      attempts[key] = (attempts[key] || []).filter(function (t) { return now - t < WINDOW_MS; });
      return attempts[key];
    }

    function note(box, text) {
      if (box.querySelector(".cpd-pane-autoheal-note")) return;
      var p = doc.createElement("p");
      p.className = "cpd-pane-autoheal-note";
      p.style.cssText = "margin:8px 16px;font-size:12px;opacity:.8";
      p.textContent = text;
      box.appendChild(p);
    }

    function handle(heading) {
      if (handled.has(heading)) return;
      handled.add(heading);
      var parts = fallbackParts(heading);
      var key = panelKey(parts.box);
      if (!parts.revert) {  // panel never mounted: only Close exists, closing would discard the dialog
        report("no_revert", key);
        return;
      }
      var tries = recent(key);
      if (tries.length >= DELAYS.length) {
        note(parts.box, "Auto-retry failed " + DELAYS.length + "x - press Close and reopen the dialog.");
        report("gave_up", key, tries.length);
        return;
      }
      var attempt = tries.length + 1;
      tries.push(Date.now());
      win.setTimeout(function () {
        if (!heading.isConnected || !parts.revert.isConnected) return;  // user already acted
        win.console.info("[cpd-pane-autoheal] retrying panel render (attempt " + attempt + ")");
        report("retry", key, attempt);
        parts.revert.click();
        win.setTimeout(function () {
          var again = doc.querySelector(".properties-error-heading");
          if (!again || panelKey(fallbackParts(again).box) !== key) report("recovered", key, attempt);
        }, RECOVER_CHECK_MS);
      }, DELAYS[attempt - 1]);
    }

    function scan() {
      var headings = doc.querySelectorAll(".properties-error-heading");
      for (var i = 0; i < headings.length; i++) handle(headings[i]);
      // same-origin iframes without their own injected copy (srcdoc / about:blank)
      var frames = doc.querySelectorAll("iframe");
      for (var j = 0; j < frames.length; j++) {
        try { if (frames[j].contentWindow) install(frames[j].contentWindow); } catch (e) { /* cross-origin */ }
      }
    }

    var queued = false;
    function schedule() {
      if (queued) return;
      queued = true;
      win.setTimeout(function () { queued = false; scan(); }, 50);
    }

    function start() {
      new win.MutationObserver(schedule).observe(doc.documentElement, { childList: true, subtree: true });
      scan();
    }
    if (doc.documentElement) start(); else doc.addEventListener("DOMContentLoaded", start);
  }

  install(window);
})();
