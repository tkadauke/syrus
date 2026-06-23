import { QueryClient } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { applyAppEvent, queryKeysFor } from "./appEvents"

afterEach(() => {
  vi.useRealTimers()
})

describe("queryKeysFor", () => {
  it("maps resource events to the query keys they invalidate", () => {
    expect(queryKeysFor(event("user", null))).toEqual([["bootstrap"]])
    expect(queryKeysFor(event("job", 42))).toEqual([["dashboard"], ["jobs"], ["jobs", "42"], ["job_run_artifacts", "42"]])
    expect(queryKeysFor(event("workflow", 7))).toEqual([["dashboard"], ["workflows"], ["workflows", "7"]])
    expect(queryKeysFor(event("epic", 5))).toEqual([["dashboard"], ["epics"], ["epics", "5"]])
    expect(queryKeysFor(event("repository", 3))).toEqual([["dashboard"], ["repositories"], ["repositories", "3"]])
    expect(queryKeysFor(event("chat", 5))).toEqual([["chats"], ["chats", "5"]])
    expect(queryKeysFor(event("admin_overview", null))).toEqual([["admin", "overview"], ["admin", "stuck"]])
    expect(queryKeysFor(event("unknown", 1))).toEqual([])
  })

  it("maps nested workflow progress job events to the Job detail query prefix", () => {
    expect(queryKeysFor({
      ...event("job", 42),
      changed: ["run.updated", "state"]
    })).toContainEqual(["jobs", "42"])
  })
})

describe("applyAppEvent", () => {
  it("invalidates non-dashboard query keys immediately", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, event("job", 42))

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs"] })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs", "42"] })
  })

  it("coalesces dashboard invalidations from event bursts", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-05-30T12:00:00.000Z"))
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, event("job", 42))
    applyAppEvent(queryClient, event("workflow", 7))

    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["dashboard"] })

    vi.runOnlyPendingTimers()

    expect(dashboardInvalidationCount(invalidate)).toBe(1)

    applyAppEvent(queryClient, event("job", 42))
    applyAppEvent(queryClient, event("workflow", 7))
    vi.advanceTimersByTime(4_999)

    expect(dashboardInvalidationCount(invalidate)).toBe(1)

    vi.advanceTimersByTime(1)

    expect(dashboardInvalidationCount(invalidate)).toBe(2)
  })

  it("applies chat replace-tail payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([
      message(1, "user", "old"),
      message(2, "tool_use", "read a", { tool_name: "Read", content: { input: { file_path: "a.rb" } } }),
      message(3, "tool_use", "read b", { tool_name: "Read", content: { input: { file_path: "b.rb" } } })
    ]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "replace_tail",
        replace_from_id: 3,
        turn_in_flight: false,
        agent_busy: true,
        stop_requested_at: "2026-05-30T12:00:00Z",
        messages: [
          message(3, "tool_use", "read b again", { tool_name: "Read", content: { input: { file_path: "b.rb" } } }),
          message(4, "tool_result", "b result", { tool_name: "Read", content: { result: [{ type: "text", text: "b" }] } }),
          message(5, "assistant", "done")
        ]
      }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.turn_in_flight).toBe(false)
    expect(updated?.agent_busy).toBe(true)
    expect(updated?.chat.stop_requested_at).toBe("2026-05-30T12:00:00Z")
    expect(updated?.messages).toEqual([
      message(1, "user", "old"),
      message(2, "tool_use", "read a", { tool_name: "Read", content: { input: { file_path: "a.rb" } } }),
      message(3, "tool_use", "read b again", { tool_name: "Read", content: { input: { file_path: "b.rb" } } }),
      message(4, "tool_result", "b result", { tool_name: "Read", content: { result: [{ type: "text", text: "b" }] } }),
      message(5, "assistant", "done")
    ])
  })

  it("invalidates chat queries when a typed chat event arrives before chat data is cached", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "replace_tail",
        replace_from_id: 1,
        messages: [message(1, "assistant", "fast response")]
      }
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"] })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("applies chat controls payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_controls",
        turn_in_flight: false,
        agent_busy: false,
        stop_requested_at: "2026-05-30T12:00:00Z"
      }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.turn_in_flight).toBe(false)
    expect(updated?.agent_busy).toBe(false)
    expect(updated?.chat.stop_requested_at).toBe("2026-05-30T12:00:00Z")
  })

  it("applies chat header payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))
    queryClient.setQueryData(["chats", "recent"], {
      chats: [
        {
          ...chatPayload([]).chat,
          id: 9,
          title: null,
          title_pending: true,
          last_message_at: "2026-05-30T12:00:00Z",
          unread: false
        }
      ],
      repositories: []
    })

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_header",
        chat: {
          title: "Updated chat",
          title_pending: false,
          pinned_context: "Keep the rollout plan in scope.",
          cumulative_input_tokens: 1500,
          cumulative_output_tokens: 250,
          cumulative_cost_usd: 0.125
        }
      }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.chat.title).toBe("Updated chat")
    expect(updated?.chat.title_pending).toBe(false)
    expect(updated?.chat.pinned_context).toBe("Keep the rollout plan in scope.")
    expect(updated?.chat.cumulative_input_tokens).toBe(1500)
    expect(updated?.chat.cumulative_output_tokens).toBe(250)
    expect(updated?.chat.cumulative_cost_usd).toBe(0.125)
    const recent = queryClient.getQueryData<{ chats: Array<{ id: number; title: string | null; title_pending: boolean }> }>(["chats", "recent"])
    expect(recent?.chats[0].title).toBe("Updated chat")
    expect(recent?.chats[0].title_pending).toBe(false)
  })

  it("applies chat bookmark payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], {
      ...chatPayload([message(1, "user", "old")]),
      bookmarks: [{ id: 4, label: "Opening", chat_message_id: 1, anchor_message_id: 1 }]
    })

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "upsert_bookmark",
        bookmark: { id: 5, label: "Fresh aqueduct", chat_message_id: 3, anchor_message_id: 6 }
      }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.bookmarks).toEqual([
      { id: 4, label: "Opening", chat_message_id: 1, anchor_message_id: 1 },
      { id: 5, label: "Fresh aqueduct", chat_message_id: 3, anchor_message_id: 6 }
    ])
  })

  it("replaces existing cached chat bookmarks by id", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", ""], {
      ...chatPayload([message(1, "user", "old")]),
      bookmarks: [{ id: 4, label: "Opening", chat_message_id: 1, anchor_message_id: 1 }]
    })

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "upsert_bookmark",
        bookmark: { id: 4, label: "Opening revised", chat_message_id: 1, anchor_message_id: 1 }
      }
    })

    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.bookmarks).toEqual([
      { id: 4, label: "Opening revised", chat_message_id: 1, anchor_message_id: 1 }
    ])
  })
})

