import { QueryClient } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { applyAppEvent, queryKeysFor } from "./appEvents"

afterEach(() => {
  vi.useRealTimers()
})

describe("queryKeysFor", () => {
  it("maps resource events to the query keys they invalidate", () => {
    expect(queryKeysFor(event("user", null))).toEqual([["bootstrap"]])
    expect(queryKeysFor(event("job", 42))).toEqual([["dashboard"], ["jobs"], ["jobs", "42", "detail"], ["job_run_artifacts", "42"]])
    expect(queryKeysFor(event("workflow", 7))).toEqual([["dashboard"], ["workflows"], ["workflows", "7"]])
    expect(queryKeysFor(event("epic", 5))).toEqual([["dashboard"], ["epics"], ["epics", "5"]])
    expect(queryKeysFor(event("repository", 3))).toEqual([["dashboard"], ["repositories"], ["repositories", "3"]])
    expect(queryKeysFor(event("chat", 5))).toEqual([["chats"], ["chats", "5"]])
    expect(queryKeysFor(event("provider_availability", "codex"))).toEqual([["bootstrap"], ["dashboard"], ["chats"]])
    expect(queryKeysFor(event("admin_overview", null))).toEqual([["admin", "overview"], ["admin", "stuck"]])
    expect(queryKeysFor(event("unknown", 1))).toEqual([])
  })

  it("maps nested workflow progress job events to the workflows query prefix", () => {
    expect(queryKeysFor({
      ...event("job", 42),
      changed: ["run.updated", "state"]
    })).toContainEqual(["jobs", "42", "workflows"])
  })
})

