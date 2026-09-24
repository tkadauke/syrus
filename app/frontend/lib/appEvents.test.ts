import { QueryClient } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ChatPayload } from "../api/chats"
import { applyAppEvent, queryKeysFor, resetAppEventSequenceTracking } from "./appEvents"
import { readEntity, resetEntityStoreForTest, upsertEntity } from "./entityStore"
import { flushClientMetricsQueue, resetClientMetricsForTest } from "./clientMetrics"
import { jsonResponse } from "../testSupport"

const desktopUa = "Mozilla/5.0 (Macintosh) Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.0 Safari/537.36"

class FakeNotification {
  static permission: NotificationPermission = "granted"
  static instances: FakeNotification[] = []

  title: string
  body?: string
  tag?: string

  constructor(title: string, options?: NotificationOptions) {
    this.title = title
    this.body = options?.body
    this.tag = options?.tag
    FakeNotification.instances.push(this)
  }

  close() {}
}

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  FakeNotification.permission = "granted"
  FakeNotification.instances = []
  resetEntityStoreForTest()
  resetClientMetricsForTest()
})

describe("queryKeysFor", () => {
  it("maps resource events to the query keys they invalidate", () => {
    expect(queryKeysFor(event("user", null))).toEqual([["bootstrap"]])
    expect(queryKeysFor(event("job", 42))).toEqual([["dashboard"], ["jobs"], ["jobs", "42", "detail"], ["job_run_artifacts", "42"]])
    expect(queryKeysFor(event("workflow", 7))).toEqual([["dashboard"], ["workflows"], ["workflows", "7"]])
    expect(queryKeysFor(event("epic", 5))).toEqual([["dashboard"], ["epics"], ["epics", "5"]])
    expect(queryKeysFor(event("repository", 3))).toEqual([["dashboard"], ["repositories"], ["repositories", "3"]])
    expect(queryKeysFor(event("design_doc", 19))).toEqual([["design_docs"], ["design_docs", "detail", "19"]])
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
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"], exact: true })
  })

  it("updates and invalidates notification cache when a notification is created", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, { type: "notification_created", unread_count: 3 })

    expect(queryClient.getQueryData(["notifications"])).toMatchObject({
      notifications: [],
      unread_count: 3
    })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["notifications"], exact: true })
  })

  it("dispatches a native browser notification when permission is granted", () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, {
      type: "notification_created",
      unread_count: 1,
      payload: {
        notification: { id: 1, kind: "pr_merged", body: "PR #4 merged", job_id: 4, pr_url: null }
      }
    })

    expect(FakeNotification.instances).toHaveLength(1)
    expect(FakeNotification.instances[0].title).toBe("PR merged")
    expect(FakeNotification.instances[0].body).toBe("PR #4 merged")
    expect(FakeNotification.instances[0].tag).toBe("syrus-notification-1")
  })

  it("dispatches with no dedupe tag when the notification payload lacks an id", () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, {
      type: "notification_created",
      unread_count: 1,
      payload: {
        notification: { kind: "pr_merged", body: "PR #4 merged", job_id: 4, pr_url: null }
      }
    })

    expect(FakeNotification.instances).toHaveLength(1)
    expect(FakeNotification.instances[0].tag).toBeUndefined()
  })

  it("does not dispatch a native browser notification when permission has not been granted", () => {
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "default"
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, {
      type: "notification_created",
      unread_count: 1,
      payload: {
        notification: { id: 1, kind: "pr_merged", body: "PR #4 merged", job_id: 4, pr_url: null }
      }
    })

    expect(FakeNotification.instances).toHaveLength(0)
  })

  it("dispatches a native browser notification inside the desktop shell too -- Electron main's own dispatch is fallback-only now", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(desktopUa)
    vi.stubGlobal("Notification", FakeNotification)
    FakeNotification.permission = "granted"
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, {
      type: "notification_created",
      unread_count: 1,
      payload: {
        notification: { id: 1, kind: "pr_merged", body: "PR #4 merged", job_id: 4, pr_url: null }
      }
    })

    expect(FakeNotification.instances).toHaveLength(1)
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
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["notifications"], exact: true })
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

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs"], exact: true })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["job_run_artifacts", "42"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["jobs", "42", "detail"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs", "42", "detail"] })
  })

  it("does not fan out a job event to source diff or review comment queries under the jobs prefix", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["jobs"], { jobs: [] })
    queryClient.setQueryData(["jobs", "42", "detail", ""], { job: { id: 42 } })
    queryClient.setQueryData(["jobs", "42", "source_diff", ""], { files: [] })
    queryClient.setQueryData(["jobs", "42", "diff_review_comments", "job_source_diff", ""], { comments: [] })

    applyAppEvent(queryClient, event("job", 42))

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs"], exact: true })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["jobs"] })
    expect(invalidate).not.toHaveBeenCalledWith(expect.objectContaining({ queryKey: ["jobs", "42", "source_diff", ""] }))
    expect(invalidate).not.toHaveBeenCalledWith(expect.objectContaining({ queryKey: ["jobs", "42", "diff_review_comments", "job_source_diff", ""] }))
  })

  it("marks hidden-tab event invalidations stale without immediate REST catch-up, then refetches each stale target once on visibility", () => {
    vi.useFakeTimers()
    vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden")
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    const refetch = vi.spyOn(queryClient, "refetchQueries").mockResolvedValue(undefined as never)

    applyAppEvent(queryClient, event("job", 42))
    applyAppEvent(queryClient, event("job", 42))
    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs"], exact: true, refetchType: "none" })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["jobs", "42", "detail"], refetchType: "none" })
    expect(refetch).not.toHaveBeenCalled()

    vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible")
    document.dispatchEvent(new Event("visibilitychange"))

    expect(refetch).toHaveBeenCalledWith({ queryKey: ["jobs"], exact: true, type: "active" })
    expect(refetch).toHaveBeenCalledWith({ queryKey: ["jobs", "42", "detail"], type: "active" })
    expect(refetch.mock.calls.filter(([arg]) => JSON.stringify(arg) === JSON.stringify({ queryKey: ["jobs", "42", "detail"], type: "active" }))).toHaveLength(1)
  })

  it("coalesces dashboard invalidations from event bursts", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-05-30T12:00:00.000Z"))
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, event("job", 42))
    applyAppEvent(queryClient, event("workflow", 7))

    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["dashboard"], exact: true })

    vi.runOnlyPendingTimers()

    expect(dashboardInvalidationCount(invalidate)).toBe(1)

    applyAppEvent(queryClient, event("job", 42))
    applyAppEvent(queryClient, event("workflow", 7))
    vi.advanceTimersByTime(4_999)

    expect(dashboardInvalidationCount(invalidate)).toBe(1)

    vi.advanceTimersByTime(1)

    expect(dashboardInvalidationCount(invalidate)).toBe(2)
  })

  it("targets mounted dashboard list queries instead of an unused exact root key", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, event("job", 42))
    vi.runOnlyPendingTimers()

    const predicate = invalidationPredicate(invalidate, ["dashboard"])
    expect(predicate).toBeDefined()
    expect(predicate?.({ queryKey: ["dashboard", "chrome", "?state=open"] })).toBe(true)
    expect(predicate?.({ queryKey: ["dashboard", "rows", "?state=open"] })).toBe(true)
    expect(predicate?.({ queryKey: ["dashboard", "graph", "jobs", "?state=open"] })).toBe(true)
    expect(predicate?.({ queryKey: ["jobs", "42", "source_diff", ""] })).toBe(false)
  })

  it("targets repository index list queries without invalidating repository detail or plugin tab queries", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, event("repository", 3))

    const predicate = invalidationPredicate(invalidate, ["repositories"])
    expect(predicate).toBeDefined()
    expect(predicate?.({ queryKey: ["repositories"] })).toBe(true)
    expect(predicate?.({ queryKey: ["repositories", ""] })).toBe(true)
    expect(predicate?.({ queryKey: ["repositories", "?archived=true"] })).toBe(true)
    expect(predicate?.({ queryKey: ["repositories", "3"] })).toBe(false)
    expect(predicate?.({ queryKey: ["repositories", "3", "tests", ""] })).toBe(false)
    expect(predicate?.({ queryKey: ["repositories", "owners"] })).toBe(false)
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

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"], exact: true })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("invalidates chat details for oversized chat message payloads while updating turn state", () => {
    vi.useFakeTimers()
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "9", ""], chatPayload([
      message(1, "user", "old")
    ]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "invalidate_messages",
        turn_in_flight: false,
        agent_busy: true,
        stop_requested_at: "2026-05-30T12:00:00Z",
        queued_messages: []
      }
    })

    const updated = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(updated?.turn_in_flight).toBe(false)
    expect(updated?.agent_busy).toBe(true)
    expect(updated?.chat.stop_requested_at).toBe("2026-05-30T12:00:00Z")
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

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"], exact: true })
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

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats"], exact: true })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("applies a lightweight turn-state payload to the recent-chats sidebar without touching the open chat detail query", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "recent"], {
      groups: [{
        key: "general",
        label: "General",
        repository_id: null,
        chats: [{ ...chatPayload([]).chat, turn_in_flight: false, agent_busy: false, current: false, last_message_at: "2026-05-30T11:00:00Z", unread: false }],
        has_more: false
      }],
      repositories: []
    })
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: { action: "update_turn_state", turn_in_flight: true, agent_busy: true }
    })

    expect(invalidate).not.toHaveBeenCalled()
    const recent = queryClient.getQueryData<{ groups: Array<{ chats: Array<{ id: number; turn_in_flight?: boolean; agent_busy?: boolean }> }> }>(["chats", "recent"])
    expect(recent?.groups[0].chats[0].turn_in_flight).toBe(true)
    expect(recent?.groups[0].chats[0].agent_busy).toBe(true)
    // Unlike update_controls/replace_tail, this lightweight payload (sent to
    // every tab over AppUserChannel, not just ChatChannel subscribers
    // actively viewing this chat) never carries message content or touches
    // the open chat-detail query -- that only comes from ChatChannel.
    const detail = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(detail?.turn_in_flight).toBe(true)
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

  it("updates and clears chat turn retry state from controls payloads", () => {
    const queryClient = new QueryClient()
    const state = {
      classification: "chat_turn_crashed",
      classification_label: "Chat turn crashed",
      retryable: true,
      next_auto_retry_at: "2026-09-18T12:05:00Z",
      retry_attempt_count: 1,
      retry_budget_remaining: 2,
      retry_budget: 3,
      auto_retry_exhausted: false,
      provider_circuit_open: false,
      retry_delayed_until: null,
      retry_delay_reason: null,
      state_label: "Retry scheduled"
    }
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_controls",
        turn_in_flight: true,
        agent_busy: false,
        turn_retry_state: state,
        stop_requested_at: null
      }
    })

    expect(queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])?.turn_retry_state).toEqual(state)

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_controls",
        turn_in_flight: true,
        agent_busy: true,
        turn_retry_state: null,
        stop_requested_at: null
      }
    })

    expect(queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])?.turn_retry_state).toBeNull()
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
          chat_model: "claude-sonnet-4-6",
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
    expect(updated?.chat.chat_model).toBe("claude-sonnet-4-6")
    expect(updated?.chat.repository).toEqual({ id: 3, slug: "acme/widgets" })
    expect(updated?.chat.cumulative_input_tokens).toBe(1500)
    expect(updated?.chat.cumulative_output_tokens).toBe(250)
    expect(updated?.chat.cumulative_cost_usd).toBe(0.125)
    const recent = queryClient.getQueryData<{ groups: Array<{ chats: Array<{ id: number; title: string | null; title_pending: boolean; repository: { id: number; slug: string } | null }> }> }>(["chats", "recent"])
    expect(recent?.groups[0].chats[0].title).toBe("Updated chat")
    expect(recent?.groups[0].chats[0].title_pending).toBe(false)
    expect(recent?.groups[0].chats[0].repository).toEqual({ id: 3, slug: "acme/widgets" })
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

  it("invalidates the chat-pins query cache on upsert_pin without touching the chat payload cache", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))
    queryClient.setQueryData(["chat-pins", "9", ""], { pins: [] })
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    const handled = applyAppEvent(queryClient, {
      ...event("chat", 9),
      changed: [ "pins" ],
      payload: { action: "upsert_pin", pin: { id: 1, chat_message_id: 3 } }
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: [ "chat-pins", "9" ], exact: true })
    const untouched = queryClient.getQueryData<ReturnType<typeof chatPayload>>(["chats", "9", ""])
    expect(untouched?.bookmarks).toEqual([])
  })

  it("invalidates the chat-pins query cache on remove_pin", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      changed: [ "pins" ],
      payload: { action: "remove_pin", pin: { id: 1, chat_message_id: 3 } }
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: [ "chat-pins", "9" ], exact: true })
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
            questions: [{ question: "Which path?", options: ["Fast", "Careful"], multiple: false }],
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
        questions: [{ question: "Which path?", options: ["Fast", "Careful"], multiple: false }],
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

  it("falls back to invalidating recent chats and chat detail when update_proposal has no serialized proposal", () => {
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

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "recent"], exact: true })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats"] })

    vi.runOnlyPendingTimers()

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "9"] })
  })

  it("patches the cached proposal in place and dispatches syrus:proposal-updated when update_proposal carries the serialized proposal", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    const dispatched: CustomEvent[] = []
    window.addEventListener("syrus:proposal-updated", (e) => dispatched.push(e as CustomEvent))

    const proposedProposal = chatProposal(42, { state: "proposed", proposed: true })
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(5, "assistant", "Proposal", { proposal: proposedProposal })]))

    const confirmedProposal = chatProposal(42, { state: "confirmed", proposed: false, resolved: true })
    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_proposal",
        proposal_id: 42,
        proposal: confirmedProposal,
        pending_proposal_count: 3
      }
    })

    const patched = queryClient.getQueryData<{ messages: Array<{ proposal?: { state: string } }>; pending_proposal_count: number }>(["chats", "9", ""])
    expect(patched?.messages[0].proposal?.state).toBe("confirmed")
    expect(patched?.pending_proposal_count).toBe(3)

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "recent"], exact: true })
    expect(invalidate).not.toHaveBeenCalledWith({ queryKey: ["chats", "9"] })

    expect(dispatched).toHaveLength(1)
    expect(dispatched[0].detail).toEqual({ chatSessionId: "9", proposal: confirmedProposal })
  })

  it("adds a chat Jobs-tab pending-proposal card immediately when a new Job proposal broadcasts as proposed", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", "job_status"], chatJobStatusPayload([]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_proposal",
        proposal_id: 42,
        job_status_proposal: chatJobStatusPendingProposal(42, { kind: "job", state: "proposed" })
      }
    })

    const patched = queryClient.getQueryData<{ pending_proposals: Array<{ id: number; kind: string }> }>(["chats", "9", "job_status"])
    expect(patched?.pending_proposals?.map((entry) => entry.id)).toEqual([42])
    expect(patched?.pending_proposals?.[0].kind).toBe("job")
  })

  it("adds a chat Jobs-tab pending-proposal card immediately when a new Epic proposal broadcasts as proposed", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", "job_status"], chatJobStatusPayload([]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_proposal",
        proposal_id: 43,
        job_status_proposal: chatJobStatusPendingProposal(43, { kind: "epic", state: "proposed", active_children_count: 2 })
      }
    })

    const patched = queryClient.getQueryData<{ pending_proposals: Array<{ id: number; kind: string }> }>(["chats", "9", "job_status"])
    expect(patched?.pending_proposals?.map((entry) => entry.id)).toEqual([43])
    expect(patched?.pending_proposals?.[0].kind).toBe("epic")
  })

  it("removes a chat Jobs-tab pending-proposal card immediately when it is confirmed, rejected, or withdrawn", () => {
    for (const state of [ "confirmed", "rejected", "withdrawn" ]) {
      const queryClient = new QueryClient()
      queryClient.setQueryData(["chats", "9", "job_status"], chatJobStatusPayload([ chatJobStatusPendingProposal(42, { state: "proposed" }) ]))

      applyAppEvent(queryClient, {
        ...event("chat", 9),
        payload: {
          action: "update_proposal",
          proposal_id: 42,
          job_status_proposal: chatJobStatusPendingProposal(42, { state })
        }
      })

      const patched = queryClient.getQueryData<{ pending_proposals: Array<{ id: number }> }>(["chats", "9", "job_status"])
      expect(patched?.pending_proposals).toEqual([])
    }
  })

  it("does not patch a different chat's job_status pending-proposal cache", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", "job_status"], chatJobStatusPayload([]))
    queryClient.setQueryData(["chats", "10", "job_status"], chatJobStatusPayload([]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "update_proposal",
        proposal_id: 42,
        job_status_proposal: chatJobStatusPendingProposal(42, { state: "proposed" })
      }
    })

    const untouched = queryClient.getQueryData<{ pending_proposals: Array<{ id: number }> }>(["chats", "10", "job_status"])
    expect(untouched?.pending_proposals).toEqual([])
  })

  it("does not corrupt job_status cache when update_controls arrives", () => {
    const queryClient = new QueryClient()
    const jobStatusData = [{ kind: "job", job_id: 1, slug: "JOB-1", title: "Test", state: "open", workflow_step: null, active_workflow: null, pr_number: null, pr_url: null, blocker: null }]
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
    const jobStatusData = [{ kind: "job", job_id: 1, slug: "JOB-1", title: "Test", state: "open", workflow_step: null, active_workflow: null, pr_number: null, pr_url: null, blocker: null }]
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

  it("dispatches a syrus:theme-preview DOM event for open_theme_preview payloads", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    const dispatched: CustomEvent[] = []
    window.addEventListener("syrus:theme-preview", (e) => dispatched.push(e as CustomEvent))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: {
        action: "open_theme_preview",
        theme_id: 42,
        path: "/design_system?theme_id=42"
      }
    })

    expect(dispatched).toHaveLength(1)
    expect(dispatched[0].detail).toEqual({ chat_session_id: 9, theme_id: 42, path: "/design_system?theme_id=42" })
    expect(invalidate).not.toHaveBeenCalled()
  })
})

