// Generic frontend performance marker API, the browser-side counterpart to
// the backend's `PerformanceLogging.phase`. It reuses the existing browser
// trace ingestion path (recordBrowserTrace/postBrowserTraces ->
// /api/v1/app/performance_events -> PerformanceLogEvent) rather than
// inventing a parallel logging island: every marker becomes one
// BrowserTracePayload, sharing the same stable envelope (name, path,
// duration, trace id, app revision stamped server-side, visibility state,
// metadata) that dashboard.route/browser.slow_input traces already use, so
// the same admin/query surfaces show marker events without extra plumbing.
//
// Unlike the passive PerformanceObserver-driven traces in performanceTrace.ts
// (which fire immediately, one request per event, because they're rare),
// markers are meant to be sprinkled through hot UI code -- a virtualized
// diff's viewport render, a syntax-highlight pass -- so every call here is
// batched: events queue in memory and flush together (debounced, size- or
// page-hide-triggered) instead of opening one request per marker.
import { useEffect, useRef } from "react"
import { browserTraceId, performanceLoggingEnabled, postBrowserTraces, type BrowserTracePayload, type BrowserTraceSpan } from "./performanceTrace"

export type PerformanceMarkerMetadata = Record<string, string | number | boolean | null | undefined>

export type PerformanceMarkerOptions = {
  // Test/story override, same convention as recordBrowserTrace: true/false
  // forces the decision; omitted defers to the live feature flag.
  enabled?: boolean
  interactionId?: string | number | null
  metadata?: PerformanceMarkerMetadata
  // Caps how many events a given marker `name` may send per page session
  // (i.e. until the tab/module reloads). Guards a marker that fires on
  // every scroll frame or keystroke from flooding production logs.
  maxPerSession?: number
  parentId?: string | null
  // Probability (0..1) that a sample passing the threshold is actually kept.
  sampleRate?: number
  spans?: BrowserTraceSpan[]
  // Minimum duration to record. Below it, the event is dropped entirely --
  // not sent as a zero-value sample. Ignored by recordCount, which has no
  // duration to threshold against.
  thresholdMs?: number
}

export type PerformanceMarkerHandle = {
  name: string
  options: PerformanceMarkerOptions
  startedAt: number
  traceId: string
}

const DEFAULT_SAMPLE_RATE = 1
const DEFAULT_MAX_PER_SESSION = 50
const DEFAULT_THRESHOLD_MS = 0
const QUEUE_FLUSH_DELAY_MS = 2_000
const QUEUE_FLUSH_SIZE = 20

let queue: BrowserTracePayload[] = []
let flushTimer: ReturnType<typeof setTimeout> | null = null
let lifecycleListenersInstalled = false
let lifecycleCleanups: Array<() => void> = []
const sessionCounts = new Map<string, number>()

// Explicit start/end pair for spans that don't fit a single function call --
// e.g. "time from the Files menu opening until its popup actually renders,"
// which spans a click handler and a later effect.
export function startMarker(name: string, options: PerformanceMarkerOptions = {}): PerformanceMarkerHandle {
  return { name, options, startedAt: performanceNow(), traceId: browserTraceId(markerPrefix(name)) }
}

export function endMarker(handle: PerformanceMarkerHandle, extra: { metadata?: PerformanceMarkerMetadata; spans?: BrowserTraceSpan[] } = {}): void {
  const durationMs = roundMs(performanceNow() - handle.startedAt)
  enqueueMarkerEvent(
    handle.name,
    durationMs,
    {
      ...handle.options,
      metadata: { ...handle.options.metadata, ...extra.metadata },
      spans: extra.spans ?? handle.options.spans
    },
    handle.traceId
  )
}

// Measures a synchronous named span. Always runs `fn` and returns/throws
// exactly what `fn` would on its own -- disabling performance logging (or
// failing sampling/threshold/cap) only skips the recorded event, never the
// work.
export function measureSync<T>(name: string, fn: () => T, options: PerformanceMarkerOptions = {}): T {
  const startedAt = performanceNow()
  try {
    return fn()
  } finally {
    enqueueMarkerEvent(name, roundMs(performanceNow() - startedAt), options)
  }
}

// Async counterpart of measureSync -- the common case for "measure an async
// operation" (a fetch, a worker round-trip, an awaited parse).
export async function measureAsync<T>(name: string, fn: () => Promise<T>, options: PerformanceMarkerOptions = {}): Promise<T> {
  const startedAt = performanceNow()
  try {
    return await fn()
  } finally {
    enqueueMarkerEvent(name, roundMs(performanceNow() - startedAt), options)
  }
}

// Records count-based context without timing a block -- e.g. "the Files menu
// was opened while N files were rendered." `thresholdMs` does not apply
// (there is no duration); sampling and the session cap still do.
export function recordCount(name: string, options: PerformanceMarkerOptions & { count?: number } = {}): void {
  const { count, ...rest } = options
  enqueueMarkerEvent(name, null, {
    ...rest,
    metadata: count != null ? { count, ...rest.metadata } : rest.metadata
  })
}

export type RenderMarkerPhase = "commit" | "paint"

