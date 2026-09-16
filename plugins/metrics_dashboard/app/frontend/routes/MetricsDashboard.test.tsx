import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import { MetricsDashboardRoute } from "./MetricsDashboard"
import type { MetricsDashboardPayload, MetricsPanel, MetricsPluginTab } from "../api/metricsDashboard"

function panel(key: string, category: string, overrides: Partial<MetricsPanel> = {}): MetricsPanel {
  return {
    key,
    metric: `syrus_${key}`,
    unit: "jobs",
    mode: "value",
    category,
    series: [ { name: "total", values: [ 1, 2, 3 ] } ],
    ...overrides
  }
}

function payload(overrides: Partial<MetricsDashboardPayload> = {}): MetricsDashboardPayload {
  return {
    window: "6h",
    windows: [ "1h", "6h", "24h", "7d" ],
    buckets: [ "2026-01-01T00:00:00Z", "2026-01-01T00:05:00Z", "2026-01-01T00:10:00Z" ],
    bucket_seconds: 300,
    recording: true,
    last_recorded_at: "2026-01-01T00:10:00Z",
    categories: [ "queue_throughput", "workers_fleet", "resilience_product" ],
    plugin_tabs: [],
    panels: [
      panel("queue_ready", "queue_throughput"),
      panel("worker_cpu", "workers_fleet"),
      panel("feature_usage", "resilience_product")
    ],
    ...overrides
  }
}

function LocationProbe() {
  const location = useLocation()
  return <span data-testid="location">{location.pathname}{location.search}</span>
}

function renderRoute(responsePayload: MetricsDashboardPayload = payload(), initialEntry = "/app-shell/metrics_dashboard") {
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(responsePayload)))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ initialEntry ]}>
        <Routes>
          <Route
            element={
              <>
                <MetricsDashboardRoute />
                <LocationProbe />
              </>
            }
            path="/app-shell/metrics_dashboard"
          />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

describe("MetricsDashboardRoute tabs", () => {
  afterEach(() => vi.restoreAllMocks())

  it("defaults to the first category and shows only that tab's panels", async () => {
    renderRoute()

    expect(await screen.findByRole("tab", { name: "Queue & Throughput" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByText("Jobs waiting, by queue")).toBeInTheDocument()
    expect(screen.queryByText("Worker CPU utilization, by host")).not.toBeInTheDocument()
    expect(screen.queryByText("Feature uses, by feature")).not.toBeInTheDocument()
  })

  it("switches panels and updates the URL when a tab is clicked", async () => {
    renderRoute()
    await screen.findByText("Jobs waiting, by queue")

    fireEvent.click(screen.getByRole("tab", { name: "Workers & Fleet" }))

    expect(await screen.findByText("Worker CPU utilization, by host")).toBeInTheDocument()
    expect(screen.queryByText("Jobs waiting, by queue")).not.toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Workers & Fleet" })).toHaveAttribute("aria-selected", "true")
    await waitFor(() => expect(screen.getByTestId("location").textContent).toContain("tab=workers_fleet"))
  })

  it("honors a tab requested via the URL on first load", async () => {
    renderRoute(payload(), "/app-shell/metrics_dashboard?tab=resilience_product")

    expect(await screen.findByText("Feature uses, by feature")).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Resilience & Product" })).toHaveAttribute("aria-selected", "true")
  })

  it("falls back to the first category when the URL names an unknown tab", async () => {
    renderRoute(payload(), "/app-shell/metrics_dashboard?tab=made_up")

    expect(await screen.findByText("Jobs waiting, by queue")).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Queue & Throughput" })).toHaveAttribute("aria-selected", "true")
  })

  it("keeps the window param when switching tabs, and the tab param when switching windows", async () => {
    renderRoute(payload({ window: "24h" }), "/app-shell/metrics_dashboard?window=24h")
    await screen.findByText("Jobs waiting, by queue")

    fireEvent.click(screen.getByRole("tab", { name: "Workers & Fleet" }))
    await waitFor(() => {
      const search = screen.getByTestId("location").textContent ?? ""
      expect(search).toContain("window=24h")
      expect(search).toContain("tab=workers_fleet")
    })

    fireEvent.click(screen.getByRole("button", { name: "1h" }))
    await waitFor(() => {
      const search = screen.getByTestId("location").textContent ?? ""
      expect(search).toContain("window=1h")
      expect(search).toContain("tab=workers_fleet")
    })
  })

  it("shows an 'Other' tab for a panel with no real category, instead of dropping it", async () => {
    renderRoute(
      payload({
        categories: [ "queue_throughput", "workers_fleet", "resilience_product", "other" ],
        panels: [
          panel("queue_ready", "queue_throughput"),
          panel("mystery", "other")
        ]
      })
    )

    expect(await screen.findByRole("tab", { name: "Other" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("tab", { name: "Other" }))

    await waitFor(() => expect(screen.getByRole("tab", { name: "Other" })).toHaveAttribute("aria-selected", "true"))
  })
})

describe("MetricsDashboardRoute plugin tabs", () => {
  afterEach(() => vi.restoreAllMocks())

  function pluginTab(id: string, label: string): MetricsPluginTab {
    return { id, label }
  }

  it("renders a tab per contributing plugin, after the core tabs, using its literal label", async () => {
    renderRoute(
      payload({
        plugin_tabs: [ pluginTab("throughput", "Throughput") ],
        panels: [
          panel("queue_ready", "queue_throughput"),
          panel("landing_units", "throughput", { label: "Landing units, by type" })
        ]
      })
    )

    expect(await screen.findByRole("tab", { name: "Queue & Throughput" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Throughput" })).toBeInTheDocument()
    expect(screen.queryByText("Landing units, by type")).not.toBeInTheDocument()
  })

  it("shows a plugin panel's literal title, and its own panels, once its tab is selected", async () => {
    renderRoute(
      payload({
        plugin_tabs: [ pluginTab("throughput", "Throughput") ],
        panels: [
          panel("queue_ready", "queue_throughput"),
          panel("landing_units", "throughput", { label: "Landing units, by type" })
        ]
      })
    )
    await screen.findByText("Jobs waiting, by queue")

    fireEvent.click(screen.getByRole("tab", { name: "Throughput" }))

    expect(await screen.findByText("Landing units, by type")).toBeInTheDocument()
    expect(screen.queryByText("Jobs waiting, by queue")).not.toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Throughput" })).toHaveAttribute("aria-selected", "true")
    await waitFor(() => expect(screen.getByTestId("location").textContent).toContain("tab=throughput"))
  })

  it("contributes no tab when no plugin declares one", async () => {
    renderRoute(payload({ plugin_tabs: [] }))

    await screen.findByRole("tab", { name: "Queue & Throughput" })
    expect(screen.queryByRole("tab", { name: "Throughput" })).not.toBeInTheDocument()
  })
})