describe("applyAppEvent revisioned event patches", () => {
  it("patches the normalized entity store from a resource event's payload.fields", () => {
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, {
      ...event("workflow", 100),
      sequence: 1,
      revision: 3,
      payload: { fields: { state: "running", started_at: "2026-09-23T00:00:00.000Z" } }
    })

    const workflow = readEntity("workflows", 100)
    expect(workflow?.fields.state).toBe("running")
    expect(workflow?.fields.started_at).toBe("2026-09-23T00:00:00.000Z")
    expect(workflow?.revision).toBe(3)
  })

  it("ignores a duplicate or replayed event outright, including its entity patch", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, { ...event("run", 5), sequence: 4, revision: 2, payload: { fields: { state: "succeeded" } } })
    invalidate.mockClear()

    applyAppEvent(queryClient, { ...event("run", 5), sequence: 4, revision: 2, payload: { fields: { state: "queued" } } })
    applyAppEvent(queryClient, { ...event("run", 5), sequence: 3, revision: 1, payload: { fields: { state: "cancelled" } } })

    expect(readEntity("runs", 5)?.fields.state).toBe("succeeded")
    expect(invalidate).not.toHaveBeenCalled()
  })

  it("applies an unsequenced event (no sequence field) without disturbing gap tracking", () => {
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, { ...event("job", 1), sequence: 1 })
    applyAppEvent(queryClient, { ...event("epic", 2) }) // no sequence -- e.g. a bypass broadcaster
    applyAppEvent(queryClient, { ...event("job", 1), sequence: 2, revision: 5, payload: { fields: { state: "running" } } })

    expect(readEntity("jobs", 1)?.revision).toBe(5)
  })

  it("recovers with one bounded, targeted refresh scoped to the resource a detected gap arrived on", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 1 })
    invalidate.mockClear()

    // Sequence jumps from 1 to 5: at least three broadcasts for this user
    // were dropped somewhere in between.
    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 5 })

    expect(invalidate).toHaveBeenCalledWith(expect.objectContaining({ queryKey: ["dashboard"] }))
    expect(invalidate).toHaveBeenCalledWith(expect.objectContaining({ queryKey: ["workflows"] }))
    expect(invalidate).toHaveBeenCalledWith(expect.objectContaining({ queryKey: ["workflows", "7"] }))
  })

  it("does not treat a merely in-order event as a gap", () => {
    // A routine (non-gap) event already invalidates queryKeysFor's keys on
    // every delivery -- gap detection must not add an extra recovery pass
    // on top of that, so the in-order second call should invalidate no
    // more than the same first call already did.
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 1 })
    const routineCallCount = invalidate.mock.calls.length
    invalidate.mockClear()

    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 2 })

    expect(invalidate).toHaveBeenCalledTimes(routineCallCount)
  })

  it("resumes normal in-order tracking after resetAppEventSequenceTracking (e.g. on reconnect)", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")

    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 1 })
    const routineCallCount = invalidate.mock.calls.length
    resetAppEventSequenceTracking(queryClient)
    invalidate.mockClear()

    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 40 })

    expect(invalidate).toHaveBeenCalledTimes(routineCallCount)
  })

  it("makes a snapshot race deterministic regardless of arrival order", () => {
    // Event arrives first (e.g. while a REST snapshot fetch for the same
    // Job is still in flight): applied immediately, not buffered/lost.
    upsertEntity({ kind: "jobs", id: 42, fields: { state: "running" }, revision: 5, source: "app_event" })
    // The in-flight snapshot resolves after, but is older than what the
    // event already established -- it must not move state backward.
    upsertEntity({ kind: "jobs", id: 42, fields: { state: "queued" }, revision: 3, source: "job_detail" })
    expect(readEntity("jobs", 42)?.fields.state).toBe("running")

    // Reverse order: an older event lands after a newer snapshot already
    // resolved -- the stale event must not overwrite it either.
    upsertEntity({ kind: "jobs", id: 43, fields: { state: "running" }, revision: 5, source: "job_detail" })
    upsertEntity({ kind: "jobs", id: 43, fields: { state: "queued" }, revision: 3, source: "app_event" })
    expect(readEntity("jobs", 43)?.fields.state).toBe("running")
  })

  it("folds chat message tail patches into the common entity-store mechanism", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      sequence: 1,
      payload: {
        action: "replace_tail",
        replace_from_id: 2,
        messages: [{ ...message(2, "assistant", "hi there"), entity_revision: 6 }]
      }
    })

    const stored = readEntity("chat_messages", 2)
    expect(stored?.fields.text).toBe("hi there")
    expect(stored?.revision).toBe(6)
  })

  it("does not let an older duplicate chat-tail delivery move a message backward through the entity store", () => {
    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "9", ""], chatPayload([message(1, "user", "old")]))

    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: { action: "replace_tail", replace_from_id: 2, messages: [{ ...message(2, "assistant", "final text"), entity_revision: 6 }] }
    })
    applyAppEvent(queryClient, {
      ...event("chat", 9),
      payload: { action: "replace_tail", replace_from_id: 2, messages: [{ ...message(2, "assistant", "stale replay"), entity_revision: 4 }] }
    })

    expect(readEntity("chat_messages", 2)?.fields.text).toBe("final text")
  })
})

