import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { ChatSettingsDialog, ChatWorkspacePanel } from "./WorkspacePanels"
import type { ChatPayload } from "../../api/chats"
import { closeChatPreviewPanel, fetchChatMedia, fetchChatMessagePins, fetchCodingCommits, fetchCodingDiff, fetchCodingFileContent, fetchCodingFileTree, fetchWhiteboardSnapshots, switchChatProvider } from "../../api/chats"
import type { WorkspaceTab } from "./workspaceTabs"

vi.mock("../../api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/chats")>()
  return {
    ...actual,
    closeChatPreviewPanel: vi.fn(),
    fetchChatMedia: vi.fn(),
    fetchChatMessagePins: vi.fn(),
    fetchCodingCommits: vi.fn(),
    fetchCodingDiff: vi.fn(),
    fetchCodingFileContent: vi.fn(),
    fetchCodingFileTree: vi.fn(),
    fetchWhiteboardSnapshots: vi.fn(),
    switchChatProvider: vi.fn()
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
    preview_panels: [],
    workspace_tabs: [],
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
  activeTab?: WorkspaceTab
  onSelectTab?: (tab: WorkspaceTab) => void
  onBookmarkSelect?: (messageId: number) => void
} = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatWorkspacePanel
          activeTab={options.activeTab ?? "files"}
          onSelectTab={options.onSelectTab ?? (() => {})}
          payload={payload}
          prefix=""
          queryKey={["chats", "1", ""] as const}
          onBookmarkSelect={options.onBookmarkSelect ?? (() => {})}
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

  it("shows the fallback provider when no effective provider label is set and no switch is available", () => {
    const payload = makePayload({
      effective_chat_provider: "provider_a",
      effective_chat_provider_label: undefined
    })
    renderDialog(payload)
    expect(screen.getByText("provider_a")).toBeInTheDocument()
    expect(screen.queryByLabelText("Chat provider")).not.toBeInTheDocument()
  })

  it("shows the effective provider label when one is set and no switch is available", () => {
    const payload = makePayload({
      effective_chat_provider_label: "Provider A"
    })
    renderDialog(payload)
    expect(screen.getByText("Provider A")).toBeInTheDocument()
    expect(screen.queryByLabelText("Chat provider")).not.toBeInTheDocument()
  })

  it("renders configured explicit provider options and switches through the switch endpoint", async () => {
    vi.mocked(switchChatProvider).mockResolvedValue({ message: "Switching to codex." })
    const payload = makePayload({
      chat_provider: "claude",
      effective_chat_provider: "claude",
      effective_chat_provider_label: "Claude",
      chat_provider_options: [
        { value: "claude", label: "Claude", configured: true, effective_provider: "claude", effective_label: "Claude" },
        { value: "codex", label: "Codex", configured: true, effective_provider: "codex", effective_label: "Codex" }
      ]
    })

    renderDialog(payload)
    fireEvent.change(screen.getByLabelText("Chat provider"), { target: { value: "codex" } })

    await waitFor(() => expect(switchChatProvider).toHaveBeenCalledWith("/api/v1/app/chats/1/switch_provider", "codex"))
  })

  it("renders the selected provider's icon at the expected size", () => {
    const payload = makePayload({
      chat_provider: "claude",
      effective_chat_provider: "claude",
      effective_chat_provider_label: "Claude",
      chat_provider_options: [
        { value: "claude", label: "Claude", configured: true, effective_provider: "claude", effective_label: "Claude" },
        { value: "codex", label: "Codex", configured: true, effective_provider: "codex", effective_label: "Codex" }
      ]
    })

    renderDialog(payload)

    const select = screen.getByLabelText("Chat provider")
    const icon = select.parentElement?.querySelector('img[src="/plugin-icons/claude_agent.svg"]')
    expect(icon).toBeInTheDocument()
    expect(icon).toHaveClass("h-4", "w-4")
  })
})

