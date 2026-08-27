import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { ThemeProvider } from "../contexts/ThemeContext"
import { DesignSystemRoute } from "./DesignSystem"

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

function renderRoute(path = "/design_system") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <ThemeProvider theme="light">
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route element={<DesignSystemRoute />} path="/design_system" />
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
  })

  it("scopes a ?theme_id preview to the page's own container, never document.documentElement", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(oceanThemePayload()))

    renderRoute("/design_system?theme_id=5")

    await waitFor(() => {
      expect(screen.getByText('Previewing "Ocean" — shown on this page only. The rest of the app keeps your active theme.')).toBeInTheDocument()
    })

    const main = screen.getByRole("main")
    expect(main.style.getPropertyValue("--color-brand")).toBe("#1d6fa5")
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("")
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false)
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
