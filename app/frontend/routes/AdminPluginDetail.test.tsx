import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminPluginDetail } from "./AdminPluginDetail"

describe("AdminPluginDetail", () => {
  it("renders overview, metadata, config, docs, metrics, routes, and provided links", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      name: "terminal",
      display_name: "Terminal",
      disable_blockers: [],
      version: "1.0.0",
      enabled: true,
      default_enabled: false,
      disableable: true,
      category: "tooling",
      category_label: "Tooling",
      description: "Interactive shell sessions.",
      long_description: "A real PTY.",
      homepage: "https://example.test/terminal",
      icon_url: "/plugin-icons/terminal.svg",
      author: "Thomas Kadauke",
      source: "/app/plugins/terminal",
      health: { state: "ok", reasons: [] },
      links: [{ label: "Open Terminal", path: "/terminal", description: "Open the Terminal workspace UI", requires_enabled: true }],
      config_schema: [{ key: "host", label: "Host", type: "string", description: "Relay host." }],
      config: { host: "worker-1" },
      routes: [{ verb: "GET", path: "/api/v1/app/terminal_sessions", controller: "api/v1/app/terminal_sessions#index" }],
      extension_points: [
        { extension_point: "sidebar_page", class_name: "Terminal::SidebarPages", availability: { status: "registered", label: "Registered" } }
      ],
      depends_on: [],
      optionally_depends_on: [],
      conflicts_with: [],
      dependents: [],
      docs: [{ title: "Terminal", path: "plugins/terminal/docs/syrus_docs/terminal.md", body: "# Terminal\n\nOpen shells." }],
      metrics: [{ name: "syrus_terminal_sessions_total", type: "counter", tags: ["state"], comment: "Sessions.", available: true, latest_sample: { value: 2, labels: { state: "open" }, recorded_at: "2026-09-13T12:00:00Z" } }]
    }))

    renderRoute()

    expect(await screen.findByText("Interactive shell sessions.")).toBeInTheDocument()
    expect(screen.getByText("terminal")).toBeInTheDocument()
    expect(screen.getByText("A real PTY.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open Terminal" })).toHaveAttribute("href", "/terminal")
    expect(screen.getByText("Host")).toBeInTheDocument()
    expect(screen.getByText("worker-1")).toBeInTheDocument()
    expect(screen.getByText("Terminal::SidebarPages")).toBeInTheDocument()
    expect(screen.getByText("/api/v1/app/terminal_sessions")).toBeInTheDocument()
    expect(screen.getByText("Open shells.")).toBeInTheDocument()
    expect(screen.getByText("syrus_terminal_sessions_total")).toBeInTheDocument()
    expect(screen.getByText("Sessions.")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("/app/plugins/terminal")).toBeInTheDocument()
  })

  it("renders empty docs and metrics states and hides enabled-only links for disabled plugins", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      name: "quiet",
      display_name: "Quiet",
      disable_blockers: [],
      version: "1.0.0",
      enabled: false,
      default_enabled: false,
      disableable: true,
      category: null,
      category_label: null,
      description: null,
      long_description: null,
      homepage: null,
      icon_url: "/plugin-icons/spqr_eagle.svg",
      author: null,
      source: null,
      health: { state: "ok", reasons: [] },
      links: [{ label: "Open Quiet", path: "/quiet", requires_enabled: true }],
      config_schema: [],
      config: {},
      routes: [],
      extension_points: [],
      depends_on: [],
      optionally_depends_on: [],
      conflicts_with: [],
      dependents: [],
      docs: [],
      metrics: []
    }))

    renderRoute("/admin/plugins/quiet")

    expect(await screen.findByRole("heading", { name: "Quiet" })).toBeInTheDocument()
    expect(screen.getByText("Enable this plugin to use its links.")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Open Quiet" })).not.toBeInTheDocument()
    expect(screen.getByText("No plugin docs found.")).toBeInTheDocument()
    expect(screen.getByText("No plugin metrics declared.")).toBeInTheDocument()
    expect(screen.getByText("No config fields declared.")).toBeInTheDocument()
    expect(screen.getByText("No extension points registered.")).toBeInTheDocument()
    expect(screen.getByText("No routes declared.")).toBeInTheDocument()
  })

  it("prefixes the Terminal primary surface link under the app shell", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      name: "terminal",
      display_name: "Terminal",
      disable_blockers: [],
      version: "1.0.0",
      enabled: true,
      default_enabled: false,
      disableable: true,
      category: "tooling",
      category_label: "Tooling",
      description: null,
      homepage: null,
      icon_url: "/plugin-icons/terminal.svg",
      author: null,
      source: null,
      health: { state: "ok", reasons: [] },
      links: [{ label: "Open Terminal", path: "/terminal", requires_enabled: true }],
      config_schema: [],
      config: {},
      routes: [],
      extension_points: [],
      depends_on: [],
      optionally_depends_on: [],
      conflicts_with: [],
      dependents: [],
      docs: [],
      metrics: []
    }))

    renderRoute("/app-shell/admin/plugins/terminal")

    const actions = await screen.findByLabelText("Actions")
    expect(within(actions).getByRole("link", { name: "Open Terminal" })).toHaveAttribute("href", "/app-shell/terminal")
  })
})

function renderRoute(path = "/admin/plugins/terminal") {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/admin/plugins/:name" element={<AdminPluginDetail />} />
          <Route path="/app-shell/admin/plugins/:name" element={<AdminPluginDetail />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}