// React render/commit/paint boundary helper. Call it at the top of a
// component body (a hook, so it participates in that component's render):
// it stamps the render's start time on every render, then records the
// elapsed time once React has committed ("commit") or, best-effort, once the
// browser has actually painted the committed frame ("paint").
//
// `deps` controls when a *new* measurement starts (defaults to `[]`, i.e.
// once per mount) -- distinct from every render re-stamping
// `renderStartedAtRef`, which happens unconditionally so a measurement in
// flight always reflects the most recent render's start.
export function useMarkedRender(name: string, options: PerformanceMarkerOptions & { deps?: unknown[]; phase?: RenderMarkerPhase } = {}): void {
  const { deps, phase = "commit", ...markerOptions } = options
  const renderStartedAtRef = useRef(performanceNow())
  renderStartedAtRef.current = performanceNow()

  useEffect(() => {
    if (phase === "commit") {
      enqueueMarkerEvent(name, roundMs(performanceNow() - renderStartedAtRef.current), markerOptions)
      return
    }

    // There is no synchronous "paint completed" browser API. A double
    // requestAnimationFrame is the standard proxy: the first callback fires
    // once the browser is ready to paint the just-committed frame, the
    // second fires after that paint has actually happened.
    let secondFrame = 0
    const firstFrame = requestAnimationFrame(() => {
      secondFrame = requestAnimationFrame(() => {
        enqueueMarkerEvent(name, roundMs(performanceNow() - renderStartedAtRef.current), markerOptions)
      })
    })
    return () => {
      cancelAnimationFrame(firstFrame)
      cancelAnimationFrame(secondFrame)
    }
    // `deps` is the caller-controlled re-measure trigger (see doc comment
    // above), not this effect's real dependency list -- the lint rule can't
    // statically analyze a non-literal array, so it doesn't flag it.
  }, deps ?? [])
}

export function flushPerformanceMarkerQueue(options: { beacon?: boolean } = {}): void {
  flushQueue(options)
}

export function resetPerformanceMarkersForTest(): void {
  queue = []
  if (flushTimer != null) {
    clearTimeout(flushTimer)
    flushTimer = null
  }
  sessionCounts.clear()
  lifecycleCleanups.forEach((cleanup) => cleanup())
  lifecycleCleanups = []
  lifecycleListenersInstalled = false
}

function enqueueMarkerEvent(name: string, durationMs: number | null, options: PerformanceMarkerOptions, traceId?: string): void {
  if (!markerLoggingEnabled(options)) return
  if (!shouldRecordMarker(name, durationMs, options)) return

  queue.push({
    trace_id: traceId ?? browserTraceId(markerPrefix(name)),
    parent_id: options.parentId ?? undefined,
    interaction_id: options.interactionId ?? undefined,
    name,
    path: currentMarkerPath(),
    duration_ms: durationMs ?? 0,
    visibility_state: markerVisibilityState(),
    metadata: compactMetadata(options.metadata),
    spans: options.spans
  })
  scheduleFlush()
}

function shouldRecordMarker(name: string, durationMs: number | null, options: PerformanceMarkerOptions): boolean {
  const thresholdMs = options.thresholdMs ?? DEFAULT_THRESHOLD_MS
  if (durationMs != null && durationMs < thresholdMs) return false

  const sampleRate = clampSampleRate(options.sampleRate ?? DEFAULT_SAMPLE_RATE)
  if (sampleRate < 1 && Math.random() >= sampleRate) return false

  const maxPerSession = options.maxPerSession ?? DEFAULT_MAX_PER_SESSION
  const seen = sessionCounts.get(name) ?? 0
  if (seen >= maxPerSession) return false

  sessionCounts.set(name, seen + 1)
  return true
}

function markerLoggingEnabled(options: PerformanceMarkerOptions): boolean {
  if (options.enabled === false) return false
  if (options.enabled === true) return true
  return performanceLoggingEnabled()
}

function scheduleFlush(): void {
  ensureLifecycleListeners()
  if (queue.length >= QUEUE_FLUSH_SIZE) {
    flushQueue()
    return
  }
  if (flushTimer != null) return
  flushTimer = setTimeout(() => flushQueue(), QUEUE_FLUSH_DELAY_MS)
}

function flushQueue(options: { beacon?: boolean } = {}): void {
  if (flushTimer != null) {
    clearTimeout(flushTimer)
    flushTimer = null
  }
  if (queue.length === 0) return
  const batch = queue
  queue = []
  // Already gated per-event in enqueueMarkerEvent; force-send here so a flag
  // flip between enqueue and flush can't silently drop an approved batch.
  postBrowserTraces(batch, { beacon: options.beacon, enabled: true })
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

function compactMetadata(metadata?: PerformanceMarkerMetadata): Record<string, string | number | boolean> | undefined {
  if (!metadata) return undefined
  const entries = Object.entries(metadata).filter((entry): entry is [string, string | number | boolean] => entry[1] !== null && entry[1] !== undefined)
  return entries.length > 0 ? Object.fromEntries(entries) : undefined
}

function clampSampleRate(rate: number): number {
  if (Number.isNaN(rate)) return DEFAULT_SAMPLE_RATE
  return Math.min(1, Math.max(0, rate))
}

function markerPrefix(name: string): string {
  return name.replace(/[^a-z0-9._-]/gi, "").slice(0, 40) || "marker"
}

function currentMarkerPath(): string {
  if (typeof window === "undefined") return ""
  return `${window.location.pathname}${window.location.search}`
}

function markerVisibilityState(): string {
  return typeof document !== "undefined" && typeof document.visibilityState === "string" ? document.visibilityState : "unknown"
}

function performanceNow(): number {
  return typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() : Date.now()
}

function roundMs(value: number): number {
  return Math.round(value * 10) / 10
}
