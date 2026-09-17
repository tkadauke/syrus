import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"

const reloadMock = vi.hoisted(() => vi.fn())

vi.mock("../lib/pageReload", () => ({
  reloadPage: reloadMock
}))

import { AdminPluginDetail, AdminPlugins } from "./AdminPlugins"

const pluginFilterSchema = [
  {
    field: "enabled",
    label: "Enabled",
    bucket: "enum",
    operators: ["is"],
    values: [
      { value: "enabled", label: "Enabled" },
      { value: "disabled", label: "Disabled" }
    ]
  },
  {
    field: "author",
    label: "Author",
    bucket: "string",
    operators: ["contains", "does_not_contain", "starts_with", "does_not_start_with", "ends_with", "does_not_end_with", "equals", "not_equals", "is_set", "is_unset"],
    values: []
  },
  {
    field: "extension_point",
    label: "Extension point",
    bucket: "enum",
    operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"],
    values: [
      { value: "agent_provider", label: "Agent provider" },
      { value: "input_source", label: "Input source" }
    ]
  },
  {
    field: "category",
    label: "Category",
    bucket: "enum",
    operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"],
    values: [
      { value: "language", label: "Language & framework intelligence" },
      { value: "agent", label: "Agent provider" },
      { value: "input_source", label: "Input source" },
      { value: "mcp_tool_set", label: "MCP tool set" },
      { value: "platform_delivery", label: "Platform delivery" },
      { value: "connectivity", label: "Connectivity" },
      { value: "observability", label: "Observability" },
      { value: "tooling", label: "Tooling" }
    ]
  },
  {
    field: "search",
    label: "Search",
    bucket: "string",
    operators: ["contains"],
    values: [],
    free_text_search: true
  }
]

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
    expect(within(list).getByRole("link", { name: "Details" })).toHaveAttribute("href", "/admin/plugins/codex_agent")
    expect(within(list).queryByText("AgentProviders::Codex")).not.toBeInTheDocument()
    expect(within(list).queryByText("OpenAI")).not.toBeInTheDocument()
  })

  it("renders the plugin icon at the expected size", async () => {
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
          icon_url: "/plugin-icons/spqr_eagle.svg",
          author: null,
          source: null,
          extension_points: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    const list = await screen.findByRole("region", { name: "Registered plugins" })
    const icon = list.querySelector('img[src="/plugin-icons/spqr_eagle.svg"]')
    expect(icon).toBeInTheDocument()
    expect(icon).toHaveClass("h-5", "w-5")
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

  it("links inventory cards to the plugin detail page", async () => {
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
    expect(screen.getByRole("link", { name: "Details" })).toHaveAttribute("href", "/admin/plugins/claude_agent")
    expect(screen.queryByText("AgentProviders::Claude")).not.toBeInTheDocument()
  })

  it("uses semantic info tokens for required extension point status badges", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugin: {
        name: "rails",
        display_name: "Rails",
        disable_blockers: [],
        version: "1.0.0",
        enabled: true,
        disableable: true,
        default_enabled: true,
        description: null,
        homepage: null,
        author: null,
        source: null,
        docs: [],
        metrics: [],
        routes: [],
        config_schema: [],
        extension_points: [
          {
            extension_point: "rails_artifact_renderer",
            class_name: "Rails::ArtifactRenderer",
            availability: { status: "required", label: "Required" }
          }
        ]
      }
    }))

    renderDetailRoute("/admin/plugins/rails")

    const badge = await screen.findByText("Required")
    expect(badge.className).toContain("bg-info/10")
    expect(badge.className).toContain("text-info")
    expect(badge.className).not.toMatch(/\b(?:bg|text)-blue-/)
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

  it("renders a category filter chip via the FilterBar add-filter menu", async () => {
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
          homepage: null,
          author: null,
          source: null,
          extension_points: []
        }
      ],
      filter: { and: [] },
      controls: { filter_schema: pluginFilterSchema }
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByRole("button", { name: "Enabled list" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Author text" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Extension point list" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Category list" })).toBeInTheDocument()
    // The search chip is the pinned free-text search field: it no longer
    // appears in the generic field/operator/value list, even with an
    // empty query.
    expect(screen.queryByRole("button", { name: "Search text" })).not.toBeInTheDocument()
  })

  it("pins the search chip as a free-text search suggestion once the operator types at least two characters", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      return Promise.resolve(jsonResponse({
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
            homepage: null,
            author: null,
            source: null,
            extension_points: []
          }
        ],
        filter: url.includes("q=") ? { and: [{ field: "search", op: "contains", value: "codex" }] } : { and: [] },
        controls: { filter_schema: pluginFilterSchema }
      }))
    })

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.queryByText(/^Search for /)).not.toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "codex" } })
    expect(screen.getByText("Search for codex")).toBeInTheDocument()

    fireEvent.click(screen.getByText("Search for codex"))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("q="), expect.anything()))
    expect(await screen.findByRole("button", { name: "Search contains codex" })).toBeInTheDocument()
  })

  it("filters plugins by the category chip and shows a filtered empty state", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      if (url.includes("q=")) {
        return Promise.resolve(jsonResponse({
          plugins: [],
          filter: { and: [{ field: "category", op: "is", value: "language" }] },
          controls: { filter_schema: pluginFilterSchema }
        }))
      }
      return Promise.resolve(jsonResponse({
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
            homepage: null,
            author: null,
            source: null,
            extension_points: []
          }
        ],
        filter: { and: [] },
        controls: { filter_schema: pluginFilterSchema }
      }))
    })

    renderRoute(<AdminPlugins />)

    await screen.findByRole("region", { name: "Registered plugins" })

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Category list" }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("q="), expect.anything()))
    expect(await screen.findByText("No plugins match your search")).toBeInTheDocument()
    expect(screen.getByText("Try a different name, description, or category.")).toBeInTheDocument()
  })

  it("shows an empty state when no plugins are registered", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ plugins: [] }))

    renderRoute(<AdminPlugins />)

    expect(await screen.findByText("No plugins registered")).toBeInTheDocument()
    expect(screen.getByText("Registered plugin manifests will appear here after plugin engines load.")).toBeInTheDocument()
  })

  it("reloads the page after disabling a plugin", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input).endsWith("/disable") && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ plugins: [] }))
      }
      return Promise.resolve(jsonResponse({
        plugins: [
          {
            name: "codex_agent",
            display_name: "Codex Agent",
            disable_blockers: [],
            disableable: true,
            version: "1.2.3",
            enabled: true,
            description: "Codex agent provider",
            extension_points: []
          }
        ]
      }))
    })

    renderRoute(<AdminPlugins />)

    fireEvent.click(await screen.findByRole("button", { name: "Disable" }))

    await waitFor(() => expect(reloadMock).toHaveBeenCalled())
  })

  it("renders declared dependency relationships", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "ruby",
          display_name: "Ruby",
          disable_blockers: [],
          version: "1.0.0",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: null,
          extension_points: [],
          depends_on: [],
          dependents: [ "rails" ]
        },
        {
          name: "rails",
          display_name: "Rails",
          disable_blockers: [],
          version: "1.0.0",
          enabled: true,
          disableable: true,
          default_enabled: true,
          description: null,
          homepage: null,
          author: null,
          source: null,
          extension_points: [],
          depends_on: [ "ruby" ],
          dependents: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    const list = await screen.findByRole("region", { name: "Registered plugins" })
    const rubyCard = within(list).getByRole("heading", { name: "Ruby" }).closest("article") as HTMLElement
    expect(within(rubyCard).getByText("Required by:")).toBeInTheDocument()
    expect(within(rubyCard).getByText("rails")).toBeInTheDocument()

    const railsCard = within(list).getByRole("heading", { name: "Rails" }).closest("article") as HTMLElement
    expect(within(railsCard).getByText("Depends on:")).toBeInTheDocument()
    expect(within(railsCard).getByText("ruby")).toBeInTheDocument()
  })

  it("shows a cascade confirmation instead of reloading when the plugin has enabled dependents", async () => {
    let confirmed = false
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input).endsWith("/disable") && init?.method === "POST") {
        const body = init?.body ? JSON.parse(String(init.body)) : {}
        if (body.confirm_cascade) {
          confirmed = true
          return Promise.resolve(jsonResponse({ plugins: [] }))
        }
        return Promise.resolve(jsonResponse({
          requires_confirmation: true,
          plugin_name: "ruby",
          dependents: [ "rails" ]
        }))
      }
      return Promise.resolve(jsonResponse({
        plugins: [
          {
            name: "ruby",
            display_name: "Ruby",
            disable_blockers: [],
            disableable: true,
            version: "1.0.0",
            enabled: true,
            description: null,
            extension_points: []
          }
        ]
      }))
    })

    renderRoute(<AdminPlugins />)

    fireEvent.click(await screen.findByRole("button", { name: "Disable" }))

    expect(await screen.findByText("Other enabled plugins depend on this one")).toBeInTheDocument()
    expect(screen.getByText("rails")).toBeInTheDocument()
    expect(reloadMock).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Disable all" }))

    await waitFor(() => expect(reloadMock).toHaveBeenCalled())
    expect(confirmed).toBe(true)
  })

  it("cancels the cascade confirmation without disabling", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input).endsWith("/disable") && init?.method === "POST") {
        return Promise.resolve(jsonResponse({
          requires_confirmation: true,
          plugin_name: "ruby",
          dependents: [ "rails" ]
        }))
      }
      return Promise.resolve(jsonResponse({
        plugins: [
          {
            name: "ruby",
            display_name: "Ruby",
            disable_blockers: [],
            disableable: true,
            version: "1.0.0",
            enabled: true,
            description: null,
            extension_points: []
          }
        ]
      }))
    })

    renderRoute(<AdminPlugins />)

    fireEvent.click(await screen.findByRole("button", { name: "Disable" }))
    await screen.findByText("Other enabled plugins depend on this one")

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.queryByText("Other enabled plugins depend on this one")).not.toBeInTheDocument()
    expect(reloadMock).not.toHaveBeenCalled()
  })

  it("navigates to the detail page after enabling a plugin", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input).endsWith("/enable") && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ plugins: [] }))
      }
      return Promise.resolve(jsonResponse({
        plugins: [
          {
            name: "codex_agent",
            display_name: "Codex Agent",
            disable_blockers: [],
            disableable: true,
            version: "1.2.3",
            enabled: false,
            description: "Codex agent provider",
            extension_points: []
          }
        ]
      }))
    })

    renderRoute(
      <Routes>
        <Route path="/admin/plugins" element={<AdminPlugins />} />
        <Route path="/admin/plugins/:name" element={<div>Plugin detail route</div>} />
      </Routes>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Enable" }))

    expect(await screen.findByText("Plugin detail route")).toBeInTheDocument()
    expect(reloadMock).not.toHaveBeenCalled()
  })

  it("renders plugin detail sections with docs, metrics, routes, config, and a provided link", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugin: {
        name: "terminal",
        display_name: "Terminal",
        disable_blockers: [],
        version: "1.0.0",
        enabled: true,
        disableable: true,
        default_enabled: false,
        health: { state: "degraded", reasons: ["Relay host is unavailable"] },
        category: "tooling",
        category_label: "Tooling",
        description: "Interactive shells",
        long_description: "Runs a real PTY.",
        homepage: "https://example.test/terminal",
        icon_url: "/plugin-icons/terminal.svg",
        author: "Thomas",
        source: "/app/plugins/terminal",
        links: [{ label: "Open Terminal", href: "/terminal", description: "Primary surface", kind: "surface", enabled_only: true }],
        docs: [{
          title: "Terminal",
          path: "plugins/terminal/docs/syrus_docs/terminal-reference-with-a-long-mobile-path.md",
          body: "# Terminal\n\n## Enabling\n\nEnable it.\n\n```sh\nbin/terminal-session --workflow extremely-long-workflow-identifier --workspace /very/long/path/that/should/stay/inside/the/doc/card\n```"
        }],
        metrics: [{ name: "syrus_terminal_sessions_total", type: "counter", tags: ["outcome"], comment: "Sessions", available: true }],
        routes: [{ verb: "GET", path: "/api/v1/app/terminal_sessions", controller: "api/v1/app/terminal_sessions#index" }],
        config_schema: [{ key: "hostname", label: "Hostname", type: "string" }],
        config: { hostname: "worker" },
        extension_points: [
          {
            extension_point: "sidebar_page",
            class_name: "Terminal::SidebarPages",
            availability: { status: "registered", label: "Registered" }
          }
        ],
        depends_on: [],
        optionally_depends_on: [],
        conflicts_with: [],
        dependents: []
      }
    }))

    renderDetailRoute()

    expect((await screen.findAllByRole("heading", { name: "Terminal" })).length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "Open Terminal" })).toHaveAttribute("href", "/terminal")
    expect(screen.getByText("Runs a real PTY.")).toBeInTheDocument()
    expect(screen.getByText("Health: degraded")).toBeInTheDocument()
    expect(screen.getByText("Relay host is unavailable")).toBeInTheDocument()
    expect(screen.getByText("Hostname")).toBeInTheDocument()
    expect(screen.getByText("worker")).toBeInTheDocument()
    expect(screen.getByText("plugins/terminal/docs/syrus_docs/terminal-reference-with-a-long-mobile-path.md")).toHaveClass("break-all")
    expect(screen.getByText("Enabling")).toBeInTheDocument()
    expect(screen.getByTestId("plugin-doc-card")).toHaveClass("min-w-0", "overflow-hidden")
    expect(screen.getByText(/bin\/terminal-session/).closest(".plugin-docs-prose")).toBeInTheDocument()
    expect(screen.getByText(/bin\/terminal-session/).closest(".overflow-x-auto")).toBeInTheDocument()
    expect(screen.getByText("syrus_terminal_sessions_total")).toBeInTheDocument()
    expect(screen.getByText("Sessions")).toBeInTheDocument()
    expect(screen.getByText("GET /api/v1/app/terminal_sessions")).toBeInTheDocument()
    expect(screen.getByText("Terminal::SidebarPages")).toBeInTheDocument()
    expect(screen.getByText("/app/plugins/terminal")).toBeInTheDocument()
  })

  it("renders detail empty states and hides enabled-only links while disabled", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugin: {
        name: "quiet",
        display_name: "Quiet",
        disable_blockers: [],
        version: "1.0.0",
        enabled: false,
        disableable: true,
        default_enabled: false,
        category: null,
        category_label: null,
        description: null,
        long_description: null,
        homepage: null,
        icon_url: null,
        author: null,
        source: null,
        links: [{ label: "Open Quiet", href: "/quiet", kind: "surface", enabled_only: true }],
        docs: [],
        metrics: [],
        routes: [],
        config_schema: [],
        config: {},
        extension_points: [],
        depends_on: [],
        optionally_depends_on: [],
        conflicts_with: [],
        dependents: []
      }
    }))

    renderDetailRoute("/admin/plugins/quiet")

    expect(await screen.findByRole("heading", { name: "Quiet" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Open Quiet" })).not.toBeInTheDocument()
    expect(screen.getByText("No config declared.")).toBeInTheDocument()
    expect(screen.getByText("No plugin docs found.")).toBeInTheDocument()
    expect(screen.getByText("No plugin metrics declared.")).toBeInTheDocument()
    expect(screen.getByText("No extension points registered.")).toBeInTheDocument()
    expect(screen.getByText("No routes declared.")).toBeInTheDocument()
  })

  it("shows why a disabled plugin is worth enabling, with the evidence behind it", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "python",
          display_name: "Python",
          disable_blockers: [],
          disableable: true,
          version: "1.0.0",
          enabled: false,
          description: "Python support",
          extension_points: [],
          recommendation: { reason: "Python repositories get pytest grader detail.", evidence: "acme/api, acme/tools" }
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    expect(await screen.findByText(/Python repositories get pytest grader detail/)).toBeInTheDocument()
    expect(screen.getByText("(acme/api, acme/tools)")).toBeInTheDocument()
  })

  it("says nothing extra about a plugin with no recommendation", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      plugins: [
        {
          name: "python",
          display_name: "Python",
          disable_blockers: [],
          disableable: true,
          version: "1.0.0",
          enabled: false,
          description: "Python support",
          extension_points: []
        }
      ]
    }))

    renderRoute(<AdminPlugins />)

    await screen.findByText("Python support")
    expect(screen.queryByText(/Suggested for this instance/)).not.toBeInTheDocument()
  })
})

function renderRoute(children: ReactNode, initialEntry = "/admin/plugins") {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[initialEntry]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function renderDetailRoute(initialEntry = "/admin/plugins/terminal") {
  renderRoute(
    <Routes>
      <Route path="/admin/plugins/:name" element={<AdminPluginDetail />} />
    </Routes>,
    initialEntry
  )
}
