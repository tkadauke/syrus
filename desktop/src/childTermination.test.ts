import { describe, expect, it, vi } from "vitest"
import type { ChildProcess } from "node:child_process"
import { ChildTerminationController } from "../electron/installer/childTermination"

describe("ChildTerminationController", () => {
  it("retains ownership through TERM grace and forces immediately when app quit follows the deadline", () => {
    vi.useFakeTimers()
    const killGroup = vi.fn()
    const child = { pid: 42, kill: vi.fn() } as unknown as ChildProcess
    const controller = new ChildTerminationController(5_000, {
      platform: "linux",
      killGroup,
      killTree: vi.fn(),
      setTimer: (callback, delay) => setTimeout(callback, delay),
      clearTimer: (timer) => clearTimeout(timer)
    })

    controller.register(child)
    controller.terminate()
    expect(killGroup).toHaveBeenLastCalledWith(42, "SIGTERM")
    expect(controller.active()).toBe(true)
    expect(() => controller.register({ pid: 43 } as ChildProcess)).toThrow("already registered")

    // before-quit must not depend on a timer that Electron is about to cancel.
    controller.terminate(true)
    expect(killGroup).toHaveBeenLastCalledWith(42, "SIGKILL")
    expect(controller.active()).toBe(false)
    vi.advanceTimersByTime(5_000)
    expect(killGroup).toHaveBeenCalledTimes(2)
    vi.useRealTimers()
  })

  it("keeps ownership until the grace timer sends SIGKILL", () => {
    vi.useFakeTimers()
    const killGroup = vi.fn()
    const child = { pid: 84, kill: vi.fn() } as unknown as ChildProcess
    const controller = new ChildTerminationController(5_000, {
      platform: "linux",
      killGroup,
      killTree: vi.fn(),
      setTimer: (callback, delay) => setTimeout(callback, delay),
      clearTimer: (timer) => clearTimeout(timer)
    })

    controller.register(child)
    controller.terminate()
    vi.advanceTimersByTime(4_999)
    expect(controller.active()).toBe(true)
    vi.advanceTimersByTime(1)
    expect(killGroup).toHaveBeenLastCalledWith(84, "SIGKILL")
    expect(controller.active()).toBe(false)
    vi.useRealTimers()
  })
})
