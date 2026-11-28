import { readFileSync } from "node:fs"
import { afterEach, describe, expect, it, vi } from "vitest"
import { markStartupMilestone } from "./startupDiagnostics"
import { jsonResponse } from "../testSupport"

const SPA_LAYOUT_PATH = "app/views/layouts/spa.html.erb"
const STARTUP_DIAGNOSTICS_PATH = "app/assets/javascripts/startup_diagnostics.js"
const startupListenerCleanups: Array<() => void> = []

function inlineStartupScript(): string {
  return readFileSync(STARTUP_DIAGNOSTICS_PATH, "utf-8")
}

function inlineStartupFallback(): string {
  const layout = readFileSync(SPA_LAYOUT_PATH, "utf-8")
  const start = layout.indexOf('<script id="syrus-startup-diagnostics-fallback"')
  const bodyStart = layout.indexOf("\n", start)
  const end = layout.indexOf("</script>", bodyStart)
  return layout.slice(bodyStart + 1, end)
}

function installStartupShell(
  options: {
    standalone?: boolean
    displayStandalone?: boolean
    path?: string
    visibility?: DocumentVisibilityState
    performanceEntries?: Record<string, PerformanceEntry[]>
    startupAssets?: Record<string, { size: number; wire: number }>
    estimated?: boolean
  } = {}
) {
  const startupAssetsMeta = document.createElement("meta")
  if (options.startupAssets) {
    const total = Object.values(options.startupAssets).reduce((sum, asset) => sum + asset.wire, 0)
    startupAssetsMeta.name = "syrus-startup-assets"
    startupAssetsMeta.content = JSON.stringify({ total, estimated: options.estimated === true, assets: options.startupAssets })
  }
  document.head.innerHTML = `
    <meta name="csrf-token" content="csrf-token-123">
    <meta name="syrus-app-revision" content="app-sha">
    <meta name="syrus-asset-revision" content="asset-sha">
  `
  if (options.startupAssets) document.head.appendChild(startupAssetsMeta)
  // Mirrors app/views/spa/show.html.erb with its English strings.
  document.body.innerHTML = `
    <div id="syrus-startup-status" role="status" data-startup-state="loading"
         data-locale="en"
         data-progress-amount="%{loaded} of %{total}"
         data-progress-amount-estimated="%{loaded} of about %{total}"
         data-progress-speed="about %{speed}"
         data-progress-time-left="about %{time} left">
      <div data-syrus-startup-spinner></div>
      <p data-syrus-startup-title>Loading Syrus</p>
      <p data-syrus-startup-message>Loading the app.</p>
      <div data-syrus-startup-progress aria-live="off" hidden>
        <div role="progressbar" aria-label="Download progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0" data-syrus-startup-progressbar>
          <div data-syrus-startup-progress-fill></div>
        </div>
        <p data-syrus-startup-progress-detail></p>
      </div>
      <p data-syrus-startup-correlation hidden></p>
      <a href="/jobs/42" data-syrus-startup-retry hidden>Retry</a>
    </div>
    <div id="syrus-spa-root"></div>
  `
  window.history.pushState({}, "", options.path ?? "/jobs/42")
  Object.defineProperty(navigator, "standalone", { configurable: true, value: options.standalone === true })
  Object.defineProperty(document, "visibilityState", { configurable: true, value: options.visibility ?? "visible" })
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn((query: string) => ({
      matches: options.displayStandalone === true && query === "(display-mode: standalone)",
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })

  const originalAddEventListener = window.addEventListener.bind(window)
  const originalRemoveEventListener = window.removeEventListener.bind(window)
  vi.spyOn(window, "addEventListener").mockImplementation((type, listener, options) => {
    originalAddEventListener(type, listener, options)
    startupListenerCleanups.push(() => originalRemoveEventListener(type, listener, options))
  })

  const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
  if (options.performanceEntries) {
    vi.spyOn(window.performance, "getEntriesByType").mockImplementation((type) => options.performanceEntries?.[type] ?? [])
  }
  window.eval(inlineStartupScript())
  return fetchSpy
}

type FetchSpy = ReturnType<typeof vi.fn<typeof window.fetch>>

function postedBodies(fetchSpy: FetchSpy): Array<Record<string, unknown>> {
  return fetchSpy.mock.calls.map((call: Parameters<typeof window.fetch>) => JSON.parse(String((call[1] as RequestInit).body)) as Record<string, unknown>)
}

function postedBrowserErrors(fetchSpy: FetchSpy): Array<Record<string, unknown>> {
  return postedBodies(fetchSpy)
    .map((body) => body.browser_error)
    .filter(Boolean) as Array<Record<string, unknown>>
}

function postedPerformanceEvents(fetchSpy: FetchSpy): Array<Record<string, unknown>> {
  return postedBodies(fetchSpy)
    .map((body) => body.performance_event)
    .filter(Boolean) as Array<Record<string, unknown>>
}

function startupStatus() {
  const status = document.getElementById("syrus-startup-status")
  if (!status) throw new Error("startup status not found")
  return status
}

function startupProgress() {
  const progress = document.querySelector("[data-syrus-startup-progress]")
  if (!(progress instanceof HTMLElement)) throw new Error("startup progress not found")
  return progress
}

function startupProgressBar() {
  const bar = document.querySelector("[role=progressbar]")
  if (!(bar instanceof HTMLElement)) throw new Error("startup progressbar not found")
  return bar
}

function startupMessage() {
  const message = document.querySelector("[data-syrus-startup-message]")
  if (!(message instanceof HTMLElement)) throw new Error("startup message not found")
  return message
}

// A stand-in for navigator.serviceWorker that delivers the worker's progress
// messages (app/views/pwa/service_worker.js.erb) to the shell's listener.
function installServiceWorker() {
  const listeners = new Set<(event: MessageEvent) => void>()
  const container = {
    controller: { state: "activated" },
    addEventListener: vi.fn((type: string, listener: (event: MessageEvent) => void) => {
      if (type === "message") listeners.add(listener)
    }),
    removeEventListener: vi.fn((type: string, listener: (event: MessageEvent) => void) => {
      if (type === "message") listeners.delete(listener)
    }),
    startMessages: vi.fn()
  }
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: container })
  return {
    container,
    listenerCount: () => listeners.size,
    progress(path: string, loaded: number, done = false) {
      listeners.forEach((listener) => listener({ data: { type: "syrus:startup-asset-progress", path, loaded, done } } as MessageEvent))
    }
  }
}

