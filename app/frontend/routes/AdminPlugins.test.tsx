import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"

const reloadMock = vi.hoisted(() => vi.fn())

vi.mock("../lib/pageReload", () => ({
  reloadPage: reloadMock
}))

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

  it("reloads the page after enabling a plugin", async () => {
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

    renderRoute(<AdminPlugins />)

    fireEvent.click(await screen.findByRole("button", { name: "Enable" }))

    await waitFor(() => expect(reloadMock).toHaveBeenCalled())
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
