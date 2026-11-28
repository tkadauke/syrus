import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { announceAppUpdate, appUpdateBlocksRetries, installReloadOnNavigation, resetAppUpdateForTests, SAVE_DRAFTS_EVENT, setAppUpdateReloaderForTests } from "./appUpdate"

describe("app update coordination", () => {
  beforeEach(() => {
    window.sessionStorage.clear()
    resetAppUpdateForTests()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("announces a compatible revision without reloading", () => {
    const assign = vi.fn()
    setAppUpdateReloaderForTests(assign)

    announceAppUpdate("compatible", "revision:new")

    expect(assign).not.toHaveBeenCalled()
  })

  it("saves drafts and reloads after the breaking-change countdown", () => {
    vi.useFakeTimers()
    const save = vi.fn()
    window.addEventListener(SAVE_DRAFTS_EVENT, save, { once: true })
    const assign = vi.fn()
    setAppUpdateReloaderForTests(assign)

    announceAppUpdate("breaking", "api:1->2")
    expect(save).toHaveBeenCalledTimes(1)
    expect(appUpdateBlocksRetries()).toBe(true)
    expect(assign).not.toHaveBeenCalled()

    vi.advanceTimersByTime(30_000)
    expect(assign).toHaveBeenCalledWith(window.location.href)
  })

  it("uses a full load for the next in-app navigation", () => {
    const assign = vi.fn()
    setAppUpdateReloaderForTests(assign)
    const uninstall = installReloadOnNavigation()
    announceAppUpdate("compatible", "revision:new")

    history.pushState({}, "", "/jobs/42")

    expect(assign).toHaveBeenCalledWith(`${window.location.origin}/jobs/42`)
    uninstall()
  })
})
