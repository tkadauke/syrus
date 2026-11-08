import { screen } from "@testing-library/react"
import { expect } from "vitest"

export function sidebarChat(overrides: {
  id: number
  title: string | null
  title_pending?: boolean
  pinned?: boolean
  repository: { id: number; slug: string; repository_path: string } | null
  last_message_at: string | null
  unread?: boolean
  turn_in_flight?: boolean
  agent_busy?: boolean
}) {
  return {
    id: overrides.id,
    title: overrides.title,
    title_pending: overrides.title_pending ?? false,
    pinned: overrides.pinned ?? false,
    pinned_context: null,
    chat_path: `/chats/${overrides.id}`,
    repository: overrides.repository,
    turn_in_flight: overrides.turn_in_flight ?? false,
    agent_busy: overrides.agent_busy ?? false,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    current: false,
    last_message_at: overrides.last_message_at,
    created_at: overrides.last_message_at || "2026-06-01T00:00:00Z",
    updated_at: overrides.last_message_at || "2026-06-01T00:00:00Z",
    unread: overrides.unread ?? false
  }
}

export function sidebarGroups(chats: ReturnType<typeof sidebarChat>[], options: { hasMore?: Record<string, boolean> } = {}) {
  const groups = new Map<string, { key: string; label: string; repository_id: number | null; chats: ReturnType<typeof sidebarChat>[]; has_more: boolean }>()
  chats.forEach((chat) => {
    const key = chat.repository ? `repository-${chat.repository.id}` : "general"
    const group = groups.get(key) || {
      key,
      label: chat.repository?.slug || "General",
      repository_id: chat.repository?.id ?? null,
      chats: [],
      has_more: Boolean(options.hasMore?.[key])
    }
    group.chats.push(chat)
    groups.set(key, group)
  })

  return Array.from(groups.values())
}

export function chatPayload(
  overrides: {
    id?: number
    chatPath?: string
    message?: string
    messages?: Array<Record<string, unknown>>
    queuedMessages?: Array<Record<string, unknown>>
    agentQuestions?: Array<Record<string, unknown>>
    pendingActions?: Array<Record<string, unknown>>
    cumulativeInputTokens?: number
    cumulativeOutputTokens?: number
    cumulativeCostUsd?: number
    turnInFlight?: boolean
    agentBusy?: boolean
    agentActivity?: {
      label: string
      raw_name: string | null
      in_flight: boolean
      elapsed_seconds: number | null
      idle_seconds: number | null
      transcript_bytes: number | null
    } | null
    hasMoreOlder?: boolean
    pinned?: boolean
    stopRequestedAt?: string | null
    chatProvider?: string | null
    effectiveChatProvider?: string
    chatProviderOptions?: Array<{ value: string; label: string; configured: boolean; effective_provider: string; effective_label: string }>
    whiteboardSnapshotCount?: number
  } = {}
) {
  const effectiveChatProvider = overrides.effectiveChatProvider ?? overrides.chatProvider ?? "claude"
  const effectiveChatProviderLabel = effectiveChatProvider === "codex" ? "Codex" : "Claude"
  return {
    message: overrides.message,
    chat: {
      id: overrides.id ?? 8,
      title: "Aqueduct planning",
      title_pending: false,
      pinned: overrides.pinned ?? false,
      pinned_context: null,
      chat_provider: overrides.chatProvider ?? null,
      effective_chat_provider: effectiveChatProvider,
      effective_chat_provider_label: effectiveChatProviderLabel,
      chat_provider_options: overrides.chatProviderOptions || [],
      chat_path: overrides.chatPath ?? "/chats/8",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      agent_activity: overrides.agentActivity ?? null,
      stop_requested_at: overrides.stopRequestedAt ?? null,
      cumulative_input_tokens: overrides.cumulativeInputTokens ?? 12400,
      cumulative_output_tokens: overrides.cumulativeOutputTokens ?? 3200,
      cumulative_cost_usd: overrides.cumulativeCostUsd ?? 0.0123,
      whiteboard_snapshot_count: overrides.whiteboardSnapshotCount ?? 0
    },
    chat_available: true,
    turn_in_flight: overrides.turnInFlight ?? false,
    agent_busy: overrides.agentBusy ?? false,
    agent_activity: overrides.agentActivity ?? null,
    has_more_older: overrides.hasMoreOlder ?? false,
    messages: overrides.messages || [
      {
        type: "message",
        id: 9,
        role: "assistant",
        tool_name: null,
        content: { text: "Discuss aqueducts." },
        text: "Discuss aqueducts.",
        bookmarkable: true
      }
    ],
    bookmarks: [{ id: 1, label: "Aqueducts", chat_message_id: 9, anchor_message_id: 9 }],
    queued_messages: overrides.queuedMessages || [],
    recent_chats: [
      {
        id: 8,
        title: "Aqueduct planning",
        title_pending: false,
        pinned: overrides.pinned ?? false,
        pinned_context: null,
        chat_provider: overrides.chatProvider ?? null,
        effective_chat_provider: effectiveChatProvider,
        effective_chat_provider_label: effectiveChatProviderLabel,
        chat_path: "/chats/8",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        stop_requested_at: null,
        cumulative_input_tokens: 12400,
        cumulative_output_tokens: 3200,
        cumulative_cost_usd: 0.0123,
        current: true,
        last_message_at: "2026-06-01T10:00:00Z",
        unread: false
      },
      {
        id: 4,
        title: "Road survey",
        title_pending: false,
        pinned: false,
        pinned_context: null,
        chat_provider: null,
        effective_chat_provider: "claude",
        effective_chat_provider_label: "Claude",
        chat_path: "/chats/4",
        repository: { id: 4, slug: "acme/roads", repository_path: "/repositories/4" },
        stop_requested_at: null,
        cumulative_input_tokens: 2000,
        cumulative_output_tokens: 1000,
        cumulative_cost_usd: 0.001,
        current: false,
        last_message_at: "2026-05-31T10:00:00Z",
        unread: true
      }
    ],
    pending_actions: overrides.pendingActions || [],
    agent_questions: overrides.agentQuestions || [],
    documents_in_scope: [{ id: 5, title: "Launch notes", repository_slug: "acme/widgets" }],
    preview_panels: [],
    workspace_tabs: [{ id: "whiteboard.canvas", label: "Whiteboard", label_key: "whiteboard:tab_whiteboard", component: "whiteboard/WhiteboardTab", order: 0 }],
    whiteboard: {
      version: 2,
      elements: [{ id: "box-1", type: "rectangle" }],
      appState: {},
      files: {},
      loaded: true
    },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/8/messages",
      app_message_path: "/api/v1/app/chats/8/message",
      app_rename_path: "/api/v1/app/chats/8/rename",
      app_clear_path: "/api/v1/app/chats/8/messages",
      app_share_path: "/api/v1/app/chats/8/share",
      app_enqueue_message_path: "/api/v1/app/chats/8/queued_messages",
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_switch_provider_path: "/api/v1/app/chats/8/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard"
    }
  }
}