function event(resource: string, id: number | null) {
  return {
    type: `${resource}.updated`,
    resource,
    id,
    changed: [],
    occurred_at: "2026-05-30T12:00:00.000Z"
  }
}

function dashboardInvalidationCount(invalidate: { mock: { calls: unknown[][] } }) {
  return invalidate.mock.calls.filter((call) => {
    const args = call[0] as { queryKey?: unknown } | undefined
    return (
      args != null &&
      Array.isArray(args.queryKey) &&
      args.queryKey.length === 1 &&
      args.queryKey[0] === "dashboard"
    )
  }).length
}

function message(id: number, role: "user" | "assistant" | "tool_use" | "tool_result" | "system", text: string, overrides: Record<string, unknown> = {}) {
  return {
    type: "message" as const,
    id,
    role,
    tool_name: null,
    content: { text },
    text,
    bookmarkable: true,
    ...overrides
  }
}

function chatPayload(messages: Array<ReturnType<typeof message>>) {
  return {
    message: null,
    chat: {
      id: 9,
      title: "Chat",
      title_pending: true,
      pinned_context: null,
      chat_path: "/chats/9",
      repository: null,
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0
    },
    chat_available: true,
    turn_in_flight: true,
    agent_busy: false,
    has_more_older: false,
    messages,
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
    documents_in_scope: [],
    attachment_results: [],
    whiteboard: { version: 0, elements: [], appState: {}, files: {} },
    paths: {
      new_chat_path: "/chats/new",
      credentials_path: "/credentials/edit",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/9/messages",
      app_message_path: "/api/v1/app/chats/9/message",
      app_stop_path: "/api/v1/app/chats/9/stop",
      app_bookmarks_path: "/api/v1/app/chats/9/bookmarks",
      app_attachments_path: "/api/v1/app/chats/9/attachments",
      app_whiteboard_path: "/api/v1/app/chats/9/whiteboard"
    }
  }
}
