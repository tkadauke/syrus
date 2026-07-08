import { afterEach, describe, expect, it, vi } from "vitest"
import { desktopBuiltAt, isDesktopShell, openInNewTab, syrusShellBridge, type SyrusShellBridge } from "./desktopShell"

const desktopUa = "Mozilla/5.0 (Macintosh) Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.0 Safari/537.36"
const browserUa = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"

describe("syrusShellBridge", () => {
  afterEach(() => {
    delete window.syrusShell
  })

  it("is null in a plain browser without the preload bridge", () => {
    expect(syrusShellBridge()).toBeNull()
  })

  it("returns the preload bridge when the desktop shell exposes it", () => {
    const bridge = {} as SyrusShellBridge
    window.syrusShell = bridge

    expect(syrusShellBridge()).toBe(bridge)
  })
})

describe("isDesktopShell", () => {
  afterEach(() => vi.restoreAllMocks())

  it("detects the SyrusDesktop user-agent marker", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    expect(isDesktopShell()).toBe(true)
  })

  it("is false in a plain browser", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(browserUa)
    expect(isDesktopShell()).toBe(false)
  })
})

describe("desktopBuiltAt", () => {
  afterEach(() => vi.restoreAllMocks())

  it("decodes the compact ISO-8601 basic token back to extended form", () => {
    // The shell strips colons/dashes because colons are not valid in UA
    // product-version tokens — see webAppWindow.ts.
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(
      `${desktopUa} SyrusDesktopBuild/0.1.2 SyrusDesktopBuiltAt/20260707T143200Z`
    )
    expect(desktopBuiltAt()).toBe("2026-07-07T14:32:00Z")
  })

  it("is null when the token is absent (older shells, plain browsers)", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    expect(desktopBuiltAt()).toBeNull()
  })

  it("is null when the token is malformed", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(`${desktopUa} SyrusDesktopBuiltAt/garbage`)
    expect(desktopBuiltAt()).toBeNull()
  })
})

describe("openInNewTab", () => {
  afterEach(() => vi.restoreAllMocks())

  it("opens without the noopener feature (which would force a null return) and severs the opener", () => {
    const opened = { opener: {} as unknown }
    const openSpy = vi.spyOn(window, "open").mockReturnValue(opened as Window)

    expect(openInNewTab("https://example.com/auth")).toBe(true)
    expect(openSpy).toHaveBeenCalledWith("https://example.com/auth", "_blank")
    expect(opened.opener).toBeNull()
  })

  it("reports a genuinely blocked popup in a plain browser", () => {
    vi.spyOn(window, "open").mockReturnValue(null)
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(browserUa)

    expect(openInNewTab("https://example.com/auth")).toBe(false)
  })

  it("treats an intercepted open as success inside the desktop shell", () => {
    vi.spyOn(window, "open").mockReturnValue(null)
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)

    expect(openInNewTab("https://example.com/auth")).toBe(true)
  })

  it("survives a cross-origin handle that refuses opener assignment", () => {
    const hostile = {}
    Object.defineProperty(hostile, "opener", {
      set() {
        throw new DOMException("Blocked a frame from accessing a cross-origin frame.")
      }
    })
    vi.spyOn(window, "open").mockReturnValue(hostile as Window)

    expect(openInNewTab("https://example.com/auth")).toBe(true)
  })
})
