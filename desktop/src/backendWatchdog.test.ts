import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

// Stub every boundary backendLifecycle touches: settings, the Docker runtime
// probes, the installer paths (electron), and child_process (compose).
vi.mock("electron", () => ({ app: { getAppPath: () => "/app", isPackaged: false } }))
vi.mock("../electron/settings.js", () => ({
  currentChannel: () => "stable",
  currentStackIdentity: () => ({ project: "syrus", dataVolume: "syrus_syrus-data", defaultPort: 3000 }),
  getBackendMode: () => "local",
  getLocalInstall: () => null,
  localStateDir: () => "/tmp/syrus-watchdog-test"
}))

let health: () => Promise<boolean> = async () => true
vi.mock("../electron/installer/dockerRuntime.js", () => ({
  composeCommand: async () => ["docker", "compose"],
  daemonUp: async () => true,
  execEnv: () => ({}),
  findDockerBinary: async () => "docker",
  installedRuntimeApp: () => null,
  startRuntimeApp: async () => {},
  syrusHealthy: () => health(),
  volumeExists: async () => true
}))
vi.mock("node:child_process", () => {
  const childProcess = {
    execFile: (_file: string, _args: string[], _options: unknown, callback: (error: Error | null, out: unknown) => void) =>
      callback(null, { stdout: "", stderr: "" }),
    spawn: () => {
      throw new Error("spawn is not used by this test")
    }
  }
  return { ...childProcess, default: childProcess }
})

const lifecycle = await import("../electron/installer/backendLifecycle")

const deferred = () => {
  let resolve: (value: boolean) => void = () => {}
  const promise = new Promise<boolean>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

describe("backend watchdog", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    lifecycle.stopWatchdog()
    vi.useRealTimers()
  })

  // The watchdog checked "busy" only when a tick began, then awaited a health
  // probe. A deliberate Stop that completed while that probe was in flight
  // marks the stack as intentionally down; the stale "healthy" answer then
  // flipped it back, and the next tick reported the stopped stack as a
  // "containers-down" outage over the "stopped" page.
  it("never lets a probe that started before a deliberate stop override it", async () => {
    const reports: Array<[boolean, string | null]> = []
    lifecycle.startWatchdog({ onHealthyChanged: (healthy, diagnosis) => reports.push([healthy, diagnosis]) })

    // Tick 1 starts while the stack is up; its probe is slow.
    const slowProbe = deferred()
    health = () => slowProbe.promise
    await vi.advanceTimersByTimeAsync(30_000)

    // The user stops the backend while that probe is still outstanding.
    expect(await lifecycle.stopBackend()).toBe(true)

    // The stale probe now answers "healthy" for the stack that was running.
    slowProbe.resolve(true)
    await vi.advanceTimersByTimeAsync(0)

    // Every later tick sees the stack down, as the user intended.
    health = async () => false
    await vi.advanceTimersByTimeAsync(60_000)

    expect(reports).toEqual([])
  })

  it("still reports a stack that goes down and comes back on its own", async () => {
    health = async () => true
    expect(await lifecycle.startBackend()).toBe(true)
    const reports: Array<[boolean, string | null]> = []
    lifecycle.startWatchdog({ onHealthyChanged: (healthy, diagnosis) => reports.push([healthy, diagnosis]) })

    // The first tick catches up with the start (the previous test stopped it).
    await vi.advanceTimersByTimeAsync(30_000)
    health = async () => false
    await vi.advanceTimersByTimeAsync(30_000)
    health = async () => true
    await vi.advanceTimersByTimeAsync(30_000)

    expect(reports).toEqual([
      [true, null],
      [false, "containers-down"],
      [true, null]
    ])
  })
})
