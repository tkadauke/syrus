import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { installStaleChunkRecovery } from "./staleChunkRecovery"

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
  const recordEvent = vi.fn()

  beforeEach(() => {
    window.sessionStorage.clear()
    setRevision("rev-1")
    recordEvent.mockClear()
    window.SyrusStartupDiagnostics = { mark: vi.fn(), event: recordEvent }
  })

  afterEach(() => {
    uninstall()
    delete window.SyrusStartupDiagnostics
  })

  it("reloads once when a chunk from a previous deploy fails to load", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    const event = dispatchPreloadError()

    expect(reload).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
    expect(recordEvent).toHaveBeenCalledWith("stale_chunk_failure", { outcome: "reload", revision: "rev-1" })
  })

  it("lets the error reach the boundary when the reload already happened for this revision", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    dispatchPreloadError()
    const second = dispatchPreloadError()

    expect(reload).toHaveBeenCalledTimes(1)
    expect(second.defaultPrevented).toBe(false)
    expect(recordEvent).toHaveBeenLastCalledWith("stale_chunk_failure", { outcome: "error_boundary", revision: "rev-1" })
  })

  it("allows another reload after the next deploy", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    dispatchPreloadError()
    setRevision("rev-2")
    dispatchPreloadError()

    expect(reload).toHaveBeenCalledTimes(2)
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
    expect(recordEvent).toHaveBeenCalledWith("stale_chunk_failure", { outcome: "error_boundary", revision: "rev-1" })
    storage.mockRestore()
  })

  it("leaves a failure during background warm-up to the warm-up queue instead of reloading", () => {
    const reload = vi.fn()
    let backgroundOnly = true
    uninstall = installStaleChunkRecovery(reload, { backgroundOnlyInFlight: () => backgroundOnly })

    const background = dispatchPreloadError()
    expect(reload).not.toHaveBeenCalled()
    expect(background.defaultPrevented).toBe(false)
    expect(recordEvent).toHaveBeenCalledWith("stale_chunk_failure", { outcome: "warmup_stopped" })

    backgroundOnly = false
    const onDemand = dispatchPreloadError()
    expect(reload).toHaveBeenCalledTimes(1)
    expect(onDemand.defaultPrevented).toBe(true)
  })
})
