import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { afterAll, beforeEach, describe, expect, it, vi } from "vitest"

// NY24: the image a backend update replaced is kept for seven days, and a
// healthy launch after that retires it. Stubs every boundary backendLifecycle
// touches, as backendWatchdog.test.ts does, with a real state directory.
const stateDir = await mkdtemp(path.join(tmpdir(), "image-retention-launch-"))

vi.mock("electron", () => ({ app: { getAppPath: () => "/app", isPackaged: false } }))
vi.mock("../electron/settings.js", () => ({
  currentChannel: () => "stable",
  currentStackIdentity: () => ({ project: "syrus", dataVolume: "syrus_syrus-data", defaultPort: 3000 }),
  getBackendMode: () => "local",
  getLocalInstall: () => null,
  localStateDir: () => stateDir
}))
vi.mock("../electron/installer/dockerRuntime.js", () => ({
  composeCommand: async () => ["docker", "compose"],
  daemonUp: async () => true,
  execEnv: () => ({}),
  findDockerBinary: async () => "docker",
  installedRuntimeApp: () => null,
  startRuntimeApp: async () => {},
  syrusHealthy: async () => true,
  volumeExists: async () => true
}))
const cleanup = vi.hoisted(() => ({ calls: [] as Array<{ pinnedRef: string | null; retainedRef?: string | null }> }))
vi.mock("../electron/installer/imageCleanup.js", () => ({
  removeSupersededSyrusImages: async (options: { pinnedRef: string | null; retainedRef?: string | null }) => {
    cleanup.calls.push({ pinnedRef: options.pinnedRef, retainedRef: options.retainedRef })
    return { removed: [], reclaimedDisplay: null }
  }
}))

const lifecycle = await import("../electron/installer/backendLifecycle")

const pin = "ghcr.io/tkadauke/syrus-backend:0.1.2"
const retentionFile = path.join(stateDir, "image-retention.json")

describe("retiring a kept previous image at launch", () => {
  beforeEach(async () => {
    cleanup.calls.length = 0
    await writeFile(path.join(stateDir, ".env"), `SYRUS_IMAGE=${pin}\n`, "utf8")
  })

  afterAll(async () => {
    await rm(stateDir, { recursive: true, force: true })
  })

  it("retires the previous image once its seven days have passed", async () => {
    await writeFile(retentionFile, JSON.stringify({ ref: "ghcr.io/tkadauke/syrus-backend:0.1.1", until: "2020-01-01T00:00:00.000Z" }))

    await lifecycle.ensureRunning()

    expect(cleanup.calls).toEqual([{ pinnedRef: pin, retainedRef: null }])
    await expect(readFile(retentionFile, "utf8")).rejects.toThrow()
  })

  it("keeps the previous image while its retention lasts", async () => {
    const until = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString()
    await writeFile(retentionFile, JSON.stringify({ ref: "ghcr.io/tkadauke/syrus-backend:0.1.1", until }))

    await lifecycle.ensureRunning()

    expect(cleanup.calls).toEqual([])
    expect(JSON.parse(await readFile(retentionFile, "utf8"))).toMatchObject({ until })
  })

  it("does nothing at launch when no image is kept", async () => {
    await rm(retentionFile, { force: true })

    await lifecycle.ensureRunning()

    expect(cleanup.calls).toEqual([])
  })
})
