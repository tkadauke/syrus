import { afterEach, beforeEach, describe, expect, it, vi, type Mock } from "vitest"
import SCRIPT from "../../assets/javascripts/startup_diagnostics.js?raw"

// The inline startup script (app/assets/javascripts/startup_diagnostics.js)
// runs before the SPA bundle exists, so it is exercised here as the browser
// loads it: evaluated into the page, then driven with real DOM events.
type StartupWindow = Window & { __syrusStartupReload?: () => void; __syrusReactFirstRender?: boolean; SyrusStartupDiagnostics?: { mark: (name: string) => void } }

function loadScript() {
  new Function(SCRIPT)()
}

function failEntryScript() {
  const script = document.createElement("script")
  script.src = "/assets/spa-entry-abc.digested.js"
  document.head.appendChild(script)
  script.dispatchEvent(new Event("error"))
}

describe("startup diagnostics script", () => {
  const win = window as StartupWindow
  let reload: Mock<() => void>

  beforeEach(() => {
    vi.useFakeTimers()
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(null, { status: 204 }))
    window.sessionStorage.clear()
    reload = vi.fn<() => void>()
    win.__syrusStartupReload = reload
    delete win.__syrusReactFirstRender
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    delete win.__syrusStartupReload
    delete win.__syrusReactFirstRender
    document.head.innerHTML = ""
  })

  // Regression: a dropped entry-script request (a phone reconnecting) left the
  // page on "Check your connection, then retry." until someone tapped Retry,
  // over and over for the length of the outage.
  it("retries a failed startup resource by itself on a backoff", () => {
    loadScript()
    failEntryScript()

    vi.advanceTimersByTime(1999)
    expect(reload).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(reload).toHaveBeenCalledTimes(1)
    expect(window.sessionStorage.getItem("syrus.startup.autoRetryAttempt")).toBe("1")
  })

  it("retries as soon as the browser is back online", () => {
    loadScript()
    failEntryScript()

    window.dispatchEvent(new Event("online"))

    expect(reload).toHaveBeenCalledTimes(1)
  })

  it("stops retrying once the backoff is spent", () => {
    window.sessionStorage.setItem("syrus.startup.autoRetryAttempt", "5")
    loadScript()
    failEntryScript()

    vi.advanceTimersByTime(10 * 60_000)

    expect(reload).not.toHaveBeenCalled()
  })

  it("resets the retry count once the app renders", () => {
    window.sessionStorage.setItem("syrus.startup.autoRetryAttempt", "3")
    loadScript()

    win.SyrusStartupDiagnostics?.mark("react_commit")

    expect(window.sessionStorage.getItem("syrus.startup.autoRetryAttempt")).toBeNull()
  })
})
