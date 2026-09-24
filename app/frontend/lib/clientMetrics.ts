// Bridges a small, closed set of browser-observed events (see
// app/services/client_metrics.rb) into real Prometheus counters. Several of
// EPIC-392's amplification signals -- an entity-store patch landing, a
// revision-gap recovery firing, a hidden tab suppressing a fetch -- only
// happen in the browser, and the backend metrics library has no way to see
// them directly. This is the one narrow bridge: callers record an
// occurrence, increments batch in memory, and the batch posts to
// /api/v1/app/client_metrics (mirroring performanceMarkers.ts's batching
// shape) instead of one request per occurrence.
import { readInitialBootstrap } from "../api/bootstrap"

export type ClientMetricResource =
  | "job" | "workflow" | "step" | "run" | "chat" | "dashboard" | "epic" | "repository" | "notification" | "unknown"

export type ClientMetricName = "entity_patch_applications" | "revision_gap_recoveries" | "hidden_tab_suppressed_fetches"

export type ClientMetricVisibilityState = "visible" | "hidden" | "unknown"

type QueuedIncrement = { name: ClientMetricName; resource: ClientMetricResource; visibility_state?: ClientMetricVisibilityState; by: number }

const FLUSH_DELAY_MS = 10_000
const FLUSH_SIZE = 50

// The backend's own closed resource enum (ClientMetrics::RESOURCES);
// anything else already normalizes to "unknown" via resourceTagFor below, but
// keeping the two lists in sync is what makes that mapping meaningful.
const KNOWN_RESOURCES: readonly string[] = [
  "job", "workflow", "step", "run", "chat", "dashboard", "epic", "repository", "notification"
]

let queue = new Map<string, QueuedIncrement>()
let flushTimer: ReturnType<typeof setTimeout> | null = null
let lifecycleListenersInstalled = false
let lifecycleCleanups: Array<() => void> = []

export function recordClientMetric(
  name: ClientMetricName,
  resource: ClientMetricResource = "unknown",
  visibilityState?: ClientMetricVisibilityState
): void {
  const key = `${name}:${resource}:${visibilityState ?? ""}`
  const existing = queue.get(key)
  if (existing) {
    existing.by += 1
  } else {
    queue.set(key, { name, resource, visibility_state: visibilityState, by: 1 })
  }
  scheduleFlush()
}

export function currentVisibilityState(): ClientMetricVisibilityState {
  if (typeof document === "undefined" || typeof document.visibilityState !== "string") return "unknown"
  return document.visibilityState === "visible" || document.visibilityState === "hidden" ? document.visibilityState : "unknown"
}

// Maps a query-key root ("jobs", "chats", ...) or an application-event
// `resource` ("job", "chat", ...) onto the closed tag vocabulary the backend
// accepts, so a plural query-key root and a singular event resource both land
// on the same series instead of silently becoming "unknown".
export function resourceTagFor(value: string | null | undefined): ClientMetricResource {
  if (!value) return "unknown"

  const singular = value.endsWith("s") ? value.slice(0, -1) : value
  return (KNOWN_RESOURCES.includes(singular) ? singular : "unknown") as ClientMetricResource
}

export function flushClientMetricsQueue(options: { beacon?: boolean } = {}): void {
  flushQueue(options)
}

export function resetClientMetricsForTest(): void {
  queue = new Map()
  if (flushTimer != null) {
    clearTimeout(flushTimer)
    flushTimer = null
  }
  lifecycleCleanups.forEach((cleanup) => cleanup())
  lifecycleCleanups = []
  lifecycleListenersInstalled = false
}

function scheduleFlush(): void {
  ensureLifecycleListeners()
  if (queue.size >= FLUSH_SIZE) {
    flushQueue()
    return
  }
  if (flushTimer != null) return
  flushTimer = setTimeout(() => flushQueue(), FLUSH_DELAY_MS)
}

function flushQueue(options: { beacon?: boolean } = {}): void {
  if (flushTimer != null) {
    clearTimeout(flushTimer)
    flushTimer = null
  }
  if (queue.size === 0) return

  const batch = Array.from(queue.values())
  queue = new Map()
  postClientMetrics(batch, options)
}

function postClientMetrics(clientMetrics: QueuedIncrement[], options: { beacon?: boolean }): void {
  const csrfToken = currentCsrfToken()
  const body = JSON.stringify({ client_metrics: clientMetrics, authenticity_token: csrfToken })

  if (options.beacon && typeof navigator !== "undefined" && typeof navigator.sendBeacon === "function") {
    const blob = new Blob([ body ], { type: "application/json" })
    if (navigator.sendBeacon("/api/v1/app/client_metrics", blob)) return
  }

  void fetch("/api/v1/app/client_metrics", {
    method: "POST",
    credentials: "same-origin",
    keepalive: true,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {})
    },
    body
  }).catch(() => {})
}

function currentCsrfToken(): string | undefined {
  if (typeof document === "undefined") return readInitialBootstrap()?.csrf_token
  return readInitialBootstrap()?.csrf_token || document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content
}

function ensureLifecycleListeners(): void {
  if (lifecycleListenersInstalled) return
  if (typeof document === "undefined") return
  lifecycleListenersInstalled = true

  const flushWithBeacon = () => flushQueue({ beacon: true })
  const onVisibilityChange = () => {
    if (document.visibilityState === "hidden") flushWithBeacon()
  }
  document.addEventListener("visibilitychange", onVisibilityChange)
  lifecycleCleanups.push(() => document.removeEventListener("visibilitychange", onVisibilityChange))

  if (typeof window !== "undefined") {
    window.addEventListener("pagehide", flushWithBeacon)
    lifecycleCleanups.push(() => window.removeEventListener("pagehide", flushWithBeacon))
  }
}
