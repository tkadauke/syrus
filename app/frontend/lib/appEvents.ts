import type { QueryClient, QueryKey } from "@tanstack/react-query"
import type { ChatAgentQuestion, ChatAgentSubQuestion, ChatBookmark, ChatConversationKind, ChatJobStatusPayload, ChatJobStatusPendingProposal, ChatMessageItem, ChatParticipant, ChatPayload, ChatProposal, ChatQueuedMessage, ChatRecord, ChatRepository } from "../api/chats"
import { updateRecentChatHeaderCache, updateRecentChatScratchpadCache, updateRecentChatTurnCache } from "./chatRecentCache"
import { dispatchNativeNotification, httpNotificationUrl, type NativeNotificationPayload } from "./nativeNotifications"
import { replaceProposalInMessages } from "../routes/chat/messageStreamItems"
import { normalizeChatMessage, readEntity, upsertEntity, type EntityKind, type EntityRevision } from "./entityStore"
import { currentVisibilityState, recordClientMetric, resourceTagFor } from "./clientMetrics"

// A proposal card can live in a chat view's paginated-older-history state,
// outside the React Query cache the rest of this module patches. Dispatching
// this alongside the cache patch lets any mounted chat view also update that
// out-of-cache copy, regardless of where the proposal's message currently
// scrolled to. See MessageStream in routes/Chat.tsx for the listener.
export const PROPOSAL_UPDATED_EVENT = "syrus:proposal-updated"

export type ProposalUpdatedDetail = { chatSessionId: string; proposal: ChatProposal }

export function dispatchProposalUpdated(chatSessionId: string | number, proposal: ChatProposal) {
  if (typeof window === "undefined") return
  window.dispatchEvent(new CustomEvent<ProposalUpdatedDetail>(PROPOSAL_UPDATED_EVENT, {
    detail: { chatSessionId: String(chatSessionId), proposal }
  }))
}

const DASHBOARD_INVALIDATION_MIN_INTERVAL_MS = 5_000
const DASHBOARD_INVALIDATION_RETRY_MS = 1_000
const JOB_DETAIL_INVALIDATION_MIN_INTERVAL_MS = 5_000
const JOB_DETAIL_INVALIDATION_RETRY_MS = 1_000
const CHAT_DETAIL_INVALIDATION_MIN_INTERVAL_MS = 5_000
const CHAT_DETAIL_INVALIDATION_RETRY_MS = 1_000

type InvalidationTarget = {
  exact?: boolean
  key?: string
  predicate?: (query: { queryKey: QueryKey }) => boolean
  queryKey: QueryKey
}

type DashboardInvalidationState = {
  lastInvalidatedAt: number
  pending: boolean
  timer: ReturnType<typeof setTimeout> | null
}

const dashboardInvalidations = new WeakMap<QueryClient, DashboardInvalidationState>()
const jobDetailInvalidations = new WeakMap<QueryClient, Map<string, DashboardInvalidationState>>()
const chatDetailInvalidations = new WeakMap<QueryClient, Map<string, DashboardInvalidationState>>()
const hiddenInvalidations = new WeakMap<QueryClient, Map<string, InvalidationTarget>>()
const visibilityListeners = new WeakSet<QueryClient>()

export type AppEvent = {
  type: string
  resource?: string
  id?: number | string | null
  // Per-user, monotonically increasing across every AppEvents.broadcast
  // call regardless of resource -- lets the client detect a dropped
  // delivery (a gap) or a network-level duplicate/replay without relying
  // on wall-clock occurred_at. Absent on the handful of broadcast paths
  // that don't yet route through AppEvents.broadcast; such events are
  // always applied and never participate in gap/duplicate detection.
  sequence?: number
  // The broadcasting resource's own revision counter (Job/Workflow/Step/
  // Run/ChatSession/ChatMessage#entity_revision), when the caller has one. Lets
  // entityStore.upsertEntity ignore this specific event outright if a
  // newer revision for the same entity is already known -- independent of
  // the stream-level sequence check above, and independent of arrival
  // order relative to a REST snapshot fetch (see applyAppEventToEntityStore).
  revision?: EntityRevision
  changed?: string[]
  occurred_at?: string
  payload?: unknown
  unread_count?: number
}

// Resources that map onto a normalized entityStore kind and so can be
// patched directly from an event's payload.fields, in addition to
// whatever React Query cache invalidation already happens below.
const EVENT_RESOURCE_ENTITY_KIND: Partial<Record<string, EntityKind>> = {
  job: "jobs",
  workflow: "workflows",
  step: "steps",
  run: "runs",
  chat: "chat_sessions"
}

type AppEventSequenceOutcome = "ok" | "duplicate" | "gap"

const lastAppEventSequence = new WeakMap<QueryClient, number>()

export function resetAppEventSequenceTracking(queryClient: QueryClient) {
  lastAppEventSequence.delete(queryClient)
}

// Stream-level ordering check, independent of any single resource: every
// event sharing one per-user sequence counter means a gap here means
// *something* was missed, not necessarily the resource this event is
// about, so the caller recovers just the resource this event names --
// bounded and targeted rather than a blanket refresh.
function trackAppEventSequence(queryClient: QueryClient, event: AppEvent): AppEventSequenceOutcome {
  if (typeof event.sequence !== "number") return "ok"

  const previous = lastAppEventSequence.get(queryClient)
  if (previous === undefined || event.sequence > previous) {
    lastAppEventSequence.set(queryClient, event.sequence)
    return previous !== undefined && event.sequence > previous + 1 ? "gap" : "ok"
  }

  return "duplicate"
}

// Patches the normalized entity store directly from an event's payload,
// when the event carries one. This is the "snapshot race" seam: an event
// applied here while a REST snapshot fetch for the same entity is still
// in flight is not lost (upsertEntity applies it immediately), and is not
// clobbered once that snapshot resolves (upsertEntity's own revision
// comparison -- see entityStore.ts -- refuses to let an older revision
// overwrite a newer one, regardless of which one lands first). There is
// no separate buffer-then-replay queue because that revision comparison
// already makes the merge order-independent and so deterministic by
// construction, for both directions of the race.
function applyAppEventToEntityStore(event: AppEvent) {
  const kind = event.resource ? EVENT_RESOURCE_ENTITY_KIND[event.resource] : undefined
  if (!kind || event.id == null) return

  const fields = entityFieldsFromEventPayload(event.payload)
  if (!fields && event.revision == null) return

  const before = readEntity(kind, event.id)
  const after = upsertEntity({
    kind,
    id: event.id,
    fields: fields ?? {},
    completeness: "partial",
    revision: event.revision ?? null,
    source: "app_event"
  })
  // upsertEntity returns the same object, unchanged, when it rejects a
  // stale/duplicate revision (see entityStore.ts) -- only a real patch
  // counts toward the amplification signal, not a discarded duplicate.
  if (after !== before) recordClientMetric("entity_patch_applications", resourceTagFor(event.resource), currentVisibilityState())
}

