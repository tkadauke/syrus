import { jsonResponse } from "../testSupport"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { actionCable } from "../test/app/appMocks"
import { bootstrapPayload } from "../test/app/bootstrap"
import { dashboardJobItem, dashboardPayload, expectDashboardFetch } from "../test/app/dashboardPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App", () => {
  installAppTestLifecycle()

  it("loads bootstrap data into the SPA shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            current_user: {
              id: 1,
              email_address: "operator@example.com",
              name: "Operator",
              first_name: null,
              last_name: null,
              display_name: "Operator",
              admin: true,
              scheduling_paused: false,
              landing_paused: false,
              agent_provider: "claude",
              agent_max_turns: 200,
              theme: "light"
            },
            team_user_count: 1,
            app: {
              revision: "dev",
              revision_url: null
            },
            navigation: {
              default_chat_path: "/dashboard"
            },
            csrf_token: "csrf-token",
            feature_flags: {}
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        {/* Bare /app-shell now routes to the dashboard like "/"; the debug
            shell only serves unregistered paths. */}
        <MemoryRouter initialEntries={["/app-shell/debug"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Syrus SPA" })).toBeInTheDocument()
    const accountNav = await screen.findByRole("navigation", { name: "Account" })
    expect(within(accountNav).getByRole("button", { name: "operator@example.com" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByRole("link", { name: "Settings" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Sign out" })).not.toBeInTheDocument()
    fireEvent.click(within(accountNav).getByRole("button", { name: "operator@example.com" }))
    expect(within(accountNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/profile")
    expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
    expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("title", "Curia — The Roman Senate house")
    expect(within(accountNav).getByRole("button", { name: "Sign out" })).toBeInTheDocument()
    expect(screen.getAllByText("dev").length).toBeGreaterThan(0)
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/bootstrap",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
    expect(actionCable.createSubscription).toHaveBeenCalledWith({ channel: "AppUserChannel" }, expect.objectContaining({ received: expect.any(Function) }))
  })

  it("does not show the old persistent connection-lost toast when ActionCable disconnects", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/session/new"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await waitFor(() => expect(actionCable.createSubscription).toHaveBeenCalled())
      const createSubscriptionMock = actionCable.createSubscription as unknown as {
        mock: { calls: Array<[unknown, { connected: () => void; disconnected: () => void }]> }
      }
      const callbacks = createSubscriptionMock.mock.calls[0][1]
      vi.useFakeTimers()
      act(() => callbacks.connected())
      act(() => callbacks.disconnected())
      act(() => vi.advanceTimersByTime(4000))

      expect(screen.queryByText("Connection lost — updates paused")).not.toBeInTheDocument()
      expect(screen.getAllByRole("button", { name: "Reconnecting" }).length).toBeGreaterThan(0)
    } finally {
      vi.useRealTimers()
      script.remove()
    }
  })

  it("routes bare /app-shell to the dashboard for signed-in users", async () => {
    // Before RootRoute covered /app-shell, the bare desktop entry path fell
    // through to the debug catch-all instead of behaving like "/".
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/dashboard")) {
        return new Response(JSON.stringify(dashboardPayload({ subject: "job", view: "list", items: [dashboardJobItem()] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      }

      return new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Dashboard" })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus SPA" })).not.toBeInTheDocument()
      expectDashboardFetch(fetchSpy, "/api/v1/app/dashboard", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      script.remove()
    }
  })

  it("routes Plugin Services through the stable admin route", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/admin/plugin_services")) {
        return jsonResponse({ mode: "external", manageable: false, manager_error: null, services: [], volumes: [] })
      }
      if (path.startsWith("/api/v1/app/sidebar_pages") || path.startsWith("/api/v1/app/admin/plugin_pages")) {
        return jsonResponse({ pages: [] })
      }
      return jsonResponse({})
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/plugin_services"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("heading", { level: 1, name: "Plugin Services" })).toBeInTheDocument()
      expect(screen.queryByRole("heading", { level: 1, name: "Page unavailable" })).not.toBeInTheDocument()
      expect(await screen.findByText("No enabled plugin runs a service.")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/plugin_services", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      script.remove()
    }
  })

  it("routes signed-in root to the dashboard instead of the public landing page", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "job",
              view: "list",
              items: [dashboardJobItem()]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Dashboard" })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus public landing" })).not.toBeInTheDocument()
      expectDashboardFetch(fetchSpy, "/api/v1/app/dashboard", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })
})