describe("applyAppEvent client-reported amplification metrics", () => {
  function sentClientMetrics(fetchSpy: ReturnType<typeof vi.spyOn>): Array<{ name: string; resource: string; by: number }> {
    flushClientMetricsQueue()
    return fetchSpy.mock.calls.flatMap((call: unknown[]) => {
      const init = call[1] as RequestInit
      return JSON.parse(String(init.body)).client_metrics
    })
  }

  it("reports a real entity-store patch, but not a discarded duplicate/stale one", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, { ...event("run", 5), sequence: 1, revision: 2, payload: { fields: { state: "succeeded" } } })
    // Stale replay of the same revision -- upsertEntity discards it outright.
    applyAppEvent(queryClient, { ...event("run", 5), sequence: 2, revision: 1, payload: { fields: { state: "cancelled" } } })

    expect(sentClientMetrics(fetchSpy)).toEqual([
      { name: "entity_patch_applications", resource: "run", visibility_state: "visible", by: 1 }
    ])
  })

  it("reports a revision-gap recovery tagged with the resource the gap arrived on", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 1 })
    applyAppEvent(queryClient, { ...event("workflow", 7), sequence: 5 })

    expect(sentClientMetrics(fetchSpy)).toEqual(expect.arrayContaining([
      { name: "revision_gap_recoveries", resource: "workflow", by: 1 }
    ]))
  })

  it("reports a hidden-tab suppressed fetch tagged by the invalidated query's resource", () => {
    vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden")
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    const queryClient = new QueryClient()

    applyAppEvent(queryClient, event("job", 42))

    expect(sentClientMetrics(fetchSpy)).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "hidden_tab_suppressed_fetches", resource: "job" })
    ]))
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

