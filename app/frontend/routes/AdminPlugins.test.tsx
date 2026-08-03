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
          name: "syrus-codex-agent",
          version: "1.2.3",
          enabled: true,
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
    expect(within(list).getByRole("heading", { name: "syrus-codex-agent" })).toBeInTheDocument()
    expect(within(list).getByText("1.2.3")).toBeInTheDocument()
    expect(within(list).getByText("AgentProviders::Codex")).toBeInTheDocument()
    expect(within(list).getByText("Available")).toBeInTheDocument()
    expect(within(list).getByText("OpenAI")).toBeInTheDocument()
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
