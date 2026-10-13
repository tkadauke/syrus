import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { ChatPayload } from "../../api/chats"
import { useWalkthroughRecorder } from "../../components/WalkthroughRecorder"
import { Compose } from "./Compose"

vi.mock("../../components/WalkthroughRecorder", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../components/WalkthroughRecorder")>()
  return {
    ...actual,
    useWalkthroughRecorder: vi.fn()
  }
})

function makePayload(): ChatPayload {
  return {
    chat: {
      id: 1,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/1",
      repository: null,
      mode: "planning",
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0,
      chat_provider_options: []
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
    documents_in_scope: [],
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
      app_video_walkthroughs_path: "/api/v1/app/chats/1/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/1/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/1/scratchpad_items/reorder"
    },
    gemini_configured: true,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false
  }
}

function renderCompose(payload = makePayload()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <Compose
          chatId="1"
          commandHandlers={{ openBookmarks: vi.fn(), openSettings: vi.fn() }}
          floating={false}
          onNotice={() => {}}
          payload={payload}
          prefix=""
          queryKey={["chats", "1", ""]}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("Compose walkthrough recorder errors", () => {
  it("renders the recorder error in the composer attachment error slot", async () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: {
        phase: "error",
        message: "This browser cannot record the screen. Drag a video file in instead."
      },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })

    renderCompose()

    expect(await screen.findByText("This browser cannot record the screen. Drag a video file in instead.")).toBeInTheDocument()
  })
})
