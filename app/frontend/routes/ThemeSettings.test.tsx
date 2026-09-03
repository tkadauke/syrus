import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ThemeProvider } from "../contexts/ThemeContext"
import { jsonResponse } from "../testSupport"
import { ThemeSettingsRoute } from "./ThemeSettings"
import type { ColorTheme } from "../api/themes"

describe("ThemeSettingsRoute", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    document.documentElement.removeAttribute("style")
    document.documentElement.removeAttribute("data-theme")
    document.documentElement.className = ""
  })

  it("lists only custom themes and saves renamed token edits with live preview", async () => {
    const warm = customTheme({ id: 11, name: "Warm Slate", tokens: tokens({ brand: "#884422" }) })
    const cool = customTheme({ id: 12, name: "Cool Mint", tokens: tokens({ brand: "#227766" }) })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/themes" && !init?.method) return Promise.resolve(jsonResponse({ themes: [builtInTheme(), warm, cool] }))
      if (path === "/api/v1/app/themes/11" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse({ theme: { ...warm, name: "Renamed Slate", tokens: editedLightBrandTokens() } }))
      }
      return Promise.resolve(jsonResponse({}))
    })

    renderRoute()

    expect(await screen.findByRole("main", { name: "Themes" })).toBeInTheDocument()
    const list = await screen.findByRole("list", { name: "Custom themes" })
    expect(within(list).getByRole("button", { name: /Warm Slate/ })).toBeInTheDocument()
    expect(within(list).getByRole("button", { name: /Cool Mint/ })).toBeInTheDocument()
    expect(within(list).queryByRole("button", { name: /Terracotta/ })).not.toBeInTheDocument()

    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Renamed Slate" } })
    fireEvent.change(screen.getByLabelText("light brand hex"), { target: { value: "#995533" } })
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#995533")

    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes/11", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ theme: { name: "Renamed Slate", tokens: editedLightBrandTokens() } })
    })))
    expect(await screen.findByText("Theme saved.")).toBeInTheDocument()
    expect(await screen.findByDisplayValue("Renamed Slate")).toBeInTheDocument()
  })

  it("saves drag reorder and renders WCAG contrast errors inline", async () => {
    const warm = customTheme({ id: 11, name: "Warm Slate" })
    const cool = customTheme({ id: 12, name: "Cool Mint" })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/themes" && !init?.method) return Promise.resolve(jsonResponse({ themes: [builtInTheme(), warm, cool] }))
      if (path === "/api/v1/app/themes/reorder" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse({ themes: [{ ...cool, position: 0 }, { ...warm, position: 1 }] }))
      }
      if (path === "/api/v1/app/themes/11" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse({
          error: {
            code: "contrast_check_failed",
            message: "Contrast check failed.",
            issues: [{ mode: "light", foreground: "text-primary", message: "light text-primary (#ffffff) on surface (#ffffff) has contrast 1:1, needs at least 4.5:1 for WCAG AA" }]
          }
        }, 422))
      }
      return Promise.resolve(jsonResponse({}))
    })

    renderRoute()

    const first = (await screen.findByRole("button", { name: /Warm Slate/ })).closest("li")!
    const second = screen.getByRole("button", { name: /Cool Mint/ }).closest("li")!
    const dataTransfer = { effectAllowed: "", dropEffect: "" }
    fireEvent.dragStart(first, { dataTransfer })
    fireEvent.dragOver(second, { dataTransfer })
    fireEvent.drop(second, { dataTransfer })

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes/reorder", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ ids: [12, 11] })
    })))

    fireEvent.change(screen.getByLabelText("light text-primary hex"), { target: { value: "#ffffff" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    expect(await screen.findByText(/light text-primary .*needs at least 4.5:1/)).toBeInTheDocument()
    expect(screen.getByLabelText("light text-primary hex")).toHaveAttribute("aria-invalid", "true")
  })

  it("creates a custom theme from the active tokens and deletes it after confirmation", async () => {
    const warm = customTheme({ id: 11, name: "Warm Slate", tokens: tokens({ brand: "#aa6633" }) })
    const cool = customTheme({ id: 12, name: "Cool Mint" })
    const created = customTheme({ id: 13, name: "Custom Theme", tokens: warm.tokens, position: 2 })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/themes" && !init?.method) return Promise.resolve(jsonResponse({ themes: [builtInTheme(), warm, cool] }))
      if (path === "/api/v1/app/themes" && init?.method === "POST") return Promise.resolve(jsonResponse({ theme: created }, 201))
      if (path === "/api/v1/app/themes/13" && init?.method === "DELETE") return Promise.resolve(jsonResponse({ deleted_theme_id: 13, fallback_theme_id: null }))
      return Promise.resolve(jsonResponse({}))
    })

    renderRoute(warm)

    await screen.findByRole("list", { name: "Custom themes" })
    fireEvent.click(screen.getByRole("button", { name: "New" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes", expect.objectContaining({
      method: "POST",
      body: JSON.stringify({ theme: { name: "Custom Theme", tokens: warm.tokens } })
    })))
    expect(await screen.findByDisplayValue("Custom Theme")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Delete" }))
    const dialog = await screen.findByRole("dialog", { name: "Delete Custom Theme?" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Delete" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/themes/13", expect.objectContaining({ method: "DELETE" })))
    expect(await screen.findByText("Theme deleted.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Custom Theme/ })).not.toBeInTheDocument()
  })
})

function renderRoute(activeTheme: ColorTheme = customTheme({ id: 11, name: "Warm Slate" })) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  render(
    <QueryClientProvider client={queryClient}>
      <ThemeProvider colorTheme={activeTheme} theme="light">
        <ThemeSettingsRoute />
      </ThemeProvider>
    </QueryClientProvider>
  )
}

function builtInTheme(): ColorTheme {
  return {
    id: 1,
    slug: "terracotta",
    name: "Terracotta",
    built_in: true,
    position: null,
    tokens: tokens({ brand: "#c9704b" })
  }
}

function customTheme(overrides: Partial<ColorTheme> = {}): ColorTheme {
  return {
    id: 11,
    slug: `custom-${overrides.id ?? 11}`,
    name: "Custom Theme",
    built_in: false,
    position: 0,
    tokens: tokens(),
    ...overrides
  }
}

function tokens(overrides: Record<string, string> = {}) {
  const base = {
    brand: "#884422",
    "brand-emphasis": "#663311",
    surface: "#ffffff",
    "surface-raised": "#f8fafc",
    border: "#d1d5db",
    "text-primary": "#111827",
    "text-secondary": "#4b5563",
    success: "#166534",
    warning: "#92400e",
    danger: "#991b1b",
    info: "#1d4ed8",
    neutral: "#374151",
    "on-brand": "#ffffff",
    ...overrides
  }

  return { light: base, dark: { ...base, surface: "#111827", "surface-raised": "#1f2937", "text-primary": "#f9fafb", "text-secondary": "#d1d5db" } }
}

function editedLightBrandTokens() {
  const current = tokens()
  return { ...current, light: { ...current.light, brand: "#995533" } }
}
