import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { createChat, fetchChats } from "../api/chats"
import { ChatNewRoute } from "./ChatNew"

vi.mock("../api/chats", () => ({
  createChat: vi.fn(),
  fetchChats: vi.fn()
}))

describe("ChatNewRoute", () => {
  beforeEach(() => {
    vi.mocked(createChat).mockReset()
    vi.mocked(fetchChats).mockReset()
  })

  it("reuses an existing unstarted chat", async () => {
    vi.mocked(fetchChats).mockResolvedValue({
      groups: [
        {
          key: "general",
          label: "General",
          repository_id: null,
          chats: [chatNavRecord({ id: 12, last_message_at: null })],
          has_more: false
        }
      ],
      repositories: []
    })

    renderNewChatRoute()

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/12")
    })
    expect(createChat).not.toHaveBeenCalled()
  })

  it("creates an unstarted chat when none exists", async () => {
    vi.mocked(fetchChats).mockResolvedValue({ groups: [], repositories: [] })
    vi.mocked(createChat).mockResolvedValue({
      message: "Chat created.",
      redirect_to: "/chats/18",
      chat: chatRecord({ id: 18 })
    })

    renderNewChatRoute()

    await waitFor(() => {
      expect(createChat).toHaveBeenCalledWith({ repositoryId: "", text: "" })
    })
    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/18")
    })
  })
})

function renderNewChatRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/new"]}>
        <Routes>
          <Route element={<ChatNewRoute />} path="/app-shell/chats/new" />
          <Route element={<LocationProbe />} path="*" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function chatRecord({ id }: { id: number }) {
  return {
    id,
    title: null,
    title_pending: true,
    pinned_context: null,
    chat_path: `/chats/${id}`,
    repository: null,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    pending_proposal_count: 0
  }
}

function chatNavRecord({ id, last_message_at }: { id: number; last_message_at: string | null }) {
  return {
    ...chatRecord({ id }),
    current: false,
    last_message_at,
    unread: false,
    pending_proposal_count: 0,
    created_at: "2026-06-01T00:00:00Z",
    updated_at: "2026-06-01T00:00:00Z"
  }
}
