import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { ChatSettingsDialog, ChatWorkspacePanel } from "./WorkspacePanels"
import type { ChatPayload } from "../../api/chats"
import { fetchCodingCommits, fetchCodingDiff, fetchCodingFileContent, fetchCodingFileTree } from "../../api/chats"

vi.mock("../../api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/chats")>()
  return {
    ...actual,
    fetchCodingCommits: vi.fn(),
    fetchCodingDiff: vi.fn(),
    fetchCodingFileContent: vi.fn(),
    fetchCodingFileTree: vi.fn()
  }
})

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
      mode: "planning",
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
      app_scheduled_messages_path: "/api/v1/app/chats/1/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/1/stop",
      app_daemon_connection_path: "/api/v1/app/chats/1/daemon_connection",
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

function makeCodingPayload(overrides: Partial<ChatPayload> = {}): ChatPayload {
  const payload = makePayload({
    mode: "coding",
    coding_checkout_branch: "syrus/chat-1"
  })
  return {
    ...payload,
    ...overrides,
    coding_mode_enabled: true,
    paths: {
      ...payload.paths,
      app_coding_files_path: "/api/v1/app/chats/1/coding_files",
      app_coding_commits_path: "/api/v1/app/chats/1/coding_commits",
      app_coding_file_path: "/api/v1/app/chats/1/coding_file",
      app_coding_diff_path: "/api/v1/app/chats/1/coding_diff",
      ...overrides.paths
    }
  }
}

function renderWorkspacePanel(payload: ChatPayload, options: {
  activeTab?: "whiteboard" | "context" | "media" | "files" | "diff" | "jobs"
  onSelectTab?: (tab: "whiteboard" | "context" | "media" | "files" | "diff" | "jobs") => void
} = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatWorkspacePanel
          activeTab={options.activeTab ?? "files"}
          fullscreen={false}
          onSelectTab={options.onSelectTab ?? (() => {})}
          onToggleWhiteboardFullscreen={() => {}}
          payload={payload}
          prefix=""
          queryKey={["chats", "1", ""] as const}
          onBookmarkSelect={() => {}}
          onNotice={() => {}}
        />
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

  it("shows the fallback provider when no effective provider label is set", () => {
    const payload = makePayload({
      effective_chat_provider: "provider_a",
      effective_chat_provider_label: undefined
    })
    renderDialog(payload)
    expect(screen.getByText("provider_a")).toBeInTheDocument()
    expect(screen.queryByLabelText("Chat provider")).not.toBeInTheDocument()
  })

  it("shows the effective provider label when one is set", () => {
    const payload = makePayload({
      effective_chat_provider_label: "Provider A"
    })
    renderDialog(payload)
    expect(screen.getByText("Provider A")).toBeInTheDocument()
    expect(screen.queryByLabelText("Chat provider")).not.toBeInTheDocument()
  })
})

