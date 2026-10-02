import { afterEach, describe, expect, it, vi } from "vitest"
import { markStartupMilestone } from "./startupDiagnostics"

describe("startupDiagnostics", () => {
  afterEach(() => {
    delete window.SyrusStartupDiagnostics
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
})