describe("ChatWorkspacePanel context attachments", () => {
  it("renders repository, epic, and job attachment groups for ordinary chats", () => {
    renderWorkspacePanel(makePayload(), { activeTab: "context" })

    const workspace = screen.getByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).getByText("Repos")).toBeInTheDocument()
    expect(within(workspace).getByText("Epics")).toBeInTheDocument()
    expect(within(workspace).getByText("Jobs")).toBeInTheDocument()
    expect(within(workspace).getByText("Documents")).toBeInTheDocument()
    expect(within(workspace).getAllByText("None")).toHaveLength(4)
  })

  it("hides repository, epic, and job attachment groups for Supervisor chats", () => {
    renderWorkspacePanel(makePayload({
      repository: null,
      system_kind: "supervisor",
      title: "Supervisor"
    }), { activeTab: "context" })

    const workspace = screen.getByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).queryByText("Repos")).not.toBeInTheDocument()
    expect(within(workspace).queryByText("Epics")).not.toBeInTheDocument()
    expect(within(workspace).queryByText("Jobs")).not.toBeInTheDocument()
    expect(within(workspace).getByText("Documents")).toBeInTheDocument()
    expect(within(workspace).getByText("In-scope documents")).toBeInTheDocument()
    expect(within(workspace).getAllByText("None")).toHaveLength(1)
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
            onSelectTab={onSelectTab}
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

describe("MediaGallery busy states", () => {
  beforeEach(() => {
    vi.mocked(fetchWhiteboardSnapshots).mockResolvedValue({ whiteboard_snapshots: [] })
    vi.mocked(fetchChatMedia).mockResolvedValue({ snapshots: [], chat_images: [], typed_artifacts: [], whiteboard_has_unsaved_content: false })
  })

  it("does not show the canvas/drawing warning when agent_busy is true", () => {
    const payload = { ...makePayload(), agent_busy: true }
    renderWorkspacePanel(payload, { activeTab: "media" })

    expect(screen.queryByText(/canvas is busy/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/wait for drawing to finish/i)).not.toBeInTheDocument()
  })

  it("shows a neutral chat-busy warning (not a canvas warning) when agent_busy is true", () => {
    const payload = { ...makePayload(), agent_busy: true }
    renderWorkspacePanel(payload, { activeTab: "media" })

    expect(screen.getByText(/chat is busy/i)).toBeInTheDocument()
    expect(screen.queryByText(/canvas is busy/i)).not.toBeInTheDocument()
  })

  it("shows no busy warning when agent_busy is false", () => {
    const payload = { ...makePayload(), agent_busy: false }
    renderWorkspacePanel(payload, { activeTab: "media" })

    expect(screen.queryByText(/chat is busy/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/canvas is busy/i)).not.toBeInTheDocument()
  })

  it("shows the empty state when nothing has been shared", async () => {
    renderWorkspacePanel(makePayload(), { activeTab: "media" })

    expect(await screen.findByText("No media shared yet.")).toBeInTheDocument()
  })
})

