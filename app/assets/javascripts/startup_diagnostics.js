(function () {
  var WATCHDOG_TIMEOUT_MS = 8000;
  var startupAt = Date.now();
  var reportedKeys = {};
  var milestones = [];
  var pendingStartupState = null;
  var lifecycleState = document.visibilityState === "hidden" ? "hidden" : "active";
  var MAX_STARTUP_RESOURCES = 40;
  var startupTraceId = "startup-" + startupAt + "-" + Math.random().toString(36).slice(2, 10);
  var watchdogTimer = null;
  // A startup script or stylesheet that fails to load is almost always the
  // network (a phone reconnecting its VPN, a dropped request), not the app. The
  // page used to sit on "Check your connection, then retry." until someone
  // tapped Retry, again and again through a five-minute outage. Retry by itself
  // instead -- on a backoff, and the moment the browser reports it is back
  // online -- counted across reloads so it can never loop forever.
  var AUTO_RETRY_DELAYS_MS = [2000, 5000, 15000, 30000, 60000];
  var AUTO_RETRY_KEY = "syrus.startup.autoRetryAttempt";
  var autoRetryTimer = null;
  var autoRetrying = false;

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

  function safeErrorText(value, limit) {
    return shortText(value, limit)
      .replace(/((?:token|secret|password|authorization|api[_-]?key)\s*[=:]\s*)[^\s,;]+/gi, "$1[FILTERED]")
      .replace(/(bearer\s+)[a-z0-9._~+\/-]+/gi, "$1[FILTERED]");
  }

  function sameOriginPath(value) {
    try {
      var url = new URL(value, window.location.href);
      if (url.origin !== window.location.origin) return "cross-origin";
      url.searchParams.forEach(function (_value, key) {
        if (/token|secret|password|authorization|api[_-]?key/i.test(key)) url.searchParams.set(key, "[FILTERED]");
      });
      return url.pathname + url.search;
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
      current_path: sameOriginPath(window.location.href),
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

  function storedRetryAttempt() {
    try {
      return parseInt(window.sessionStorage.getItem(AUTO_RETRY_KEY) || "0", 10) || 0;
    } catch (e) {
      return 0;
    }
  }

  function storeRetryAttempt(attempt) {
    try {
      if (attempt > 0) {
        window.sessionStorage.setItem(AUTO_RETRY_KEY, String(attempt));
      } else {
        window.sessionStorage.removeItem(AUTO_RETRY_KEY);
      }
    } catch (e) {
      // Private browsing can refuse storage; retrying still works, uncounted.
    }
  }

  function reloadForRetry() {
    if (window.__syrusReactFirstRender || autoRetrying) return;
    autoRetrying = true;
    storeRetryAttempt(storedRetryAttempt() + 1);
    (window.__syrusStartupReload || function () { window.location.reload(); })();
  }

  function scheduleAutoRetry() {
    if (autoRetryTimer !== null) return;
    var delay = AUTO_RETRY_DELAYS_MS[storedRetryAttempt()];
    if (delay === undefined) return;
    autoRetryTimer = window.setTimeout(reloadForRetry, delay);
    window.addEventListener("online", reloadForRetry, { once: true });
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
    var correlation = el.querySelector("[data-syrus-startup-correlation]");
    el.hidden = !!state.hidden;
    el.dataset.startupState = state.name || "";
    if (title && state.title) title.textContent = state.title;
    if (message && state.message) message.textContent = state.message;
    if (spinner) spinner.hidden = state.retry === true;
    if (retry) retry.hidden = state.retry !== true;
    if (correlation) {
      correlation.hidden = state.retry !== true;
      correlation.textContent = state.retry === true ? (el.dataset.referenceLabel || "Reference") + ": " + startupTraceId : "";
    }
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
        trace_id: startupTraceId,
        name: "startup." + milestone,
        path: sameOriginPath(window.location.href),
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
        message: safeErrorText(message, 500),
        url: window.location.origin + sameOriginPath(window.location.href),
        path: sameOriginPath(window.location.href),
        trace_id: startupTraceId,
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
      storeRetryAttempt(0);
      if (autoRetryTimer !== null) {
        window.clearTimeout(autoRetryTimer);
        autoRetryTimer = null;
      }
      if (window.__syrusStartupFallbackTimer) {
        window.clearTimeout(window.__syrusStartupFallbackTimer);
        window.__syrusStartupFallbackTimer = null;
      }
      if (watchdogTimer !== null) {
        window.clearTimeout(watchdogTimer);
        watchdogTimer = null;
      }
      hideStartupState();
    }
    reportMilestone(milestone);
  }

  function fail(phase, error, extra) {
    var errorObject = error && typeof error === "object" ? error : null;
    var message = errorObject && errorObject.message ? errorObject.message : "SPA startup failed";
    if (!window.__syrusReactFirstRender) {
      var status = startupStatus();
      showStartupState({
        name: "failure",
        title: status && status.dataset.failureTitle ? status.dataset.failureTitle : "The app could not start",
        message: status && status.dataset.failureMessage ? status.dataset.failureMessage : "Retry the page. If this keeps happening, share the reference below.",
        retry: true
      });
    }
    var details = {
      phase: shortText(phase || "unknown", 80),
      error_name: errorObject && errorObject.name ? shortText(errorObject.name, 100) : typeof error,
      stack: errorObject && errorObject.stack ? safeErrorText(errorObject.stack, 2000) : null,
      route_intent: sameOriginPath(window.location.href),
      trace_id: startupTraceId
    };
    Object.keys(extra || {}).forEach(function (key) { details[key] = extra[key]; });
    report("StartupFailure", message, details);
  }

  window.SyrusStartupDiagnostics = { mark: mark, fail: fail, report: report, context: context };
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
          scheduleAutoRetry();
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

  watchdogTimer = window.setTimeout(function () {
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
      phase: milestones.some(function (entry) { return entry.name === "react_module_evaluated"; }) ? "root_mount" : "bundle_evaluation",
      root_present: !!root,
      root_blank: rootBlank,
      route_intent: sameOriginPath(window.location.href),
      trace_id: startupTraceId
    });
  }, WATCHDOG_TIMEOUT_MS);
})();
