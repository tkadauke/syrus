// Background warm-up for lazy SPA chunks.
//
// Startup downloads only what the first paint needs: the entry, the shell and
// the chunk of the route the URL names. Every other lazy chunk is registered
// here and fetched in the background once React has committed and the browser
// is idle, so later navigations find their module already loaded and a deploy
// that replaces the chunk hashes is less likely to strand an open tab.
//
// The rules the queue keeps:
//   - one background load at a time, highest priority (lowest number) first,
//     registration order within a priority;
//   - a load something on screen is waiting for (`load()` of a registered
//     loader) starts immediately and pauses the queue until it settles;
//   - nothing starts while the tab is hidden, and the queue never starts on a
//     connection that asks to save data or reports 2g;
//   - every caller shares one promise per chunk, so a navigation after
//     warm-up issues no second request;
//   - a failed background load stops the queue (after a deploy every
//     remaining chunk would fail the same way) and is forgotten, so the next
//     on-demand load retries and the stale-chunk recovery can reload once.

export type ChunkWarmupOptions = {
  /** Lower runs first. */
  priority: number
  /** Optional group name; `start({ skipGroups })` leaves those entries cold. */
  group?: string
  /** Vite manifest source key, used only by subscribed diagnostics. */
  manifestKey?: string
}

type ConnectionLike = { saveData?: boolean; effectiveType?: string }

export type ChunkWarmupEnvironment = {
  scheduleIdle: (callback: () => void) => void
  isHidden: () => boolean
  onVisible: (callback: () => void) => void
  connection: () => ConnectionLike | undefined
}

type Entry = {
  id: string
  priority: number
  group?: string
  order: number
  load: () => Promise<unknown>
  promise?: Promise<unknown>
  loaded: boolean
  manifestKey?: string
}

export type ChunkLoadState = "not_loaded" | "queued" | "loading" | "loaded" | "failed"
export type ChunkLoadSource = "warmup" | "on_demand"
export type ChunkWarmupEntrySnapshot = {
  id: string
  group: string | null
  priority: number
  state: ChunkLoadState
  source: ChunkLoadSource | null
  startedAt: number | null
  durationMs: number | null
  manifestKey: string | null
  size: number | null
}
export type ChunkWarmupSnapshot = {
  entries: ChunkWarmupEntrySnapshot[]
  queue: string[]
  loading: string | null
  paused: boolean
  pauseReasons: string[]
  stoppedAfterFailure: boolean
}

type ObservedLoad = { source: ChunkLoadSource; startedAt: number; durationMs: number | null; failed: boolean }

export type WarmableLoader<T> = (() => Promise<T>) & { readonly warmupId: string }

const SLOW_CONNECTION_TYPES = new Set(["slow-2g", "2g"])

function inferredManifestKey(id: string) {
  if (id.startsWith("route:")) return `app/frontend/routes/${id.slice("route:".length)}.tsx`
  if (id.startsWith("plugin:../../")) return id.slice("plugin:../../".length)
  return undefined
}

function browserEnvironment(): ChunkWarmupEnvironment {
  return {
    scheduleIdle(callback) {
      const idle = (window as Window & { requestIdleCallback?: (cb: () => void, options?: { timeout: number }) => number }).requestIdleCallback
      if (typeof idle === "function") idle.call(window, callback, { timeout: 5000 })
      else window.setTimeout(callback, 250)
    },
    isHidden: () => document.visibilityState === "hidden",
    onVisible(callback) {
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState !== "hidden") callback()
      })
    },
    connection: () => (navigator as Navigator & { connection?: ConnectionLike }).connection
  }
}

export class ChunkWarmupQueue {
  private entries = new Map<string, Entry>()
  private order = 0
  private started = false
  private stoppedReason: "data_saver" | "slow_connection" | "failure" | null = null
  private skipGroups = new Set<string>()
  private demandsInFlight = 0
  private backgroundInFlight: Entry | null = null
  private pumpScheduled = false
  private visibilityListening = false
  private disabledReason: "signed_out" | "dev_server" | null = null
  private listeners: Set<() => void> | null = null
  private observedLoads: Map<string, ObservedLoad> | null = null
  private readonly environment: () => ChunkWarmupEnvironment

