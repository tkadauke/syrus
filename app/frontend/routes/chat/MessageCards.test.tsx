import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ChatMessage, humanMessageBubbleClass, resolveWorkspaceFileLink, ToolGroup } from "./MessageCards"
import type { ChatMessagePin, ChatPayload, ChatRenderItem, ChatSystemMessage, ChatToolGroupItem } from "../../api/chats"
import { createChatMessagePin, deleteChatMessagePin, fetchChatMessagePins, fetchSourceFileContent } from "../../api/chats"

vi.mock("../../api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/chats")>()
  return {
    ...actual,
    fetchSourceFileContent: vi.fn(),
    fetchChatMessagePins: vi.fn(),
    createChatMessagePin: vi.fn(),
    deleteChatMessagePin: vi.fn()
  }
})

function makePayload(): ChatPayload {
  return {
    chat: {
      id: 122,
      current_user_id: 1,
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
    preview_panels: [],
    workspace_tabs: [],
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

function assistantMessage(text: string, options: { pinnable?: boolean } = {}): Extract<ChatRenderItem, { type: "message" }> {
  return {
    type: "message",
    id: 5,
    role: "assistant",
    text,
    bookmarkable: true,
    pinnable: options.pinnable ?? false,
    attachments: []
  }
}

function userMessage(text: string, overrides: Partial<Extract<ChatRenderItem, { type: "message" }>> = {}): Extract<ChatRenderItem, { type: "message" }> {
  return {
    type: "message",
    id: 6,
    role: "user",
    text,
    bookmarkable: true,
    attachments: [],
    ...overrides
  }
}

function renderMessage(text: string, payload = makePayload(), options: { pinnable?: boolean } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatMessage
          item={assistantMessage(text, options)}
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

function renderChatMessageItem(item: Extract<ChatRenderItem, { type: "message" }>, payload = makePayload(), extra: { readOnly?: boolean; retryText?: string | null; retrying?: boolean; onRetry?: (text: string) => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatMessage
          item={item}
          payload={payload}
          pendingActionIds={new Set()}
          prefix=""
          queryKey={["chats", "122", ""] as const}
          onNotice={() => {}}
          {...extra}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function systemMessageItem(system: ChatSystemMessage, overrides: Partial<Extract<ChatRenderItem, { type: "message" }>> = {}): Extract<ChatRenderItem, { type: "message" }> {
  return {
    type: "message",
    id: 7,
    role: "system",
    text: system.body,
    bookmarkable: false,
    system,
    ...overrides
  }
}

beforeEach(() => {
  vi.mocked(fetchSourceFileContent).mockReset()
  vi.mocked(fetchChatMessagePins).mockReset().mockResolvedValue({ pins: [] })
  vi.mocked(createChatMessagePin).mockReset()
  vi.mocked(deleteChatMessagePin).mockReset()
})

describe("sender attribution", () => {
  it("renders the sender's name above a human message in a group chat", () => {
    const payload = makePayload()
    payload.chat.conversation_kind = "group"

    renderChatMessageItem(userMessage("Ave.", { sender_user: { id: 3, name: "Marcus Cato" } }), payload)

    expect(screen.getByText("Marcus Cato")).toBeInTheDocument()
  })

  it("does not render a sender name in a direct chat even if sender_user is present", () => {
    const payload = makePayload()
    payload.chat.conversation_kind = "direct"

    renderChatMessageItem(userMessage("Ave.", { sender_user: { id: 3, name: "Marcus Cato" } }), payload)

    expect(screen.queryByText("Marcus Cato")).not.toBeInTheDocument()
  })

  it("omits sender attribution in a group chat when the message has no recorded sender", () => {
    const payload = makePayload()
    payload.chat.conversation_kind = "group"

    renderChatMessageItem(userMessage("Ave.", { sender_user: null }), payload)

    expect(screen.getByText("Ave.")).toBeInTheDocument()
    expect(screen.queryByText("Marcus Cato")).not.toBeInTheDocument()
  })

  it("uses the default bubble color for the current user's group messages", () => {
    const payload = makePayload()
    payload.chat.conversation_kind = "group"

    const className = humanMessageBubbleClass(userMessage("Ave.", { sender_user: { id: 1, name: "Julia Kadauke" } }), payload)

    expect(className).toContain("bg-brand")
    expect(className).toContain("text-on-brand")
  })

  it("uses one alternate bubble color for other group participants", () => {
    const payload = makePayload()
    payload.chat.conversation_kind = "group"

    const className = humanMessageBubbleClass(userMessage("Ave.", { sender_user: { id: 3, name: "Marcus Cato" } }), payload)

    expect(className).toContain("bg-gray-100")
    expect(className).toContain("dark:bg-gray-800")
    expect(className).not.toContain("bg-brand")
  })
})

describe("shell command rendering", () => {
  it("renders a completed `!` command distinctly from a normal chat bubble, with ANSI output resolved to colored text", () => {
    renderChatMessageItem(userMessage("", {
      chat_shell_command: {
        id: 501,
        command: "git status",
        output: "[32mnothing to commit, working tree clean[0m",
        outcome: "succeeded",
        exit_status: 0,
        started_at: "2026-09-07T10:00:00Z",
        finished_at: "2026-09-07T10:00:01Z"
      }
    }))

    const card = screen.getByTestId("shell-command-card")
    expect(within(card).getByText("git status")).toBeInTheDocument()
    expect(within(card).getByText("nothing to commit, working tree clean")).toHaveClass("text-emerald-700")
    expect(within(card).getByText("Succeeded")).toBeInTheDocument()
    expect(within(card).getByText("exit 0")).toBeInTheDocument()
    // No plain-prose bubble should render alongside the card for an empty-text shell command message.
    expect(screen.queryByText("git status", { selector: ".whitespace-pre-wrap" })).not.toBeInTheDocument()
  })

  it("shows a failed command's exit status and a distinct outcome badge", () => {
    renderChatMessageItem(userMessage("", {
      chat_shell_command: {
        id: 502,
        command: "bin/rspec",
        output: "1 example, 1 failure",
        outcome: "failed",
        exit_status: 1,
        started_at: "2026-09-07T10:00:00Z",
        finished_at: "2026-09-07T10:00:05Z"
      }
    }))

    const card = screen.getByTestId("shell-command-card")
    expect(within(card).getByText("exit 1")).toBeInTheDocument()
    expect(within(card).getByText("Failed")).toBeInTheDocument()
  })

  it("shows a placeholder when a command produced no output", () => {
    renderChatMessageItem(userMessage("", {
      chat_shell_command: {
        id: 503,
        command: "true",
        output: "",
        outcome: "succeeded",
        exit_status: 0,
        started_at: "2026-09-07T10:00:00Z",
        finished_at: "2026-09-07T10:00:00Z"
      }
    }))

    expect(within(screen.getByTestId("shell-command-card")).getByText("(no output)")).toBeInTheDocument()
  })

  it("does not render a shell command card for ordinary messages", () => {
    renderChatMessageItem(userMessage("Just a normal message."))

    expect(screen.queryByTestId("shell-command-card")).not.toBeInTheDocument()
  })
})

describe("system message retry", () => {
  it("shows a Retry now button under a non-prominent error system message and resends the given text", () => {
    const onRetry = vi.fn()
    renderChatMessageItem(
      systemMessageItem({ tone: "error", label: "Claude auth", body: "Claude authentication failed." }),
      makePayload(),
      { retryText: "does syrus have that feature?", onRetry }
    )

    const button = screen.getByRole("button", { name: "Retry now" })
    fireEvent.click(button)

    expect(onRetry).toHaveBeenCalledWith("does syrus have that feature?")
  })

  it("shows a Retry now button under a prominent error system message", () => {
    const onRetry = vi.fn()
    renderChatMessageItem(
      systemMessageItem({ tone: "error", label: "Agent error", body: "Agent turn failed.", prominent: true }),
      makePayload(),
      { retryText: "please retry this", onRetry }
    )

    fireEvent.click(screen.getByRole("button", { name: "Retry now" }))

    expect(onRetry).toHaveBeenCalledWith("please retry this")
  })

  it("does not render Retry now for non-error tones even when retry text is available", () => {
    renderChatMessageItem(
      systemMessageItem({ tone: "warning", label: "MCP unavailable", body: "MCP unavailable: syrus-chat-sidecar down." }),
      makePayload(),
      { retryText: "hello", onRetry: vi.fn() }
    )

    expect(screen.queryByRole("button", { name: "Retry now" })).not.toBeInTheDocument()
  })

  it("does not render Retry now when there is no retry text to resend", () => {
    renderChatMessageItem(
      systemMessageItem({ tone: "error", label: "Claude auth", body: "Claude authentication failed." }),
      makePayload(),
      { retryText: null, onRetry: vi.fn() }
    )

    expect(screen.queryByRole("button", { name: "Retry now" })).not.toBeInTheDocument()
  })

  it("does not render Retry now in a read-only stream even with retry text available", () => {
    renderChatMessageItem(
      systemMessageItem({ tone: "error", label: "Claude auth", body: "Claude authentication failed." }),
      makePayload(),
      { readOnly: true, retryText: "hello", onRetry: vi.fn() }
    )

    expect(screen.queryByRole("button", { name: "Retry now" })).not.toBeInTheDocument()
  })

  it("disables the button and labels it Retrying… while a retry is in flight", () => {
    renderChatMessageItem(
      systemMessageItem({ tone: "error", label: "Claude auth", body: "Claude authentication failed." }),
      makePayload(),
      { retryText: "hello", retrying: true, onRetry: vi.fn() }
    )

    const button = screen.getByRole("button", { name: "Retrying…" })
    expect(button).toBeDisabled()
  })
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

    expect(await screen.findByRole("dialog", { name: /file preview/i })).toBeInTheDocument()
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

describe("tool result rendering", () => {
  function expandToolGroup(label: string) {
    const summary = screen.getByText(label).closest("summary")
    expect(summary).not.toBeNull()
    if (!summary) throw new Error(`missing summary for ${label}`)
    fireEvent.click(summary)
  }

  function openRawDetails() {
    const rawDetails = screen.getByText(/Raw details/).closest("details")
    expect(rawDetails).not.toBeNull()
    if (!rawDetails) throw new Error("missing raw details")
    rawDetails.open = true
    fireEvent(rawDetails, new Event("toggle"))
    return rawDetails
  }

  it("defers large tool result bodies until the operator expands the group", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "read_live_state",
      calls: [
        {
          message_id: 1,
          tool_name: "read_live_state",
          raw_name: "read_live_state",
          detail: "detail",
          display_label: "Read live state",
          progress_label: "Reading",
          raw_payload: {},
          result_body: "very large hidden body",
          result_error: false,
          result_kind: "text",
          result_summary: "summary"
        }
      ]
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("summary")).toBeInTheDocument()
    expect(screen.queryByText("very large hidden body")).not.toBeInTheDocument()

    const details = screen.getByText("read_live_state").closest("details")
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event("toggle"))

    expect(screen.getByText("very large hidden body")).toBeInTheDocument()
  })

  it("keeps a live in-progress tool call collapsed until the operator expands it", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Bash",
      calls: [
        {
          message_id: 1,
          tool_name: "Bash",
          raw_name: "Bash",
          detail: "bin/rspec",
          display_label: "Bash",
          progress_label: "Running command",
          raw_payload: { command: "bin/rspec" },
          result_body: "",
          result_error: false,
          result_kind: "unknown",
          result_summary: ""
        }
      ],
      summary_label: "Bash",
      outcome_label: "Running",
      collapsed_by_default: false,
      prominent: true
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("Bash")).toBeInTheDocument()
    expect(screen.getByText("Running")).toBeInTheDocument()
    expect(screen.getByText("bin/rspec")).toBeInTheDocument()
    expect(screen.queryByText("Raw details")).not.toBeInTheDocument()

    expandToolGroup("Bash")

    expect(screen.getByText("Raw details")).toBeInTheDocument()
  })

  it("keeps a reused collapsed group closed when a streamed result turns it into a failure", () => {
    const baseCall = {
      message_id: 1,
      tool_name: "Read",
      raw_name: "Read",
      detail: "missing.rb",
      display_label: "Read",
      progress_label: "Reading",
      raw_payload: {},
      result_body: "",
      result_error: false,
      result_kind: "unknown" as const,
      result_summary: ""
    }
    const { rerender } = render(
      <ToolGroup
        item={{
          type: "tool_group",
          tool: "Inspection",
          calls: [baseCall],
          summary_label: "Inspected missing.rb",
          outcome_label: "Running",
          collapsed_by_default: true,
          prominent: false
        }}
      />
    )

    expect(screen.queryByText("No such file")).not.toBeInTheDocument()

    rerender(
      <ToolGroup
        item={{
          type: "tool_group",
          tool: "Inspection",
          calls: [{ ...baseCall, result_body: "No such file", result_error: true, result_kind: "error" as const }],
          summary_label: "Inspected missing.rb",
          outcome_label: "Failed",
          collapsed_by_default: false,
          prominent: true
        }}
      />
    )

    expect(screen.getByText("Failed")).toBeInTheDocument()
    expect(screen.queryByText("No such file")).not.toBeInTheDocument()

    expandToolGroup("Inspected missing.rb")

    expect(screen.getByText("No such file")).toBeInTheDocument()
  })

  it("does not syntax-highlight pathological single-line tool results when expanded", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Read",
      calls: [
        {
          message_id: 1,
          tool_name: "Read",
          raw_name: "Read",
          detail: "app/models/job.rb",
          display_label: "Read",
          progress_label: "Reading",
          raw_payload: {},
          result_body: "a".repeat(2_000),
          result_error: false,
          result_kind: "text",
          result_summary: "summary"
        }
      ]
    }

    render(<ToolGroup item={item} />)
    const details = screen.getByText("Read").closest("details")
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event("toggle"))

    const body = screen.getByText("a".repeat(2_000))
    expect(body.tagName).toBe("PRE")
    expect(body.querySelector("span")).toBeNull()
  })

  it("syntax-highlights tool results for tools other than Read", async () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Edit",
      calls: [
        {
          message_id: 1,
          tool_name: "Edit",
          raw_name: "Edit",
          detail: "app/models/job.rb",
          display_label: "Edit",
          progress_label: "Editing",
          raw_payload: {},
          result_body: "class Job\nend\n",
          result_error: false,
          result_kind: "text",
          result_summary: "summary"
        }
      ]
    }

    render(<ToolGroup item={item} />)
    expandToolGroup("Edit")

    const keyword = await screen.findByText("class")
    expect(keyword.tagName).toBe("SPAN")
    expect(keyword.style.color).toBe("var(--shiki-token-keyword)")
  })

  it("renders list_chat_media results as a compact dark-mode-safe gallery with stable IDs, filenames, kind, and content type", () => {
    // list_chat_media's card lives under routes/chat/tool_cards/ ,
    // registered through the plugin-aware extension point .
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "List chat media",
      calls: [
        {
          message_id: 1,
          tool_name: "list_chat_media",
          raw_name: "syrus-chat-sidecar.list_chat_media",
          detail: "No arguments",
          display_label: "List chat media",
          progress_label: "Reading",
          raw_payload: {},
          result_body: JSON.stringify({
            snapshots: [{ id: "snapshot:9", kind: "snapshot", name: "Checkout flow", element_count: 4, created_at: "2026-09-01T12:00:00Z" }],
            chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/3/file" }],
            whiteboard_element_count: 7
          }),
          result_error: false,
          result_kind: "list",
          result_summary: "2 media items"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("2 media items")).toBeInTheDocument()
    expect(screen.queryByText("7 whiteboard elements")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open desktop.png" })).not.toBeInTheDocument()

    expandToolGroup("List chat media")

    expect(screen.getAllByText("2 media items")).toHaveLength(2)
    expect(screen.getByText("7 whiteboard elements")).toBeInTheDocument()

    const imageTile = screen.getByRole("button", { name: "Open desktop.png" })
    expect(imageTile).toHaveClass("dark:bg-gray-950")
    expect(within(imageTile).getByRole("img", { name: "desktop.png" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/3/file")
    expect(within(imageTile).getByText("desktop.png")).toBeInTheDocument()
    expect(within(imageTile).getByText("image/png")).toBeInTheDocument()
    expect(within(imageTile).getByText("image")).toBeInTheDocument()

    const snapshotTile = screen.getByRole("button", { name: "Open Checkout flow" })
    expect(within(snapshotTile).getByText("Checkout flow")).toBeInTheDocument()
    expect(within(snapshotTile).getByText("snapshot")).toBeInTheDocument()

    fireEvent.click(imageTile)
    expect(screen.getByRole("dialog", { name: "desktop.png" })).toBeInTheDocument()
    expect(screen.getAllByRole("img", { name: "desktop.png" })).toHaveLength(2)
    expect(screen.getByText("Content type")).toBeInTheDocument()
    expect(screen.getByText("chat_image:3")).toBeInTheDocument()

    const rawDetails = screen.getByText("Raw details").closest("details")
    expect(rawDetails).not.toBeNull()
    if (!rawDetails) return
    rawDetails.open = true
    fireEvent(rawDetails, new Event("toggle"))
    expect(screen.getByText((_, element) => element?.tagName === "PRE" && element.textContent?.includes("chat_image:3") === true)).toBeInTheDocument()
  })

  it("closes list_chat_media previews with Escape", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "List chat media",
      calls: [
        {
          message_id: 1,
          tool_name: "list_chat_media",
          raw_name: "syrus-chat-sidecar.list_chat_media",
          detail: "No arguments",
          display_label: "List chat media",
          progress_label: "Reading",
          raw_payload: {},
          result_body: JSON.stringify({
            snapshots: [{ id: "snapshot:9", kind: "snapshot", name: "Checkout flow", element_count: 4, created_at: "2026-09-01T12:00:00Z" }],
            chat_images: [
              { id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/3/file" },
              { id: "chat_image:4", kind: "chat_image", filename: "mobile.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/4/file" }
            ],
            whiteboard_element_count: 7
          }),
          result_error: false,
          result_kind: "list",
          result_summary: "3 media items"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)
    expandToolGroup("List chat media")

    fireEvent.click(screen.getByRole("button", { name: "Open desktop.png" }))

    expect(screen.getByRole("dialog", { name: "desktop.png" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("href", "/api/v1/app/chats/12/media/chat_images/3/file")
    expect(screen.getByRole("button", { name: "Previous image" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Next image" })).toBeEnabled()

    fireEvent.keyDown(window, { key: "ArrowRight" })
    expect(screen.getByRole("dialog", { name: "mobile.png" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Previous image" })).toBeEnabled()
    expect(screen.getByRole("button", { name: "Next image" })).toBeDisabled()

    fireEvent.click(screen.getByRole("button", { name: "Previous image" }))
    expect(screen.getByRole("dialog", { name: "desktop.png" })).toBeInTheDocument()

    fireEvent.keyDown(window, { key: "Escape" })

    expect(screen.queryByRole("dialog", { name: "desktop.png" })).not.toBeInTheDocument()
  })

  it("renders an empty state for list_chat_media when the chat has no media", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "List chat media",
      calls: [
        {
          message_id: 1,
          tool_name: "list_chat_media",
          raw_name: "list_chat_media",
          detail: "No arguments",
          display_label: "List chat media",
          progress_label: "Reading",
          raw_payload: {},
          result_body: JSON.stringify({ snapshots: [], chat_images: [] }),
          result_error: false,
          result_kind: "list",
          result_summary: "0 media items"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)
    expandToolGroup("List chat media")

    expect(screen.getByText("No media in this chat yet.")).toBeInTheDocument()
  })

  it("renders plugin card bodies for settled Browser calls with empty result content", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Browser resize",
      calls: [
        {
          message_id: 1,
          tool_name: "browser_resize",
          raw_name: "browser_resize",
          detail: "390x844",
          display_label: "Browser resize",
          progress_label: "Thinking",
          raw_payload: { width: 390, height: 844 },
          result_body: "",
          result_settled: true,
          result_error: false,
          result_kind: "text",
          result_summary: "Resize 390x844 · success"
        }
      ],
      summary_label: "Browser resize",
      outcome_label: "Done",
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("Done")).toBeInTheDocument()
    expect(screen.getByText("Resize 390x844 · success")).toBeInTheDocument()

    expandToolGroup("Browser resize")

    expect(screen.getByText("Resize")).toBeInTheDocument()
    expect(screen.getByText("Viewport")).toBeInTheDocument()
    expect(screen.getAllByText("390x844")).toHaveLength(1)
  })

  it("shows a done outcome for settled Browser screenshot calls with empty display bodies", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Browser screenshot",
      calls: [
        {
          message_id: 1,
          tool_name: "browser_screenshot",
          raw_name: "browser_screenshot",
          detail: "Hero panel",
          display_label: "Browser screenshot",
          progress_label: "Thinking",
          raw_payload: { element: "Hero panel" },
          result_body: "",
          result_json: [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }],
          result_settled: true,
          result_error: false,
          result_kind: "text",
          result_summary: "Screenshot Hero panel · Browser screenshot · success"
        }
      ],
      summary_label: "Browser screenshot",
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("Done")).toBeInTheDocument()
    expect(screen.queryByText("Running")).not.toBeInTheDocument()
    expect(screen.getByText("Screenshot Hero panel · Browser screenshot · success")).toBeInTheDocument()
  })

  it("renders typed success and record outputs instead of raw JSON", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Actions",
      calls: [
        {
          message_id: 1,
          tool_name: "set_bookmark",
          raw_name: "set_bookmark",
          detail: "Launch notes",
          display_label: "Set bookmark",
          progress_label: "Making changes",
          raw_payload: { label: "Launch notes" },
          result_body: JSON.stringify({ id: 4, label: "Launch notes", kind: "topic" }),
          result_error: false,
          result_kind: "record",
          result_summary: "1 bookmark"
        },
        {
          message_id: 3,
          tool_name: "read_job",
          raw_name: "read_job",
          detail: "4048",
          display_label: "Read job",
          progress_label: "Reading",
          raw_payload: { job_id: 4048 },
          result_body: JSON.stringify({ job: { id: 4048, issue_title: "Typed renderers", state: "running", pr_number: 12, branch_name: "syrus/direct-148" } }),
          result_error: false,
          result_kind: "record",
          result_summary: "1 Job"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("1 bookmark")).toBeInTheDocument()
    expect(screen.getByText("1 Job")).toBeInTheDocument()
    expect(screen.queryByText("Bookmark added: Launch notes")).not.toBeInTheDocument()
    expect(screen.queryByText("Typed renderers")).not.toBeInTheDocument()

    expandToolGroup("Actions")

    expect(screen.getByText("Bookmark added: Launch notes")).toBeInTheDocument()
    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("Typed renderers")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-148")).toBeInTheDocument()
    expect(screen.queryByText(/"kind": "topic"/)).not.toBeInTheDocument()
  })

  it("falls back to formatted raw output for unknown and malformed typed payloads", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Unknown tool",
      calls: [
        {
          message_id: 1,
          tool_name: "set_bookmark",
          raw_name: "set_bookmark",
          detail: "bad",
          display_label: "Set bookmark",
          progress_label: "Making changes",
          raw_payload: {},
          result_body: "{\"label\":",
          result_error: false,
          result_kind: "text",
          result_summary: ""
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.queryByText("{\"label\":")).not.toBeInTheDocument()

    expandToolGroup("Unknown tool")

    expect(screen.getByText("{\"label\":")).toBeInTheDocument()
  })

  it("redacts raw details, fallback output, summaries, and copied payloads for unknown tool cards", async () => {
    const clipboardWrite = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText: clipboardWrite } })
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Unknown tool",
      calls: [
        {
          message_id: 1,
          tool_name: "unknown_tool",
          raw_name: "unknown_tool",
          detail: "token=detail-secret-123456",
          display_label: "Unknown tool",
          progress_label: "Reading",
          raw_payload: { accessToken: "input-access-secret-123456", api_token: "input-secret-123456", query: "visible" },
          result_body: 'Authorization: Bearer resultsecret1234567890\n{"accessToken":"result-access-secret-123456"}\nvisible result',
          result_error: false,
          result_kind: "text",
          result_summary: "password=summary-secret-123456"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.getAllByText(/token=\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/password=\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/detail-secret/)).not.toBeInTheDocument()
    expect(screen.queryByText(/summary-secret/)).not.toBeInTheDocument()

    expandToolGroup("Unknown tool")

    expect(screen.getByText(/Authorization: Bearer \[redacted\]/)).toBeInTheDocument()
    expect(screen.getByText((_, element) => element?.tagName === "PRE" && element.textContent?.includes("visible result") === true)).toBeInTheDocument()
    expect(screen.queryByText(/resultsecret/)).not.toBeInTheDocument()
    expect(screen.queryByText(/result-access-secret/)).not.toBeInTheDocument()

    const rawDetails = openRawDetails()
    expect(within(rawDetails).getByText(/\([^)]+, redacted\)/)).toBeInTheDocument()
    expect(within(rawDetails).getByText(/Secret-like values are redacted/)).toBeInTheDocument()
    expect(within(rawDetails).getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/input-secret/)).not.toBeInTheDocument()
    expect(screen.queryByText(/input-access-secret/)).not.toBeInTheDocument()

    fireEvent.click(within(rawDetails).getByRole("button", { name: "Copy" }))

    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledTimes(1))
    const copied = clipboardWrite.mock.calls[0][0]
    expect(copied).toContain("[redacted]")
    expect(copied).toContain("visible")
    expect(copied).not.toContain("input-secret")
    expect(copied).not.toContain("input-access-secret")
    expect(copied).not.toContain("resultsecret")
    expect(copied).not.toContain("result-access-secret")
  })

  it("keeps standalone structured tool messages collapsed until expansion", () => {
    renderChatMessageItem({
      type: "message",
      id: 11,
      role: "tool_use",
      text: "fallback raw payload",
      bookmarkable: false,
      tool: {
        name: "read_job",
        raw_name: "syrus-chat-sidecar.read_job",
        display_label: "Read job",
        argument_summary: "JOB-172",
        raw_payload: { job_id: 4072 },
        result_kind: "record",
        result_summary: "1 Job",
        payload: { job: { id: 4072, issue_title: "Collapsed tools" } },
        proposal_id: null,
        proposal_state_label: null
      }
    })

    expect(screen.getByText("Read job")).toBeInTheDocument()
    expect(screen.getByText("JOB-172")).toBeInTheDocument()
    expect(screen.getByText("1 Job")).toBeInTheDocument()
    expect(screen.queryByText(/Collapsed tools/)).not.toBeInTheDocument()

    expandToolGroup("Read job")

    openRawDetails()

    expect(screen.getByText((_, element) => element?.tagName === "PRE" && element.textContent?.includes("Collapsed tools") === true)).toBeInTheDocument()
  })

  it("renders a plugin-registered card for a plugin-owned tool, without core naming that plugin", () => {
    // list_design_docs's card lives entirely under
    // plugins/design_docs/app/frontend/tool_cards/ — this
    // spec proves the extension point resolves it purely by tool name.
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "List design docs",
      calls: [
        {
          message_id: 1,
          tool_name: "list_design_docs",
          raw_name: "list_design_docs",
          detail: "No arguments",
          display_label: "List design docs",
          progress_label: "Reading",
          raw_payload: {},
          result_body: JSON.stringify({ design_docs: [{ id: 20, doc_ref: "DOC-20", title: "Target Graphs", state: "draft" }] }),
          result_error: false,
          result_kind: "record",
          result_summary: "1 design doc"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.queryByText("DOC-20")).not.toBeInTheDocument()

    expandToolGroup("List design docs")

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("Target Graphs")).toBeInTheDocument()
  })

  it("redacts plugin-owned card summaries, rendered body, and raw details through the shared tool-card context", () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "List design docs",
      calls: [
        {
          message_id: 1,
          tool_name: "list_design_docs",
          raw_name: "list_design_docs",
          detail: "plugin-input-secret-123456",
          display_label: "List design docs",
          progress_label: "Reading",
          raw_payload: { refresh_token: "plugin-input-secret-123456" },
          result_body: JSON.stringify({ design_docs: [{ id: 999, doc_ref: "DOC-999", title: "token=plugin-title-secret-123456", state: "draft" }] }),
          result_json: { design_docs: [{ id: 999, doc_ref: "DOC-999", title: "token=plugin-title-secret-123456", state: "draft" }] },
          result_error: false,
          result_kind: "record",
          result_summary: ""
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("1 design doc")).toBeInTheDocument()
    expect(screen.getByText(/\[redacted\] · 1 design doc/)).toBeInTheDocument()
    expect(screen.queryByText(/plugin-input-secret/)).not.toBeInTheDocument()
    expect(screen.queryByText(/plugin-title-secret/)).not.toBeInTheDocument()

    expandToolGroup("List design docs")

    expect(screen.getByText("DOC-999")).toBeInTheDocument()
    expect(screen.getByText("token=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/plugin-input-secret/)).not.toBeInTheDocument()
    expect(screen.queryByText(/plugin-title-secret/)).not.toBeInTheDocument()

    const rawDetails = openRawDetails()
    expect(within(rawDetails).getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/plugin-input-secret/)).not.toBeInTheDocument()
  })

  it("still resolves a plugin-registered card when the tool call errored", () => {
    // Regression for ToolResultBody used to skip plugin card
    // resolution entirely whenever result_error was true, so a plugin tool
    // that reports a structured failure through the MCP error flag (rather
    // than a bare "Error: ..." string) fell back to a raw JSON dump instead
    // of the card it registered. list_design_docs's own parsing doesn't
    // care about resultError, so it renders the same either way once the
    // card gets the chance to see the payload at all.
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "List design docs",
      calls: [
        {
          message_id: 1,
          tool_name: "list_design_docs",
          raw_name: "list_design_docs",
          detail: "No arguments",
          display_label: "List design docs",
          progress_label: "Reading",
          raw_payload: {},
          result_body: JSON.stringify({ design_docs: [{ id: 21, doc_ref: "DOC-21", title: "K8s Cluster Viewer", state: "draft" }] }),
          result_error: true,
          result_kind: "error",
          result_summary: "Error"
        }
      ],
      collapsed_by_default: false
    }

    render(<ToolGroup item={item} />)

    expandToolGroup("List design docs")

    expect(screen.getByText("DOC-21")).toBeInTheDocument()
    expect(screen.getByText("K8s Cluster Viewer")).toBeInTheDocument()
  })
})

describe("pin control", () => {
  it("does not render a pin toggle for non-pinnable messages", () => {
    renderMessage("Not pinnable", makePayload(), { pinnable: false })

    expect(screen.queryByRole("button", { name: "Pin message" })).not.toBeInTheDocument()
  })

  it("shows a pin toggle for pinnable messages and pins on click", async () => {
    vi.mocked(createChatMessagePin).mockResolvedValue({} as ChatPayload)
    renderMessage("Discuss the aqueduct.", makePayload(), { pinnable: true })

    const pinButton = await screen.findByRole("button", { name: "Pin message" })
    fireEvent.click(pinButton)

    await waitFor(() => {
      expect(createChatMessagePin).toHaveBeenCalledWith("/api/v1/app/chats/122/pins", 5)
    })
  })

  it("shows an unpin toggle and unpins on click when the message is already pinned", async () => {
    const pin: ChatMessagePin = { id: 1, chat_message_id: 5, text: "Discuss the aqueduct.", role: "assistant", created_at: "2026-08-10T10:00:00Z" }
    vi.mocked(fetchChatMessagePins).mockResolvedValue({ pins: [ pin ] })
    vi.mocked(deleteChatMessagePin).mockResolvedValue({ pins: [] } as unknown as ChatPayload & { pins: ChatMessagePin[] })
    renderMessage("Discuss the aqueduct.", makePayload(), { pinnable: true })

    const unpinButton = await screen.findByRole("button", { name: "Unpin message" })
    fireEvent.click(unpinButton)

    await waitFor(() => {
      expect(deleteChatMessagePin).toHaveBeenCalledWith("/api/v1/app/chats/122/pins", 5)
    })
  })
})