function entityFieldsFromEventPayload(payload: unknown): Record<string, unknown> | null {
  if (!payload || typeof payload !== "object") return null

  const fields = (payload as { fields?: unknown }).fields
  return fields && typeof fields === "object" && !Array.isArray(fields) ? fields as Record<string, unknown> : null
}

type NotificationsCache = {
  notifications: Array<{ id: number; read_at: string | null }>
  unread_count: number
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
  }
}

type NotificationReadPayload = {
  notification_ids?: number[]
  all_read?: boolean
  read_at?: string
}

export function applyAppEvent(queryClient: QueryClient, event: AppEvent) {
  const sequenceOutcome = trackAppEventSequence(queryClient, event)
  if (sequenceOutcome === "duplicate") return

  applyAppEventToEntityStore(event)
  if (sequenceOutcome === "gap") {
    recordClientMetric("revision_gap_recoveries", resourceTagFor(event.resource))
    recoverEventResourceContinuity(queryClient, event)
  }

  if (event.type.startsWith("video_walkthrough.")) {
    // The chat composer owns the walkthrough chip; hand it the payload
    // directly (a chat-scoped query invalidation would not carry state).
    if (typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("syrus:video-walkthrough", {
        detail: { id: event.id, ...(event.payload as object | undefined) }
      }))
    }
    return
  }

  if (event.type === "notification_created") {
    const current = queryClient.getQueryData<{ unread_count: number }>(["notifications"])
    const unreadCount = typeof event.unread_count === "number" ? event.unread_count : (current?.unread_count ?? 0) + 1
    queryClient.setQueryData(["notifications"], current ? {
      ...current,
      unread_count: unreadCount
    } : {
      notifications: [],
      unread_count: unreadCount,
      pagination: {
        page: 1,
        per_page: 20,
        total: 0,
        total_pages: 0
      }
    })
    invalidateAppQuery(queryClient, { queryKey: ["notifications"], exact: true })

    const nativePayload = notificationCreatedNativePayload(event.payload)
    if (nativePayload) dispatchNativeNotification(nativePayload)
    return
  }

  if (event.type === "notification_read") {
    const payload = notificationReadPayload(event.payload)
    const readAt = payload?.read_at ?? event.occurred_at ?? new Date().toISOString()
    queryClient.setQueryData<NotificationsCache>(["notifications"], (current) => {
      const unreadCount = typeof event.unread_count === "number" ? event.unread_count : current?.unread_count ?? 0
      if (!current) return emptyNotificationsCache(unreadCount)

      const readIds = new Set(payload?.notification_ids ?? [])
      return {
        ...current,
        unread_count: unreadCount,
        notifications: current.notifications.map((notification) => {
          if (!payload?.all_read && !readIds.has(notification.id)) return notification

          return {
            ...notification,
            read_at: notification.read_at ?? readAt
          }
        })
      }
    })
    invalidateAppQuery(queryClient, { queryKey: ["notifications"], exact: true })
    return
  }

  if (applyChatPayloadEvent(queryClient, event)) return

  let dashboardChanged = false
  for (const queryKey of queryKeysFor(event)) {
    if (isDashboardQueryKey(queryKey)) {
      dashboardChanged = true
      continue
    }

    if (isJobDetailQueryKey(queryKey)) {
      scheduleJobDetailInvalidation(queryClient, queryKey)
      continue
    }

    if (isChatDetailQueryKey(queryKey)) {
      scheduleChatDetailInvalidation(queryClient, queryKey)
      continue
    }

    invalidateAppQuery(queryClient, exactListTarget(queryKey))
  }
  if (dashboardChanged) scheduleDashboardInvalidation(queryClient)
}

// A detected sequence gap means *some* event for this user was dropped --
// not necessarily one about this resource -- but the only resource we
// know for sure might be stale is the one this event names, so recovery
// is bounded to exactly its query keys rather than the full continuity
// sweep recoverAppEventContinuity does on reconnect.
function recoverEventResourceContinuity(queryClient: QueryClient, event: AppEvent) {
  for (const queryKey of queryKeysFor(event)) {
    invalidateAppQuery(queryClient, { queryKey })
  }
}

export function recoverAppEventContinuity(queryClient: QueryClient) {
  if (tabIsHidden()) {
    for (const query of queryClient.getQueryCache().findAll({ type: "active", predicate: continuityRecoveryQuery })) {
      invalidateAppQuery(queryClient, { queryKey: query.queryKey, exact: true })
    }
    return
  }

  void queryClient.refetchQueries({ type: "active", predicate: continuityRecoveryQuery })
}

// Bounded reconnect recovery for a resource-scoped (JobChannel/ChatChannel)
// subscription: unlike recoverAppEventContinuity's full sweep of every active
// query, a resource channel only ever carried events for this one Job or
// Chat, so a reconnect can only have missed events about that one resource --
// recovery is scoped to it instead of the whole app. Reuses invalidateAppQuery
// so hidden tabs still defer to a catch-up-on-visible refetch rather than
// fetching in the background (see markHiddenInvalidation/flushHiddenInvalidations).
export function recoverJobResourceContinuity(queryClient: QueryClient, jobId: string | number) {
  const id = String(jobId)
  invalidateAppQuery(queryClient, { queryKey: [ "jobs", id, "detail" ] })
  invalidateAppQuery(queryClient, { queryKey: [ "jobs", id, "workflows" ] })
}

export function recoverChatResourceContinuity(queryClient: QueryClient, chatId: string | number) {
  invalidateAppQuery(queryClient, { queryKey: [ "chats", String(chatId) ] })
}

function invalidateAppQuery(queryClient: QueryClient, target: InvalidationTarget) {
  if (tabIsHidden()) {
    recordClientMetric("hidden_tab_suppressed_fetches", resourceTagFor(String(target.queryKey[0] ?? "")))
    markHiddenInvalidation(queryClient, target)
    void queryClient.invalidateQueries({ ...queryFilterFor(target), refetchType: "none" })
    return
  }

  void queryClient.invalidateQueries(queryFilterFor(target))
}

