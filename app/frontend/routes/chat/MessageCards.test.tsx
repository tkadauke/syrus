import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ChatMessage, resolveWorkspaceFileLink } from "./MessageCards"
import type { ChatPayload, ChatRenderItem } from "../../api/chats"
import { fetchSourceFileContent } from "../../api/chats"

vi.mock("../../api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/chats")>()
  return {
    ...actual,
    fetchSourceFileContent: vi.fn()
  }
})

function makePayload(): ChatPayload {
  return {
    chat: {
      id: 122,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/122",
      repository: { id: 2, slug: "tkadauke/syrus", repository_path: "/repositories/2" },
      mode: "planning",
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0
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
      app_messages_path: "/api/v1/app/chats/122/messages",
      app_message_path: "/api/v1/app/chats/122/message",
      app_rename_path: "/api/v1/app/chats/122/rename",
      app_clear_path: "/api/v1/app/chats/122/messages",
      app_branch_path: "/api/v1/app/chats/122/branch",
      app_share_path: "/api/v1/app/chats/122/share",
      app_enqueue_message_path: "/api/v1/app/chats/122/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/122/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/122/stop",
      app_daemon_connection_path: "/api/v1/app/chats/122/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/122/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/122/bookmarks",
      app_attachments_path: "/api/v1/app/chats/122/attachments",
      app_video_walkthroughs_path: "/api/v1/app/chats/122/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/122/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/122/scratchpad_items/reorder",
      app_source_file_path: "/api/v1/app/chats/122/source_file",
      app_source_file_raw_path: "/api/v1/app/chats/122/source_file/raw"
    },
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false
  } as ChatPayload
}

function assistantMessage(text: string): Extract<ChatRenderItem, { type: "message" }> {
  return {
    type: "message",
    id: 5,
    role: "assistant",
    text,
    bookmarkable: true,
    attachments: []
  }
}

function renderMessage(text: string, payload = makePayload()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatMessage
          item={assistantMessage(text)}
          payload={payload}
          pendingActionIds={new Set()}
          prefix=""
          queryKey={["chats", "122", ""] as const}
          onNotice={() => {}}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

beforeEach(() => {
  vi.mocked(fetchSourceFileContent).mockReset()
})

describe("chat workspace source links", () => {
  it("resolves same-origin and absolute workspace file links for the current chat and repo only", () => {
    const payload = makePayload()
    expect(resolveWorkspaceFileLink(`${window.location.origin}/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/app/services/system_alerts.rb:62`, payload)).toEqual({
      path: "app/services/system_alerts.rb",
      line: 62
    })
    expect(resolveWorkspaceFileLink("/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/README.md", payload)).toEqual({
      path: "README.md",
      line: null
    })
    expect(resolveWorkspaceFileLink("/syrus-home/.syrus/chat-workspaces/999/repositories/tkadauke/syrus/README.md", payload)).toBeNull()
    expect(resolveWorkspaceFileLink("/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/other/README.md", payload)).toBeNull()
    expect(resolveWorkspaceFileLink("/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/../secret.txt", payload)).toBeNull()
  })

  it("opens recognized workspace links in a source preview modal instead of navigating", async () => {
    vi.mocked(fetchSourceFileContent).mockResolvedValue({ path: "app/models/user.rb", content: "class User\nend\n", binary: false, too_large: false })
    renderMessage("[user](/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/app/models/user.rb:2)")

    fireEvent.click(screen.getByRole("link", { name: "user" }))

    expect(await screen.findByRole("dialog", { name: /source preview/i })).toBeInTheDocument()
    expect(fetchSourceFileContent).toHaveBeenCalledWith("/api/v1/app/chats/122/source_file", "app/models/user.rb")
    expect(screen.getByText("app/models/user.rb")).toBeInTheDocument()
    expect(screen.getByText("Line 2")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/chats/122/source_file/raw?path=app%2Fmodels%2Fuser.rb")
    expect(await screen.findByTestId("source-preview-code")).toBeInTheDocument()
    expect(document.querySelector("[data-source-line='2']")).toHaveClass("bg-yellow-100")
  })

  it("renders markdown files as markdown by default and offers a source fallback", async () => {
    vi.mocked(fetchSourceFileContent).mockResolvedValue({ path: "README.md", content: "# Title\n\nHello", binary: false, too_large: false })
    renderMessage("[readme](/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/README.md)")

    fireEvent.click(screen.getByRole("link", { name: "readme" }))

    expect(await screen.findByRole("heading", { name: "Title" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Source" }))
    expect(await screen.findByTestId("source-preview-code")).toHaveTextContent("Title")
  })

  it("keeps ordinary markdown links unchanged", () => {
    renderMessage("[dashboard](/app) and [site](https://example.com)")

    expect(screen.getByRole("link", { name: "dashboard" })).toHaveAttribute("href", "/app")
    expect(screen.getByRole("link", { name: "site" })).toHaveAttribute("href", "https://example.com")
  })
})