describe("applyAppEvent", () => {
  it("invalidates bootstrap, dashboard, and chats when provider availability changes", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      type: "provider_availability.changed",
      resource: "provider_availability",
      id: "codex",
      changed: ["provider_availability"]
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["bootstrap"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["jobs"] })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"] })
  })

  it("updates and invalidates notification cache when a notification is created", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, { type: "notification_created", unread_count: 3 })

    expect(queryClient.getQueryData(["notifications"])).toMatchObject({
      notifications: [],
      unread_count: 3
    })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["notifications"] })
  })

  it("marks one cached notification read when a notification read event arrives", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["notifications"], notificationsCache([
      notification(1),
      notification(2)
    ], 2))

    applyAppEvent(queryClient, {
      type: "notification_read",
      unread_count: 1,
      payload: {
        notification_ids: [2],
        read_at: "2026-06-25T12:01:00Z"
      }
    })

    expect(queryClient.getQueryData<ReturnType<typeof notificationsCache>>(["notifications"])).toMatchObject({
      unread_count: 1,
      notifications: [
        { id: 1, read_at: null },
        { id: 2, read_at: "2026-06-25T12:01:00Z" }
      ]
    })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["notifications"] })
  })

  it("marks all cached notifications read when a bulk read event arrives", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["notifications"], notificationsCache([
      notification(1),
      notification(2, "2026-06-25T11:00:00Z")
    ], 1))

    applyAppEvent(queryClient, {
      type: "notification_read",
      unread_count: 0,
      payload: {
        all_read: true,
        read_at: "2026-06-25T12:01:00Z"
      }
    })

    expect(queryClient.getQueryData<ReturnType<typeof notificationsCache>>(["notifications"])).toMatchObject({
      unread_count: 0,
      notifications: [
        { id: 1, read_at: "2026-06-25T12:01:00Z" },
        { id: 2, read_at: "2026-06-25T11:00:00Z" }
      ]
    })
  })

  it("invalidates cheap job query keys immediately and coalesces job detail", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, event("job", 42))

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs"] })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["job_run_artifacts", "42"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["jobs", "42", "detail"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs", "42", "detail"] })
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
    vi.useFakeTimers()
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
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("invalidates chat queries instead of crashing when cached chat messages are malformed", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], {
      ...chatPayload([message(1, "user", "old")]),
      messages: undefined
    })

    expect(() => applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "replace_tail",
        replace_from_id: 1,
        messages: [message(1, "assistant", "fresh response")]
      }
    })).not.toThrow()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("invalidates chat queries for queued pending action updates", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      changed: ["pending_action_updated"],
      payload: {
        action: "pending_action_updated",
        pending_action_id: 12,
        state: "pending"
      }
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("applies chat controls payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "recent"], {
      groups: [{
        key: "general",
        label: "General",
        repository_id: null,
        chats: [{ ...chatPayload([]).chat, turn_in_flight: true, agent_busy: true, current: false, last_message_at: "2026-05-30T11:00:00Z", unread: false }],
        has_more: false
      }],
      repositories: []
    })
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
    const recent = queryClient.getQueryData<{ groups: Array<{ chats: Array<{ id: number; turn_in_flight?: boolean; agent_busy?: boolean }> }> }>(["chats", "recent"])
    expect(recent?.groups[0].chats[0].turn_in_flight).toBe(false)
    expect(recent?.groups[0].chats[0].agent_busy).toBe(false)
  })

  it("updates scratchpad_items_count in recent chats when update_controls includes scratchpad_items", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "recent"], {
      groups: [{
        key: "general",
        label: "General",
        repository_id: null,
        chats: [{ ...chatPayload([]).chat, turn_in_flight: false, agent_busy: false, current: false, last_message_at: "2026-05-30T11:00:00Z", unread: false, scratchpad_items_count: 3 }],
        has_more: false
      }],
      repositories: []
    })

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_controls",
        turn_in_flight: false,
        agent_busy: false,
        stop_requested_at: null,
        scratchpad_items: []
      }
    })

    const recent = queryClient.getQueryData<{ groups: Array<{ chats: Array<{ id: number; scratchpad_items_count: number }> }> }>(["chats", "recent"])
    expect(recent?.groups[0].chats[0].scratchpad_items_count).toBe(0)
  })

  it("leaves scratchpad_items_count unchanged in recent chats when update_controls omits scratchpad_items", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "recent"], {
      groups: [{
        key: "general",
        label: "General",
        repository_id: null,
        chats: [{ ...chatPayload([]).chat, turn_in_flight: false, agent_busy: false, current: false, last_message_at: "2026-05-30T11:00:00Z", unread: false, scratchpad_items_count: 2 }],
        has_more: false
      }],
      repositories: []
    })

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_controls",
        turn_in_flight: false,
        agent_busy: false,
        stop_requested_at: null
      }
    })

    const recent = queryClient.getQueryData<{ groups: Array<{ chats: Array<{ id: number; scratchpad_items_count: number }> }> }>(["chats", "recent"])
    expect(recent?.groups[0].chats[0].scratchpad_items_count).toBe(2)
  })

  it("applies chat header payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))
    queryClient.setQueryData(["chats", "recent"], {
      groups: [
        {
          key: "general",
          label: "General",
          repository_id: null,
          has_more: false,
          chats: [
            {
              ...chatPayload([]).chat,
              id: 9,
              title: null,
              title_pending: true,
              last_message_at: "2026-05-30T12:00:00Z",
              unread: false
            }
          ]
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
          repository: { id: 3, slug: "acme/widgets" },
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
    expect(updated?.chat.repository).toEqual({ id: 3, slug: "acme/widgets" })
    expect(updated?.chat.cumulative_input_tokens).toBe(1500)
    expect(updated?.chat.cumulative_output_tokens).toBe(250)
    expect(updated?.chat.cumulative_cost_usd).toBe(0.125)
    const recent = queryClient.getQueryData<{ groups: Array<{ chats: Array<{ id: number; title: string | null; title_pending: boolean; repository: { id: number; slug: string } | null }> }> }>(["chats", "recent"])
    expect(recent?.groups[0].chats[0].title).toBe("Updated chat")
    expect(recent?.groups[0].chats[0].title_pending).toBe(false)
    expect(recent?.groups[0].chats[0].repository).toEqual({ id: 3, slug: "acme/widgets" })
  })

  it("applies supervisor chat header payloads to the top-level recent slot", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))
    queryClient.setQueryData(["chats", "recent"], {
      supervisor_chat: {
        ...chatPayload([]).chat,
        id: 9,
        title: "Supervisor",
        title_pending: false,
        system_kind: "supervisor",
        current: false,
        last_message_at: "2026-05-30T12:00:00Z",
        unread: false,
        pending_proposal_count: 0,
        scratchpad_items_count: 0
      },
      groups: [{
        key: "general",
        label: "General",
        repository_id: null,
        has_more: false,
        chats: []
      }],
      repositories: []
    })

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_header",
        chat: {
          title: "Supervisor",
          title_pending: false,
          system_kind: "supervisor",
          cumulative_input_tokens: 300
        }
      }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const recent = queryClient.getQueryData<{ supervisor_chat?: { system_kind?: string; cumulative_input_tokens?: number }; groups: Array<{ chats: unknown[] }> }>(["chats", "recent"])
    expect(recent?.supervisor_chat?.system_kind).toBe("supervisor")
    expect(recent?.supervisor_chat?.cumulative_input_tokens).toBe(300)
    expect(recent?.groups[0].chats).toEqual([])
  })

  it("invalidates recent chats when a supervisor event appends", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      changed: ["last_message_at", "last_read_at", "supervisor_event"]
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "recent"] })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("applies chat header payloads when the cached recent chat list is missing", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], {
      ...chatPayload([message(1, "user", "old")]),
      recent_chats: undefined
    })

    expect(() => applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_header",
        chat: {
          title: "Updated chat",
          title_pending: false
        }
      }
    })).not.toThrow()

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.chat.title).toBe("Updated chat")
    expect(updated?.recent_chats).toEqual([])
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

  it("applies chat bookmark payloads when the cached bookmark list is missing", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], {
      ...chatPayload([message(1, "user", "old")]),
      bookmarks: undefined
    })

    expect(() => applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "upsert_bookmark",
        bookmark: { id: 5, label: "Fresh aqueduct", chat_message_id: 3, anchor_message_id: 6 }
      }
    })).not.toThrow()

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.bookmarks).toEqual([
      { id: 5, label: "Fresh aqueduct", chat_message_id: 3, anchor_message_id: 6 }
    ])
  })

  it("applies chat agent question payloads directly to cached chat data", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_agent_questions",
        agent_questions: [
          {
            id: 7,
            question: "Which path?",
            options: ["Fast", "Careful"],
            asked_at: "2026-05-30T12:00:00Z",
            app_answer_path: "/api/v1/app/chats/9/agent_questions/7/answer"
          }
        ]
      }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.agent_questions).toEqual([
      {
        id: 7,
        question: "Which path?",
        options: ["Fast", "Careful"],
        asked_at: "2026-05-30T12:00:00Z",
        app_answer_path: "/api/v1/app/chats/9/agent_questions/7/answer"
      }
    ])
  })

  it("invalidates cached chat data for pending action updates", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "assistant", "Confirm?")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "pending_action_updated",
        pending_action_id: 7,
        chat_message_id: 1
      }
    })

    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("invalidates cached chat data for orphaned pending action updates", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "pending_action_updated",
        pending_action_id: 7,
        chat_message_id: null
      }
    })

    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("invalidates recent chats and chat detail for update_proposal events", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_proposal",
        proposal_id: 42
      }
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "recent"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("does not corrupt job_status cache when update_controls arrives", () => {
    const queryClient = new QueryClient()
    const jobStatusData = [{ kind: "job", job_id: 1, slug: "JOB-1", title: "Test", state: "open", workflow_step: null, pr_number: null, pr_url: null, blocker: null }]
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "hello")]))
    queryClient.setQueryData(["chats", "9", "job_status"], jobStatusData)

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_controls",
        turn_in_flight: false,
        agent_busy: false,
        stop_requested_at: null
      }
    })

    expect(queryClient.getQueryData(["chats", "9", "job_status"])).toEqual(jobStatusData)
  })

  it("does not corrupt job_status cache when update_header arrives", () => {
    const queryClient = new QueryClient()
    const jobStatusData = [{ kind: "job", job_id: 1, slug: "JOB-1", title: "Test", state: "open", workflow_step: null, pr_number: null, pr_url: null, blocker: null }]
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "hello")]))
    queryClient.setQueryData(["chats", "9", "job_status"], jobStatusData)

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_header",
        chat: { title: "New Title" }
      }
    })

    expect(queryClient.getQueryData(["chats", "9", "job_status"])).toEqual(jobStatusData)
  })

  it("dispatches a syrus:job-status-changed DOM event for job_status_changed payloads", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    const dispatched: CustomEvent[] = []
    window.addEventListener("syrus:job-status-changed", (e) => dispatched.push(e as CustomEvent))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "job_status_changed",
        job_id: 77
      }
    })

    expect(dispatched).toHaveLength(1)
    expect(dispatched[0].detail).toEqual({ job_id: 77, chat_session_id: 9 })
    expect(invalidate).not.toHaveBeenCalled()
  })
})