function markHiddenInvalidation(queryClient: QueryClient, target: InvalidationTarget) {
  let pending = hiddenInvalidations.get(queryClient)
  if (!pending) {
    pending = new Map()
    hiddenInvalidations.set(queryClient, pending)
  }
  pending.set(invalidationTargetKey(target), target)
  ensureVisibilityListener(queryClient)
}

function ensureVisibilityListener(queryClient: QueryClient) {
  if (typeof document === "undefined") return
  if (visibilityListeners.has(queryClient)) return

  visibilityListeners.add(queryClient)
  document.addEventListener("visibilitychange", () => {
    if (tabIsHidden()) return
    flushHiddenInvalidations(queryClient)
  })
}

function flushHiddenInvalidations(queryClient: QueryClient) {
  const pending = hiddenInvalidations.get(queryClient)
  if (!pending || pending.size === 0) return

  const targets = Array.from(pending.values())
  pending.clear()
  for (const target of targets) {
    void queryClient.refetchQueries({ ...queryFilterFor(target), type: "active" })
  }
}

function invalidationTargetKey(target: InvalidationTarget) {
  if (target.key) return target.key
  return `${target.exact === true ? "exact" : "prefix"}:${JSON.stringify(target.queryKey)}`
}

function tabIsHidden() {
  return typeof document !== "undefined" && document.visibilityState === "hidden"
}

function queryFilterFor(target: InvalidationTarget) {
  const base = target.exact === true ? { queryKey: target.queryKey, exact: true } : { queryKey: target.queryKey }
  return target.predicate ? { ...base, predicate: target.predicate } : base
}

function emptyNotificationsCache(unreadCount: number): NotificationsCache {
  return {
    notifications: [],
    unread_count: unreadCount,
    pagination: {
      page: 1,
      per_page: 20,
      total: 0,
      total_pages: 0
    }
  }
}

function notificationCreatedNativePayload(payload: unknown): NativeNotificationPayload | null {
  if (!payload || typeof payload !== "object") return null

  const notification = (payload as { notification?: unknown }).notification
  if (!notification || typeof notification !== "object") return null

  const record = notification as Record<string, unknown>
  const kind = typeof record.kind === "string" ? record.kind : null
  const body = typeof record.body === "string" ? record.body : null
  if (!kind || !body) return null

  return {
    kind,
    body,
    jobId: typeof record.job_id === "number" ? record.job_id : null,
    prUrl: httpNotificationUrl(record.pr_url),
    notificationId: typeof record.id === "number" ? record.id : null
  }
}

function notificationReadPayload(payload: unknown): NotificationReadPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as NotificationReadPayload
  return {
    notification_ids: Array.isArray(candidate.notification_ids) ? candidate.notification_ids.filter((id) => typeof id === "number") : [],
    all_read: candidate.all_read === true,
    read_at: typeof candidate.read_at === "string" ? candidate.read_at : undefined
  }
}

export function queryKeysFor(event: AppEvent): QueryKey[] {
  switch (event.resource) {
    case "user":
      return [["bootstrap"]]
    case "job":
      return jobQueryKeysFor(event)
    case "workflow":
      return event.id == null ? [["dashboard"], ["workflows"]] : [["dashboard"], ["workflows"], ["workflows", String(event.id)]]
    case "epic":
      return event.id == null ? [["dashboard"], ["epics"]] : [["dashboard"], ["epics"], ["epics", String(event.id)]]
    case "repository":
      return event.id == null ? [["dashboard"], ["repositories"]] : [["dashboard"], ["repositories"], ["repositories", String(event.id)]]
    case "design_doc":
      return event.id == null ? [["design_docs"]] : [["design_docs"], ["design_docs", "detail", String(event.id)]]
    case "chat":
      return event.id == null
        ? [["chats"]]
        : chatMediaChanged(event)
          ? [["chats"], ["chats", String(event.id)], ["chat_media", String(event.id)], ["whiteboard_snapshots", String(event.id)]]
          : [["chats"], ["chats", String(event.id)]]
    case "provider_availability":
      return [["bootstrap"], ["dashboard"], ["chats"]]
    case "admin_overview":
      return [["admin", "overview"], ["admin", "stuck"]]
    default:
      return []
  }
}

function chatMediaChanged(event: AppEvent) {
  const changed = event.changed || []
  return changed.includes("media") || changed.includes("chat_images") || changed.includes("whiteboard_snapshots")
}

function jobQueryKeysFor(event: AppEvent): QueryKey[] {
  if (event.id == null) return [["dashboard"], ["jobs"], ["job_run_artifacts"]]

  const id = String(event.id)
  const detailKey: QueryKey = workflowOnlyJobEvent(event) ? ["jobs", id, "workflows"] : ["jobs", id, "detail"]
  return [["dashboard"], ["jobs"], detailKey, ["job_run_artifacts", id]]
}

function workflowOnlyJobEvent(event: AppEvent) {
  const changed = event.changed || []
  return changed.some((item) => item.startsWith("run.") || item.startsWith("step.") || item.startsWith("workflow."))
}

function isDashboardQueryKey(queryKey: QueryKey) {
  return queryKey.length === 1 && queryKey[0] === "dashboard"
}

function isJobDetailQueryKey(queryKey: QueryKey) {
  return queryKey.length === 3 &&
    queryKey[0] === "jobs" &&
    typeof queryKey[1] === "string" &&
    (queryKey[2] === "detail" || queryKey[2] === "workflows")
}

function isChatDetailQueryKey(queryKey: QueryKey) {
  return queryKey.length === 2 &&
    queryKey[0] === "chats" &&
    typeof queryKey[1] === "string" &&
    queryKey[1] !== "recent"
}

function scheduleDashboardInvalidation(queryClient: QueryClient) {
  const state = dashboardInvalidations.get(queryClient) ?? {
    lastInvalidatedAt: 0,
    pending: false,
    timer: null
  }
  state.pending = true
  dashboardInvalidations.set(queryClient, state)

  if (state.timer) return

  const elapsed = Date.now() - state.lastInvalidatedAt
  const delay = Math.max(0, DASHBOARD_INVALIDATION_MIN_INTERVAL_MS - elapsed)
  state.timer = setTimeout(() => flushDashboardInvalidation(queryClient), delay)
}

