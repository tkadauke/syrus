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
}

export type WarmableLoader<T> = (() => Promise<T>) & { readonly warmupId: string }

const SLOW_CONNECTION_TYPES = new Set(["slow-2g", "2g"])

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
  private stopped = false
  private skipGroups = new Set<string>()
  private demandsInFlight = 0
  private backgroundInFlight: Entry | null = null
  private pumpScheduled = false
  private visibilityListening = false
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
      entry = { id, priority: options.priority, group: options.group, order: this.order++, load, loaded: false }
      this.entries.set(id, entry)
    }
    const registered = entry
    const demand = () => this.demand(registered) as Promise<T>
    return Object.assign(demand, { warmupId: id })
  }

  /** Begins background warm-up. Idempotent; call it after the first commit. */
  start({ skipGroups = [] }: { skipGroups?: readonly string[] } = {}) {
    skipGroups.forEach((group) => this.skipGroups.add(group))
    if (this.started) return
    this.started = true
    if (this.slowConnection()) {
      this.stopped = true
      return
    }
    if (!this.visibilityListening) {
      this.visibilityListening = true
      this.environment().onVisible(() => this.schedulePump())
    }
    this.schedulePump()
  }

  /** True while the only chunk loads in flight are background ones. */
  backgroundOnlyInFlight() {
    return this.backgroundInFlight !== null && this.demandsInFlight === 0
  }

  isLoaded(id: string) {
    return this.entries.get(id)?.loaded ?? false
  }

  private slowConnection() {
    const connection = this.environment().connection()
    if (!connection) return false
    return connection.saveData === true || SLOW_CONNECTION_TYPES.has(connection.effectiveType ?? "")
  }

  private fetch(entry: Entry) {
    if (!entry.promise) {
      entry.promise = entry.load().then(
        (module) => {
          entry.loaded = true
          return module
        },
        (error: unknown) => {
          // Forget the failure so the next on-demand load can retry.
          entry.promise = undefined
          throw error
        }
      )
    }
    return entry.promise
  }

  private demand(entry: Entry) {
    if (entry.loaded && entry.promise) return entry.promise
    this.demandsInFlight += 1
    const promise = this.fetch(entry)
    const settle = () => {
      this.demandsInFlight -= 1
      this.schedulePump()
    }
    promise.then(settle, settle)
    return promise
  }

  private schedulePump() {
    if (!this.started || this.stopped || this.pumpScheduled) return
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
    if (this.stopped || this.backgroundInFlight || this.demandsInFlight > 0) return
    if (this.environment().isHidden()) return
    const entry = this.nextEntry()
    if (!entry) return

    this.backgroundInFlight = entry
    this.fetch(entry).then(
      () => {
        this.backgroundInFlight = null
        this.schedulePump()
      },
      () => {
        // handled-error-expected: a background load failing (typically a chunk a deploy replaced) stops warm-up; the on-demand load retries and owns recovery.
        this.backgroundInFlight = null
        this.stopped = true
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
