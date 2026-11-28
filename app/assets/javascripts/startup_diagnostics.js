(function () {
  var WATCHDOG_TIMEOUT_MS = 8000;
  // A slow connection is still a working one. Retrying throws away whatever
  // has already downloaded and starts over, so the watchdog only says the app
  // is still loading, with a progress bar when it can measure one; Retry is
  // offered once nothing has made progress for this long. "Progress" is bytes
  // arriving when the service worker reports them, and otherwise a startup
  // resource finishing or a milestone being reached.
  var STALL_RETRY_MS = 30000;
  var PROGRESS_TICK_MS = 1000;
  var progressTimer = null;
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
  var REVISION_KEY = "syrus.startup.appRevision";
  var autoRetryTimer = null;
  var autoRetrying = false;
  var currentRevision = meta("syrus-app-revision") || "unknown";
  var previousRevision = storedValue(REVISION_KEY);
  var revisionChanged = !!previousRevision && previousRevision !== currentRevision;
  var snapshotListeners = null;
  var startupEvents = null;
  var serviceWorkerRegistration = null;

  function notifySnapshotListeners() {
    if (!snapshotListeners) return;
    snapshotListeners.forEach(function (listener) { listener(); });
  }

  function subscribeSnapshot(listener) {
    if (!snapshotListeners) {
      snapshotListeners = [];
      startupEvents = [];
    }
    snapshotListeners.push(listener);
    if (snapshotListeners.length === 1 && navigator.serviceWorker && typeof navigator.serviceWorker.getRegistration === "function") {
      navigator.serviceWorker.getRegistration().then(function (registration) {
        if (!snapshotListeners) return;
        serviceWorkerRegistration = registration ? {
          installing: registration.installing ? registration.installing.state : null,
          waiting: registration.waiting ? registration.waiting.state : null,
          active: registration.active ? registration.active.state : null
        } : null;
        notifySnapshotListeners();
      }).catch(function () {});
    }
    return function () {
      if (!snapshotListeners) return;
      snapshotListeners = snapshotListeners.filter(function (candidate) { return candidate !== listener; });
      if (!snapshotListeners.length) {
        snapshotListeners = null;
        startupEvents = null;
      }
    };
  }

  function recordSnapshotEvent(kind, details) {
    if (!snapshotListeners) return;
    var event = { kind: kind, at_ms: Date.now() - startupAt };
    Object.keys(details || {}).forEach(function (key) { event[key] = details[key]; });
    startupEvents.push(event);
    notifySnapshotListeners();
  }

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

  function sameOriginAssetPath(value) {
    try {
      var url = new URL(value, window.location.href);
      return url.origin === window.location.origin && url.pathname.indexOf("/assets/") === 0 ? url.pathname : "unknown";
    } catch (e) {
      return "unknown";
    }
  }

  function storedValue(key) {
    try {
      return window.sessionStorage.getItem(key);
    } catch (e) {
      return null;
    }
  }

  function storeValue(key, value) {
    try {
      window.sessionStorage.setItem(key, value);
    } catch (e) {
      // Diagnostics remain useful when private browsing refuses storage.
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

  function sizeBucket(value) {
    if (typeof value !== "number" || !isFinite(value) || value < 0) return "unavailable";
    if (value === 0) return "zero";
    if (value < 10 * 1024) return "under_10kb";
    if (value < 100 * 1024) return "10kb_to_100kb";
    if (value < 1024 * 1024) return "100kb_to_1mb";
    return "over_1mb";
  }

  function durationBucket(value) {
    if (typeof value !== "number" || !isFinite(value) || value < 0) return "unavailable";
    if (value < 100) return "under_100ms";
    if (value < 1000) return "100ms_to_1s";
    if (value < 5000) return "1s_to_5s";
    return "over_5s";
  }

  function resourceTiming(resourceUrl, resourcePath) {
    if (!window.performance || !performance.getEntriesByType) return null;
    var entries = performance.getEntriesByType("resource");
    var entry = entries.filter(function (candidate) {
      return candidate.name === resourceUrl || sameOriginAssetPath(candidate.name) === resourcePath;
    }).pop();
    if (!entry) return null;

    var transferSize = finiteNumber(entry.transferSize);
    var encodedSize = finiteNumber(entry.encodedBodySize);
    var classification = "unavailable";
    if (entry.deliveryType === "cache" || (transferSize === 0 && encodedSize > 0)) classification = "cache";
    else if (entry.deliveryType === "local") classification = "service_worker";
    else if (transferSize > 0) classification = "network";

    return {
      response_status: finiteNumber(entry.responseStatus),
      duration_bucket: durationBucket(entry.duration),
      transfer_size_bucket: sizeBucket(entry.transferSize),
      encoded_size_bucket: sizeBucket(entry.encodedBodySize),
      transfer_classification: classification
    };
  }

  function serviceWorkerContext() {
    var container = navigator.serviceWorker;
    return {
      service_worker_present: !!container,
      service_worker_controlled: !!(container && container.controller)
    };
  }

  function lastCompletedMilestone() {
    return milestones.length ? milestones[milestones.length - 1].name : "none";
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
    return ["startup", kind, previousRevision || "none", currentRevision, sameOriginPath(window.location.href), sameOriginAssetPath(detail || "")].join(":").slice(0, 500);
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
    if (startupEvents) startupEvents.push({ kind: "auto_retry", at_ms: Date.now() - startupAt, attempt: storedRetryAttempt() });
    notifySnapshotListeners();
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
    if (message) message.hidden = false;
    // The download bar belongs to "still loading" and "stalled"; every other
    // state (a failure, ready) replaces it.
    var progress = el.querySelector("[data-syrus-startup-progress]");
    if (progress && state.name !== "watchdog" && state.name !== "stalled") progress.hidden = true;
    if (state.name === "watchdog" || state.name === "stalled") renderProgress();
    return true;
  }

  function showStartupState(state) {
    pendingStartupState = state;
    if (startupEvents) startupEvents.push({ kind: state.name || "unknown", at_ms: Date.now() - startupAt });
    notifySnapshotListeners();
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
    var key = kind + ":" + (extra && extra.milestone ? extra.milestone : "") + ":" + (extra && (extra.resource_path || extra.resource_url) ? (extra.resource_path || extra.resource_url) : "");
    if (reportedKeys[key]) return;
    reportedKeys[key] = true;

    postJson("/api/v1/app/browser_errors", {
      browser_error: {
        occurred_at: new Date().toISOString(),
        app_revision: meta("syrus-app-revision"),
        fingerprint: fingerprint(kind, extra && (extra.resource_path || extra.resource_url)),
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
        recoverable: kind === "StartupResourceError",
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
      stopProgressTracking();
      hideStartupState();
    }
    reportMilestone(milestone);
    notifySnapshotListeners();
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

  function diagnosticsSnapshot() {
    var assets = [];
    if (startupAssets) {
      Object.keys(startupAssets.sizes).forEach(function (path) {
        var timing = finishedStartupEntries().filter(function (entry) { return sameOriginAssetPath(entry.name) === path; }).pop();
        assets.push({
          path: path,
          bytes: workerBytes[path] || (timing ? startupAssets.sizes[path] : 0),
          size: startupAssets.sizes[path],
          wire_size: startupAssets.wire[path],
          budget_size: startupAssets.budgetSizes[path] == null ? null : startupAssets.budgetSizes[path],
          source: workerBytes[path] ? "service_worker" : timing ? ((timing.transferSize === 0 && timing.decodedBodySize > 0) ? "cache" : "network") : "pending",
          timing: timing ? timingEntry(timing, false) : null
        });
      });
    }
    return {
      milestones: milestones.slice(),
      assets: assets,
      progress_samples: byteSamples.slice(),
      progress: progressSnapshot(),
      budget: startupAssets && startupAssets.budget ? startupAssets.budget : null,
      lazy_chunks: startupAssets && startupAssets.lazy_chunks ? startupAssets.lazy_chunks : {},
      events: startupEvents ? startupEvents.slice() : [],
      revision: { page: currentRevision, previous: previousRevision, changed: revisionChanged },
      current_state: pendingStartupState ? pendingStartupState.name || "unknown" : null,
      service_worker: {
        present: serviceWorkerContext().service_worker_present,
        controlled: serviceWorkerContext().service_worker_controlled,
        registration: serviceWorkerRegistration,
        worker_revision: (function () {
          try { return navigator.serviceWorker.controller ? new URL(navigator.serviceWorker.controller.scriptURL).searchParams.get("v") : null; }
          catch (e) { return null; }
        })(),
        counted_requests: Object.keys(workerBytes)
      },
      auto_retry_attempt: storedRetryAttempt()
    };
  }

  window.SyrusStartupDiagnostics = { mark: mark, fail: fail, report: report, context: context, snapshot: diagnosticsSnapshot, subscribe: subscribeSnapshot, event: recordSnapshotEvent };
  mark("shell_loaded");

  document.addEventListener("visibilitychange", function () {
    lifecycleState = document.visibilityState === "hidden" ? "hidden" : "active";
  });
  window.addEventListener("pagehide", function () {
    lifecycleState = "pagehide";
    storeValue(REVISION_KEY, currentRevision);
  });
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
          resource_path: sameOriginAssetPath(resourceUrl),
          resource_type: tagName === "link" ? "stylesheet" : "script",
          initiator_type: tagName,
          startup_phase: window.__syrusReactFirstRender ? "post_render" : "startup",
          last_completed_milestone: lastCompletedMilestone(),
          event_kind: shortText(event.type || "error", 20),
          browser_online: navigator.onLine !== false,
          revision_changed: revisionChanged,
          previous_app_revision: previousRevision,
          resource_timing: resourceTiming(resourceUrl, sameOriginAssetPath(resourceUrl)),
          service_worker_present: serviceWorkerContext().service_worker_present,
          service_worker_controlled: serviceWorkerContext().service_worker_controlled
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

  // This script owns the watchdog once it runs; the shell's own fallback
  // timer is only for when this script never arrives.
  if (window.__syrusStartupFallbackTimer) {
    window.clearTimeout(window.__syrusStartupFallbackTimer);
    window.__syrusStartupFallbackTimer = null;
  }

  // ---- Startup download progress ------------------------------------------
  //
  // The shell embeds what startup has to download (syrus-startup-assets: per
  // startup asset, its uncompressed size and its size on the wire, i.e. the
  // precompressed variant this browser is served, plus the wire total).
  // Everything shown -- "X of Y", the speed, the time left -- is in wire
  // bytes, so the speed is the connection's real rate. Two sources say how
  // much has arrived:
  //
  // - the service worker, which counts the decoded bytes of each startup
  //   asset as they stream past and posts them here (app/views/pwa/
  //   service_worker.js.erb); they are scaled to wire bytes by that file's
  //   compression ratio;
  // - resource timing, which lists each asset once it has finished. That is
  //   coarse -- two chunks are most of the download -- but it is all there is
  //   on a first visit, before the worker controls the page.
  //
  // Neither is shown until the watchdog fires: a fast start never sees a bar.
  var PROGRESS_MESSAGE_TYPE = "syrus:startup-asset-progress";
  var SPEED_WINDOW_MS = 10000;
  var MIN_SPEED_SPAN_MS = 2000;
  var STABLE_SPEED_SAMPLES = 3;
  var STABLE_SPEED_RATIO = 1.5;
  var startupAssets = readStartupAssets();
  var workerBytes = {};
  var workerReported = false;
  var byteSamples = [];
  var recentSpeeds = [];
  var lastByteAt = null;
  var lastSignatureChangeAt = null;
  var lastSignature = null;
  var watchStartedAt = null;
  var serviceWorkerListener = null;
  var WATCHDOG_STATE = {
    name: "watchdog",
    title: "Syrus is still loading",
    message: "This can take a while on a slow connection. It keeps loading on its own."
  };

  function readStartupAssets() {
    var raw = meta("syrus-startup-assets");
    if (!raw) return null;
    try {
      var parsed = JSON.parse(raw);
      var listed = parsed && parsed.assets;
      if (!listed || typeof listed !== "object") return null;
      var sizes = {};
      var wire = {};
      var budgetSizes = {};
      var total = 0;
      Object.keys(listed).forEach(function (path) {
        var asset = listed[path] || {};
        var size = Number(asset.size);
        var wireSize = Number(asset.wire);
        if (path.indexOf("/assets/") !== 0 || !isFinite(size) || size < 0) return;
        if (!isFinite(wireSize) || wireSize < 0) wireSize = size;
        sizes[path] = size;
        wire[path] = wireSize;
        if (isFinite(Number(asset.budget)) && Number(asset.budget) >= 0) budgetSizes[path] = Number(asset.budget);
        total += wireSize;
      });
      return total > 0 ? { total: total, sizes: sizes, wire: wire, budgetSizes: budgetSizes, estimated: parsed.estimated === true, budget: parsed.budget || null, lazy_chunks: parsed.lazy_chunks || {} } : null;
    } catch (e) {
      return null;
    }
  }

  function isStartupAsset(path) {
    return !!startupAssets && Object.prototype.hasOwnProperty.call(startupAssets.sizes, path);
  }

  // The worker counts decoded bytes; the wire carried the compressed ones.
  // Compression is close enough to uniform within a file that the share of
  // the file decoded so far is the share of its wire bytes received.
  function wireBytes(path, decoded) {
    var size = startupAssets.sizes[path];
    if (!size) return 0;
    return (Math.min(decoded, size) / size) * startupAssets.wire[path];
  }

  function workerTotal() {
    var total = 0;
    Object.keys(workerBytes).forEach(function (path) {
      total += wireBytes(path, workerBytes[path]);
    });
    return total;
  }

  // Bytes resource timing saw cross the network for a finished asset: the
  // encoded body when the browser reports it, else the transfer size, else
  // the wire size the shell expected.
  function measuredWireBytes(entry, path) {
    var encoded = finiteNumber(entry.encodedBodySize);
    if (encoded) return encoded;
    var transferred = finiteNumber(entry.transferSize);
    if (transferred) return transferred;
    return startupAssets.wire[path];
  }

  function finishedStartupEntries() {
    if (!startupAssets) return [];
    try {
      if (!window.performance || !performance.getEntriesByType) return [];
      // A resource timing entry exists only once its resource has finished.
      return performance.getEntriesByType("resource").filter(function (entry) {
        return isStartupAsset(sameOriginAssetPath(entry.name));
      });
    } catch (e) {
      return [];
    }
  }

  function recordByteSample(now) {
    byteSamples.push({ at: now, bytes: workerTotal() });
    while (byteSamples.length > 2 && now - byteSamples[1].at > SPEED_WINDOW_MS) byteSamples.shift();
  }

  function onWorkerMessage(event) {
    var data = event && event.data;
    if (!data || data.type !== PROGRESS_MESSAGE_TYPE || window.__syrusReactFirstRender) return;
    var path = typeof data.path === "string" ? data.path : "";
    var loaded = Number(data.loaded);
    if (!isStartupAsset(path) || !isFinite(loaded) || loaded < 0) return;
    workerReported = true;
    if (loaded > (workerBytes[path] || 0)) {
      workerBytes[path] = loaded;
      lastByteAt = Date.now();
      recordByteSample(lastByteAt);
    }
    if (watchStartedAt !== null) renderProgress();
    notifySnapshotListeners();
  }

  function listenForWorkerProgress() {
    var container = navigator.serviceWorker;
    if (!startupAssets || !container || typeof container.addEventListener !== "function") return;
    serviceWorkerListener = onWorkerMessage;
    container.addEventListener("message", serviceWorkerListener);
    // Messages from the worker queue until the page opts in; with
    // addEventListener (rather than onmessage) that has to be explicit.
    try {
      if (typeof container.startMessages === "function") container.startMessages();
    } catch (e) {
      // Older engines start the queue on their own once the document parses.
    }
  }

  function stopProgressTracking() {
    if (progressTimer !== null) {
      window.clearInterval(progressTimer);
      progressTimer = null;
    }
    try {
      if (serviceWorkerListener && navigator.serviceWorker && typeof navigator.serviceWorker.removeEventListener === "function") {
        navigator.serviceWorker.removeEventListener("message", serviceWorkerListener);
      }
    } catch (e) {
      // Nothing to remove if the container cannot be reached.
    }
    serviceWorkerListener = null;
  }

  // What has arrived, in wire bytes, by the best source available: per
  // asset, what the worker counted, or (once it finished) its full wire size.
  function progressSnapshot() {
    if (!startupAssets) return null;
    var entries = finishedStartupEntries();
    if (!workerReported && !entries.length) return null;

    var perPath = {};
    Object.keys(workerBytes).forEach(function (path) {
      perPath[path] = wireBytes(path, workerBytes[path]);
    });
    entries.forEach(function (entry) {
      var path = sameOriginAssetPath(entry.name);
      perPath[path] = startupAssets.wire[path];
    });
    var loaded = 0;
    Object.keys(perPath).forEach(function (path) { loaded += perPath[path]; });
    loaded = Math.min(loaded, startupAssets.total);

    var speed = workerReported ? workerSpeed() : timingSpeed(entries);
    return {
      loaded: loaded,
      total: startupAssets.total,
      speed: speed,
      secondsLeft: workerReported && speedIsStable() && speed > 0 ? (startupAssets.total - loaded) / speed : null
    };
  }

  // Bytes per second over the recent window of worker samples.
  function workerSpeed() {
    if (byteSamples.length < 2) return null;
    var first = byteSamples[0];
    var last = byteSamples[byteSamples.length - 1];
    var span = last.at - first.at;
    if (span < MIN_SPEED_SPAN_MS) return null;
    return Math.max(0, (last.bytes - first.bytes) / (span / 1000));
  }

  function speedIsStable() {
    if (recentSpeeds.length < STABLE_SPEED_SAMPLES) return false;
    var min = Math.min.apply(Math, recentSpeeds);
    var max = Math.max.apply(Math, recentSpeeds);
    return min > 0 && max / min <= STABLE_SPEED_RATIO;
  }

  // Without the worker: the wire bytes of the startup assets that came over
  // the network, over the time from the first request to the last finish.
  // Assets served from the HTTP cache arrived instantly and would only
  // flatter it.
  function timingSpeed(entries) {
    var bytes = 0;
    var start = null;
    var end = null;
    entries.forEach(function (entry) {
      var cached = entry.deliveryType === "cache" || (entry.transferSize === 0 && entry.decodedBodySize > 0);
      var finishedAt = finiteNumber(entry.responseEnd);
      var startedAt = finiteNumber(entry.startTime);
      if (cached || finishedAt === null || startedAt === null) return;
      bytes += measuredWireBytes(entry, sameOriginAssetPath(entry.name));
      start = start === null ? startedAt : Math.min(start, startedAt);
      end = end === null ? finishedAt : Math.max(end, finishedAt);
    });
    if (!bytes || start === null || end - start <= 0) return null;
    return bytes / ((end - start) / 1000);
  }

  function formatNumber(value, digits) {
    var status = startupStatus();
    var locale = status && status.dataset.locale;
    try {
      return new Intl.NumberFormat(locale || undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value);
    } catch (e) {
      return value.toFixed(digits);
    }
  }

  function formatBytes(bytes) {
    if (bytes >= 1024 * 1024) return formatNumber(bytes / (1024 * 1024), 1) + " MB";
    return formatNumber(Math.max(0, Math.round(bytes / 1024)), 0) + " KB";
  }

  function formatSpeed(bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) return formatNumber(bytesPerSecond / (1024 * 1024), 1) + " MB/s";
    return formatNumber(Math.max(1, Math.round(bytesPerSecond / 1024)), 0) + " KB/s";
  }

  function formatDuration(seconds) {
    if (seconds < 90) return formatNumber(Math.max(5, Math.ceil(seconds / 5) * 5), 0) + " s";
    return formatNumber(Math.round(seconds / 60), 0) + " min";
  }

  function fillTemplate(template, fallback, values) {
    return String(template || fallback).replace(/%\{(\w+)\}/g, function (match, key) {
      return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : match;
    });
  }

  function renderProgress() {
    var el = startupStatus();
    if (!el || watchStartedAt === null) return;
    var state = el.dataset.startupState;
    if (state !== "watchdog" && state !== "stalled") return;
    var container = el.querySelector("[data-syrus-startup-progress]");
    var bar = el.querySelector("[data-syrus-startup-progressbar]");
    var fill = el.querySelector("[data-syrus-startup-progress-fill]");
    var detail = el.querySelector("[data-syrus-startup-progress-detail]");
    var message = el.querySelector("[data-syrus-startup-message]");
    var spinner = el.querySelector("[data-syrus-startup-spinner]");
    var snapshot = progressSnapshot();
    // Nothing measured yet: keep the plain "still loading" text and spinner.
    if (!container || !bar || !snapshot) return;

    var percent = Math.min(100, Math.floor((snapshot.loaded / snapshot.total) * 100));
    // An estimated total (the shell could not tell which compression the
    // browser gets) says so.
    var amountValues = { loaded: formatBytes(snapshot.loaded), total: formatBytes(snapshot.total) };
    var amount = startupAssets.estimated
      ? fillTemplate(el.dataset.progressAmountEstimated, "%{loaded} of about %{total}", amountValues)
      : fillTemplate(el.dataset.progressAmount, "%{loaded} of %{total}", amountValues);
    var parts = [ amount ];
    if (snapshot.speed !== null) {
      parts.push(fillTemplate(el.dataset.progressSpeed, "about %{speed}", { speed: formatSpeed(snapshot.speed) }));
    }
    if (snapshot.secondsLeft !== null && snapshot.loaded < snapshot.total) {
      parts.push(fillTemplate(el.dataset.progressTimeLeft, "about %{time} left", { time: formatDuration(snapshot.secondsLeft) }));
    }

    container.hidden = false;
    bar.setAttribute("aria-valuenow", String(percent));
    bar.setAttribute("aria-valuetext", amount);
    if (fill) fill.style.width = percent + "%";
    if (detail) detail.textContent = parts.join(" · ");
    if (spinner) spinner.hidden = true;
    // The bar replaces the "still loading" sentence; a stalled message stays.
    if (message && state === "watchdog") message.hidden = true;
  }

  function startupProgressSignature() {
    var resources = 0;
    try {
      if (window.performance && performance.getEntriesByType) resources = performance.getEntriesByType("resource").length;
    } catch (e) {
      resources = 0;
    }
    return resources + ":" + milestones.length + ":" + (document.readyState || "");
  }

  // When progress was last made. With the worker reporting, that is the last
  // byte that arrived -- a bundle still trickling in is not stalled however
  // long it takes. Once every byte is in (the bundle is evaluating), or with
  // no worker at all, it falls back to resources finishing and milestones.
  function lastProgressAt(now) {
    var signature = startupProgressSignature();
    if (signature !== lastSignature) {
      lastSignature = signature;
      lastSignatureChangeAt = now;
    }
    // (Within a byte: scaled wire bytes are fractional.)
    if (workerReported && workerTotal() < startupAssets.total - 1) return Math.max(lastByteAt || 0, watchStartedAt);
    return Math.max(lastSignatureChangeAt, lastByteAt || 0);
  }

  function progressTick() {
    if (window.__syrusReactFirstRender) {
      stopProgressTracking();
      return;
    }
    var now = Date.now();
    if (workerReported) {
      // A sample per tick, so a pause shows up as falling speed.
      recordByteSample(now);
      var speed = workerSpeed();
      if (speed !== null) {
        recentSpeeds.push(speed);
        if (recentSpeeds.length > STABLE_SPEED_SAMPLES) recentSpeeds.shift();
      }
    }

    var el = startupStatus();
    var state = el ? el.dataset.startupState : null;
    var stalled = now - lastProgressAt(now) >= STALL_RETRY_MS;
    if (stalled && state === "watchdog") {
      showStartupState({
        name: "stalled",
        title: "Loading has stalled",
        message: "Nothing has arrived for a while. Retry, or keep waiting.",
        retry: true
      });
    } else if (!stalled && state === "stalled") {
      // Bytes started arriving again: back to waiting, without the nudge.
      showStartupState(WATCHDOG_STATE);
    } else {
      renderProgress();
    }
  }

  function watchProgress() {
    var now = Date.now();
    watchStartedAt = now;
    lastSignature = startupProgressSignature();
    lastSignatureChangeAt = now;
    progressTimer = window.setInterval(progressTick, PROGRESS_TICK_MS);
  }

  try {
    listenForWorkerProgress();
  } catch (e) {
    // A browser that refuses service workers here leaves resource timing.
    serviceWorkerListener = null;
  }

  watchdogTimer = window.setTimeout(function () {
    if (window.__syrusReactFirstRender) return;
    var root = document.getElementById("syrus-spa-root");
    var rootBlank = !root || !root.textContent.trim();
    watchProgress();
    showStartupState(WATCHDOG_STATE);
    report("StartupWatchdog", rootBlank ? "SPA startup watchdog: root still blank" : "SPA startup watchdog: first render not marked", {
      phase: milestones.some(function (entry) { return entry.name === "react_module_evaluated"; }) ? "root_mount" : "bundle_evaluation",
      root_present: !!root,
      root_blank: rootBlank,
      route_intent: sameOriginPath(window.location.href),
      trace_id: startupTraceId
    });
  }, WATCHDOG_TIMEOUT_MS);
})();