describe("MediaGallery artifacts", () => {
  beforeEach(() => {
    vi.mocked(fetchWhiteboardSnapshots).mockResolvedValue({ whiteboard_snapshots: [] })
  })

  it("lists a submitted rails_schema_erd artifact and renders it via TypedArtifactPanel when viewed", async () => {
    vi.mocked(fetchChatMedia).mockResolvedValue({
      snapshots: [],
      chat_images: [],
      typed_artifacts: [
        {
          type: "rails_schema_erd",
          title: "Schema ERD",
          created_at: "2026-08-06T10:00:00Z",
          renderer_type: "erd_diagram",
          payload: {
            tables: [
              { name: "users", columns: [{ name: "id", type: "bigint" }, { name: "email", type: "string" }] }
            ]
          }
        }
      ],
      whiteboard_has_unsaved_content: false
    })

    renderWorkspacePanel(makePayload(), { activeTab: "media" })

    expect(await screen.findByText("Schema ERD")).toBeInTheDocument()
    expect(screen.getByText("rails_schema_erd")).toBeInTheDocument()
    expect(screen.queryByText("users")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "View" }))

    expect(await screen.findByText("users")).toBeInTheDocument()
    expect(screen.getByText("email")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Hide" }))

    expect(screen.queryByText("users")).not.toBeInTheDocument()
  })

  it("renders a submitted visual_review_screenshot artifact as an image via TypedArtifactPanel", async () => {
    vi.mocked(fetchChatMedia).mockResolvedValue({
      snapshots: [],
      chat_images: [],
      typed_artifacts: [
        {
          type: "visual_review_screenshot",
          title: "Homepage after fix",
          created_at: "2026-08-06T10:00:00Z",
          renderer_type: "image_diff",
          payload: {
            image_url: "/api/v1/app/workflows/1/visual_artifact?type=visual_review_screenshot",
            content_type: "image/png",
            byte_size: 48213
          }
        }
      ],
      whiteboard_has_unsaved_content: false
    })

    renderWorkspacePanel(makePayload(), { activeTab: "media" })

    expect(await screen.findByText("Homepage after fix")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "View" }))

    const image = await screen.findByRole("img", { name: "Homepage after fix" })
    expect(image).toHaveAttribute("src", "/api/v1/app/workflows/1/visual_artifact?type=visual_review_screenshot")
  })

  it("does not show the media-empty placeholder when only artifacts are present", async () => {
    vi.mocked(fetchChatMedia).mockResolvedValue({
      snapshots: [],
      chat_images: [],
      typed_artifacts: [
        { type: "rails_schema_erd", title: "Schema ERD", created_at: "2026-08-06T10:00:00Z", renderer_type: "erd_diagram", payload: { tables: [] } }
      ],
      whiteboard_has_unsaved_content: false
    })

    renderWorkspacePanel(makePayload(), { activeTab: "media" })

    expect(await screen.findByText("Schema ERD")).toBeInTheDocument()
    expect(screen.queryByText(/no media shared yet/i)).not.toBeInTheDocument()
  })
})

describe("ChatWorkspacePanel pinned tab", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("lists every pinned message newest first with sender and relative timestamp", async () => {
    vi.mocked(fetchChatMessagePins).mockResolvedValue({
      pins: [
        { id: 1, chat_message_id: 21, text: "First pinned note.", role: "user", created_at: "2026-08-10T10:00:00Z" },
        { id: 2, chat_message_id: 22, text: "Second pinned note.", role: "assistant", created_at: "2026-08-12T10:00:00Z" }
      ]
    })

    renderWorkspacePanel(makePayload(), { activeTab: "pinned" })

    const rows = await screen.findAllByRole("listitem")
    expect(rows.map((row) => row.textContent)).toEqual([
      expect.stringContaining("Second pinned note."),
      expect.stringContaining("First pinned note.")
    ])
    expect(screen.getByText("Assistant")).toBeInTheDocument()
    expect(screen.getByText("You")).toBeInTheDocument()
  })

  it("shows an empty state when there are no pinned messages", async () => {
    vi.mocked(fetchChatMessagePins).mockResolvedValue({ pins: [] })

    renderWorkspacePanel(makePayload(), { activeTab: "pinned" })

    expect(await screen.findByText("No pinned messages yet.")).toBeInTheDocument()
  })

  it("navigates to the message when a pinned row is clicked", async () => {
    vi.mocked(fetchChatMessagePins).mockResolvedValue({
      pins: [{ id: 1, chat_message_id: 21, text: "Discuss aqueducts.", role: "assistant", created_at: "2026-08-10T10:00:00Z" }]
    })
    const onBookmarkSelect = vi.fn()

    renderWorkspacePanel(makePayload(), { activeTab: "pinned", onBookmarkSelect })

    fireEvent.click(await screen.findByRole("button", { name: /Discuss aqueducts\./ }))

    expect(onBookmarkSelect).toHaveBeenCalledWith(21)
  })
})

