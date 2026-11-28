import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { APP_UPDATE_EVENT, resetAppUpdateForTests } from "./appUpdate"
import { installChunkNavigationTracking, installStaleChunkRecovery } from "./staleChunkRecovery"

function setRevision(revision: string) {
  document.head.querySelector('meta[name="syrus-asset-revision"]')?.remove()
  const meta = document.createElement("meta")
  meta.name = "syrus-asset-revision"
  meta.content = revision
  document.head.appendChild(meta)
}

function dispatchPreloadError() {
  const event = new Event("vite:preloadError", { cancelable: true })
  window.dispatchEvent(event)
  return event
}

describe("installStaleChunkRecovery", () => {
  let uninstall: () => void = () => {}

  beforeEach(() => {
    window.sessionStorage.clear()
    resetAppUpdateForTests()
    setRevision("rev-1")
  })

  afterEach(() => {
    uninstall()
  })

  it("announces a stale chunk without reloading an in-page component", () => {
    const reload = vi.fn()
    const announced = vi.fn()
    window.addEventListener(APP_UPDATE_EVENT, announced, { once: true })
    uninstall = installStaleChunkRecovery(reload)

    const event = dispatchPreloadError()

    expect(reload).not.toHaveBeenCalled()
    expect(announced).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
  })

  it("lets the error reach the boundary when the reload already happened for this revision", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    dispatchPreloadError()
    const second = dispatchPreloadError()

    expect(reload).not.toHaveBeenCalled()
    expect(second.defaultPrevented).toBe(false)
  })

  it("allows another reload after the next deploy", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    dispatchPreloadError()
    setRevision("rev-2")
    dispatchPreloadError()

    expect(reload).not.toHaveBeenCalled()
  })

  it("does not reload when sessionStorage is unavailable, so it cannot loop", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)
    const storage = vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
      throw new DOMException("blocked", "SecurityError")
    })

    const event = dispatchPreloadError()

    expect(reload).not.toHaveBeenCalled()
    expect(event.defaultPrevented).toBe(false)
    storage.mockRestore()
  })

  it("leaves a failure during background warm-up to the warm-up queue instead of reloading", () => {
    const reload = vi.fn()
    let backgroundOnly = true
    uninstall = installStaleChunkRecovery(reload, { backgroundOnlyInFlight: () => backgroundOnly })

    const background = dispatchPreloadError()
    expect(reload).not.toHaveBeenCalled()
    expect(background.defaultPrevented).toBe(false)

    backgroundOnly = false
    const onDemand = dispatchPreloadError()
    expect(reload).not.toHaveBeenCalled()
    expect(onDemand.defaultPrevented).toBe(true)
  })

  it("turns a stale chunk during navigation into a full load of the target", () => {
    const reload = vi.fn()
    const stopTracking = installChunkNavigationTracking()
    const stopRecovery = installStaleChunkRecovery(reload)
    uninstall = () => {
      stopTracking()
      stopRecovery()
    }
    const anchor = document.createElement("a")
    anchor.href = "/jobs/42"
    document.body.appendChild(anchor)
    anchor.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }))

    dispatchPreloadError()

    expect(reload).toHaveBeenCalledWith(`${window.location.origin}/jobs/42`)
    anchor.remove()
  })

  it("tracks a programmatic navigation target for stale chunk recovery", () => {
    const reload = vi.fn()
    const stopTracking = installChunkNavigationTracking()
    const stopRecovery = installStaleChunkRecovery(reload)
    uninstall = () => {
      stopTracking()
      stopRecovery()
    }

    history.pushState({}, "", "/jobs/43")
    dispatchPreloadError()

    expect(reload).toHaveBeenCalledWith(`${window.location.origin}/jobs/43`)
  })

  it("tracks the destination of back and forward navigation", () => {
    const reload = vi.fn()
    const stopTracking = installChunkNavigationTracking()
    const stopRecovery = installStaleChunkRecovery(reload)
    uninstall = () => {
      stopTracking()
      stopRecovery()
    }

    window.dispatchEvent(new PopStateEvent("popstate"))
    dispatchPreloadError()

    expect(reload).toHaveBeenCalledWith(window.location.href)
  })
})
