import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { ChatSettingsDialog } from "./WorkspacePanels"
import type { ChatPayload } from "../../api/chats"

function makePayload(overrides: Partial<ChatPayload["chat"]> = {}): ChatPayload {
  return {
    chat: {
      id: 1,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/1",
      repository: { id: 2, slug: "acme/repo", repository_path: "/repositories/2" },
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0,
      confirmed_proposal_count: 0,
      ...overrides
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
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
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
      app_stop_path: "/api/v1/app/chats/1/stop",
      app_daemon_connection_path: "/api/v1/app/chats/1/daemon_connection",
      app_bookmarks_path: "/api/v1/app/chats/1/bookmarks",
      app_attachments_path: "/api/v1/app/chats/1/attachments",
      app_video_walkthroughs_path: "/api/v1/app/chats/1/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/1/whiteboard",
      app_switch_provider_path: "/api/v1/app/chats/1/switch_provider",
      app_scratchpad_reorder_path: "/api/v1/app/chats/1/scratchpad_items/reorder"
    },
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false
  } as ChatPayload
}

function renderDialog(payload: ChatPayload, onClose = () => {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatSettingsDialog onClose={onClose} payload={payload} prefix="" queryKey={["chats", "1", ""] as const} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ChatSettingsDialog", () => {
  it("renders the Repository settings link", () => {
    renderDialog(makePayload())
    expect(screen.getByRole("link", { name: "Repository settings" })).toBeInTheDocument()
  })

  it("renders the Chat credentials link", () => {
    renderDialog(makePayload())
    expect(screen.getByRole("link", { name: "Chat credentials" })).toBeInTheDocument()
  })

  it("shows 'Effective: Default' when no effective provider label is set", () => {
    const payload = makePayload({
      chat_provider_options: [
        { value: "provider_a", label: "Provider A", configured: true, effective_provider: "provider_a", effective_label: "Provider A" },
        { value: "provider_b", label: "Provider B", configured: true, effective_provider: "provider_b", effective_label: "Provider B" }
      ]
    })
    renderDialog(payload)
    expect(screen.getByText("Effective: Default")).toBeInTheDocument()
  })

  it("shows the effective provider label when one is set", () => {
    const payload = makePayload({
      chat_provider_options: [
        { value: "provider_a", label: "Provider A", configured: true, effective_provider: "provider_a", effective_label: "Provider A" },
        { value: "provider_b", label: "Provider B", configured: true, effective_provider: "provider_b", effective_label: "Provider B" }
      ],
      effective_chat_provider_label: "Provider A"
    })
    renderDialog(payload)
    expect(screen.getByText("Effective: Provider A")).toBeInTheDocument()
  })
})
