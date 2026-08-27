import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { ThemeProvider, useTheme, type Theme } from "./ThemeContext"
import type { BootstrapPayload } from "../api/bootstrap"
import type { ColorTheme } from "../api/themes"

function Probe() {
  const { theme, resolvedTheme, setTheme, colorTheme, setColorTheme } = useTheme()

  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="resolved">{resolvedTheme}</span>
      <span data-testid="colorTheme">{colorTheme?.slug ?? "none"}</span>
      <button onClick={() => setTheme("light")} type="button">light</button>
      <button onClick={() => setTheme("dark")} type="button">dark</button>
      <button onClick={() => setTheme("system")} type="button">system</button>
      <button onClick={() => setColorTheme(oceanColorTheme())} type="button">ocean</button>
      <button onClick={() => setColorTheme(customColorTheme())} type="button">custom</button>
    </div>
  )
}

function oceanColorTheme(): ColorTheme {
  return {
    id: 2,
    slug: "ocean",
    name: "Ocean",
    built_in: true,
    tokens: {
      light: { brand: "#1d6fa5" },
      dark: { brand: "#4db3e8" }
    }
  }
}

function customColorTheme(): ColorTheme {
  return {
    id: 9,
    slug: "my-custom",
    name: "My Custom",
    built_in: false,
    tokens: {
      light: { brand: "#abcdef" },
      dark: { brand: "#123456" }
    }
  }
}

function renderProbe(theme: Theme, colorTheme: ColorTheme | null = null, queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  render(
    <QueryClientProvider client={queryClient}>
      <ThemeProvider colorTheme={colorTheme} theme={theme}>
        <Probe />
      </ThemeProvider>
    </QueryClientProvider>
  )
  return queryClient
}

function mockColorSchemeMatchMedia(prefersDark: boolean) {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia")

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: query === "(prefers-color-scheme: dark)" ? prefersDark : false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn()
    }))
  })

  return () => {
    if (original) {
      Object.defineProperty(window, "matchMedia", original)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  }
}

describe("ThemeContext", () => {
  afterEach(() => {
    document.documentElement.classList.remove("dark")
    document.documentElement.removeAttribute("data-theme")
    document.documentElement.removeAttribute("style")
  })

  it("applies the dark class immediately for an explicit dark theme", () => {
    renderProbe("dark")

    expect(document.documentElement.classList.contains("dark")).toBe(true)
    expect(screen.getByTestId("resolved")).toHaveTextContent("dark")
  })

  it("resolves system against the OS preference", () => {
    const restore = mockColorSchemeMatchMedia(true)

    try {
      renderProbe("system")

      expect(document.documentElement.classList.contains("dark")).toBe(true)
      expect(screen.getByTestId("resolved")).toHaveTextContent("dark")
    } finally {
      restore()
    }
  })

  it("resolves system to light when the OS prefers light", () => {
    const restore = mockColorSchemeMatchMedia(false)

    try {
      renderProbe("system")

      expect(document.documentElement.classList.contains("dark")).toBe(false)
      expect(screen.getByTestId("resolved")).toHaveTextContent("light")
    } finally {
      restore()
    }
  })

  it("persists a theme change and updates the shared bootstrap cache", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/theme") return Promise.resolve(jsonResponse({ theme: "dark" }))
      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = renderProbe("light")
    queryClient.setQueryData(["bootstrap"], { current_user: { theme: "light" } } as unknown as BootstrapPayload)

    screen.getByRole("button", { name: "dark" }).click()

    expect(document.documentElement.classList.contains("dark")).toBe(true)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/theme", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ theme: "dark" })
      }))
    })
    await waitFor(() => {
      expect(queryClient.getQueryData<BootstrapPayload>(["bootstrap"])?.current_user?.theme).toBe("dark")
    })
  })

  it("rolls back the optimistic update when the request fails", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ error: { code: "validation_failed" } }, 422)))
    const queryClient = renderProbe("light")
    queryClient.setQueryData(["bootstrap"], { current_user: { theme: "light" } } as unknown as BootstrapPayload)

    screen.getByRole("button", { name: "dark" }).click()
    expect(document.documentElement.classList.contains("dark")).toBe(true)

    await waitFor(() => {
      expect(document.documentElement.classList.contains("dark")).toBe(false)
    })
    expect(queryClient.getQueryData<BootstrapPayload>(["bootstrap"])?.current_user?.theme).toBe("light")
  })

  it("sets data-theme for a built-in color theme and applies no inline custom properties", () => {
    renderProbe("light", oceanColorTheme())

    expect(document.documentElement.getAttribute("data-theme")).toBe("ocean")
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("")
  })

  it("applies token values as inline custom properties for a custom color theme, matching the resolved mode", () => {
    renderProbe("light", customColorTheme())

    expect(document.documentElement.hasAttribute("data-theme")).toBe(false)
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#abcdef")
  })

  it("re-applies the custom theme's dark token set when resolved mode changes", () => {
    renderProbe("dark", customColorTheme())

    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#123456")
  })

  it("clears inline custom properties when switching from a custom theme to a built-in theme", () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ color_theme: oceanColorTheme() })))
    queryClient.setQueryData(["bootstrap"], { current_user: { theme: "light", color_theme: customColorTheme() } } as unknown as BootstrapPayload)
    renderProbe("light", customColorTheme(), queryClient)

    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#abcdef")

    screen.getByRole("button", { name: "ocean" }).click()

    expect(document.documentElement.getAttribute("data-theme")).toBe("ocean")
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("")
  })

  it("persists a color theme change and updates the shared bootstrap cache", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/theme") return Promise.resolve(jsonResponse({ color_theme: customColorTheme() }))
      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = renderProbe("light")
    queryClient.setQueryData(["bootstrap"], { current_user: { theme: "light", color_theme: null } } as unknown as BootstrapPayload)

    screen.getByRole("button", { name: "custom" }).click()

    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#abcdef")

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/theme", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ color_theme_id: 9 })
      }))
    })
    await waitFor(() => {
      expect(queryClient.getQueryData<BootstrapPayload>(["bootstrap"])?.current_user?.color_theme?.slug).toBe("my-custom")
    })
  })

  it("rolls back the optimistic color theme update when the request fails", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ error: { code: "validation_failed" } }, 422)))
    const queryClient = renderProbe("light", oceanColorTheme())
    queryClient.setQueryData(["bootstrap"], { current_user: { theme: "light", color_theme: oceanColorTheme() } } as unknown as BootstrapPayload)

    screen.getByRole("button", { name: "custom" }).click()
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("#abcdef")

    await waitFor(() => {
      expect(document.documentElement.getAttribute("data-theme")).toBe("ocean")
    })
    expect(document.documentElement.style.getPropertyValue("--color-brand")).toBe("")
    expect(queryClient.getQueryData<BootstrapPayload>(["bootstrap"])?.current_user?.color_theme?.slug).toBe("ocean")
  })

  it("throws when useTheme is used outside a ThemeProvider", () => {
    function Bare() {
      useTheme()
      return null
    }

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    expect(() => render(<Bare />)).toThrow("useTheme must be used within a ThemeProvider")
    consoleSpy.mockRestore()
  })
})
