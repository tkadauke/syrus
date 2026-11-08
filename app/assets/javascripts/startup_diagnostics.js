(function () {
  var WATCHDOG_TIMEOUT_MS = 8000;
  var startupAt = Date.now();
  var reportedKeys = {};
  var milestones = [];
  var pendingStartupState = null;
  var lifecycleState = document.visibilityState === "hidden" ? "hidden" : "active";
  var MAX_STARTUP_RESOURCES = 40;

  function meta(name) {
    var el = document.querySelector('meta[name="' + name + '"]');
    return el ? el.getAttribute("content") : null;
  }

  function csrfToken() {
    return meta("csrf-token");
  }

  function shortText(value, limit) {
    return String(value == null ? "" : value).replace(/\s+/g, " ").slice(0, limit);
  }

  function sameOriginPath(value) {
    try {
      var url = new URL(value, window.location.href);
      return url.origin === window.location.origin ? url.pathname + url.search : "cross-origin";
    } catch (e) {
      return "unknown";
    }
  }

  function finiteNumber(value) {
    return typeof value === "number" && isFinite(value) ? Math.max(0, Math.round(value * 10) / 10) : null;
  }

  function timingEntry(entry, includePath) {
    var transferSize = finiteNumber(entry.transferSize);
    var decodedSize = finiteNumber(entry.decodedBodySize);
    var result = {
      request_start_ms: finiteNumber(entry.requestStart),
      response_start_ms: finiteNumber(entry.responseStart),
      response_end_ms: finiteNumber(entry.responseEnd),
      transfer_size: transferSize,
      encoded_body_size: finiteNumber(entry.encodedBodySize),
      decoded_body_size: decodedSize,
      cache_status: transferSize === 0 && decodedSize > 0 ? "cached" : null,
      protocol: shortText(entry.nextHopProtocol || "", 30) || null,
      delivery_type: shortText(entry.deliveryType || "", 30) || null
    };
    if (includePath) {
      try {
        result.path = new URL(entry.name, window.location.href).pathname;
      } catch (e) {
        result.path = "unknown";
      }
    }
    return result;
  }

  function startupTimings() {
    if (!window.performance || !performance.getEntriesByType) return { navigation: null, resources: [] };
    var navigation = performance.getEntriesByType("navigation")[0];
    var resources = performance.getEntriesByType("resource").filter(function (entry) {
      if (entry.initiatorType !== "script") return false;
      return sameOriginPath(entry.name) !== "cross-origin";
    }).slice(0, MAX_STARTUP_RESOURCES).map(function (entry) {
      return timingEntry(entry, true);
    });
    return { navigation: navigation ? timingEntry(navigation, false) : null, resources: resources };
  }

  function userAgentFamily() {
    var ua = navigator.userAgent || "";
    if (/CriOS/i.test(ua)) return "chrome_ios";
    if (/FxiOS/i.test(ua)) return "firefox_ios";
    if (/EdgiOS/i.test(ua)) return "edge_ios";
    if (/Safari/i.test(ua) && /Mobile|iPhone|iPad|iPod/i.test(ua)) return "mobile_safari";
    if (/Safari/i.test(ua)) return "safari";
    if (/Chrome|Chromium/i.test(ua)) return "chromium";
    if (/Firefox/i.test(ua)) return "firefox";
    return "unknown";
  }

  function standaloneContext() {
    var displayStandalone = false;
    try {
      displayStandalone = !!(window.matchMedia && window.matchMedia("(display-mode: standalone)").matches);
    } catch (e) {
      displayStandalone = false;
    }
    return {
      navigator_standalone: navigator.standalone === true,
      display_mode_standalone: displayStandalone
    };
  }

  function context(extra) {
    var standalone = standaloneContext();
    var base = {
      startup_elapsed_ms: Date.now() - startupAt,
      current_path: window.location.pathname + window.location.search,
      app_revision: meta("syrus-app-revision"),
      asset_revision: meta("syrus-asset-revision"),
      user_agent_family: userAgentFamily(),
      navigator_standalone: standalone.navigator_standalone,
      display_mode_standalone: standalone.display_mode_standalone,
      visibility_state: document.visibilityState || "unknown",
      document_ready_state: document.readyState || "unknown",
      lifecycle_state: lifecycleState,
      milestones: milestones.slice(-20)
    };
    Object.keys(extra || {}).forEach(function (key) {
      base[key] = extra[key];
    });
    return base;
  }

  function shouldReportMilestone() {
    var standalone = standaloneContext();
    return standalone.navigator_standalone ||
      standalone.display_mode_standalone ||
      /(?:\?|&)startup_diagnostics=1(?:&|$)/.test(window.location.search);
  }

  function fingerprint(kind, detail) {
    return ["startup", kind, meta("syrus-app-revision") || "unknown", sameOriginPath(detail || window.location.href)].join(":").slice(0, 500);
  }

  function postJson(path, payload) {
    var token = csrfToken();
    var bodyPayload = { authenticity_token: token };
    var headers = {
      "Accept": "application/json",
      "Content-Type": "application/json"
    };
    Object.keys(payload || {}).forEach(function (key) {
      bodyPayload[key] = payload[key];
    });
    if (token) headers["X-CSRF-Token"] = token;
    fetch(path, {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: headers,
      body: JSON.stringify(bodyPayload)
    }).catch(function () {});
  }

  function startupStatus() {
    return document.getElementById("syrus-startup-status");
  }

  function applyStartupState(state) {
    var el = startupStatus();
    if (!el) return false;
    var title = el.querySelector("[data-syrus-startup-title]");
    var message = el.querySelector("[data-syrus-startup-message]");
    var spinner = el.querySelector("[data-syrus-startup-spinner]");
    var retry = el.querySelector("[data-syrus-startup-retry]");
    el.hidden = !!state.hidden;
    el.dataset.startupState = state.name || "";
    if (title && state.title) title.textContent = state.title;
    if (message && state.message) message.textContent = state.message;
    if (spinner) spinner.hidden = state.retry === true;
    if (retry) retry.hidden = state.retry !== true;
    return true;
  }

  function showStartupState(state) {
    pendingStartupState = state;
    if (!applyStartupState(state)) {
      document.addEventListener("DOMContentLoaded", function () {
        if (pendingStartupState) applyStartupState(pendingStartupState);
      }, { once: true });
    }
  }

  function hideStartupState() {
    showStartupState({ name: "ready", hidden: true });
  }

  function reportMilestone(milestone) {
    if (!shouldReportMilestone()) return;

    var extra = { milestone: milestone };
    if (milestone === "react_module_evaluated") extra.startup_timings = startupTimings();

    postJson("/api/v1/app/performance_events", {
      performance_event: {
        trace_id: "startup-" + startupAt + "-" + milestone,
        name: "startup." + milestone,
        path: window.location.pathname + window.location.search,
        duration_ms: Date.now() - startupAt,
        visibility_state: document.visibilityState || "unknown",
        metadata: context(extra)
      }
    });
  }

  function report(kind, message, extra) {
    var key = kind + ":" + (extra && extra.milestone ? extra.milestone : "") + ":" + (extra && extra.resource_url ? extra.resource_url : "");
    if (reportedKeys[key]) return;
    reportedKeys[key] = true;

    postJson("/api/v1/app/browser_errors", {
      browser_error: {
        occurred_at: new Date().toISOString(),
        app_revision: meta("syrus-app-revision"),
        fingerprint: fingerprint(kind, extra && extra.resource_url),
        name: kind,
        message: shortText(message, 500),
        url: window.location.href,
        path: window.location.pathname + window.location.search,
        user_agent: navigator.userAgent || "",
        viewport: {
          width: window.innerWidth,
          height: window.innerHeight,
          device_pixel_ratio: window.devicePixelRatio
        },
        feature_flags: {},
        recent_api_requests: [],
        recent_errors: [],
        metadata: context(extra || {})
      }
    });
  }

  function mark(milestone) {
    var entry = {
      name: milestone,
      at_ms: Date.now() - startupAt,
      visibility_state: document.visibilityState || "unknown",
      document_ready_state: document.readyState || "unknown",
      lifecycle_state: lifecycleState
    };
    milestones.push(entry);
    if (milestones.length > 20) milestones.shift();
    if (milestone === "react_commit") {
      window.__syrusReactFirstRender = true;
      hideStartupState();
    }
    reportMilestone(milestone);
  }

  window.SyrusStartupDiagnostics = { mark: mark, report: report, context: context };
  mark("shell_loaded");

  document.addEventListener("visibilitychange", function () {
    lifecycleState = document.visibilityState === "hidden" ? "hidden" : "active";
  });
  window.addEventListener("pagehide", function () { lifecycleState = "pagehide"; });
  window.addEventListener("pageshow", function (event) { lifecycleState = event.persisted ? "restored" : "active"; });
  document.addEventListener("freeze", function () { lifecycleState = "frozen"; });
  document.addEventListener("resume", function () { lifecycleState = "active"; });

  window.addEventListener("error", function (event) {
    var target = event.target;
    var resourceUrl = target && (target.src || target.href);
    if (resourceUrl) {
      var tagName = target.tagName ? String(target.tagName).toLowerCase() : "resource";
      if (tagName === "script" || tagName === "link") {
        if (!window.__syrusReactFirstRender) {
          showStartupState({
            name: "resource_error",
            title: "The app could not load",
            message: "Check your connection, then retry.",
            retry: true
          });
        }
        report("StartupResourceError", "SPA startup resource failed to load", {
          resource_tag: tagName,
          resource_url: sameOriginPath(resourceUrl)
        });
      }
      return;
    }

    report("StartupWindowError", event.message || "SPA startup window error", {
      source: sameOriginPath(event.filename || ""),
      line: event.lineno || null,
      column: event.colno || null,
      error_name: event.error && event.error.name ? shortText(event.error.name, 100) : null,
      stack: event.error && event.error.stack ? shortText(event.error.stack, 2000) : null
    });
  }, true);

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    var isError = reason && typeof reason === "object" && ("message" in reason || "name" in reason);
    report("StartupUnhandledRejection", isError ? reason.message || "Unhandled startup rejection" : "Unhandled startup rejection", {
      error_name: isError && reason.name ? shortText(reason.name, 100) : typeof reason,
      stack: isError && reason.stack ? shortText(reason.stack, 2000) : null
    });
  });

  window.setTimeout(function () {
    if (window.__syrusReactFirstRender) return;
    var root = document.getElementById("syrus-spa-root");
    var rootBlank = !root || !root.textContent.trim();
    showStartupState({
      name: "watchdog",
      title: "Syrus is still loading",
      message: "This can happen on a slow connection. Retry if it does not finish soon.",
      retry: true
    });
    report("StartupWatchdog", rootBlank ? "SPA startup watchdog: root still blank" : "SPA startup watchdog: first render not marked", {
      root_present: !!root,
      root_blank: rootBlank
    });
  }, WATCHDOG_TIMEOUT_MS);
})();
