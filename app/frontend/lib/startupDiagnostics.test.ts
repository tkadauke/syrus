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

function installStartupShell(options: { standalone?: boolean; displayStandalone?: boolean; path?: string } = {}) {
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

    markStartupMilestone("react_first_render")

    expect(mark).toHaveBeenCalledWith("react_first_render")
  })

  it("does nothing when the shell hook is unavailable", () => {
    expect(() => markStartupMilestone("react_module_loaded")).not.toThrow()
  })

  it("posts standalone startup milestones to performance events with launch context", () => {
    const fetchSpy = installStartupShell({ standalone: true, path: "/jobs/42?tab=summary" })

    window.SyrusStartupDiagnostics?.mark("react_module_loaded")
    window.SyrusStartupDiagnostics?.mark("react_first_render")

    expect(window.__syrusReactFirstRender).toBe(true)
    const events = postedPerformanceEvents(fetchSpy)
    expect(events.map((event) => event.name)).toEqual([
      "startup.shell_loaded",
      "startup.react_module_loaded",
      "startup.react_first_render"
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

  it("keeps normal tab milestones local unless diagnostics are explicitly requested", () => {
    const fetchSpy = installStartupShell()

    window.SyrusStartupDiagnostics?.mark("react_first_render")

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("allows opt-in startup milestone posting from a normal browser tab", () => {
    const fetchSpy = installStartupShell({ path: "/dashboard?startup_diagnostics=1" })

    window.SyrusStartupDiagnostics?.mark("react_first_render")

    expect(postedPerformanceEvents(fetchSpy).map((event) => event.name)).toEqual([
      "startup.shell_loaded",
      "startup.react_first_render"
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
    window.SyrusStartupDiagnostics?.mark("react_first_render")
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
        { name: "shell_loaded", at_ms: 0 }
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

    window.SyrusStartupDiagnostics?.mark("react_first_render")
    vi.advanceTimersByTime(8000)

    expect(postedBrowserErrors(fetchSpy)).toEqual([])
    expect(startupStatus()).toHaveAttribute("hidden")
    expect(startupStatus()).toHaveAttribute("data-startup-state", "ready")
  })
})
