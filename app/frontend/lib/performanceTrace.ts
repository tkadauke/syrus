import { readInitialBootstrap } from "../api/bootstrap"
import type { JsonResponseMeta } from "../api/client"

export type BrowserTraceApiRequest = {
  name: string
  path: string
  request_id: string | null
  duration_ms: number
  status: number
}

export type BrowserTraceSpan = {
  name: string
  duration_ms: number
  started_at_ms?: number | null
  metadata?: Record<string, unknown>
}

export type BrowserTracePayload = {
  trace_id: string
  name: string
  path: string
  duration_ms: number
  visibility_state: string
  metadata?: Record<string, unknown>
  api_requests?: BrowserTraceApiRequest[]
  spans?: BrowserTraceSpan[]
}

type BrowserObserverOptions = {
  enabled?: boolean
  eventLoopIntervalMs?: number
  eventLoopLagThresholdMs?: number
  minEventLoopReportIntervalMs?: number
  maxPlausibleEventLoopLagMs?: number
}

type PerformanceEventTimingEntry = PerformanceEntry & {
  processingStart?: number
  processingEnd?: number
  interactionId?: number
  target?: EventTarget | null
}

let observersStarted = false
let observerCleanups: Array<() => void> = []

export function performanceLoggingEnabled(): boolean {
  return readInitialBootstrap()?.feature_flags?.performance_logging === true
}

export function browserTraceId(prefix: string): string {
  const random = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : Math.random().toString(36).slice(2)
  return `${prefix}-${Date.now().toString(36)}-${random}`
}

export function apiRequestTrace(name: string, meta: JsonResponseMeta | null | undefined): BrowserTraceApiRequest | null {
  if (!meta) return null

  return {
    name,
    path: meta.path,
    request_id: meta.requestId,
    duration_ms: Math.round(meta.durationMs * 10) / 10,
    status: meta.status
  }
}

export function recordBrowserTrace(payload: BrowserTracePayload, options: { enabled?: boolean } = {}): void {
  if (options.enabled === false) return
  if (options.enabled !== true && !performanceLoggingEnabled()) return

  const csrfToken = readInitialBootstrap()?.csrf_token || document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content
  const body = JSON.stringify({ performance_event: payload })
  void fetch("/api/v1/app/performance_events", {
    method: "POST",
    credentials: "same-origin",
    keepalive: body.length < 60_000,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {})
    },
    body
  }).catch(() => {})
}

export function startBrowserPerformanceObservers(options: BrowserObserverOptions = {}): void {
  if (observersStarted) return
  if (options.enabled === false) return
  if (options.enabled !== true && !performanceLoggingEnabled()) return

  observersStarted = true
  observeLongTasks(options)
  observeSlowEvents(options)
  observeEventLoopLag(options)
}

export function resetBrowserPerformanceObserversForTest(): void {
  observerCleanups.forEach((cleanup) => cleanup())
  observerCleanups = []
  observersStarted = false
}

function observeLongTasks(_options: BrowserObserverOptions): void {
  if (!supportsPerformanceObserverType("longtask")) return

  const observer = new PerformanceObserver((list) => {
    list.getEntries().forEach((entry) => {
      if (entry.duration < 100) return

      recordBrowserTrace({
        trace_id: browserTraceId("longtask"),
        name: "browser.long_task",
        path: currentTracePath(),
        duration_ms: roundMs(entry.duration),
        visibility_state: visibilityState(),
        metadata: {
          entry_type: entry.entryType,
          start_time_ms: roundMs(entry.startTime),
          source: "performance_observer"
        }
      }, { enabled: true })
    })
  })

  try {
    observer.observe({ type: "longtask", buffered: true })
    observerCleanups.push(() => observer.disconnect())
  } catch {
    observer.disconnect()
  }
}

function observeSlowEvents(_options: BrowserObserverOptions): void {
  if (!supportsPerformanceObserverType("event")) return

  const observer = new PerformanceObserver((list) => {
    list.getEntries().forEach((rawEntry) => {
      const entry = rawEntry as PerformanceEventTimingEntry
      if (entry.duration < 50) return

      const inputDelayMs = typeof entry.processingStart === "number" ? Math.max(0, entry.processingStart - entry.startTime) : null
      const processingDurationMs = typeof entry.processingStart === "number" && typeof entry.processingEnd === "number"
        ? Math.max(0, entry.processingEnd - entry.processingStart)
        : null

      recordBrowserTrace({
        trace_id: browserTraceId("input"),
        name: "browser.slow_input",
        path: currentTracePath(),
        duration_ms: roundMs(entry.duration),
        visibility_state: visibilityState(),
        metadata: {
          event_name: entry.name,
          entry_type: entry.entryType,
          input_delay_ms: inputDelayMs === null ? null : roundMs(inputDelayMs),
          processing_duration_ms: processingDurationMs === null ? null : roundMs(processingDurationMs),
          interaction_id: typeof entry.interactionId === "number" && entry.interactionId > 0 ? entry.interactionId : null,
          target: targetLabel(entry.target),
          source: "performance_observer"
        }
      }, { enabled: true })
    })
  })

  try {
    observer.observe({ type: "event", buffered: true, durationThreshold: 40 } as PerformanceObserverInit & { durationThreshold: number })
    observerCleanups.push(() => observer.disconnect())
  } catch {
    observer.disconnect()
  }
}