describe("ChatWorkspacePanel coding files", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(fetchCodingCommits).mockResolvedValue({ commits: [] })
  })

  it("renders file content with highlighted spans and line numbers", async () => {
    vi.mocked(fetchCodingFileTree).mockResolvedValue({ checkout_branch: "syrus/chat-1", files: ["app/example.ts"] })
    vi.mocked(fetchCodingFileContent).mockResolvedValue({
      binary: false,
      content: "const answer = 42\n",
      path: "app/example.ts",
      too_large: false
    })

    const { container } = renderWorkspacePanel(makeCodingPayload())
    fireEvent.click(await screen.findByRole("button", { name: /app/ }))
    fireEvent.click(await screen.findByRole("button", { name: "example.ts" }))

    expect(await screen.findByTestId("coding-source-viewer")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
    const keyword = screen.getByText("const")
    expect(keyword.tagName).toBe("SPAN")
    expect(keyword).toHaveClass("font-semibold")
    expect(container.querySelector("pre code")).not.toBeInTheDocument()
  })

  it("shows a file list and renders only the selected file diff", async () => {
    vi.mocked(fetchCodingFileTree).mockResolvedValue({ checkout_branch: "syrus/chat-1", files: [] })
    vi.mocked(fetchCodingDiff).mockResolvedValue({
      checkout_branch: "syrus/chat-1",
      mode: "cumulative",
      diff: [
        "diff --git a/app/a.ts b/app/a.ts",
        "index 1111111..2222222 100644",
        "--- a/app/a.ts",
        "+++ b/app/a.ts",
        "@@ -1 +1 @@",
        "-export const a = 1",
        "+export const a = 2",
        "diff --git a/app/b.ts b/app/b.ts",
        "new file mode 100644",
        "index 0000000..3333333",
        "--- /dev/null",
        "+++ b/app/b.ts",
        "@@ -0,0 +1 @@",
        "+export const b = 2"
      ].join("\n")
    })

    renderWorkspacePanel(makeCodingPayload())
    fireEvent.click(screen.getByRole("button", { name: "Diff" }))

    expect(await screen.findByRole("button", { name: /app\/a\.ts/ })).toBeInTheDocument()
    const secondFile = screen.getByRole("button", { name: /app\/b\.ts/ })
    expect(secondFile).toHaveTextContent("A")

    fireEvent.click(secondFile)

    expect(await screen.findByTestId("coding-diff-viewer")).toBeInTheDocument()
    expect(screen.getByText("export const b = 2")).toBeInTheDocument()
    expect(screen.queryByText("export const a = 2")).not.toBeInTheDocument()
  })

  it("renders a commit selector and passes ref to file and diff fetches", async () => {
    const sha = "abc1234abc1234abc1234abc1234abc1234abc12"
    vi.mocked(fetchCodingCommits).mockResolvedValue({
      commits: [{ sha, date: "2026-07-30 12:00:00 +0000", message: "Add commit browser" }]
    })
    vi.mocked(fetchCodingFileTree).mockResolvedValue({ checkout_branch: "syrus/chat-1", files: ["README.md"] })
    vi.mocked(fetchCodingFileContent).mockResolvedValue({
      binary: false,
      content: "# Old\n",
      path: "README.md",
      too_large: false
    })
    vi.mocked(fetchCodingDiff).mockResolvedValue({
      checkout_branch: "syrus/chat-1",
      mode: "cumulative",
      diff: "diff --git a/README.md b/README.md\n@@ -1 +1 @@\n-# Old\n+# New\n"
    })

    renderWorkspacePanel(makeCodingPayload())

    await screen.findByRole("option", { name: /Add commit browser/ })
    fireEvent.change(screen.getByLabelText("Commit"), { target: { value: sha } })

    await waitFor(() => {
      expect(fetchCodingFileTree).toHaveBeenCalledWith("/api/v1/app/chats/1/coding_files", sha)
    })

    fireEvent.click(await screen.findByRole("button", { name: "README.md" }))

    await waitFor(() => {
      expect(fetchCodingFileContent).toHaveBeenCalledWith("/api/v1/app/chats/1/coding_file", "README.md", sha)
    })

    fireEvent.click(screen.getByRole("button", { name: "Diff" }))

    await waitFor(() => {
      expect(fetchCodingDiff).toHaveBeenCalledWith("/api/v1/app/chats/1/coding_diff", "cumulative", sha)
    })
  })

  it("deselects the files panel when the coding checkout disappears", async () => {
    vi.mocked(fetchCodingFileTree).mockResolvedValue({ checkout_branch: "syrus/chat-1", files: [] })
    const onSelectTab = vi.fn()
    const { rerender } = renderWorkspacePanel(makeCodingPayload(), { onSelectTab })

    const withoutCheckout = makePayload({ mode: "planning", coding_checkout_branch: null })
    rerender(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <ChatWorkspacePanel
            activeTab="files"
            fullscreen={false}
            onSelectTab={onSelectTab}
            onToggleWhiteboardFullscreen={() => {}}
            payload={withoutCheckout}
            prefix=""
            queryKey={["chats", "1", ""] as const}
            onBookmarkSelect={() => {}}
            onNotice={() => {}}
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await waitFor(() => expect(onSelectTab).toHaveBeenCalledWith("context"))
  })
})