describe("ChatWorkspacePanel preview panels", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  function payloadWithPanel(): ChatPayload {
    return {
      ...makePayload(),
      preview_panels: [
        { id: 7, title: "Layout mockup", file_count: 2, url: "http://preview-panel-7.lvh.me/", app_close_path: "/api/v1/app/chats/1/preview_panels/7" }
      ]
    }
  }

  it("renders a tab for each open panel and a sandboxed iframe pointed at it once selected", () => {
    renderWorkspacePanel(payloadWithPanel(), { activeTab: "preview:7" as WorkspaceTab })

    expect(screen.getByRole("button", { name: "Layout mockup" })).toBeInTheDocument()

    const iframe = document.querySelector("iframe")
    expect(iframe).not.toBeNull()
    expect(iframe?.getAttribute("src")).toBe("http://preview-panel-7.lvh.me/")
    expect(iframe?.getAttribute("sandbox")).toBe("allow-scripts")
  })

  it("renders an https panel URL verbatim in the iframe src", () => {
    const payload: ChatPayload = {
      ...makePayload(),
      preview_panels: [
        { id: 7, title: "Layout mockup", file_count: 2, url: "https://preview-panel-7.lvh.me/", app_close_path: "/api/v1/app/chats/1/preview_panels/7" }
      ]
    }

    renderWorkspacePanel(payload, { activeTab: "preview:7" as WorkspaceTab })

    const iframe = document.querySelector("iframe")
    expect(iframe?.getAttribute("src")).toBe("https://preview-panel-7.lvh.me/")
  })

  it("does not render a preview tab or iframe once the panel list is empty", () => {
    renderWorkspacePanel(makePayload(), { activeTab: "files" })

    expect(screen.queryByRole("button", { name: "Layout mockup" })).not.toBeInTheDocument()
    expect(document.querySelector("iframe")).toBeNull()
  })

  it("closes the panel through the API when the close affordance is clicked", async () => {
    vi.mocked(closeChatPreviewPanel).mockResolvedValue({ ...makePayload(), preview_panels: [] })

    renderWorkspacePanel(payloadWithPanel(), { activeTab: "preview:7" as WorkspaceTab })

    fireEvent.click(screen.getByRole("button", { name: "Close preview panel: Layout mockup" }))

    await waitFor(() => {
      expect(closeChatPreviewPanel).toHaveBeenCalledWith("/api/v1/app/chats/1/preview_panels/7")
    })
  })
})

describe("ChatWorkspacePanel plugin tabs", () => {
  function payloadWithPluginTab(): ChatPayload {
    return {
      ...makePayload(),
      workspace_tabs: [
        { id: "syrus_dev.workspace_tab_demo", label: "Workspace Tab Demo", label_key: "syrus_dev:workspace_tab_demo_label", component: "syrus_dev/WorkspaceTabDemo", order: 100 }
      ]
    }
  }

  it("renders a tab button for each plugin-declared tab", () => {
    renderWorkspacePanel(payloadWithPluginTab(), { activeTab: "files" })

    expect(screen.getByRole("button", { name: "Workspace Tab Demo" })).toBeInTheDocument()
  })

  it("lazily mounts the declared plugin component when its tab is active", async () => {
    renderWorkspacePanel(payloadWithPluginTab(), { activeTab: "plugin:syrus_dev.workspace_tab_demo" as WorkspaceTab })

    expect(await screen.findByText(/syrus_dev/)).toBeInTheDocument()
  })

  it("shows an unavailable message for a tab whose component cannot be resolved", async () => {
    const payload: ChatPayload = {
      ...makePayload(),
      workspace_tabs: [
        { id: "missing.tab", label: "Missing", label_key: null, component: "missing/Nope", order: 0 }
      ]
    }

    renderWorkspacePanel(payload, { activeTab: "plugin:missing.tab" as WorkspaceTab })

    expect(await screen.findByText("This tab is not available.")).toBeInTheDocument()
  })

  it("does not render a plugin tab button once the workspace_tabs list is empty", () => {
    renderWorkspacePanel(makePayload(), { activeTab: "files" })

    expect(screen.queryByRole("button", { name: "Workspace Tab Demo" })).not.toBeInTheDocument()
  })
})