// A setInterval sampler cannot, on its own, tell a blocked main thread from a
// timer that was never allowed to run. Browsers clamp background-tab timers to
// roughly once a minute, and across system sleep they do not fire at all, so
// the overshoot on the next tick measures the throttle or the nap rather than
// any work the page did. Unfiltered, that dwarfs real jank: production
// collected a 3,139,015ms sample (52 minutes, which no live page survives),
// and hidden tabs produced 96% of all recorded lag.
//
// Two filters, because the two causes are different. Visibility catches
// background throttling. A plausibility ceiling catches clock discontinuities
// that leave visibility alone — a sleeping machine with the tab still
// foregrounded reports visibility_state "visible" on wake.
function observeEventLoopLag(options: BrowserObserverOptions): void {
  const intervalMs = options.eventLoopIntervalMs ?? 1_000
  const thresholdMs = options.eventLoopLagThresholdMs ?? 150
  const minReportIntervalMs = options.minEventLoopReportIntervalMs ?? 10_000
  const maxPlausibleLagMs = options.maxPlausibleEventLoopLagMs ?? 10_000
  let expectedAt = performanceNow() + intervalMs
  let lastReportedAt = 0
  // The interval spanning a visibility transition measured the throttle, not
  // the page, so drop it and re-baseline.
  let skipNextSample = documentHidden()

  const onVisibilityChange = (): void => {
    expectedAt = performanceNow() + intervalMs
    skipNextSample = true
  }
  document.addEventListener("visibilitychange", onVisibilityChange)

  const intervalId = window.setInterval(() => {
    const now = performanceNow()
    const lagMs = now - expectedAt
    expectedAt = now + intervalMs

    const hidden = documentHidden()
    const skip = skipNextSample || hidden
    // Stay suppressed for as long as the tab is hidden, and for the first tick
    // after it comes back.
    skipNextSample = hidden
    if (skip) return

    if (lagMs < thresholdMs) return
    if (lagMs > maxPlausibleLagMs) return
    if (now - lastReportedAt < minReportIntervalMs) return

    lastReportedAt = now
    recordBrowserTrace({
      trace_id: browserTraceId("event-loop"),
      name: "browser.event_loop_lag",
      path: currentTracePath(),
      duration_ms: roundMs(lagMs),
      visibility_state: visibilityState(),
      metadata: {
        interval_ms: intervalMs,
        threshold_ms: thresholdMs,
        max_plausible_lag_ms: maxPlausibleLagMs,
        source: "event_loop_sampler"
      }
    }, { enabled: true })
  }, intervalMs)

  observerCleanups.push(() => {
    document.removeEventListener("visibilitychange", onVisibilityChange)
    window.clearInterval(intervalId)
  })
}

function documentHidden(): boolean {
  return typeof document !== "undefined" && document.visibilityState === "hidden"
}

function supportsPerformanceObserverType(type: string): boolean {
  if (typeof PerformanceObserver === "undefined") return false

  const supported = PerformanceObserver.supportedEntryTypes
  return !Array.isArray(supported) || supported.includes(type)
}

function currentTracePath(): string {
  return `${window.location.pathname}${window.location.search}`
}

function visibilityState(): string {
  return typeof document.visibilityState === "string" ? document.visibilityState : "unknown"
}

function performanceNow(): number {
  return typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() : Date.now()
}

function roundMs(value: number): number {
  return Math.round(value * 10) / 10
}

function targetLabel(target: EventTarget | null | undefined): string | null {
  if (typeof Element === "undefined") return null
  if (!(target instanceof Element)) return null

  const tag = target.tagName.toLowerCase()
  const role = target.getAttribute("role")
  const testId = target.getAttribute("data-testid")
  const pieces = [ tag ]
  if (role) pieces.push(`[role=${role}]`)
  if (testId) pieces.push(`[data-testid=${testId}]`)

  return pieces.join("")
}
