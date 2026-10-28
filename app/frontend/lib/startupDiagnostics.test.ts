import { readFileSync } from "node:fs"
import { afterEach, describe, expect, it, vi } from "vitest"
import { markStartupMilestone } from "./startupDiagnostics"
import { jsonResponse } from "../testSupport"

const SPA_LAYOUT_PATH = "app/views/layouts/spa.html.erb"
const startupListenerCleanups: Array<() => void> = []

function inlineStartupScript(): string {
  const layout = readFileSync(SPA_LAYOUT_PATH, "utf-8")
  const scriptLineStart = layout.indexOf('<script id="syrus-startup-diagnostics"')
  if (scriptLineStart < 0) throw new Error("startup diagnostics script not found")
  const bodyStart = layout.indexOf("\n", scriptLineStart)
  const bodyEnd = layout.indexOf("</script>", bodyStart)
  if (bodyStart < 0 || bodyEnd < 0) throw new Error("startup diagnostics script body not found")
  return layout.slice(bodyStart + 1, bodyEnd)
}

function installStartupShell(options: {
  standalone?: boolean
  displayStandalone?: boolean
  path?: string
  visibility?: DocumentVisibilityState
  performanceEntries?: Record<string, PerformanceEntry[]>
} = {}) {
  document.head.innerHTML = `
    <meta name="csrf-token" content="csrf-token-123">
    <meta name="syrus-app-revision" content="app-sha">
    <meta name="syrus-asset-revision" content="asset-sha">
  `
  document.body.innerHTML = `
    <div id="syrus-startup-status" role="status" data-startup-state="loading">
      <div data-syrus-startup-spinner></div>
      <p data-syrus-startup-title>Loading Syrus</p>
      <p data-syrus-startup-message>Loading the app.</p>
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
  return postedBodies(fetchSpy).map((body) => body.browser_error).filter(Boolean) as Array<Record<string, unknown>>
}

function postedPerformanceEvents(fetchSpy: FetchSpy): Array<Record<string, unknown>> {
  return postedBodies(fetchSpy).map((body) => body.performance_event).filter(Boolean) as Array<Record<string, unknown>>
}

function startupStatus() {
  const status = document.getElementById("syrus-startup-status")
  if (!status) throw new Error("startup status not found")
  return status
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
    document.head.innerHTML = ""
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  it("passes milestones to the shell-installed startup diagnostics hook", () => {
    const mark = vi.fn()
    window.SyrusStartupDiagnostics = { mark }

    markStartupMilestone("react_commit")

    expect(mark).toHaveBeenCalledWith("react_commit")
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
    const resource = (index: number, origin = window.location.origin) => ({
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
        navigation: [{
          requestStart: 1,
          responseStart: 2,
          responseEnd: 3,
          transferSize: 4,
          encodedBodySize: 5,
          decodedBodySize: 6,
          nextHopProtocol: "h3"
        } as unknown as PerformanceEntry],
        resource: [
          ...Array.from({ length: 45 }, (_, index) => resource(index)),
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

    expect(postedPerformanceEvents(fetchSpy).map((event) => event.name)).toEqual([
      "startup.shell_loaded",
      "startup.react_commit"
    ])
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
      resource_tag: "script",
      resource_url: "/assets/spa-dead.js?v=asset-sha",
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
      resource_tag: "script",
      resource_url: "/assets/lazy-chunk-dead.js?v=asset-sha"
    })
    expect(startupStatus()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "ready")
    expect(startupStatus()).not.toHaveTextContent("The app could not load")
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
    expect(errors.map((entry) => entry.name)).toEqual([
      "StartupWindowError",
      "StartupUnhandledRejection"
    ])
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
      root_present: true,
      root_blank: true,
      milestones: [
        {
          name: "shell_loaded",
          at_ms: 0,
          visibility_state: "visible",
          document_ready_state: "complete",
          lifecycle_state: "active"
        }
      ]
    })
    expect(startupStatus()).toHaveAttribute("data-startup-state", "watchdog")
    expect(startupStatus()).toHaveTextContent("Syrus is still loading")
    expect(startupStatus()).toHaveTextContent("This can happen on a slow connection. Retry if it does not finish soon.")
    expect(startupRetry()).not.toHaveAttribute("hidden")
    expect(startupRetry().href).toBe(`${window.location.origin}/jobs/42`)
  })

  it("hides the shell loading state and does not report the watchdog after React marks first render", () => {
    vi.useFakeTimers()
    const fetchSpy = installStartupShell()

    window.SyrusStartupDiagnostics?.mark("react_commit")
    vi.advanceTimersByTime(8000)

    expect(postedBrowserErrors(fetchSpy)).toEqual([])
    expect(startupStatus()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "ready")
  })
})
