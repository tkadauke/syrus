import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { TestChannelBadge, TestChannelDot } from "./TestChannelBadge"

const stableUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.5 SyrusDesktopBuild/0.1.5 Safari/537.36"
const testUa =
  "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.5-test.3 SyrusDesktopBuild/0.1.5-test.3 SyrusDesktopChannel/test Safari/537.36"

describe("TestChannelBadge", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders nothing in a plain browser", () => {
    render(<TestChannelBadge />)
    expect(screen.queryByText("Test")).toBeNull()
  })

  it("renders nothing on the stable channel (no SyrusDesktopChannel token)", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(stableUa)
    render(<TestChannelBadge />)
    expect(screen.queryByText("Test")).toBeNull()
  })

  it("shows an amber TEST pill inside a test build", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(testUa)
    render(<TestChannelBadge />)
    const badge = screen.getByText("Test").closest("[data-status-pill]")
    expect(badge).not.toBeNull()
    expect(badge?.className).toContain("amber")
    expect(badge?.getAttribute("title")).toContain("test build")
  })
})

// The compact dot variant used on the floating mobile brand trigger, where the
// in-flow top-bar pill has scrolled out of view.
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

  it("shows an amber dot inside a test build", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(testUa)
    render(<TestChannelDot />)
    const dot = screen.getByTestId("test-channel-dot")
    expect(dot.className).toContain("amber")
    expect(dot.getAttribute("aria-label")).toBe("Test")
  })

  it("accepts a className override for placement", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(testUa)
    render(<TestChannelDot className="custom-dot" />)
    expect(screen.getByTestId("test-channel-dot").className).toBe("custom-dot")
  })
})