export function pendingAction(
  overrides: {
    id?: number
    label?: string
    detail?: string | null
    state?: string
    action?: string | null
    actionType?: string | null
    confirmPath?: string
    cancelPath?: string
    chatMessageId?: number | null
    executionStatus?: string | null
    executionStep?: string | null
    executionError?: string | null
  } = {}
) {
  const id = overrides.id ?? 7
  return {
    id,
    label: overrides.label ?? "Cancel JOB-44",
    detail: overrides.detail ?? null,
    state: overrides.state ?? "pending",
    action: overrides.action ?? "cancel_job",
    action_type: overrides.actionType ?? null,
    chat_message_id: overrides.chatMessageId,
    execution_status: overrides.executionStatus ?? null,
    execution_step: overrides.executionStep ?? null,
    execution_error: overrides.executionError ?? null,
    app_confirm_path: overrides.confirmPath ?? `/api/v1/app/chats/8/pending_actions/${id}/confirm`,
    app_reject_path: `/api/v1/app/chats/8/pending_actions/${id}/reject`,
    app_cancel_path: overrides.cancelPath ?? `/api/v1/app/chats/8/pending_actions/${id}`
  }
}

export function transcriptPayload(
  overrides: {
    events?: Array<Record<string, unknown>>
    totalEvents?: number
  } = {}
) {
  const events = overrides.events || [
    {
      kind: "tool_use",
      timestamp: "2026-05-30T12:00:00Z",
      data: { name: "Bash", input: { command: "ls" }, id: "u1" }
    }
  ]

  return {
    run_id: 4,
    job_id: 1,
    step_kind: "implement",
    workflow_trigger_kind: "initial",
    session_id: "abc-123",
    summary: {
      session_id: "abc-123",
      model: "claude-sonnet-4-6",
      cwd: "/workspace",
      total_turns: 1,
      total_tool_calls: 1,
      total_cost_usd: 0.01,
      exit_reason: "success",
      tool_call_counts: { Bash: 1 },
      mcp_tool_called: false,
      available_tools_at_init: ["Bash"]
    },
    pagination: {
      page: 1,
      per: 100,
      total_events: overrides.totalEvents ?? events.length,
      total_pages: 1
    },
    events
  }
}

export function expectSyrusBrandLink(href: string) {
  const brandLink = screen.getByRole("link", { name: "Syrus" })
  expect(brandLink).toHaveAttribute("href", href)
  const mark = brandLink.querySelector('[data-testid="syrus-mark"]')
  expect(mark).not.toBeNull()
  expect(mark?.querySelector('g > rect[width="512"]')).toHaveAttribute("fill", "var(--color-brand)")
}

export function chatSearchPayload() {
  const threeDaysAgo = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()
  return {
    results: [
      {
        chat_session_id: 77,
        chat_title: "Forum planning",
        best_snippet: "Best <b>needle</b> <i>ignored</i>",
        badges: [{ kind: "coworker", id: 7, name: "Ada" }],
        best_match_message_id: 11,
        top_matches: [
          chatSearchMatch({ message_id: 11, role: "assistant", snippet: "Best <b>needle</b> <i>ignored</i>", created_at: threeDaysAgo }),
          chatSearchMatch({ message_id: 13, role: "assistant", snippet: "Third <b>needle</b>", created_at: threeDaysAgo }),
          chatSearchMatch({ message_id: 14, role: "tool_result", snippet: "Fourth <b>needle</b>", created_at: threeDaysAgo })
        ],
        total_match_count: 4,
        has_more_matches: true
      }
    ],
    total: 1,
    page: 1,
    per_page: 20
  }
}

export function chatSearchMatch(overrides: Record<string, unknown> = {}) {
  return {
    message_id: 11,
    role: "assistant",
    snippet: "Best <b>needle</b>",
    created_at: new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString(),
    ...overrides
  }
}
