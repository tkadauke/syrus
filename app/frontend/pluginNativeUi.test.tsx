import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import { ThemeProvider, type Theme } from "./contexts/ThemeContext"
import { AdminPerformance } from "../../plugins/syrus_dev/app/frontend/routes/AdminPerformance"
import { DesignDocsSurface } from "../../plugins/design_docs/app/frontend/components/DesignDocsSurface"

describe("plugin-native UI primitives", () => {
  afterEach(() => {
    document.documentElement.classList.remove("dark")
  })

  it.each(["light", "dark"] as Theme[])("renders a plugin admin page that imports @app/components/ui in %s theme", async (theme) => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(performancePayload()))

    renderWithTheme(<AdminPerformance />, theme, "/app-shell/admin/performance")

    expect(await screen.findByRole("heading", { name: "Performance" })).toBeInTheDocument()
    await waitFor(() => {
      expect(document.documentElement.classList.contains("dark")).toBe(theme === "dark")
    })
    expect(screen.getByRole("region", { name: "Performance summary" })).toBeInTheDocument()
  })

  it.each(["light", "dark"] as Theme[])("renders a plugin sidebar page that imports @app/components/ui in %s theme", async (theme) => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ active_repositories: [] }))

    renderWithTheme(
      <DesignDocsSurface compact mode="chat" />,
      theme,
      "/app-shell/design_docs"
    )

    expect(await screen.findByText("No design docs are attached to this chat.")).toBeInTheDocument()
    await waitFor(() => {
      expect(document.documentElement.classList.contains("dark")).toBe(theme === "dark")
    })
  })
})

function renderWithTheme(children: ReactNode, theme: Theme, path: string) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <ThemeProvider theme={theme}>
        <MemoryRouter initialEntries={[path]}>
          {children}
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>
  )
}

function performancePayload() {
  return {
    enabled: true,
    current_revision: "abcdef1234567890",
    revision_scope: "current",
    thresholds: {
      slow_request_ms: 1000,
      slow_job_ms: 5000,
      slow_sql_ms: 500,
      slow_phase_ms: 250,
      request_sql_count_threshold: 50,
      request_sql_duration_ms: 500,
      top_sql_fingerprint_limit: 10,
      max_sql_fingerprints_per_request: 5
    },
    storage: {
      kind: "rails.cache",
      max_events: 200,
      expires_in_seconds: 86400
    },
    baseline: {
      revision: null,
      comparisons: {
        slow_requests: [],
        slow_jobs: [],
        slow_phases: [],
        browser_traces: [],
        sql_fingerprints: []
      }
    },
    summaries: {
      slow_requests: [],
      slow_jobs: [],
      slow_phases: [],
      browser_traces: [],
      sql_fingerprints: []
    },
    events: []
  }
}
