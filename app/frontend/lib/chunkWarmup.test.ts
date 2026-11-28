import { describe, expect, it, vi } from "vitest"
import { ChunkWarmupQueue, type ChunkWarmupEnvironment } from "./chunkWarmup"

type Deferred = { promise: Promise<unknown>; resolve: (value?: unknown) => void; reject: (error: unknown) => void }

function deferred(): Deferred {
  let resolve!: Deferred["resolve"]
  let reject!: Deferred["reject"]
  const promise = new Promise<unknown>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

function fakeEnvironment(overrides: Partial<{ hidden: boolean; connection: { saveData?: boolean; effectiveType?: string } }> = {}) {
  const idle: Array<() => void> = []
  const visibleListeners: Array<() => void> = []
  const state = { hidden: overrides.hidden ?? false }
  const environment: ChunkWarmupEnvironment = {
    scheduleIdle: (callback) => idle.push(callback),
    isHidden: () => state.hidden,
    onVisible: (callback) => visibleListeners.push(callback),
    connection: () => overrides.connection
  }
  return {
    environment,
    state,
    // Runs idle callbacks (and the microtasks their loads settle in) until
    // nothing is left to schedule.
    async flush() {
      for (let round = 0; round < 50; round += 1) {
        await new Promise((resolve) => setTimeout(resolve, 0))
        const callbacks = idle.splice(0)
        if (callbacks.length === 0) return
        callbacks.forEach((callback) => callback())
      }
    },
    becomeVisible() {
      state.hidden = false
      visibleListeners.forEach((listener) => listener())
    }
  }
}

function controlledLoader(name: string, log: string[]) {
  const pending = deferred()
  const load = vi.fn(() => {
    log.push(`start:${name}`)
    return pending.promise.then((value) => {
      log.push(`done:${name}`)
      return value ?? { name }
    })
  })
  return { load, pending }
}

describe("ChunkWarmupQueue", () => {
  it("warms registered chunks one at a time in priority order, registration order within a priority", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const log: string[] = []
    const admin = controlledLoader("admin", log)
    const chat = controlledLoader("chat", log)
    const plugin = controlledLoader("plugin", log)
    const job = controlledLoader("job", log)
    queue.register("admin", admin.load, { priority: 4 })
    queue.register("chat", chat.load, { priority: 0 })
    queue.register("plugin", plugin.load, { priority: 2 })
    queue.register("job", job.load, { priority: 0 })

    queue.start()
    await env.flush()
    expect(log).toEqual(["start:chat"])

    chat.pending.resolve()
    await env.flush()
    expect(log).toEqual(["start:chat", "done:chat", "start:job"])

    job.pending.resolve()
    await env.flush()
    plugin.pending.resolve()
    await env.flush()
    admin.pending.resolve()
    await env.flush()

    expect(log).toEqual(["start:chat", "done:chat", "start:job", "done:job", "start:plugin", "done:plugin", "start:admin", "done:admin"])
  })

  it("does nothing before start, so warm-up cannot join the startup download", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const load = vi.fn(async () => ({}))
    queue.register("chat", load, { priority: 0 })

    await env.flush()

    expect(load).not.toHaveBeenCalled()
  })

  it("does not collect timing diagnostics when nobody subscribes", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const now = vi.spyOn(performance, "now")
    const load = queue.register("chat", async () => ({}), { priority: 0 })

    await load()

    expect(now).not.toHaveBeenCalled()
    now.mockRestore()
  })

  it("loads an on-demand chunk ahead of the queue and pauses warm-up until it settles", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const log: string[] = []
    const first = controlledLoader("first", log)
    const second = controlledLoader("second", log)
    const wanted = controlledLoader("wanted", log)
    queue.register("first", first.load, { priority: 0 })
    queue.register("second", second.load, { priority: 1 })
    const loadWanted = queue.register("wanted", wanted.load, { priority: 4 })

    queue.start()
    await env.flush()
    expect(log).toEqual(["start:first"])

    const demanded = loadWanted()
    expect(log).toEqual(["start:first", "start:wanted"])
    expect(queue.backgroundOnlyInFlight()).toBe(false)

    first.pending.resolve()
    await env.flush()
    // The background load finished, but the user is still waiting on theirs.
    expect(log).toEqual(["start:first", "start:wanted", "done:first"])

    wanted.pending.resolve()
    await demanded
    await env.flush()
    expect(log).toEqual(["start:first", "start:wanted", "done:first", "done:wanted", "start:second"])
  })

  it("shares one request between an on-demand load and a finished or in-flight warm-up", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const module = { ChatRoute: () => null }
    const load = vi.fn(async () => module)
    const loadChat = queue.register("chat", load, { priority: 0 })

    queue.start()
    await env.flush()
    expect(load).toHaveBeenCalledTimes(1)
    expect(queue.isLoaded("chat")).toBe(true)

    await expect(loadChat()).resolves.toBe(module)
    await expect(loadChat()).resolves.toBe(module)
    expect(load).toHaveBeenCalledTimes(1)

    const inFlight = deferred()
    const slowLoad = vi.fn(() => inFlight.promise)
    const loadJob = queue.register("job", slowLoad, { priority: 0 })
    const waiting = loadJob()
    const again = loadJob()
    inFlight.resolve(module)
    await Promise.all([waiting, again])
    expect(slowLoad).toHaveBeenCalledTimes(1)
  })

  it("never starts on a connection that asks to save data", async () => {
    const env = fakeEnvironment({ connection: { saveData: true, effectiveType: "4g" } })
    const queue = new ChunkWarmupQueue(env.environment)
    const load = vi.fn(async () => ({}))
    const loadChat = queue.register("chat", load, { priority: 0 })

    queue.start()
    await env.flush()
    expect(load).not.toHaveBeenCalled()

    // On-demand loads still work.
    await loadChat()
    expect(load).toHaveBeenCalledTimes(1)
  })

  it("never starts on a 2g connection", async () => {
    const env = fakeEnvironment({ connection: { effectiveType: "slow-2g" } })
    const queue = new ChunkWarmupQueue(env.environment)
    const load = vi.fn(async () => ({}))
    queue.register("chat", load, { priority: 0 })

    queue.start()
    await env.flush()

    expect(load).not.toHaveBeenCalled()
  })

  it("waits while the tab is hidden and resumes when it becomes visible", async () => {
    const env = fakeEnvironment({ hidden: true })
    const queue = new ChunkWarmupQueue(env.environment)
    const load = vi.fn(async () => ({}))
    queue.register("chat", load, { priority: 0 })

    queue.start()
    await env.flush()
    expect(load).not.toHaveBeenCalled()

    env.becomeVisible()
    await env.flush()
    expect(load).toHaveBeenCalledTimes(1)
  })

  it("stops after the next load once the tab is hidden", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const log: string[] = []
    const first = controlledLoader("first", log)
    const second = controlledLoader("second", log)
    queue.register("first", first.load, { priority: 0 })
    queue.register("second", second.load, { priority: 0 })

    queue.start()
    await env.flush()
    env.state.hidden = true
    first.pending.resolve()
    await env.flush()
    expect(log).toEqual(["start:first", "done:first"])

    env.becomeVisible()
    await env.flush()
    expect(log).toEqual(["start:first", "done:first", "start:second"])
  })

  it("skips groups the caller leaves cold", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const adminLoad = vi.fn(async () => ({}))
    const chatLoad = vi.fn(async () => ({}))
    queue.register("admin", adminLoad, { priority: 4, group: "admin" })
    queue.register("chat", chatLoad, { priority: 0 })

    queue.start({ skipGroups: ["admin"] })
    await env.flush()

    expect(chatLoad).toHaveBeenCalledTimes(1)
    expect(adminLoad).not.toHaveBeenCalled()
  })

  it("stops warm-up after a failed background load and lets the next on-demand load retry", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const failing = deferred()
    const staleLoad = vi.fn().mockReturnValueOnce(failing.promise).mockResolvedValueOnce({ fresh: true })
    const laterLoad = vi.fn(async () => ({}))
    const loadStale = queue.register("stale", staleLoad, { priority: 0 })
    queue.register("later", laterLoad, { priority: 1 })

    queue.start()
    await env.flush()
    expect(queue.backgroundOnlyInFlight()).toBe(true)

    failing.reject(new Error("Failed to fetch dynamically imported module"))
    await env.flush()

    expect(queue.backgroundOnlyInFlight()).toBe(false)
    expect(laterLoad).not.toHaveBeenCalled()
    await expect(loadStale()).resolves.toEqual({ fresh: true })
    expect(staleLoad).toHaveBeenCalledTimes(2)
  })

  it("publishes queue transitions and stops diagnostic work after unsubscribe", async () => {
    const env = fakeEnvironment()
    const queue = new ChunkWarmupQueue(env.environment)
    const pending = deferred()
    const load = queue.register("chat", () => pending.promise, { priority: 2, group: "routes" })
    const listener = vi.fn()
    const unsubscribe = queue.subscribe(listener)

    queue.start()
    expect(queue.snapshot().entries[0]).toMatchObject({ id: "chat", state: "queued", group: "routes", priority: 2 })
    await env.flush()
    expect(queue.snapshot()).toMatchObject({ loading: "chat", stoppedAfterFailure: false })

    pending.resolve()
    await load()
    expect(queue.snapshot().entries[0]).toMatchObject({ state: "loaded", source: "warmup" })
    expect(listener).toHaveBeenCalled()

    unsubscribe()
    listener.mockClear()
    queue.clearWarmupState()
    expect(listener).not.toHaveBeenCalled()
  })

  it("reports connection, visibility, and on-demand pause reasons", async () => {
    const env = fakeEnvironment({ hidden: true, connection: { saveData: true, effectiveType: "2g" } })
    const queue = new ChunkWarmupQueue(env.environment)
    const pending = deferred()
    const demand = queue.register("chat", () => pending.promise, { priority: 0 })
    queue.subscribe(() => {})
    void demand()

    expect(queue.snapshot().pauseReasons).toEqual(["data_saver", "slow_connection", "hidden_tab", "on_demand"])
    pending.resolve()
    await pending.promise
  })
})
