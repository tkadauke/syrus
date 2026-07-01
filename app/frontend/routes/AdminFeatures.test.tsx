import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { AppChromeV2 } from "./AppChromeV2"
import { AdminFeatures } from "./AdminFeatures"
import type { BootstrapPayload } from "../api/bootstrap"

describe("AdminFeatures", () => {
  it("renders features grouped by category", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(featuresPayload()))

    renderRoute(<AdminFeatures />)

    const navigation = await screen.findByRole("region", { name: "Navigation" })
    expect(within(navigation).getByRole("heading", { name: "Navigation" })).toBeInTheDocument()
    expect(within(navigation).getByText("New dashboard")).toBeInTheDocument()
    expect(within(navigation).getByText("new_dashboard")).toBeInTheDocument()
    expect(within(navigation).getByText("Use the redesigned dashboard.")).toBeInTheDocument()

    const operations = screen.getByRole("region", { name: "Operations" })
    expect(within(operations).getByText("Fast queue")).toBeInTheDocument()
  })

  it("optimistically toggles a feature and keeps the API result", async () => {
    let resolvePatch: (response: Response) => void = () => undefined
    const patchPromise = new Promise<Response>((resolve) => {
      resolvePatch = resolve
    })
    let featuresLoaded = false
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/features/new_dashboard" && init?.method === "PATCH") {
        return patchPromise
      }

      if (!featuresLoaded) {
        featuresLoaded = true
        return Promise.resolve(jsonResponse(featuresPayload()))
      }

      return Promise.resolve(jsonResponse(featuresPayload({
        categories: [
          {
            category: "Navigation",
            features: [
              {
                slug: "new_dashboard",
                category: "Navigation",
                name: "New dashboard",
                description: "Use the redesigned dashboard.",
                enabled: true
              }
            ]
          }
        ]
      })))
    })

    renderRoute(<AdminFeatures />)

    const toggle = await screen.findByRole("checkbox", { name: "Disabled" })
    fireEvent.click(toggle)
    await waitFor(() => expect(toggle).toBeChecked())

    resolvePatch(jsonResponse({
      feature: {
        slug: "new_dashboard",
        category: "Navigation",
        name: "New dashboard",
        description: "Use the redesigned dashboard.",
        enabled: true
      }
    }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/features/new_dashboard", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ feature: { enabled: true } })
      }))
    })
    expect(await screen.findByRole("checkbox", { name: "Enabled" })).toBeChecked()
  })

  it("rolls back optimistic changes when a toggle fails", async () => {
    let resolvePatch: (response: Response) => void = () => undefined
    const patchPromise = new Promise<Response>((resolve) => {
      resolvePatch = resolve
    })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/features/new_dashboard" && init?.method === "PATCH") {
        return patchPromise
      }

      return Promise.resolve(jsonResponse(featuresPayload()))
    })

    renderRoute(<AdminFeatures />)

    const toggle = await screen.findByRole("checkbox", { name: "Disabled" })
    fireEvent.click(toggle)

    await waitFor(() => expect(toggle).toBeChecked())
    resolvePatch(jsonResponse({ error: { message: "Feature could not be updated." } }, 422))
    expect(await screen.findByRole("alert")).toHaveTextContent("Feature could not be updated.")
    expect(await screen.findByRole("checkbox", { name: "Disabled" })).not.toBeChecked()
  })

  it("shows an empty state and omits the nav item when no features are declared", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats") return Promise.resolve(jsonResponse({ chats: [] }))

      return Promise.resolve(jsonResponse({ categories: [] }))
    })

    renderRoute(
      <AppChromeV2 initialBootstrap={bootstrapPayload({ feature_flags: {} })}>
        <AdminFeatures />
      </AppChromeV2>,
      "/app-shell/admin/features"
    )

    expect(await screen.findByText("No features declared")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Features" })).not.toBeInTheDocument()
  })
})

function renderRoute(children: ReactNode, path = "/app-shell/admin/features") {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function featuresPayload(overrides: Partial<{ categories: Array<{ category: string; features: Array<Record<string, unknown>> }> }> = {}) {
  return {
    categories: [
      {
        category: "Navigation",
        features: [
          {
            slug: "new_dashboard",
            category: "Navigation",
            name: "New dashboard",
            description: "Use the redesigned dashboard.",
            enabled: false
          }
        ]
      },
      {
        category: "Operations",
        features: [
          {
            slug: "fast_queue",
            category: "Operations",
            name: "Fast queue",
            description: null,
            enabled: true
          }
        ]
      }
    ],
    ...overrides
  }
}

function bootstrapPayload(overrides: Partial<BootstrapPayload> = {}): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "operator@example.com",
      name: "Operator",
      first_name: null,
      last_name: null,
      display_name: "Operator",
      admin: true,
      role: "developer",
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      chat_provider: null,
      agent_max_turns: 200,
      theme: "light",
    },
    team_user_count: 1,
    app: {
      revision: "dev",
      revision_url: null
    },
    setup_status: null,
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    navigation: {
      default_chat_path: "/dashboard"
    },
    setup: null,
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    feature_flags: { new_dashboard: false },
    ...overrides
  }
}