  constructor(environment?: ChunkWarmupEnvironment) {
    let cached = environment
    this.environment = () => (cached ??= browserEnvironment())
  }

  /**
   * Registers a chunk loader and returns the function every caller (lazy(),
   * a preload, the queue) must use, so they all share one request. Calling the
   * returned function is an on-demand load.
   */
  register<T>(id: string, load: () => Promise<T>, options: ChunkWarmupOptions): WarmableLoader<T> {
    let entry = this.entries.get(id)
    if (!entry) {
      entry = { id, priority: options.priority, group: options.group, order: this.order++, load, loaded: false, manifestKey: options.manifestKey ?? inferredManifestKey(id) }
      this.entries.set(id, entry)
    }
    const registered = entry
    const demand = () => this.demand(registered) as Promise<T>
    return Object.assign(demand, { warmupId: id })
  }

  /** Read-only diagnostics. Tracking is activated only while somebody subscribes. */
  subscribe(listener: () => void) {
    this.listeners ??= new Set()
    this.observedLoads ??= new Map()
    this.listeners.add(listener)
    return () => {
      this.listeners?.delete(listener)
      if (this.listeners?.size === 0) {
        this.listeners = null
        this.observedLoads = null
      }
    }
  }

  snapshot(): ChunkWarmupSnapshot {
    const pauseReasons: string[] = []
    const connection = this.environment().connection()
    if (connection?.saveData) pauseReasons.push("data_saver")
    if (SLOW_CONNECTION_TYPES.has(connection?.effectiveType ?? "")) pauseReasons.push("slow_connection")
    if (this.environment().isHidden()) pauseReasons.push("hidden_tab")
    if (this.demandsInFlight > 0) pauseReasons.push("on_demand")
    if (this.disabledReason) pauseReasons.push(this.disabledReason)
    if (this.stoppedReason && this.stoppedReason !== "failure" && !pauseReasons.includes(this.stoppedReason)) pauseReasons.push(this.stoppedReason)
    const entries = Array.from(this.entries.values()).map((entry): ChunkWarmupEntrySnapshot => {
      const observed = this.observedLoads?.get(entry.id)
      let state: ChunkLoadState = entry.loaded ? "loaded" : "not_loaded"
      if (!entry.loaded && observed?.failed) state = "failed"
      else if (!entry.loaded && entry.promise) state = "loading"
      else if (!entry.loaded && this.started && !(entry.group && this.skipGroups.has(entry.group))) state = "queued"
      return {
        id: entry.id,
        group: entry.group ?? null,
        priority: entry.priority,
        state,
        source: observed?.source ?? null,
        startedAt: observed?.startedAt ?? null,
        durationMs: observed?.durationMs ?? null,
        manifestKey: entry.manifestKey ?? null,
        size: null
      }
    })
    return {
      entries,
      queue: entries.filter((entry) => entry.state === "queued").sort((left, right) => left.priority - right.priority).map((entry) => entry.id),
      loading: this.backgroundInFlight?.id ?? entries.find((entry) => entry.state === "loading")?.id ?? null,
      paused: pauseReasons.length > 0,
      pauseReasons,
      stoppedAfterFailure: this.stoppedReason === "failure"
    }
  }

  /** In-tab testing actions used by the diagnostics page. */
  warmEverythingNow() {
    this.started = true
    this.stoppedReason = null
    this.skipGroups.clear()
    this.disabledReason = null
    this.schedulePump()
    this.notify()
  }

  clearWarmupState() {
    this.started = false
    this.stoppedReason = null
    this.skipGroups.clear()
    this.observedLoads?.clear()
    this.notify()
  }

  disable(reason: "signed_out" | "dev_server") {
    this.disabledReason = reason
    this.notify()
  }

