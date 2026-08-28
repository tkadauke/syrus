import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { Attachments } from "./Attachments"
import type { ChatPayload } from "../../api/chats"

function makePayload(overrides: Partial<ChatPayload> = {}): ChatPayload {
  return {
    chat: {
      id: 1,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/1",
      repository: { id: 2, slug: "acme/repo", repository_path: "/repositories/2" },
      mode: "planning",
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0,
      confirmed_proposal_count: 0
    },
    chat_available: true,
    turn_in_flight: false,
    agent_busy: false,
    switching_provider: false,
    has_more_older: false,
    messages: [],
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    scratchpad_items: [],
    video_walkthroughs: [],
    preview_panels: [],
    workspace_tabs: [],
    attachment_groups: {
      repositories: [{ id: 2, label: "acme/repo", app_detach_path: "/api/v1/app/chats/1/attachments/repository/2" }],
      epics: [],
      jobs: [],
      documents: []
    },
    documents_in_scope: [],
    attachment_results: [],
    whiteboard: { version: 1, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/1/messages",
      app_message_path: "/api/v1/app/chats/1/message",
      app_rename_path: "/api/v1/app/chats/1/rename",
      app_clear_path: "/api/v1/app/chats/1/messages",
      app_branch_path: "/api/v1/app/chats/1/branch",
      app_share_path: "/api/v1/app/chats/1/share",
      app_enqueue_message_path: "/api/v1/app/chats/1/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/1/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/1/stop",
      app_daemon_connection_path: "/api/v1/app/chats/1/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/1/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/1/bookmarks",
      app_attachments_path: "/api/v1/app/chats/1/attachments",
      app_video_walkthroughs_path: "/api/v1/app/chats/1/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/1/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/1/scratchpad_items/reorder"
    },
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false,
    ...overrides
  } as ChatPayload
}

function renderAttachments(payload: ChatPayload) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <Attachments onNotice={() => {}} payload={payload} prefix="" queryKey={["chats", "1", ""] as const} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("Attachments", () => {
  it("left-justifies attachment row buttons instead of centering their label", () => {
    renderAttachments(makePayload())
    const row = screen.getByRole("button", { name: "acme/repo" })
    expect(row.className).toMatch(/(?:^|\s)!justify-start(?:\s|$)/)
  })
})
