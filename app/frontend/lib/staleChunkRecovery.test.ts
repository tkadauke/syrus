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

  beforeEach(() => {
    window.sessionStorage.clear()
    setRevision("rev-1")
  })

  afterEach(() => {
    uninstall()
  })

  it("reloads once when a chunk from a previous deploy fails to load", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    const event = dispatchPreloadError()

    expect(reload).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
  })

  it("lets the error reach the boundary when the reload already happened for this revision", () => {
    const reload = vi.fn()
    uninstall = installStaleChunkRecovery(reload)

    dispatchPreloadError()
    const second = dispatchPreloadError()

    expect(reload).toHaveBeenCalledTimes(1)
    expect(second.defaultPrevented).toBe(false)
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
    storage.mockRestore()
  })
})