function flushDashboardInvalidation(queryClient: QueryClient) {
  const state = dashboardInvalidations.get(queryClient)
  if (!state) return

  state.timer = null
  if (!state.pending) return

  if (queryClient.isFetching({ queryKey: ["dashboard"] }) > 0) {
    state.timer = setTimeout(() => flushDashboardInvalidation(queryClient), DASHBOARD_INVALIDATION_RETRY_MS)
    return
  }

  state.pending = false
  state.lastInvalidatedAt = Date.now()
  invalidateAppQuery(queryClient, exactListTarget(["dashboard"]))
}

export function scheduleJobDetailInvalidation(queryClient: QueryClient, queryKey: QueryKey) {
  let states = jobDetailInvalidations.get(queryClient)
  if (!states) {
    states = new Map()
    jobDetailInvalidations.set(queryClient, states)
  }

  const stateKey = String(queryKey.join(":"))
  const state = states.get(stateKey) ?? {
    lastInvalidatedAt: 0,
    pending: false,
    timer: null
  }
  state.pending = true
  states.set(stateKey, state)

  if (state.timer) return

  const elapsed = Date.now() - state.lastInvalidatedAt
  const delay = Math.max(0, JOB_DETAIL_INVALIDATION_MIN_INTERVAL_MS - elapsed)
  state.timer = setTimeout(() => flushJobDetailInvalidation(queryClient, queryKey), delay)
}

function flushJobDetailInvalidation(queryClient: QueryClient, queryKey: QueryKey) {
  const stateKey = String(queryKey.join(":"))
  const state = jobDetailInvalidations.get(queryClient)?.get(stateKey)
  if (!state) return

  state.timer = null
  if (!state.pending) return

  if (queryClient.isFetching({ queryKey }) > 0) {
    state.timer = setTimeout(() => flushJobDetailInvalidation(queryClient, queryKey), JOB_DETAIL_INVALIDATION_RETRY_MS)
    return
  }

  state.pending = false
  state.lastInvalidatedAt = Date.now()
  invalidateAppQuery(queryClient, { queryKey })
}

function scheduleChatDetailInvalidation(queryClient: QueryClient, queryKey: QueryKey) {
  let states = chatDetailInvalidations.get(queryClient)
  if (!states) {
    states = new Map()
    chatDetailInvalidations.set(queryClient, states)
  }

  const stateKey = String(queryKey.join(":"))
  const state = states.get(stateKey) ?? {
    lastInvalidatedAt: 0,
    pending: false,
    timer: null
  }
  state.pending = true
  states.set(stateKey, state)

  if (state.timer) return

  const elapsed = Date.now() - state.lastInvalidatedAt
  const delay = Math.max(0, CHAT_DETAIL_INVALIDATION_MIN_INTERVAL_MS - elapsed)
  state.timer = setTimeout(() => flushChatDetailInvalidation(queryClient, queryKey), delay)
}

function flushChatDetailInvalidation(queryClient: QueryClient, queryKey: QueryKey) {
  const stateKey = String(queryKey.join(":"))
  const state = chatDetailInvalidations.get(queryClient)?.get(stateKey)
  if (!state) return

  state.timer = null
  if (!state.pending) return

  if (queryClient.isFetching({ queryKey }) > 0) {
    state.timer = setTimeout(() => flushChatDetailInvalidation(queryClient, queryKey), CHAT_DETAIL_INVALIDATION_RETRY_MS)
    return
  }

  state.pending = false
  state.lastInvalidatedAt = Date.now()
  invalidateAppQuery(queryClient, { queryKey })
}

function exactListTarget(queryKey: QueryKey): InvalidationTarget {
  const listTarget = listFamilyTarget(queryKey)
  if (listTarget) return listTarget

  return queryKey.length === 1 && exactListRoots.has(String(queryKey[0])) ? { queryKey, exact: true } : { queryKey }
}

function listFamilyTarget(queryKey: QueryKey): InvalidationTarget | null {
  const root = queryKey[0]

  if (queryKey.length !== 1) return null
  if (root === "dashboard") {
    return { queryKey, key: "list-family:dashboard", predicate: dashboardListQuery }
  }
  if (root === "repositories") {
    return { queryKey, key: "list-family:repositories", predicate: repositoryListQuery }
  }
  return null
}

const exactListRoots = new Set([
  "chats",
  "dashboard",
  "design_docs",
  "epics",
  "job_run_artifacts",
  "jobs",
  "notifications",
  "repositories",
  "workflows"
])

function continuityRecoveryQuery(query: { queryKey: QueryKey }) {
  const queryKey = query.queryKey
  const root = queryKey[0]

  if (dashboardListQuery(query) || repositoryListQuery(query)) return true
  if (queryKey.length === 1 && exactListRoots.has(String(root))) return true
  if (root === "bootstrap") return true
  if (root === "admin" && (queryKey[1] === "overview" || queryKey[1] === "stuck")) return true
  if (root === "chats" && queryKey.length >= 2) return true
  if (root === "epics" && queryKey.length >= 2) return true
  if (root === "repositories" && queryKey.length >= 2) return true
  if (root === "workflows" && queryKey.length >= 2) return true
  if (root !== "jobs") return false

  const jobQueryKind = queryKey[2]
  return jobQueryKind === "detail" || jobQueryKind === "workflows"
}

function dashboardListQuery(query: { queryKey: QueryKey }) {
  const queryKey = query.queryKey
  return queryKey[0] === "dashboard" &&
    (queryKey[1] === "chrome" || queryKey[1] === "rows" || queryKey[1] === "graph")
}

function repositoryListQuery(query: { queryKey: QueryKey }) {
  const queryKey = query.queryKey
  if (queryKey[0] !== "repositories") return false
  if (queryKey.length === 1) return true
  return queryKey.length === 2 && typeof queryKey[1] === "string" && (queryKey[1] === "" || queryKey[1].startsWith("?"))
}

