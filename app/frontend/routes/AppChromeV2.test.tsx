import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { AppChromeV2 } from "./AppChromeV2"
import { createChat } from "../api/chats"
import type { BootstrapPayload } from "../api/bootstrap"

vi.mock("../api/chats", () => ({
  createChat: vi.fn(),
  fetchChats: vi.fn(async () => ({ groups: [] })),
  fetchMoreChatsForGroup: vi.fn(async () => ({ chats: [], has_more: false })),
  hideChat: vi.fn()
}))

describe("AppChromeV2", () => {
  it("navigates to the new chat route without creating a chat", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], {
      groups: [
        {
          key: "general",
          label: "General",
          repository_id: null,
          chats: [
            {
              id: 12,
              title: null,
              title_pending: true,
              pinned_context: null,
              chat_path: "/chats/12",
              repository: null,
              stop_requested_at: null,
              cumulative_input_tokens: 0,
              cumulative_output_tokens: 0,
              cumulative_cost_usd: 0,
              current: false,
              last_message_at: null,
              unread: false,
              created_at: "2026-06-01T00:00:00Z",
              updated_at: "2026-06-01T00:00:00Z"
            }
          ],
          has_more: false
        }
      ],
      repositories: []
    })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs"]}>
          <Routes>
            <Route
              element={(
                <AppChromeV2 initialBootstrap={bootstrapPayload()}>
                  <LocationProbe />
                </AppChromeV2>
              )}
              path="*"
            />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/12")
    })
    expect(createChat).not.toHaveBeenCalled()
  })

  it("does nothing when already on the new chat route", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/new"]}>
          <Routes>
            <Route
              element={(
                <AppChromeV2 initialBootstrap={bootstrapPayload()}>
                  <LocationProbe />
                </AppChromeV2>
              )}
              path="*"
            />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/new")
    expect(createChat).not.toHaveBeenCalled()
  })
})

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function bootstrapPayload(): BootstrapPayload {
  return {
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
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    navigation: {
      default_chat_path: "/chats/new"
    },
    setup: {
      complete: true,
      chat_started: true,
      next_step: "complete",
      progress: {
        completed: 4,
        total: 4,
        steps: []
      }
    },
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    setup_status: null,
    feature_flags: {}
  } as unknown as BootstrapPayload
}