function invalidationPredicate(invalidate: { mock: { calls: unknown[][] } }, queryKey: unknown[]) {
  const call = invalidate.mock.calls.find(([arg]) => {
    const candidate = arg as { queryKey?: unknown } | undefined
    return JSON.stringify(candidate?.queryKey) === JSON.stringify(queryKey)
  })
  return (call?.[0] as { predicate?: (query: { queryKey: unknown[] }) => boolean } | undefined)?.predicate
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

function chatProposal(id: number, overrides: Record<string, unknown> = {}) {
  return {
    id,
    kind: "syrus_issue",
    kind_label: "Syrus issue",
    state: "proposed",
    state_label: "Proposed",
    title: "Add greeting helper",
    slug: "add-greeting-helper",
    body: "Do it.",
    proposed: true,
    resolved: false,
    epic_bundle: false,
    scoped_repository_slug: "tkadauke/syrus",
    dependencies: [],
    has_dependencies: false,
    target_epic_id: null,
    target_epic_label: null,
    app_update_path: "/api/v1/app/chats/9/proposals/42",
    app_confirm_path: "/api/v1/app/chats/9/proposals/42/confirm",
    app_reject_path: "/api/v1/app/chats/9/proposals/42/reject",
    materialized_label: null,
    materialized_path: null,
    ...overrides
  }
}

function chatJobStatusPendingProposal(id: number, overrides: Record<string, unknown> = {}) {
  return {
    id,
    kind: "job",
    title: "Add greeting helper",
    state: "proposed",
    anchor_message_id: 5,
    active_children_count: null,
    created_at: "2026-05-30T12:00:00.000Z",
    ...overrides
  }
}

function chatJobStatusPayload(pendingProposals: Array<ReturnType<typeof chatJobStatusPendingProposal>>) {
  return { pending_proposals: pendingProposals, items: [] }
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

function chatPayload(messages: Array<ReturnType<typeof message>>): ChatPayload {
  return {
    message: null,
    chat: {
      id: 9,
      title: "Chat",
      title_pending: true,
      pinned: false,
      pinned_context: null,
      chat_model: null,
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
    turn_retry_state: null,
    switching_provider: false,
    has_more_older: false,
    messages,
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    scratchpad_items: [],
    preview_panels: [],
    workspace_tabs: [],
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
    documents_in_scope: [],
    attachment_results: [],
    whiteboard: { version: 0, elements: [], appState: {}, files: {} },
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false,
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/9/messages",
      app_message_path: "/api/v1/app/chats/9/message",
      app_rename_path: "/api/v1/app/chats/9/rename",
      app_clear_path: "/api/v1/app/chats/9/messages",
      app_branch_path: "/api/v1/app/chats/9/branch",
      app_share_path: "/api/v1/app/chats/9/share",
      app_enqueue_message_path: "/api/v1/app/chats/9/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/9/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/9/stop",
      app_daemon_connection_path: "/api/v1/app/chats/9/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/9/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/9/bookmarks",
      app_attachments_path: "/api/v1/app/chats/9/attachments",
      app_whiteboard_path: "/api/v1/app/chats/9/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/9/scratchpad_items/reorder"
    }
  }
}
