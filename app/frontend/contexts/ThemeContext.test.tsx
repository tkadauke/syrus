import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { ThemeProvider, useTheme, type Theme } from "./ThemeContext"
import type { BootstrapPayload } from "../api/bootstrap"

function Probe() {
  const { theme, resolvedTheme, setTheme } = useTheme()

  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="resolved">{resolvedTheme}</span>
      <button onClick={() => setTheme("light")} type="button">light</button>
      <button onClick={() => setTheme("dark")} type="button">dark</button>
      <button onClick={() => setTheme("system")} type="button">system</button>
    </div>
  )
}

function renderProbe(theme: Theme, queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  render(
    <QueryClientProvider client={queryClient}>
      <ThemeProvider theme={theme}>
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