function applyChatPayloadEvent(queryClient: QueryClient, event: AppEvent) {
  if (event.resource !== "chat" || event.id == null) return false

  const turnState = chatUpdateTurnStatePayload(event.payload)
  if (turnState) {
    updateRecentChatTurnCache(queryClient, event.id, { turn_in_flight: turnState.turn_in_flight, agent_busy: turnState.agent_busy })
    return true
  }

  const replaceTail = chatReplaceTailPayload(event.payload)
  if (replaceTail) {
    // Route each message through the same revision-gated entity merge as
    // everywhere else (see applyAppEventToEntityStore) instead of a
    // chat-tail-specific path, so a duplicate/out-of-order delivery of the
    // same tail can't move a message backward, and so any other surface
    // that reads a message by ID through the entity store (not just the
    // ChatPayload query below) also sees it.
    replaceTail.messages.forEach((message) => normalizeChatMessage(message, "app_event"))

    let patched = false
    if (typeof replaceTail.turn_in_flight === "boolean") updateRecentChatTurnCache(queryClient, event.id, { turn_in_flight: replaceTail.turn_in_flight, agent_busy: replaceTail.agent_busy })
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current) return current
        if (!Array.isArray(current.messages)) return current
        patched = true

        return {
          ...current,
          turn_in_flight: replaceTail.turn_in_flight ?? current.turn_in_flight,
          agent_busy: replaceTail.agent_busy ?? current.agent_busy,
          turn_retry_state: replaceTail.turn_retry_state !== undefined ? replaceTail.turn_retry_state : current.turn_retry_state,
          queued_messages: replaceTail.queued_messages ?? current.queued_messages,
          messages: replaceMessageTail(current.messages, replaceTail.replace_from_id, replaceTail.messages),
          chat: {
            ...current.chat,
            turn_retry_state: replaceTail.turn_retry_state !== undefined ? replaceTail.turn_retry_state : current.chat.turn_retry_state,
            stop_requested_at: replaceTail.stop_requested_at ?? current.chat.stop_requested_at
          }
        }
      }
    )
    return patched
  }

  const invalidateMessages = chatInvalidateMessagesPayload(event.payload)
  if (invalidateMessages) {
    updateRecentChatTurnCache(queryClient, event.id, { turn_in_flight: invalidateMessages.turn_in_flight, agent_busy: invalidateMessages.agent_busy })
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => current ? {
        ...current,
        turn_in_flight: invalidateMessages.turn_in_flight ?? current.turn_in_flight,
        agent_busy: invalidateMessages.agent_busy ?? current.agent_busy,
        turn_retry_state: invalidateMessages.turn_retry_state !== undefined ? invalidateMessages.turn_retry_state : current.turn_retry_state,
        queued_messages: invalidateMessages.queued_messages ?? current.queued_messages,
        chat: {
          ...current.chat,
          turn_retry_state: invalidateMessages.turn_retry_state !== undefined ? invalidateMessages.turn_retry_state : current.chat.turn_retry_state,
          stop_requested_at: invalidateMessages.stop_requested_at ?? current.chat.stop_requested_at
        }
      } : current
    )
    scheduleChatDetailInvalidation(queryClient, ["chats", String(event.id)])
    return true
  }

  const controls = chatControlsPayload(event.payload)
  if (controls) {
    let patched = false
    updateRecentChatTurnCache(queryClient, event.id, { turn_in_flight: controls.turn_in_flight, agent_busy: controls.agent_busy })
    if (controls.scratchpad_items_count !== undefined) {
      updateRecentChatScratchpadCache(queryClient, event.id, controls.scratchpad_items_count)
    }
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true

        return {
          ...current,
          turn_in_flight: controls.turn_in_flight,
          agent_busy: controls.agent_busy ?? current.agent_busy,
          turn_retry_state: controls.turn_retry_state !== undefined ? controls.turn_retry_state : current.turn_retry_state,
          switching_provider: controls.switching_provider ?? current.switching_provider,
          queued_messages: controls.queued_messages ?? current.queued_messages,
          chat: {
            ...current.chat,
            turn_retry_state: controls.turn_retry_state !== undefined ? controls.turn_retry_state : current.chat.turn_retry_state,
            stop_requested_at: controls.stop_requested_at
          }
        }
      }
    )
    return patched
  }

  const header = chatHeaderPayload(event.payload)
  if (header) {
    let patched = false
    updateRecentChatHeaderCache(queryClient, event.id, header.chat)
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        const recentChats = Array.isArray(current.recent_chats) ? current.recent_chats : []
        patched = true
        return {
          ...current,
          chat: { ...current.chat, ...header.chat },
          recent_chats: recentChats.map((chat) => (
            chat.id === current.chat.id ? { ...chat, ...header.chat } : chat
          ))
        }
      }
    )
    return patched
  }

  const participants = chatParticipantsPayload(event.payload)
  if (participants) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true
        return {
          ...current,
          chat: { ...current.chat, conversation_kind: participants.conversation_kind, participants: participants.participants }
        }
      }
    )
    return patched
  }

  const bookmark = chatBookmarkPayload(event.payload)
  if (bookmark) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        const bookmarks = Array.isArray(current.bookmarks) ? current.bookmarks : []
        patched = true
        return { ...current, bookmarks: upsertBookmark(bookmarks, bookmark.bookmark) }
      }
    )
    return patched
  }

  const pin = chatPinPayload(event.payload)
  if (pin) {
    // Pin broadcasts carry only the pin id / chat_message_id (no preview
    // text), so refetch the pins query rather than trying to patch it —
    // same "extend the existing chat-payload handling" pattern as the
    // bookmark/header/controls branches above, just invalidate-based since
    // pins live in their own query cache, not on ChatPayload itself.
    invalidateAppQuery(queryClient, { queryKey: ["chat-pins", String(event.id)], exact: true })
    return true
  }

  const agentQuestions = chatAgentQuestionsPayload(event.payload)
  if (agentQuestions) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true
        return { ...current, agent_questions: agentQuestions.agent_questions }
      }
    )
    return patched
  }

  const suggestion = chatSuggestionPayload(event.payload)
  if (suggestion) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true
        return {
          ...current,
          chat: { ...current.chat, suggested_next_step: suggestion.suggested_next_step }
        }
      }
    )
    return patched
  }

  const pendingAction = chatPendingActionUpdatedPayload(event.payload)
  if (pendingAction) {
    scheduleChatDetailInvalidation(queryClient, ["chats", String(event.id)])
    return true
  }

  const updateProposal = chatUpdateProposalPayload(event.payload)
  if (updateProposal) {
    invalidateAppQuery(queryClient, { queryKey: ["chats", "recent"], exact: true })

    if (updateProposal.job_status_proposal) {
      patchChatJobStatusPendingProposal(queryClient, event.id, updateProposal.job_status_proposal)
    }

    if (!updateProposal.proposal) {
      // Older/mixed-deploy broadcast without a serialized proposal: fall back
      // to a full refetch, same as before this event carried enough data to
      // patch directly.
      scheduleChatDetailInvalidation(queryClient, ["chats", String(event.id)])
      return true
    }

    const proposal = updateProposal.proposal
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        return {
          ...current,
          messages: replaceProposalInMessages(current.messages, proposal),
          pending_proposal_count: updateProposal.pending_proposal_count ?? current.pending_proposal_count
        }
      }
    )
    dispatchProposalUpdated(event.id, proposal)
    return true
  }

  const jobStatusChanged = chatJobStatusChangedPayload(event.payload)
  if (jobStatusChanged) {
    if (typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("syrus:job-status-changed", {
        detail: { job_id: jobStatusChanged.job_id, chat_session_id: event.id }
      }))
    }
    return true
  }

  const themePreview = chatThemePreviewPayload(event.payload)
  if (themePreview) {
    if (typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("syrus:theme-preview", {
        detail: { chat_session_id: event.id, theme_id: themePreview.theme_id, path: themePreview.path }
      }))
    }
    return true
  }

  return false
}