function event(resource: string, id: number | string | null) {
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

function notificationsCache(notifications: Array<ReturnType<typeof notification>>, unreadCount: number) {
  return {
    notifications,
    unread_count: unreadCount,
    pagination: {
      page: 1,
      per_page: 20,
      total: notifications.length,
      total_pages: notifications.length > 0 ? 1 : 0
    }
  }
}

function notification(id: number, readAt: string | null = null) {
  return {
    id,
    kind: "job_failed",
    body: `Notification ${id}`,
    read_at: readAt,
    pr_url: null,
    job_id: null,
    job_title: null,
    created_at: "2026-06-25T12:00:00Z"
  }
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
      pinned: false,
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
    agent_questions: [],
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
    documents_in_scope: [],
    attachment_results: [],
    whiteboard: { version: 0, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/9/messages",
      app_message_path: "/api/v1/app/chats/9/message",
      app_rename_path: "/api/v1/app/chats/9/rename",
      app_clear_path: "/api/v1/app/chats/9/messages",
      app_stop_path: "/api/v1/app/chats/9/stop",
      app_bookmarks_path: "/api/v1/app/chats/9/bookmarks",
      app_attachments_path: "/api/v1/app/chats/9/attachments",
      app_whiteboard_path: "/api/v1/app/chats/9/whiteboard"
    }
  }
}
