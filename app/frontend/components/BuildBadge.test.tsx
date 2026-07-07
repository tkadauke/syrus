import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { BuildBadge } from "./BuildBadge"

const desktopUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.2.0 SyrusDesktopBuild/abc1234 Safari/537.36"

describe("BuildBadge", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows app and backend builds inside the desktop shell", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    render(<BuildBadge revision="439245a" />)
    expect(screen.getByTestId("build-badge").textContent).toBe("app abc1234 · backend 439245a")
  })

  it("shows only the backend build in a plain browser", () => {
    render(<BuildBadge revision="439245a" />)
    expect(screen.getByTestId("build-badge").textContent).toBe("backend 439245a")
  })

  it("renders nothing when there is nothing to say (dev backend, no shell)", () => {
    render(<BuildBadge revision="dev" />)
    expect(screen.queryByTestId("build-badge")).toBeNull()
  })

  it("prefers the backend release version over the revision", () => {
    render(<BuildBadge revision="439245a" version="0.1.2" />)
    expect(screen.getByTestId("build-badge").textContent).toBe("backend 0.1.2")
  })

  it("shows the backend version even when the revision reads dev", () => {
    // A published image always bakes GIT_SHA too, but the badge must not
    // depend on that coupling.
    render(<BuildBadge revision="dev" version="0.1.2" />)
    expect(screen.getByTestId("build-badge").textContent).toBe("backend 0.1.2")
  })

  it("shows release versions for both parts on release builds", () => {
    // Release desktop builds put the version (not the sha) in the UA token.
    const releaseUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.2 SyrusDesktopBuild/0.1.2 Safari/537.36"
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(releaseUa)
    render(<BuildBadge revision="439245a" version="0.1.2" />)
    expect(screen.getByTestId("build-badge").textContent).toBe("app 0.1.2 · backend 0.1.2")
  })

  it("keeps the sha fallback when no version is present (dev builds)", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    render(<BuildBadge revision="439245a" version={null} />)
    expect(screen.getByTestId("build-badge").textContent).toBe("app abc1234 · backend 439245a")
  })

  // Formats through the same Intl path as the component so the expectation
  // doesn't hardcode a locale or the test machine's timezone.
  const formatted = (iso: string) =>
    new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(iso))

  it("shows the backend build time as a hover tooltip", () => {
    render(<BuildBadge builtAt="2026-07-05T08:15:00Z" revision="439245a" version="0.1.2" />)
    const segment = screen.getByText("backend 0.1.2")
    expect(segment.getAttribute("title")).toBe(`backend 0.1.2 — built ${formatted("2026-07-05T08:15:00Z")}`)
    // The visible badge text must not change — the timestamp is hover-only.
    expect(screen.getByTestId("build-badge").textContent).toBe("backend 0.1.2")
  })

  it("shows the app build time from the SyrusDesktopBuiltAt UA token", () => {
    const releaseUa =
      "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.2 SyrusDesktopBuild/0.1.2 SyrusDesktopBuiltAt/20260707T143200Z Safari/537.36"
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(releaseUa)
    render(<BuildBadge builtAt="2026-07-05T08:15:00Z" revision="439245a" version="0.1.2" />)
    expect(screen.getByText("app 0.1.2").getAttribute("title")).toBe(
      `app 0.1.2 — built ${formatted("2026-07-07T14:32:00Z")}`
    )
    expect(screen.getByTestId("build-badge").textContent).toBe("app 0.1.2 · backend 0.1.2")
  })

  it("renders no tooltips when build times are absent (dev backend, older shell)", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    render(<BuildBadge revision="439245a" />)
    expect(screen.getByText("app abc1234").getAttribute("title")).toBeNull()
    expect(screen.getByText("backend 439245a").getAttribute("title")).toBeNull()
  })

  it("ignores an unparseable backend timestamp instead of showing a broken tooltip", () => {
    render(<BuildBadge builtAt="not-a-timestamp" revision="439245a" />)
    expect(screen.getByText("backend 439245a").getAttribute("title")).toBeNull()
  })
})