type ChatUpdateTurnStatePayload = {
  action: "update_turn_state"
  turn_in_flight: boolean
  agent_busy?: boolean
}

function chatUpdateTurnStatePayload(payload: unknown): ChatUpdateTurnStatePayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatUpdateTurnStatePayload>
  if (candidate.action !== "update_turn_state") return null
  if (typeof candidate.turn_in_flight !== "boolean") return null

  return {
    action: "update_turn_state",
    turn_in_flight: candidate.turn_in_flight,
    agent_busy: typeof candidate.agent_busy === "boolean" ? candidate.agent_busy : undefined
  }
}

type ChatReplaceTailPayload = {
  action: "replace_tail"
  replace_from_id: number
  messages: ChatMessageItem[]
  turn_in_flight?: boolean
  agent_busy?: boolean
  turn_retry_state?: ChatPayload["turn_retry_state"]
  stop_requested_at?: string | null
  queued_messages?: ChatQueuedMessage[]
}

type ChatControlsPayload = {
  action: "update_controls"
  turn_in_flight: boolean
  agent_busy?: boolean
  turn_retry_state?: ChatPayload["turn_retry_state"]
  stop_requested_at: string | null
  switching_provider?: boolean
  queued_messages?: ChatQueuedMessage[]
  scratchpad_items_count?: number
}

type ChatInvalidateMessagesPayload = {
  action: "invalidate_messages"
  turn_in_flight?: boolean
  agent_busy?: boolean
  turn_retry_state?: ChatPayload["turn_retry_state"]
  stop_requested_at?: string | null
  queued_messages?: ChatQueuedMessage[]
}

type ChatHeaderPayload = {
  action: "update_header"
  chat: Partial<Pick<ChatRecord, "title" | "title_pending" | "system_kind" | "pinned_context" | "chat_provider" | "effective_chat_provider" | "effective_chat_provider_label" | "provider_availability" | "chat_model" | "mode" | "local_daemon_state" | "local_daemon_repo" | "local_daemon_branch" | "repository" | "stop_requested_at" | "cumulative_input_tokens" | "cumulative_output_tokens" | "cumulative_cost_usd" | "coding_checkout_uncommitted">>
}

type ChatBookmarkPayload = {
  action: "upsert_bookmark"
  bookmark: ChatBookmark
}

type ChatPinPayload = {
  action: "upsert_pin" | "remove_pin"
}

type ChatAgentQuestionsPayload = {
  action: "update_agent_questions"
  agent_questions: ChatAgentQuestion[]
}

type ChatPendingActionUpdatedPayload = {
  action: "pending_action_updated"
  pending_action_id: number
  chat_message_id: number | null
}

type ChatSuggestionPayload = {
  action: "update_suggestion"
  suggested_next_step: string | null
}

type ChatUpdateProposalPayload = {
  action: "update_proposal"
  proposal_id: number
  proposal?: ChatProposal
  job_status_proposal?: ChatJobStatusPendingProposal
  pending_proposal_count?: number
}

type ChatJobStatusChangedPayload = {
  action: "job_status_changed"
  job_id: number
}

type ChatThemePreviewPayload = {
  action: "open_theme_preview"
  theme_id: number
  path: string
}

type ChatParticipantsPayload = {
  action: "update_participants"
  conversation_kind: ChatConversationKind
  participants: ChatParticipant[]
}

function chatReplaceTailPayload(payload: unknown): ChatReplaceTailPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatReplaceTailPayload>
  if (candidate.action !== "replace_tail") return null
  if (typeof candidate.replace_from_id !== "number") return null
  const messages = Array.isArray(candidate.messages) ? candidate.messages : Array.isArray((payload as { items?: unknown }).items) ? (payload as { items: unknown[] }).items : null
  if (!isChatMessages(messages)) return null

  return {
    action: "replace_tail",
    replace_from_id: candidate.replace_from_id,
    messages,
    turn_in_flight: typeof candidate.turn_in_flight === "boolean" ? candidate.turn_in_flight : undefined,
    agent_busy: typeof candidate.agent_busy === "boolean" ? candidate.agent_busy : undefined,
    turn_retry_state: isChatTurnRetryState(candidate.turn_retry_state) ? candidate.turn_retry_state : candidate.turn_retry_state === null ? null : undefined,
    stop_requested_at: typeof candidate.stop_requested_at === "string" || candidate.stop_requested_at === null ? candidate.stop_requested_at : undefined,
    queued_messages: isChatQueuedMessages(candidate.queued_messages) ? candidate.queued_messages : undefined
  }
}

function chatControlsPayload(payload: unknown): ChatControlsPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatControlsPayload>
  if (candidate.action !== "update_controls") return null
  if (typeof candidate.turn_in_flight !== "boolean") return null
  if (typeof candidate.stop_requested_at !== "string" && candidate.stop_requested_at !== null) return null

  return {
    action: "update_controls",
    turn_in_flight: candidate.turn_in_flight,
    agent_busy: typeof candidate.agent_busy === "boolean" ? candidate.agent_busy : undefined,
    turn_retry_state: isChatTurnRetryState(candidate.turn_retry_state) ? candidate.turn_retry_state : candidate.turn_retry_state === null ? null : undefined,
    stop_requested_at: candidate.stop_requested_at,
    switching_provider: typeof candidate.switching_provider === "boolean" ? candidate.switching_provider : undefined,
    queued_messages: isChatQueuedMessages(candidate.queued_messages) ? candidate.queued_messages : undefined,
    scratchpad_items_count: Array.isArray((candidate as { scratchpad_items?: unknown }).scratchpad_items)
      ? ((candidate as { scratchpad_items: unknown[] }).scratchpad_items).length
      : undefined
  }
}

