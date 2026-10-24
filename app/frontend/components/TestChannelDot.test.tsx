import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { TestChannelDot } from "./TestChannelDot"

const stableUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.5 SyrusDesktopBuild/0.1.5 Safari/537.36"
const testUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.5-test.3 SyrusDesktopBuild/0.1.5-test.3 SyrusDesktopChannel/test Safari/537.36"

describe("TestChannelDot", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders nothing in a plain browser", () => {
    render(<TestChannelDot />)
    expect(screen.queryByTestId("test-channel-dot")).toBeNull()
  })

  it("renders nothing on the stable channel", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(stableUa)
    render(<TestChannelDot />)
    expect(screen.queryByTestId("test-channel-dot")).toBeNull()
  })

  it("shows a warning-colored dot inside a test build", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(testUa)
    render(<TestChannelDot />)
    const dot = screen.getByTestId("test-channel-dot")
    expect(dot.className).toContain("bg-warning")
    expect(dot.getAttribute("aria-label")).toBe("This is a side-by-side test build, isolated from your production Syrus.")
  })

  it("accepts a className override for placement", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(testUa)
    render(<TestChannelDot className="custom-dot" />)
    expect(screen.getByTestId("test-channel-dot").className).toBe("custom-dot")
  })
})
