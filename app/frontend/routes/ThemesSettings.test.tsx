import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { ThemeProvider } from "../contexts/ThemeContext"
import type { ColorTheme } from "../api/themes"
import { ThemesSettingsRoute } from "./ThemesSettings"

describe("ThemesSettingsRoute", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    document.documentElement.removeAttribute("data-theme")
    document.documentElement.removeAttribute("style")
  })

  it("lists only custom themes in the editable order list", async () => {
    mockFetch()
    renderRoute()

    const customList = await screen.findByRole("navigation", { name: "Custom theme order" })
    expect(within(customList).getByRole("button", { name: /Solar Draft/ })).toBeInTheDocument()
    expect(within(customList).getByRole("button", { name: /Night Shift/ })).toBeInTheDocument()
    expect(within(customList).queryByRole("button", { name: /Terracotta/ })).not.toBeInTheDocument()
  })

  it("saves renamed token edits and live-previews the changed custom theme", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    await screen.findByRole("button", { name: /Solar Draft/ })
    fireEvent.change(screen.getByRole("textbox", { name: "Name" }), { target: { value: "Solar Edited" } })
    fireEvent.change(screen.getByLabelText("Light brand"), { target: { value: "#0f766e" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes/2", expect.objectContaining({
        method: "PATCH",
        body: expect.stringContaining("Solar Edited")
      }))
    })
    const updateCall = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/themes/2" && call[1]?.method === "PATCH")
    expect(JSON.parse(String(updateCall?.[1]?.body)).theme.tokens.light.brand).toBe("#0f766e")
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#0f766e")
    expect(await screen.findByText("Theme saved.")).toBeInTheDocument()
    expect(customThemeNames()).toEqual(["Solar Edited", "Night Shift"])
  })

  it("live-previews token edits without persisting the active theme before save", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    await screen.findByRole("button", { name: /Solar Draft/ })
    fireEvent.change(screen.getByLabelText("Light brand"), { target: { value: "#0f766e" } })

    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#0f766e")
    expect(fetchSpy.mock.calls.some((call) => String(call[0]) === "/api/v1/app/theme" && call[1]?.method === "PATCH")).toBe(false)
  })

  it("creates a new custom theme from the active theme tokens", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "New" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes", expect.objectContaining({
        method: "POST",
        body: expect.stringContaining("Custom Theme 3")
      }))
    })
    const createCall = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/themes" && call[1]?.method === "POST")
    expect(JSON.parse(String(createCall?.[1]?.body)).theme.tokens.light.brand).toBe("#b6492e")
    expect(await screen.findByRole("button", { name: /Custom Theme 3/ })).toBeInTheDocument()
    expect(customThemeNames()).toEqual(["Solar Draft", "Night Shift", "Custom Theme 3"])
  })

  it("deletes a custom theme after confirmation", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true)
    const fetchSpy = mockFetch()
    renderRoute()

    await screen.findByRole("button", { name: /Solar Draft/ })
    fireEvent.click(screen.getByRole("button", { name: "Delete" }))

    expect(confirmSpy).toHaveBeenCalledWith("Delete Solar Draft?")
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes/2", expect.objectContaining({ method: "DELETE" }))
    })
    expect(await screen.findByText("Theme deleted.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Solar Draft/ })).not.toBeInTheDocument()
  })

  it("shows contrast errors beside every affected token field", async () => {
    mockFetch({
      update: () => jsonResponse({
        error: {
          code: "contrast_check_failed",
          message: "Contrast check failed.",
          issues: [
            {
              mode: "light",
              foreground: "text-primary",
              background: "surface",
              message: "light text-primary (#ffffff) on surface (#ffffff) has contrast 1:1, needs at least 4.5:1 for WCAG AA"
            }
          ]
        }
      }, 422)
    })
    renderRoute()

    await screen.findByRole("button", { name: /Solar Draft/ })
    fireEvent.change(screen.getByLabelText("Light text-primary"), { target: { value: "#ffffff" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    expect(await screen.findAllByText(/light text-primary/)).toHaveLength(2)
    expect(screen.getByLabelText("Light text-primary")).toHaveAttribute("aria-invalid", "true")
    expect(screen.getByLabelText("Light surface")).toHaveAttribute("aria-invalid", "true")
  })

  it("blocks saving invalid hand-entered hex values on the client", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    await screen.findByRole("button", { name: /Solar Draft/ })
    fireEvent.change(screen.getByLabelText("Light brand"), { target: { value: "#12345" } })

    expect(screen.getByLabelText("Light brand")).toHaveAttribute("aria-invalid", "true")
    expect(screen.getByText("Use a 6-digit hex color like #1d4ed8.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled()
    expect(fetchSpy.mock.calls.some((call) => String(call[0]) === "/api/v1/app/themes/2" && call[1]?.method === "PATCH")).toBe(false)
  })

  it("reorders custom themes with native drag and drop", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    const customList = await screen.findByRole("navigation", { name: "Custom theme order" })
    const solar = within(customList).getByRole("button", { name: /Solar Draft/ })
    const night = within(customList).getByRole("button", { name: /Night Shift/ })
    const dataTransfer = { effectAllowed: "", dropEffect: "" }

    fireEvent.dragStart(night, { dataTransfer })
    fireEvent.dragOver(solar, { dataTransfer })
    fireEvent.drop(solar, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes/reorder", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ ids: [3, 2] })
      }))
    })
  })
})

function renderRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <ThemeProvider colorTheme={terracottaTheme()} theme="light">
        <ThemesSettingsRoute />
      </ThemeProvider>
    </QueryClientProvider>
  )
}

function mockFetch(overrides: { update?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/themes" && init?.method == null) return Promise.resolve(jsonResponse({ themes: [terracottaTheme(), solarTheme(), nightTheme()] }))
    if (path === "/api/v1/app/themes" && init?.method === "POST") return Promise.resolve(jsonResponse({ theme: customTheme({ id: 4, slug: "custom-theme-3", name: "Custom Theme 3", position: 2 }) }, 201))
    if (path === "/api/v1/app/themes/2" && init?.method === "PATCH") return Promise.resolve(overrides.update?.() ?? jsonResponse({ theme: solarThemeFromBody(init.body) }))
    if (path === "/api/v1/app/themes/2" && init?.method === "DELETE") return Promise.resolve(jsonResponse({ deleted_theme_id: 2, fallback_theme_id: null }))
    if (path === "/api/v1/app/themes/reorder" && init?.method === "PATCH") return Promise.resolve(jsonResponse({ themes: [nightTheme({ position: 0 }), solarTheme({ position: 1 })] }))
    if (path === "/api/v1/app/theme" && init?.method === "PATCH") return Promise.resolve(jsonResponse({ color_theme: solarTheme(), color_theme_id: 2, theme: "light" }))

    return Promise.resolve(jsonResponse({}))
  })
}

function customThemeNames() {
  return within(screen.getByRole("navigation", { name: "Custom theme order" }))
    .getAllByRole("button")
    .map((button) => button.textContent?.trim())
}

function solarThemeFromBody(body: BodyInit | null | undefined) {
  const payload = JSON.parse(String(body)) as { theme: { name: string; tokens: ColorTheme["tokens"] } }
  return customTheme({ id: 2, slug: "solar-draft", name: payload.theme.name, position: 0, tokens: payload.theme.tokens })
}

function terracottaTheme(): ColorTheme {
  return {
    id: 1,
    slug: "terracotta",
    name: "Terracotta",
    built_in: true,
    position: null,
    tokens: fullTokens("#b6492e")
  }
}

function solarTheme(overrides: Partial<ColorTheme> = {}): ColorTheme {
  return customTheme({ id: 2, slug: "solar-draft", name: "Solar Draft", position: 0, ...overrides })
}

function nightTheme(overrides: Partial<ColorTheme> = {}): ColorTheme {
  return customTheme({ id: 3, slug: "night-shift", name: "Night Shift", position: 1, tokens: fullTokens("#2563eb"), ...overrides })
}

function customTheme(overrides: Partial<ColorTheme> = {}): ColorTheme {
  return {
    id: 2,
    slug: "solar-draft",
    name: "Solar Draft",
    built_in: false,
    position: 0,
    tokens: fullTokens("#b45309"),
    ...overrides
  }
}

function fullTokens(brand: string): ColorTheme["tokens"] {
  return {
    light: {
      brand,
      "brand-emphasis": "#7c2d12",
      surface: "#ffffff",
      "surface-raised": "#f8fafc",
      border: "#cbd5e1",
      "text-primary": "#111827",
      "text-secondary": "#475569",
      success: "#166534",
      warning: "#92400e",
      danger: "#991b1b",
      info: "#1d4ed8",
      neutral: "#4b5563",
      "on-brand": "#ffffff"
    },
    dark: {
      brand: "#f59e0b",
      "brand-emphasis": "#fbbf24",
      surface: "#111827",
      "surface-raised": "#1f2937",
      border: "#374151",
      "text-primary": "#f9fafb",
      "text-secondary": "#cbd5e1",
      success: "#86efac",
      warning: "#fde68a",
      danger: "#fca5a5",
      info: "#93c5fd",
      neutral: "#d1d5db",
      "on-brand": "#111827"
    }
  }
}