function isChatTurnRetryState(value: unknown): value is NonNullable<ChatPayload["turn_retry_state"]> {
  if (!value || typeof value !== "object") return false

  const candidate = value as NonNullable<ChatPayload["turn_retry_state"]>
  return (typeof candidate.classification === "string" || candidate.classification === null) &&
    typeof candidate.classification_label === "string" &&
    typeof candidate.retryable === "boolean" &&
    (typeof candidate.next_auto_retry_at === "string" || candidate.next_auto_retry_at === null) &&
    typeof candidate.retry_attempt_count === "number" &&
    typeof candidate.retry_budget_remaining === "number" &&
    typeof candidate.retry_budget === "number" &&
    typeof candidate.auto_retry_exhausted === "boolean" &&
    typeof candidate.provider_circuit_open === "boolean" &&
    (typeof candidate.retry_delayed_until === "string" || candidate.retry_delayed_until === null) &&
    (typeof candidate.retry_delay_reason === "string" || candidate.retry_delay_reason === null) &&
    typeof candidate.state_label === "string"
}

function chatInvalidateMessagesPayload(payload: unknown): ChatInvalidateMessagesPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatInvalidateMessagesPayload>
  if (candidate.action !== "invalidate_messages") return null

  return {
    action: "invalidate_messages",
    turn_in_flight: typeof candidate.turn_in_flight === "boolean" ? candidate.turn_in_flight : undefined,
    agent_busy: typeof candidate.agent_busy === "boolean" ? candidate.agent_busy : undefined,
    turn_retry_state: isChatTurnRetryState(candidate.turn_retry_state) ? candidate.turn_retry_state : candidate.turn_retry_state === null ? null : undefined,
    stop_requested_at: typeof candidate.stop_requested_at === "string" || candidate.stop_requested_at === null ? candidate.stop_requested_at : undefined,
    queued_messages: isChatQueuedMessages(candidate.queued_messages) ? candidate.queued_messages : undefined
  }
}

function chatHeaderPayload(payload: unknown): ChatHeaderPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatHeaderPayload>
  if (candidate.action !== "update_header") return null
  if (!candidate.chat || typeof candidate.chat !== "object") return null

  const chat = candidate.chat
  const updates: ChatHeaderPayload["chat"] = {}
  if (typeof chat.title === "string" || chat.title === null) updates.title = chat.title
  if (typeof chat.title_pending === "boolean") updates.title_pending = chat.title_pending
  if (typeof chat.system_kind === "string" || chat.system_kind === null) updates.system_kind = chat.system_kind
  if (typeof chat.pinned_context === "string" || chat.pinned_context === null) updates.pinned_context = chat.pinned_context
  if (typeof chat.chat_provider === "string") updates.chat_provider = chat.chat_provider
  if (typeof chat.effective_chat_provider === "string") updates.effective_chat_provider = chat.effective_chat_provider
  if (typeof chat.effective_chat_provider_label === "string") updates.effective_chat_provider_label = chat.effective_chat_provider_label
  if (typeof chat.provider_availability === "object" || chat.provider_availability === null) updates.provider_availability = chat.provider_availability
  if (typeof chat.chat_model === "string" || chat.chat_model === null) updates.chat_model = chat.chat_model
  if (typeof chat.mode === "string" || chat.mode === null) updates.mode = chat.mode as ChatRecord["mode"]
  if (typeof chat.local_daemon_state === "string" || chat.local_daemon_state === null) updates.local_daemon_state = chat.local_daemon_state as ChatRecord["local_daemon_state"]
  if (typeof chat.local_daemon_repo === "string" || chat.local_daemon_repo === null) updates.local_daemon_repo = chat.local_daemon_repo
  if (typeof chat.local_daemon_branch === "string" || chat.local_daemon_branch === null) updates.local_daemon_branch = chat.local_daemon_branch
  if (isChatRepository(chat.repository) || chat.repository === null) updates.repository = chat.repository
  if (typeof chat.stop_requested_at === "string" || chat.stop_requested_at === null) updates.stop_requested_at = chat.stop_requested_at
  if (typeof chat.cumulative_input_tokens === "number") updates.cumulative_input_tokens = chat.cumulative_input_tokens
  if (typeof chat.cumulative_output_tokens === "number") updates.cumulative_output_tokens = chat.cumulative_output_tokens
  if (typeof chat.cumulative_cost_usd === "number") updates.cumulative_cost_usd = chat.cumulative_cost_usd
  if (typeof chat.coding_checkout_uncommitted === "boolean") updates.coding_checkout_uncommitted = chat.coding_checkout_uncommitted

  return {
    action: "update_header",
    chat: updates
  }
}

function chatBookmarkPayload(payload: unknown): ChatBookmarkPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatBookmarkPayload>
  if (candidate.action !== "upsert_bookmark") return null
  if (!isChatBookmark(candidate.bookmark)) return null

  return {
    action: "upsert_bookmark",
    bookmark: candidate.bookmark
  }
}

function chatPinPayload(payload: unknown): ChatPinPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatPinPayload>
  if (candidate.action !== "upsert_pin" && candidate.action !== "remove_pin") return null

  return { action: candidate.action }
}

function chatAgentQuestionsPayload(payload: unknown): ChatAgentQuestionsPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatAgentQuestionsPayload>
  if (candidate.action !== "update_agent_questions") return null
  if (!isChatAgentQuestions(candidate.agent_questions)) return null

  return {
    action: "update_agent_questions",
    agent_questions: candidate.agent_questions
  }
}

function chatPendingActionUpdatedPayload(payload: unknown): ChatPendingActionUpdatedPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatPendingActionUpdatedPayload>
  if (candidate.action !== "pending_action_updated") return null
  if (typeof candidate.pending_action_id !== "number") return null
  if (typeof candidate.chat_message_id !== "number" && candidate.chat_message_id !== null) return null

  return {
    action: "pending_action_updated",
    pending_action_id: candidate.pending_action_id,
    chat_message_id: candidate.chat_message_id
  }
}

function chatSuggestionPayload(payload: unknown): ChatSuggestionPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatSuggestionPayload>
  if (candidate.action !== "update_suggestion") return null
  if (typeof candidate.suggested_next_step !== "string" && candidate.suggested_next_step !== null) return null

  return {
    action: "update_suggestion",
    suggested_next_step: candidate.suggested_next_step
  }
}

