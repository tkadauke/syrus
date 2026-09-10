import { QueryClient } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { mergeChatPayloadUpdate, updateRecentChatCache } from "./chatCache"
import type { ChatNavRecord, ChatPayload, ChatsIndexPayload } from "../api/chats"

describe("mergeChatPayloadUpdate", () => {
  it("patches compact chat metadata into the cached full payload without dropping transcript state", () => {
    const queryClient = new QueryClient()
    const queryKey = ["chat", "8", ""] as const
    queryClient.setQueryData<ChatPayload>(queryKey, chatPayload())

    const merged = mergeChatPayloadUpdate(queryClient, queryKey, {
      message: "Chat pinned",
      chat: { id: 8, pinned: true, chat_model: "claude-sonnet-4-6" }
    })

    expect(merged.message).toBe("Chat pinned")
    expect(merged.chat.pinned).toBe(true)
    expect(merged.chat.chat_model).toBe("claude-sonnet-4-6")
    expect(merged.messages).toEqual([
      expect.objectContaining({ id: 101, role: "user" })
    ])
    expect(queryClient.getQueryData<ChatPayload>(queryKey)).toEqual(merged)
  })
})

describe("updateRecentChatCache", () => {
  it("moves the active chat to the top and records fresh activity", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-25T12:00:00Z"))

    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "recent"], {
      repositories: [],
      groups: [
        {
          key: "general",
          label: "General",
          repository_id: null,
          chats: [
            chatRecord({ id: 1, title: "Newer", lastMessageAt: "2026-06-25T11:00:00Z" }),
            chatRecord({ id: 2, title: "Active", lastMessageAt: "2026-06-24T11:00:00Z", updatedAt: "2026-06-24T11:00:00Z" })
          ],
          has_more: false
        }
      ]
    })

    updateRecentChatCache(queryClient, { ...chatRecord({ id: 2, title: "Active", lastMessageAt: "2026-06-24T11:00:00Z" }) }, { prepend: true })

    const updated = queryClient.getQueryData<ChatsIndexPayload>(["chats", "recent"])
    const chats = updated?.groups[0]?.chats
    expect(chats?.map((chat) => chat.id)).toEqual([2, 1])
    expect(chats?.[0].updated_at).toBe("2026-06-25T12:00:00.000Z")

    vi.useRealTimers()
  })
})

function chatRecord({ id, title, lastMessageAt, updatedAt }: { id: number; title: string; lastMessageAt: string | null; updatedAt?: string }): ChatNavRecord {
  return {
    id,
    title,
    title_pending: false,
    pinned: false,
    pinned_context: null,
    chat_provider: "claude",
    chat_path: `/chats/${id}`,
    repository: null,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    current: false,
    last_message_at: lastMessageAt,
    unread: false,
    pending_proposal_count: 0,
    scratchpad_items_count: 0,
    created_at: "2026-06-20T10:00:00Z",
    updated_at: updatedAt || lastMessageAt || "2026-06-20T10:00:00Z"
  }
}

function chatPayload(): ChatPayload {
  return {
    message: null,
    chat: {
      ...chatRecord({ id: 8, title: "Chat", lastMessageAt: "2026-06-25T11:00:00Z" }),
      current_user_id: 1,
      conversation_kind: "direct",
      participants: [],
      effective_chat_provider: "claude",
      effective_chat_provider_label: "Claude",
      chat_model: null,
      available_chat_models: [],
      provider_availability: null,
      chat_provider_options: [],
      mode: "planning",
      agent_busy: false,
      turn_in_flight: false,
      confirmed_proposal_count: 0,
      linked_direct_job_count: 0,
      runtime_session_count: 0,
      typed_artifact_count: 0,
      has_chat_images: false,
      coding_checkout_uncommitted: false,
      coding_checkout_branch: null,
      chat_effort: null
    },
    chat_available: true,
    turn_in_flight: false,
    agent_busy: false,
    chat_shell_command_in_flight: null,
    switching_provider: false,
    has_more_older: false,
    pending_proposal_count: 0,
    messages: [
      {
        type: "message",
        id: 101,
        role: "user",
        content: { text: "Keep me" },
        text: "Keep me",
        bookmarkable: true,
        created_at: "2026-06-25T11:00:00Z",
        pending_action: null
      }
    ],
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    pending_action_groups: [],
    agent_questions: [],
    queued_messages: [],
    active_goal: null,
    scratchpad_items: [],
    preview_panels: [],
    workspace_tabs: [],
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
    documents_in_scope: [],
    attachment_results: [],
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/8/messages",
      app_message_path: "/api/v1/app/chats/8/message",
      app_rename_path: "/api/v1/app/chats/8/rename",
      app_delete_path: "/api/v1/app/chats/8",
      app_clear_path: "/api/v1/app/chats/8/messages",
      app_branch_path: "/api/v1/app/chats/8/branch",
      app_share_path: "/api/v1/app/chats/8/share",
      app_enqueue_message_path: "/api/v1/app/chats/8/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/8/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_daemon_connection_path: "/api/v1/app/chats/8/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/8/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_attachments_path: "/api/v1/app/chats/8/attachments",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/8/scratchpad_items/reorder"
    },
    whiteboard: { version: 1, elements: [], appState: {}, files: {}, loaded: false },
    speech_to_text: {
      enabled: false,
      modes: {
        backend_streaming: { available: false },
        backend_batch: { available: false },
        browser: { available: true }
      }
    },
    coding_mode_enabled: true,
    local_mode_enabled: true,
    local_tunnel_connected: false
  }
}
