import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { AdminPlugins } from "./AdminPlugins"

describe("AdminPlugins", () => {
  it("renders registered plugins and extension points", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "codex_agent",
          display_name: "Codex Agent",
          disable_blockers: [],
          version: "1.2.3",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: "Codex agent provider",
          homepage: "https://example.test/codex",
          author: "OpenAI",
          source: "/app/plugins/codex_agent",
          extension_points: [
            {
              extension_point: "agent_provider",
              class_name: "AgentProviders::Codex",
              availability: { status: "available", label: "Available" }
            }
          ]
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    const list = await screen.findByRole("region", { name: "Registered plugins" })
    expect(within(list).getByRole("heading", { name: "Codex Agent" })).toBeInTheDocument()
    expect(within(list).getByText("codex_agent")).toBeInTheDocument()
    expect(within(list).getByText("1.2.3")).toBeInTheDocument()
    expect(within(list).getByText("AgentProviders::Codex")).toBeInTheDocument()
    expect(within(list).getByText("Available")).toBeInTheDocument()
    expect(within(list).getByText("OpenAI")).toBeInTheDocument()
  })

  it("does not render the source path", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "codex_agent",
          display_name: "Codex Agent",
          disable_blockers: [],
          version: "1.2.3",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: "/rails/plugins/codex_agent",
          extension_points: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })
    expect(screen.queryByText("/rails/plugins/codex_agent")).not.toBeInTheDocument()
    expect(screen.queryByText("Source")).not.toBeInTheDocument()
  })

  it("shows extension points in a collapsed section", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "claude_agent",
          display_name: "Claude Agent",
          disable_blockers: [],
          version: "0.1.0",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: null,
          extension_points: [
            {
              extension_point: "agent_provider",
              class_name: "AgentProviders::Claude",
              availability: { status: "available", label: "Available" }
            }
          ]
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })
    expect(screen.getByText("Extension points")).toBeInTheDocument()
    // Content exists in DOM (inside details) but section is collapsed by default
    expect(screen.getByText("AgentProviders::Claude")).toBeInTheDocument()
  })

  it("tooltips the disable button with a single blocker reason", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "claude_agent",
          display_name: "Claude Agent",
          disable_blockers: [{ kind: "open_jobs", label: "Open jobs use Claude Code", count: 27 }],
          version: "0.1.0",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: null,
          extension_points: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })
    const tooltipWrapper = screen.getByTitle("Open jobs use Claude Code: 27")
    expect(within(tooltipWrapper).getByRole("button", { name: "Disable" })).toBeDisabled()
  })

  it("tooltips the disable button with a summary when there are multiple blockers", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "claude_agent",
          display_name: "Claude Agent",
          disable_blockers: [
            { kind: "open_jobs", label: "Open jobs", count: 27 },
            { kind: "active_workflows", label: "Active workflows", count: 6 }
          ],
          version: "0.1.0",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: null,
          extension_points: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })
    const tooltipWrapper = screen.getByTitle("In use — see usage details")
    expect(within(tooltipWrapper).getByRole("button", { name: "Disable" })).toBeDisabled()
  })

  it("shows usage details in a collapsed section when there are disable blockers", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "claude_agent",
          display_name: "Claude Agent",
          disable_blockers: [
            { kind: "open_jobs", label: "Open jobs use Claude Code", count: 27 },
            { kind: "active_workflows", label: "Active workflows use Claude Code", count: 6 }
          ],
          version: "0.1.0",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: null,
          extension_points: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })
    expect(screen.getByText("Usage")).toBeInTheDocument()
    expect(screen.getByText("Open jobs use Claude Code: 27")).toBeInTheDocument()
    expect(screen.getByText("Active workflows use Claude Code: 6")).toBeInTheDocument()
  })

  it("shows an empty state when no plugins are registered", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ plugins: [] }))

    renderRoute(<AdminPlugins />)

    expect(await screen.findByText("No plugins registered")).toBeInTheDocument()
    expect(screen.getByText("Registered plugin manifests will appear here after plugin engines load.")).toBeInTheDocument()
  })
})

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/admin/plugins"]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}