  /** Begins background warm-up. Idempotent; call it after the first commit. */
  start({ skipGroups = [] }: { skipGroups?: readonly string[] } = {}) {
    this.disabledReason = null
    skipGroups.forEach((group) => this.skipGroups.add(group))
    if (this.started) return
    this.started = true
    const connectionStopReason = this.connectionStopReason()
    if (connectionStopReason) {
      this.stoppedReason = connectionStopReason
      this.notify()
      return
    }
    if (!this.visibilityListening) {
      this.visibilityListening = true
      this.environment().onVisible(() => this.schedulePump())
    }
    this.schedulePump()
    this.notify()
  }

  /** True while the only chunk loads in flight are background ones. */
  backgroundOnlyInFlight() {
    return this.backgroundInFlight !== null && this.demandsInFlight === 0
  }

  isLoaded(id: string) {
    return this.entries.get(id)?.loaded ?? false
  }

  private connectionStopReason(): "data_saver" | "slow_connection" | null {
    const connection = this.environment().connection()
    if (connection?.saveData === true) return "data_saver"
    if (SLOW_CONNECTION_TYPES.has(connection?.effectiveType ?? "")) return "slow_connection"
    return null
  }

  private fetch(entry: Entry) {
    if (!entry.promise) {
      if (this.listeners) this.observedLoads?.set(entry.id, { source: this.backgroundInFlight === entry ? "warmup" : "on_demand", startedAt: performance.now(), durationMs: null, failed: false })
      this.notify()
      entry.promise = entry.load().then(
        (module) => {
          entry.loaded = true
          this.finishObservedLoad(entry, false)
          return module
        },
        (error: unknown) => {
          // Forget the failure so the next on-demand load can retry.
          entry.promise = undefined
          this.finishObservedLoad(entry, true)
          throw error
        }
      )
    }
    return entry.promise
  }

  private finishObservedLoad(entry: Entry, failed: boolean) {
    const observed = this.observedLoads?.get(entry.id)
    if (observed) {
      observed.durationMs = performance.now() - observed.startedAt
      observed.failed = failed
    }
    this.notify()
  }

  private notify() {
    this.listeners?.forEach((listener) => listener())
  }

  private demand(entry: Entry) {
    if (entry.loaded && entry.promise) return entry.promise
    this.demandsInFlight += 1
    this.notify()
    const promise = this.fetch(entry)
    const settle = () => {
      this.demandsInFlight -= 1
      this.schedulePump()
      this.notify()
    }
    promise.then(settle, settle)
    return promise
  }

  private schedulePump() {
    if (!this.started || this.stoppedReason || this.pumpScheduled) return
    this.pumpScheduled = true
    this.environment().scheduleIdle(() => {
      this.pumpScheduled = false
      this.pump()
    })
  }

  private nextEntry() {
    let next: Entry | undefined
    for (const entry of this.entries.values()) {
      if (entry.promise || (entry.group && this.skipGroups.has(entry.group))) continue
      if (!next || entry.priority < next.priority || (entry.priority === next.priority && entry.order < next.order)) next = entry
    }
    return next
  }

  private pump() {
    if (!this.started || this.stoppedReason || this.backgroundInFlight || this.demandsInFlight > 0) return
    if (this.environment().isHidden()) return
    const entry = this.nextEntry()
    if (!entry) return

    this.backgroundInFlight = entry
    this.notify()
    this.fetch(entry).then(
      () => {
        this.backgroundInFlight = null
        this.schedulePump()
        this.notify()
      },
      () => {
        // handled-error-expected: a background load failing (typically a chunk a deploy replaced) stops warm-up; the on-demand load retries and owns recovery.
        this.backgroundInFlight = null
        this.stoppedReason = "failure"
        this.notify()
      }
    )
  }
}

export const chunkWarmup = new ChunkWarmupQueue()

export function warmableChunk<T>(id: string, load: () => Promise<T>, options: ChunkWarmupOptions): WarmableLoader<T> {
  return chunkWarmup.register(id, load, options)
}

export function startChunkWarmup(options?: { skipGroups?: readonly string[] }) {
  chunkWarmup.start(options)
}

export function disableChunkWarmup(reason: "signed_out" | "dev_server") {
  chunkWarmup.disable(reason)
}
