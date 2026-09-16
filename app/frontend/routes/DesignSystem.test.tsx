import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { ThemeProvider } from "../contexts/ThemeContext"
import { DesignSystemRoute } from "./DesignSystem"
import AdminDesignSystem from "../../../plugins/syrus_dev/app/frontend/routes/AdminDesignSystem"

function oceanThemePayload() {
  return {
    theme: {
      id: 5,
      slug: "ocean",
      name: "Ocean",
      built_in: true,
      tokens: {
        light: { brand: "#1d6fa5", surface: "#ffffff" },
        dark: { brand: "#4db3e8", surface: "#0b1620" }
      }
    }
  }
}

function consoleThemePayload() {
  return {
    theme: {
      id: 9,
      slug: "console",
      name: "Console",
      built_in: true,
      tokens: {
        light: { brand: "#166534", surface: "#ffffff" },
        dark: { brand: "#4ade80", surface: "#09090b" },
        shape: { "radius-control": "0px", "radius-panel": "0px" },
        spacing: { "space-page-x": "1rem" },
        typography: { "font-sans": "ui-monospace, SFMono-Regular, monospace" }
      }
    }
  }
}

function renderRoute(path = "/design_system") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <ThemeProvider theme="light">
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route element={<DesignSystemRoute />} path="/design_system" />
            <Route element={<AdminDesignSystem />} path="/admin/design_system" />
          </Routes>
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>
  )
}