function chatUpdateProposalPayload(payload: unknown): ChatUpdateProposalPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatUpdateProposalPayload>
  if (candidate.action !== "update_proposal") return null
  if (typeof candidate.proposal_id !== "number") return null

  return {
    action: "update_proposal",
    proposal_id: candidate.proposal_id,
    proposal: isChatProposal(candidate.proposal, candidate.proposal_id) ? candidate.proposal : undefined,
    job_status_proposal: isChatJobStatusPendingProposal(candidate.job_status_proposal) ? candidate.job_status_proposal : undefined,
    pending_proposal_count: typeof candidate.pending_proposal_count === "number" ? candidate.pending_proposal_count : undefined
  }
}

function isChatProposal(value: unknown, expectedId: number): value is ChatProposal {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatProposal>
  return (
    candidate.id === expectedId &&
    typeof candidate.slug === "string" &&
    typeof candidate.title === "string" &&
    typeof candidate.state === "string" &&
    typeof candidate.app_confirm_path === "string"
  )
}

function isChatJobStatusPendingProposal(value: unknown): value is ChatJobStatusPendingProposal {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatJobStatusPendingProposal>
  return (
    typeof candidate.id === "number" &&
    typeof candidate.kind === "string" &&
    typeof candidate.state === "string"
  )
}

// Direct-cache-patch counterpart to the chat Jobs tab's own job_status query:
// adds a card immediately when a Job/Epic proposal is created (or edited
// while still pending) in this chat, and removes it immediately once it
// leaves the "proposed" state (confirmed, rejected, or withdrawn) -- a
// resolved proposal disappears right away, not on the next job_status
// refetch. A non-"proposed" state also invalidates the query so a confirmed
// proposal's materialized Job/Epic shows up without waiting on a separate
// job_status_changed broadcast.
function patchChatJobStatusPendingProposal(queryClient: QueryClient, chatSessionId: string | number, proposal: ChatJobStatusPendingProposal) {
  const queryKey = ["chats", String(chatSessionId), "job_status"]
  queryClient.setQueriesData<ChatJobStatusPayload>(
    { queryKey },
    (current) => {
      if (!current) return current

      const withoutExisting = current.pending_proposals.filter((entry) => entry.id !== proposal.id)
      const pendingProposals = proposal.state === "proposed" ? [ proposal, ...withoutExisting ] : withoutExisting

      return { ...current, pending_proposals: pendingProposals }
    }
  )
  if (proposal.state !== "proposed") {
    invalidateAppQuery(queryClient, { queryKey, exact: true })
  }
}

function chatJobStatusChangedPayload(payload: unknown): ChatJobStatusChangedPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatJobStatusChangedPayload>
  if (candidate.action !== "job_status_changed") return null
  if (typeof candidate.job_id !== "number") return null

  return { action: "job_status_changed", job_id: candidate.job_id }
}

function isChatMessages(value: unknown): value is ChatMessageItem[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatMessageItem>
    return candidate.type === "message" && typeof candidate.id === "number"
  })
}

function isChatQueuedMessages(value: unknown): value is ChatQueuedMessage[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatQueuedMessage>
    return (
      typeof candidate.id === "number" &&
      typeof candidate.text === "string" &&
      (typeof candidate.created_at === "string" || candidate.created_at == null) &&
      typeof candidate.app_update_path === "string" &&
      typeof candidate.app_delete_path === "string"
    )
  })
}

function isChatRepository(value: unknown): value is ChatRepository {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatRepository>
  return typeof candidate.id === "number" && typeof candidate.slug === "string"
}

function isChatBookmark(value: unknown): value is ChatBookmark {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatBookmark>
  return (
    typeof candidate.id === "number" &&
    typeof candidate.label === "string" &&
    typeof candidate.chat_message_id === "number" &&
    (typeof candidate.anchor_message_id === "number" || candidate.anchor_message_id == null)
  )
}

function isChatParticipants(value: unknown): value is ChatParticipant[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatParticipant>
    return typeof candidate.id === "number" && typeof candidate.name === "string" && typeof candidate.role === "string"
  })
}

function chatThemePreviewPayload(payload: unknown): ChatThemePreviewPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatThemePreviewPayload>
  if (candidate.action !== "open_theme_preview") return null
  if (typeof candidate.theme_id !== "number") return null
  if (typeof candidate.path !== "string") return null

  return { action: "open_theme_preview", theme_id: candidate.theme_id, path: candidate.path }
}

function chatParticipantsPayload(payload: unknown): ChatParticipantsPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatParticipantsPayload>
  if (candidate.action !== "update_participants") return null
  if (candidate.conversation_kind !== "direct" && candidate.conversation_kind !== "group") return null
  if (!isChatParticipants(candidate.participants)) return null

  return {
    action: "update_participants",
    conversation_kind: candidate.conversation_kind,
    participants: candidate.participants
  }
}

function isChatAgentSubQuestion(value: unknown): value is ChatAgentSubQuestion {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatAgentSubQuestion>
  return (
    typeof candidate.question === "string" &&
    (candidate.options === null || (Array.isArray(candidate.options) && candidate.options.every((option) => typeof option === "string"))) &&
    typeof candidate.multiple === "boolean"
  )
}

function isChatAgentQuestions(value: unknown): value is ChatAgentQuestion[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatAgentQuestion>
    return (
      typeof candidate.id === "number" &&
      Array.isArray(candidate.questions) && candidate.questions.every(isChatAgentSubQuestion) &&
      (typeof candidate.asked_at === "string" || candidate.asked_at == null) &&
      typeof candidate.app_answer_path === "string"
    )
  })
}

function replaceMessageTail(current: ChatMessageItem[], replaceFromId: number, nextMessages: ChatMessageItem[]) {
  return dedupeMessages([
    ...current.filter((message) => message.id < replaceFromId),
    ...nextMessages
  ])
}

function dedupeMessages(messages: ChatMessageItem[]) {
  const seen = new Set<number>()
  const result: ChatMessageItem[] = []

  for (const message of messages) {
    if (seen.has(message.id)) continue

    seen.add(message.id)
    result.push(message)
  }

  return result
}

function upsertBookmark(current: ChatBookmark[], bookmark: ChatBookmark) {
  const next = current.filter((item) => item.id !== bookmark.id)
  next.push(bookmark)
  return next.sort((a, b) => a.chat_message_id - b.chat_message_id || a.id - b.id)
}
