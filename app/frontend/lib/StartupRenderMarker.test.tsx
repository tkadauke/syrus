import { render } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"
import { StartupRenderMarker } from "./StartupRenderMarker"

afterEach(() => vi.restoreAllMocks())

it("marks commit before the first completed paint boundary", () => {
  const mark = vi.fn()
  const callbacks: FrameRequestCallback[] = []
  window.SyrusStartupDiagnostics = { mark }
  vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
    callbacks.push(callback)
    return callbacks.length
  })

  render(<StartupRenderMarker />)
  expect(mark).toHaveBeenCalledWith("react_commit")
  expect(mark).not.toHaveBeenCalledWith("react_post_paint")

  callbacks.shift()?.(10)
  expect(mark).not.toHaveBeenCalledWith("react_post_paint")
  callbacks.shift()?.(20)
  expect(mark.mock.calls.map(([name]) => name)).toEqual(["react_commit", "react_post_paint"])
})