describe("DesignSystemRoute", () => {
  afterEach(() => {
    document.documentElement.classList.remove("dark")
    document.documentElement.removeAttribute("data-theme")
    document.documentElement.removeAttribute("style")
  })

  it("renders the component gallery without a theme_id param", () => {
    renderRoute()

    expect(screen.getByRole("heading", { level: 1, name: "Design System" })).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Primary" }).length).toBeGreaterThan(0)
    expect(screen.getByLabelText("Text input")).toBeInTheDocument()
    expect(screen.getByLabelText("Select")).toBeInTheDocument()
    expect(screen.getByLabelText("Enable notifications")).toBeInTheDocument()
    expect(screen.getByRole("switch", { name: "Auto-merge" })).toBeInTheDocument()
    expect(screen.getByText("Base card")).toBeInTheDocument()
    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText("Semantic primitives")).toBeInTheDocument()
    expect(screen.getByRole("toolbar", { name: "Semantic primitive actions" })).toBeInTheDocument()
    expect(screen.getByText("Panel surface")).toBeInTheDocument()
    expect(screen.getByText("Live preview")).toBeInTheDocument()
  })

  it("renders the same live gallery through the syrus_dev admin route", () => {
    renderRoute("/admin/design_system")

    expect(screen.getByRole("heading", { level: 1, name: "Design System" })).toBeInTheDocument()
    expect(screen.getByText("Semantic primitives")).toBeInTheDocument()
    expect(screen.getByLabelText("Text input")).toBeInTheDocument()
  })

  it("scopes a ?theme_id preview to the page's own container, never document.documentElement", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(oceanThemePayload()))

    renderRoute("/design_system?theme_id=5")

    await waitFor(() => {
      expect(screen.getByText('Previewing "Ocean" — shown on this page only. The rest of the app keeps your active theme.')).toBeInTheDocument()
    })

    const main = screen.getByRole("main")
    expect(main.style.getPropertyValue("--color-brand")).toBe("#1d6fa5")
    expect(main.style.getPropertyValue("--color-link")).toBe("var(--color-brand-emphasis)")
    expect(main.style.getPropertyValue("--color-info-surface")).toBe("color-mix(in srgb, var(--color-surface) 94%, var(--color-info))")
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("")
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false)
  })

  it("renders the expanded (non-color) token groups from the live theme", () => {
    renderRoute()

    expect(screen.getByText("Expanded tokens")).toBeInTheDocument()
    expect(screen.getByText("Shape")).toBeInTheDocument()
    expect(screen.getByText("Shadow")).toBeInTheDocument()
    expect(screen.getByText("Spacing")).toBeInTheDocument()
    expect(screen.getByText("Density")).toBeInTheDocument()
    expect(screen.getByText("Typography")).toBeInTheDocument()
    expect(screen.getByText("radius-control")).toBeInTheDocument()
    expect(screen.getByText("font-sans")).toBeInTheDocument()
  })

  it("never lets a long typography value squeeze its label unreadable or overflow its card", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(consoleThemePayload()))

    renderRoute("/design_system?theme_id=9")

    await waitFor(() => {
      expect(screen.getByText('Previewing "Console" — shown on this page only. The rest of the app keeps your active theme.')).toBeInTheDocument()
    })

    const label = screen.getByText("font-sans")
    const value = screen.getByText("ui-monospace, SFMono-Regular, monospace")

    // The label never shares the value's shrink/truncate treatment, so a long
    // font-stack string can't crush it down to an illegible "f…".
    expect(label.className).toContain("shrink-0")
    expect(label.className).not.toContain("truncate")

    // The value truncates on its own, inside a grid card constrained to
    // min-w-0 -- so a long value ellipsizes within its card instead of
    // forcing the card (and the page) wider than the viewport.
    expect(value.className).toContain("min-w-0")
    expect(value.className).toContain("truncate")
    expect(value.getAttribute("title")).toBe("ui-monospace, SFMono-Regular, monospace")

    const card = label.closest("div.rounded")
    expect(card?.className).toContain("min-w-0")

    const grid = card?.parentElement
    expect(grid?.className).toContain("grid-cols-1")
  })

  it("scopes a non-color ?theme_id preview's shape/spacing/typography tokens to the page's own container", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(consoleThemePayload()))

    renderRoute("/design_system?theme_id=9")

    await waitFor(() => {
      expect(screen.getByText('Previewing "Console" — shown on this page only. The rest of the app keeps your active theme.')).toBeInTheDocument()
    })

    const main = screen.getByRole("main")
    expect(main.style.getPropertyValue("--radius-control")).toBe("0px")
    expect(main.style.getPropertyValue("--radius-panel")).toBe("0px")
    expect(main.style.getPropertyValue("--space-page-x")).toBe("1rem")
    expect(main.style.getPropertyValue("--font-sans")).toBe("ui-monospace, SFMono-Regular, monospace")
    // Untouched extended tokens still default (Theme#tokens_with_defaults is
    // what fills these server-side; the client-side preview only ever sees
    // whatever the API response actually included).
    expect(document.documentElement.style.getPropertyValue("--radius-control")).toBe("")
  })

  it("shows non-blocking contrast warnings for a draft preview with issues", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...oceanThemePayload(),
      contrast_warnings: [ "light text-primary (#111827) on surface (#ffffff) has contrast 1.2:1, needs at least 4.5:1 for WCAG AA" ]
    }))

    renderRoute("/design_system?theme_id=5")

    await waitFor(() => {
      expect(screen.getByText("Contrast warnings — these will block install_theme until fixed")).toBeInTheDocument()
    })
    expect(screen.getByText("light text-primary (#111827) on surface (#ffffff) has contrast 1.2:1, needs at least 4.5:1 for WCAG AA")).toBeInTheDocument()
  })

  it("shows no contrast warning banner when the draft preview has no issues", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(oceanThemePayload()))

    renderRoute("/design_system?theme_id=5")

    await waitFor(() => {
      expect(screen.getByText('Previewing "Ocean" — shown on this page only. The rest of the app keeps your active theme.')).toBeInTheDocument()
    })
    expect(screen.queryByText("Contrast warnings — these will block install_theme until fixed")).not.toBeInTheDocument()
  })

  it("shows an error message when the requested theme can't be loaded", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ error: { code: "not_found", message: "not found" } }, 404))

    renderRoute("/design_system?theme_id=999")

    await waitFor(() => {
      expect(screen.getByText("That theme couldn't be loaded — it may not exist, or it may belong to another user.")).toBeInTheDocument()
    })
  })

  it("opens and closes the example modal", () => {
    renderRoute()

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Open example modal" }))
    expect(screen.getByRole("dialog", { name: "Example modal" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Close" }))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})