const ENTRY_PATH = "/assets/spa-entry-AbC_12-x.digested.js"
const VENDOR_PATH = "/assets/spa-vendor-Zz9_ab-c.digested.js"
// Uncompressed size and the size of the variant on the wire: the entry
// compresses 4:1, so a megabyte of wire bytes in all.
const STARTUP_ASSETS = {
  [ENTRY_PATH]: { size: 3_000_000, wire: 750_000 },
  [VENDOR_PATH]: { size: 1_000_000, wire: 250_000 }
}

function startupRetry() {
  const retry = document.querySelector("[data-syrus-startup-retry]")
  if (!(retry instanceof HTMLAnchorElement)) throw new Error("startup retry not found")
  return retry
}

describe("startupDiagnostics", () => {
  afterEach(() => {
    startupListenerCleanups.splice(0).forEach((cleanup) => cleanup())
    vi.useRealTimers()
    delete window.SyrusStartupDiagnostics
    delete window.__syrusReactFirstRender
    delete window.__syrusStartupFallbackTimer
    document.head.innerHTML = ""
    document.body.innerHTML = ""
    window.sessionStorage.clear()
    Reflect.deleteProperty(navigator, "serviceWorker")
    vi.restoreAllMocks()
  })

  it("passes milestones to the shell-installed startup diagnostics hook", () => {
    const mark = vi.fn()
    window.SyrusStartupDiagnostics = { mark }

    markStartupMilestone("react_commit")

    expect(mark).toHaveBeenCalledWith("react_commit")
  })

  it("exposes retained startup state and retry count before diagnostics subscribe", () => {
    vi.useFakeTimers()
    window.sessionStorage.setItem("syrus.startup.autoRetryAttempt", "2")
    installStartupShell()

    vi.advanceTimersByTime(8000)
    const snapshot = window.SyrusStartupDiagnostics?.snapshot?.()

    expect(snapshot).toMatchObject({ current_state: "watchdog", auto_retry_attempt: 2 })
    expect(snapshot?.events).toEqual([])
  })

  it("loads diagnostics and startup styles as digestible assets instead of shell-inline payloads", () => {
    const layout = readFileSync(SPA_LAYOUT_PATH, "utf-8")

    expect(layout).toContain('javascript_include_tag "startup_diagnostics"')
    expect(readFileSync("app/assets/stylesheets/startup_diagnostics.css", "utf-8")).toContain(".syrus-startup-status__panel")
    expect(layout).not.toContain("function startupTimings()")
    expect(layout).not.toContain(".syrus-startup-status__panel {")
  })

  it("keeps a shell watchdog when the diagnostics asset itself fails", () => {
    vi.useFakeTimers()
    document.body.innerHTML = `
      <div id="syrus-startup-status" hidden><span data-syrus-startup-spinner></span><p data-syrus-startup-title></p><p data-syrus-startup-message></p><a data-syrus-startup-retry hidden></a></div>
    `
    window.eval(inlineStartupFallback())
    const failedAsset = document.createElement("script")
    failedAsset.id = "syrus-startup-diagnostics"
    document.head.appendChild(failedAsset)
    failedAsset.dispatchEvent(new Event("error"))

    expect(startupStatus()).not.toHaveAttribute("hidden")
    expect(startupStatus()).toHaveTextContent("The app could not load")
    expect(startupRetry()).not.toHaveAttribute("hidden")
  })

  it("does nothing when the shell hook is unavailable", () => {
    expect(() => markStartupMilestone("react_module_evaluated")).not.toThrow()
  })

  it("posts standalone startup milestones to performance events with launch context", () => {
    const fetchSpy = installStartupShell({ standalone: true, path: "/jobs/42?tab=summary" })

    window.SyrusStartupDiagnostics?.mark("react_module_evaluated")
    window.SyrusStartupDiagnostics?.mark("react_commit")
    window.SyrusStartupDiagnostics?.mark("react_post_paint")

    expect(window.__syrusReactFirstRender).toBe(true)
    const events = postedPerformanceEvents(fetchSpy)
    expect(events.map((event) => event.name)).toEqual([
      "startup.shell_loaded",
      "startup.react_module_evaluated",
      "startup.react_commit",
      "startup.react_post_paint"
    ])
    expect(events[0]).toMatchObject({
      path: "/jobs/42?tab=summary",
      visibility_state: "visible"
    })
    expect(events[0].metadata).toMatchObject({
      current_path: "/jobs/42?tab=summary",
      app_revision: "app-sha",
      asset_revision: "asset-sha",
      navigator_standalone: true,
      display_mode_standalone: false,
      milestone: "shell_loaded"
    })
  })

  it("records bounded transfer context including cached and zeroed timing fields", () => {
    const resource = (index: number, origin = window.location.origin) =>
      ({
        name: `${origin}/assets/chunk-${index}.js?secret=no`,
        entryType: "resource",
        initiatorType: "script",
        requestStart: index === 0 ? 0 : 10.04,
        responseStart: index === 0 ? 0 : 12.06,
        responseEnd: index === 0 ? 0 : 14.08,
        transferSize: index === 0 ? 0 : 1234,
        encodedBodySize: index === 0 ? 900 : 1000,
        decodedBodySize: index === 0 ? 1200 : 1500,
        nextHopProtocol: index === 0 ? "" : "h2"
      }) as unknown as PerformanceEntry
    const fetchSpy = installStartupShell({
      standalone: true,
      performanceEntries: {
        navigation: [
          {
            requestStart: 1,
            responseStart: 2,
            responseEnd: 3,
            transferSize: 4,
            encodedBodySize: 5,
            decodedBodySize: 6,
            nextHopProtocol: "h3"
          } as unknown as PerformanceEntry
        ],
        resource: [
          resource(0),
          { name: `${window.location.origin}/assets/missing.js`, entryType: "resource", initiatorType: "script" } as unknown as PerformanceEntry,
          ...Array.from({ length: 44 }, (_, index) => resource(index + 1)),
          resource(99, "https://cdn.example.test")
        ]
      }
    })

    window.SyrusStartupDiagnostics?.mark("react_module_evaluated")

    const event = postedPerformanceEvents(fetchSpy).find((entry) => entry.name === "startup.react_module_evaluated")
    const timings = (event?.metadata as { startup_timings: { navigation: Record<string, unknown>; resources: Array<Record<string, unknown>> } }).startup_timings
    expect(timings.navigation).toMatchObject({ response_end_ms: 3, transfer_size: 4, protocol: "h3" })
    expect(timings.resources).toHaveLength(40)
    expect(timings.resources[0]).toEqual({
      path: "/assets/chunk-0.js",
      request_start_ms: 0,
      response_start_ms: 0,
      response_end_ms: 0,
      transfer_size: 0,
      encoded_body_size: 900,
      decoded_body_size: 1200,
      cache_status: "cached",
      protocol: null,
      delivery_type: null
    })
    expect(timings.resources[1]).toMatchObject({
      path: "/assets/missing.js",
      request_start_ms: null,
      response_start_ms: null,
      response_end_ms: null,
      transfer_size: null,
      encoded_body_size: null,
      decoded_body_size: null,
      cache_status: null,
      protocol: null,
      delivery_type: null
    })
    expect(JSON.stringify(timings)).not.toContain("cdn.example.test")
  })

  it("records initially hidden visibility and lifecycle state on every milestone", () => {
    const fetchSpy = installStartupShell({ standalone: true, visibility: "hidden" })
    window.SyrusStartupDiagnostics?.mark("react_commit")

    for (const event of postedPerformanceEvents(fetchSpy)) {
      expect(event.visibility_state).toBe("hidden")
      expect(event.metadata).toMatchObject({ visibility_state: "hidden", lifecycle_state: "hidden" })
    }
  })

  it("keeps normal tab milestones local unless diagnostics are explicitly requested", () => {
    const fetchSpy = installStartupShell()

    window.SyrusStartupDiagnostics?.mark("react_commit")

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("allows opt-in startup milestone posting from a normal browser tab", () => {
    const fetchSpy = installStartupShell({ path: "/dashboard?startup_diagnostics=1" })

    window.SyrusStartupDiagnostics?.mark("react_commit")

    expect(postedPerformanceEvents(fetchSpy).map((event) => event.name)).toEqual(["startup.shell_loaded", "startup.react_commit"])
  })

  it("reports script and stylesheet load failures to browser errors without leaking cross-origin URLs", () => {
    const fetchSpy = installStartupShell()
    const failedScript = document.createElement("script")
    failedScript.src = `${window.location.origin}/assets/spa-dead.js?v=asset-sha`
    document.head.appendChild(failedScript)

    failedScript.dispatchEvent(new Event("error"))

    const [error] = postedBrowserErrors(fetchSpy)
    expect(error).toMatchObject({
      app_revision: "app-sha",
      name: "StartupResourceError",
      message: "SPA startup resource failed to load",
      path: "/jobs/42"
    })
    expect(error.metadata).toMatchObject({
      app_revision: "app-sha",
      asset_revision: "asset-sha",
      resource_path: "/assets/spa-dead.js",
      resource_type: "script",
      initiator_type: "script",
      event_kind: "error",
      last_completed_milestone: "shell_loaded",
      browser_online: true,
      navigator_standalone: false
    })
    expect(startupStatus()).toHaveAttribute("data-startup-state", "resource_error")
    expect(startupStatus()).toHaveTextContent("The app could not load")
    expect(startupStatus()).toHaveTextContent("Check your connection, then retry.")
    expect(startupRetry()).not.toHaveAttribute("hidden")
    expect(startupRetry().href).toBe(`${window.location.origin}/jobs/42`)
  })

  it("does not show the startup shell for resource failures after React renders", () => {
    const fetchSpy = installStartupShell()
    window.SyrusStartupDiagnostics?.mark("react_commit")
    const failedLazyScript = document.createElement("script")
    failedLazyScript.src = `${window.location.origin}/assets/lazy-chunk-dead.js?v=asset-sha`
    document.head.appendChild(failedLazyScript)

    failedLazyScript.dispatchEvent(new Event("error"))

    const [error] = postedBrowserErrors(fetchSpy)
    expect(error).toMatchObject({
      name: "StartupResourceError",
      message: "SPA startup resource failed to load"
    })
    expect(error.metadata).toMatchObject({
      resource_path: "/assets/lazy-chunk-dead.js",
      resource_type: "script",
      startup_phase: "post_render"
    })
    expect(startupStatus()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "ready")
    expect(startupStatus()).not.toHaveTextContent("The app could not load")
  })

  it("reports allowlisted resource transport, service-worker, and revision evidence without URL content", () => {
    window.sessionStorage.setItem("syrus.startup.appRevision", "previous-sha")
    Object.defineProperty(navigator, "onLine", { configurable: true, value: false })
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: { controller: { state: "activated", scriptURL: "https://unsafe.example/sw.js?token=secret" } }
    })
    const resourceUrl = `${window.location.origin}/assets/spa-WhiteboardTab.css?token=secret&user=private`
    const fetchSpy = installStartupShell({
      performanceEntries: {
        resource: [
          {
            name: resourceUrl,
            entryType: "resource",
            initiatorType: "link",
            responseStatus: 503,
            duration: 1400,
            transferSize: 2048,
            encodedBodySize: 12000
          } as unknown as PerformanceEntry
        ]
      }
    })
    const failedStylesheet = document.createElement("link")
    failedStylesheet.rel = "stylesheet"
    failedStylesheet.href = resourceUrl
    document.head.appendChild(failedStylesheet)

    failedStylesheet.dispatchEvent(new Event("error"))

    const [error] = postedBrowserErrors(fetchSpy)
    expect(error).toMatchObject({ recoverable: true })
    expect(error.metadata).toMatchObject({
      resource_path: "/assets/spa-WhiteboardTab.css",
      resource_type: "stylesheet",
      initiator_type: "link",
      startup_phase: "startup",
      last_completed_milestone: "shell_loaded",
      event_kind: "error",
      browser_online: false,
      service_worker_present: true,
      service_worker_controlled: true,
      revision_changed: true,
      previous_app_revision: "previous-sha",
      resource_timing: {
        response_status: 503,
        duration_bucket: "1s_to_5s",
        transfer_size_bucket: "under_10kb",
        encoded_size_bucket: "10kb_to_100kb",
        transfer_classification: "network"
      }
    })
    expect(JSON.stringify(error)).not.toContain("token=secret")
    expect(JSON.stringify(error)).not.toContain("user=private")
    expect(JSON.stringify(error)).not.toContain("unsafe.example")
  })

  it("reports global errors and unhandled rejections with bounded structured fields", () => {
    const fetchSpy = installStartupShell()
    const error = new Error("module exploded with a long message")
    const errorEvent = new ErrorEvent("error", {
      message: error.message,
      filename: `${window.location.origin}/assets/chunk.js?v=asset-sha`,
      lineno: 12,
      colno: 34,
      error
    })
    const rejectionEvent = new Event("unhandledrejection") as PromiseRejectionEvent
    Object.defineProperty(rejectionEvent, "reason", { value: new TypeError("bootstrap fetch failed") })

    window.dispatchEvent(errorEvent)
    window.dispatchEvent(rejectionEvent)

    const errors = postedBrowserErrors(fetchSpy)
    expect(errors.map((entry) => entry.name)).toEqual(["StartupWindowError", "StartupUnhandledRejection"])
    expect(errors[0].metadata).toMatchObject({
      source: "/assets/chunk.js?v=asset-sha",
      line: 12,
      column: 34,
      error_name: "Error"
    })
    expect(errors[1]).toMatchObject({
      name: "StartupUnhandledRejection",
      message: "bootstrap fetch failed"
    })
    expect(errors[1].metadata).toMatchObject({
      error_name: "TypeError"
    })
  })

  it("reports the startup watchdog when React never marks first render", () => {
    vi.useFakeTimers()
    const fetchSpy = installStartupShell()

    vi.advanceTimersByTime(8000)

    const [error] = postedBrowserErrors(fetchSpy)
    expect(error).toMatchObject({
      name: "StartupWatchdog",
      message: "SPA startup watchdog: root still blank",
      path: "/jobs/42"
    })
    expect(error.metadata).toMatchObject({
      phase: "bundle_evaluation",
      root_present: true,
      root_blank: true,
      milestones: [{ name: "shell_loaded", at_ms: 0, visibility_state: "visible", document_ready_state: "complete", lifecycle_state: "active" }]
    })
    expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")
    expect(startupStatus()).toHaveTextContent("Syrus is still loading")
    expect(startupStatus()).toHaveTextContent("It keeps loading on its own.")
    // Retrying a slow load throws away what already downloaded.
    expect(startupRetry()).toHaveAttribute("hidden")
  })

  it("offers Retry only once startup has made no progress for the stall window", () => {
    vi.useFakeTimers()
    let resources: PerformanceEntry[] = []
    installStartupShell({ performanceEntries: { get resource() { return resources } } as unknown as Record<string, PerformanceEntry[]> })

    vi.advanceTimersByTime(8000)
    // A slow bundle finishes after a while: that is progress, so no Retry yet.
    vi.advanceTimersByTime(25000)
    resources = [ { name: "/assets/app.js" } as PerformanceEntry ]
    vi.advanceTimersByTime(5000)
    expect(startupRetry()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")

    // Then nothing arrives for the whole stall window.
    vi.advanceTimersByTime(35000)
    expect(startupStatus()).toHaveAttribute("data-startup-state", "stalled")
    expect(startupStatus()).toHaveTextContent("Loading has stalled")
    expect(startupRetry()).not.toHaveAttribute("hidden")
    expect(startupRetry().href).toBe(`${window.location.origin}/jobs/42`)
  })

  it("takes over from the shell's fallback timer, so the shell never offers an early Retry", () => {
    vi.useFakeTimers()
    document.body.innerHTML = `<div id="syrus-startup-status"></div>`
    window.eval(inlineStartupFallback())
    installStartupShell()

    vi.advanceTimersByTime(8000)

    expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")
    expect(startupRetry()).toHaveAttribute("hidden")
  })

  it("hides the shell loading state and does not report the watchdog after React marks first render", () => {
    vi.useFakeTimers()
    const fetchSpy = installStartupShell()

    window.SyrusStartupDiagnostics?.mark("react_commit")
    vi.advanceTimersByTime(8000)

    expect(postedBrowserErrors(fetchSpy)).toEqual([])
    expect(startupStatus()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "ready")
    expect(vi.getTimerCount()).toBe(0)
  })

  it("cleans up both shell and diagnostics watchdog timers after mount", () => {
    vi.useFakeTimers()
    installStartupShell()
    window.eval(inlineStartupFallback())

    window.SyrusStartupDiagnostics?.mark("react_commit")

    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(["root_mount", "bootstrap_fetch", "route_initialization"] as const)("shows and reports a bounded recovery surface for %s failures", (phase) => {
    const fetchSpy = installStartupShell({ path: "/jobs/42?tab=review" })

    window.SyrusStartupDiagnostics?.fail?.(phase, new TypeError("secret=do-not-render"))

    const [error] = postedBrowserErrors(fetchSpy)
    expect(error).toMatchObject({
      name: "StartupFailure",
      message: "secret=[FILTERED]",
      trace_id: expect.stringMatching(/^startup-/),
      path: "/jobs/42?tab=review"
    })
    expect(error.metadata).toMatchObject({
      phase,
      error_name: "TypeError",
      route_intent: "/jobs/42?tab=review"
    })
    expect(startupStatus()).toHaveAttribute("data-startup-state", "failure")
    expect(startupStatus()).not.toHaveTextContent("secret=do-not-render")
    expect(startupStatus()).toHaveTextContent(/Reference: startup-/)
    expect(startupRetry()).not.toHaveAttribute("hidden")
  })

  it("reports later failures without resurrecting the startup recovery surface", () => {
    const fetchSpy = installStartupShell()
    window.SyrusStartupDiagnostics?.mark("react_commit")

    window.SyrusStartupDiagnostics?.fail?.("bootstrap_fetch", new Error("later bootstrap failure"))

    expect(postedBrowserErrors(fetchSpy)).toEqual([
      expect.objectContaining({
        name: "StartupFailure",
        message: "later bootstrap failure"
      })
    ])
    expect(startupStatus()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "ready")
    expect(startupRetry()).toHaveAttribute("hidden")
  })

  describe("download progress", () => {
    it("shows the service worker's progress, speed, and time left in wire bytes only once the watchdog fires", () => {
      vi.useFakeTimers()
      const worker = installServiceWorker()
      installStartupShell({ startupAssets: STARTUP_ASSETS })
      expect(worker.container.startMessages).toHaveBeenCalled()

      // The worker counts decoded bytes: 180 KB of them a second is 45 KB a
      // second on the wire for a file that compresses 4:1.
      let loaded = 0
      const receiveForSeconds = (seconds: number) => {
        for (let second = 0; second < seconds; second += 1) {
          vi.advanceTimersByTime(500)
          loaded += 180 * 1024
          worker.progress(ENTRY_PATH, loaded)
          vi.advanceTimersByTime(500)
        }
      }

      receiveForSeconds(7)
      expect(startupStatus()).toHaveAttribute("data-startup-state", "loading")
      expect(startupProgress()).toHaveAttribute("hidden")
      expect(startupMessage()).toHaveTextContent("Loading the app.")

      receiveForSeconds(1)
      expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")
      expect(startupProgress()).not.toHaveAttribute("hidden")
      expect(startupMessage()).toHaveAttribute("hidden")
      expect(startupProgressBar()).toHaveAttribute("aria-valuenow", "36")
      expect(startupProgressBar()).toHaveAttribute("aria-valuetext", "360 KB of 977 KB")
      expect(startupProgress()).toHaveTextContent("360 KB of 977 KB · about 45 KB/s")

      receiveForSeconds(4)
      // 437 KB left at about 44 KB/s.
      expect(startupProgress()).toHaveTextContent(/^540 KB of 977 KB · about 4\d KB\/s · about 1[05] s left$/)
      expect(startupProgressBar()).toHaveAttribute("aria-valuenow", "55")
      expect((document.querySelector("[data-syrus-startup-progress-fill]") as HTMLElement).style.width).toBe("55%")
      expect(startupRetry()).toHaveAttribute("hidden")
    })

    it("ignores progress for files startup is not waiting for", () => {
      vi.useFakeTimers()
      const worker = installServiceWorker()
      installStartupShell({ startupAssets: STARTUP_ASSETS })

      worker.progress("/assets/spa-WhiteboardTab-BuK7SBJt.digested.js", 500_000)
      vi.advanceTimersByTime(8000)

      expect(startupProgress()).toHaveAttribute("hidden")
      expect(startupMessage()).toHaveTextContent("It keeps loading on its own.")
    })

    it("falls back to finished startup assets in resource timing without the service worker", () => {
      vi.useFakeTimers()
      installStartupShell({
        startupAssets: STARTUP_ASSETS,
        performanceEntries: {
          resource: [
            // 200 KB of body crossed the network (a little better than the
            // shell expected), in four seconds.
            { name: `${window.location.origin}${VENDOR_PATH}`, startTime: 100, responseEnd: 4100, transferSize: 205_100, encodedBodySize: 204_800, decodedBodySize: 1_000_000 },
            // Cached: counts toward progress, not toward speed.
            { name: `${window.location.origin}/assets/app-74e6a7ef.css`, startTime: 50, responseEnd: 60, transferSize: 0, decodedBodySize: 4000 },
            { name: `${window.location.origin}/api/v1/app/bootstrap`, startTime: 50, responseEnd: 9000, transferSize: 900_000 }
          ] as unknown as PerformanceEntry[]
        }
      })

      vi.advanceTimersByTime(8000)

      expect(startupProgress()).not.toHaveAttribute("hidden")
      expect(startupProgressBar()).toHaveAttribute("aria-valuenow", "25")
      expect(startupProgress()).toHaveTextContent("244 KB of 977 KB · about 50 KB/s")
      expect(startupProgress()).not.toHaveTextContent("left")
    })

    it("measures fallback speed from the transfer size when the browser gives no encoded size", () => {
      vi.useFakeTimers()
      installStartupShell({
        startupAssets: STARTUP_ASSETS,
        performanceEntries: {
          resource: [
            { name: `${window.location.origin}${VENDOR_PATH}`, startTime: 0, responseEnd: 5000, transferSize: 256_000 }
          ] as unknown as PerformanceEntry[]
        }
      })

      vi.advanceTimersByTime(8000)

      expect(startupProgress()).toHaveTextContent("244 KB of 977 KB · about 50 KB/s")
    })

    it("says the total is an estimate when the shell could not tell the browser's compression", () => {
      vi.useFakeTimers()
      const worker = installServiceWorker()
      installStartupShell({ startupAssets: STARTUP_ASSETS, estimated: true })

      worker.progress(ENTRY_PATH, 1_500_000)
      vi.advanceTimersByTime(8000)

      expect(startupProgress()).toHaveTextContent("366 KB of about 977 KB")
    })

    it("keeps the plain loading text when neither source has anything to show", () => {
      vi.useFakeTimers()
      installServiceWorker()
      installStartupShell({ startupAssets: STARTUP_ASSETS, performanceEntries: { resource: [] } })

      vi.advanceTimersByTime(12000)

      expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")
      expect(startupProgress()).toHaveAttribute("hidden")
      expect(startupMessage()).not.toHaveAttribute("hidden")
      expect(startupMessage()).toHaveTextContent("It keeps loading on its own.")
    })

    it("keeps the plain loading text when the shell has no startup size", () => {
      vi.useFakeTimers()
      const worker = installServiceWorker()
      installStartupShell()

      worker.progress(ENTRY_PATH, 500_000)
      vi.advanceTimersByTime(8000)

      expect(worker.container.addEventListener).not.toHaveBeenCalled()
      expect(startupProgress()).toHaveAttribute("hidden")
      expect(startupMessage()).toHaveTextContent("It keeps loading on its own.")
    })

    it("offers Retry only after bytes stop arriving for the stall window, and withdraws it when they resume", () => {
      vi.useFakeTimers()
      const worker = installServiceWorker()
      // Resource timing never changes here: on its own, the old signature
      // check would call this stalled 30 seconds after the watchdog.
      installStartupShell({ startupAssets: STARTUP_ASSETS, performanceEntries: { resource: [] } })

      let loaded = 0
      vi.advanceTimersByTime(8000)
      for (let second = 0; second < 60; second += 5) {
        loaded += 5000
        worker.progress(ENTRY_PATH, loaded)
        vi.advanceTimersByTime(5000)
        expect(startupRetry()).toHaveAttribute("hidden")
      }
      expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")

      // The connection goes quiet.
      vi.advanceTimersByTime(24000)
      expect(startupRetry()).toHaveAttribute("hidden")
      vi.advanceTimersByTime(2000)
      expect(startupStatus()).toHaveAttribute("data-startup-state", "stalled")
      expect(startupStatus()).toHaveTextContent("Loading has stalled")
      expect(startupRetry()).not.toHaveAttribute("hidden")
      // The bar stays, showing where it stopped.
      expect(startupProgress()).not.toHaveAttribute("hidden")

      worker.progress(ENTRY_PATH, loaded + 5000)
      vi.advanceTimersByTime(1000)
      expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")
      expect(startupRetry()).toHaveAttribute("hidden")
    })

    it("stops every timer and the worker listener when React commits", () => {
      vi.useFakeTimers()
      const worker = installServiceWorker()
      installStartupShell({ startupAssets: STARTUP_ASSETS })
      worker.progress(ENTRY_PATH, 100_000)
      vi.advanceTimersByTime(10000)
      expect(startupProgress()).not.toHaveAttribute("hidden")

      window.SyrusStartupDiagnostics?.mark("react_commit")

      expect(vi.getTimerCount()).toBe(0)
      expect(worker.listenerCount()).toBe(0)
      expect(worker.container.removeEventListener).toHaveBeenCalledWith("message", expect.any(Function))
      expect(startupStatus()).toHaveAttribute("hidden")
    })
  })
})
