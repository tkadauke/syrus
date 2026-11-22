import { EventEmitter } from "node:events"
import os from "node:os"
import path from "node:path"
import { PassThrough } from "node:stream"
import { afterEach, describe, expect, it, vi } from "vitest"

const stateDir = path.join(os.tmpdir(), `syrus-installer-cancel-${process.pid}`)

vi.mock("electron", () => ({ app: { getAppPath: () => "/app", isPackaged: false }, dialog: {}, shell: {} }))
vi.mock("../electron/settings.js", () => ({
  currentStackIdentity: () => ({ project: "syrus", dataVolume: "syrus_syrus-data", defaultPort: 3000 }),
  localStateDir: () => stateDir,
  saveBackendConfig: vi.fn(),
  setOnboardingResumeLocal: vi.fn()
}))
vi.mock("../electron/installer/installPaths.js", () => ({
  installerCommand: () => ({ command: "/bin/sh", args: ["install.sh"] }),
  installerScriptPath: () => "install.sh",
  readBackendManifest: async () => null
}))

// The lock open is held until the test releases it, so a cancel can land
// while the driver is still acquiring the install lock.
let releaseLockOpen: () => void = () => {}
vi.mock("node:fs/promises", async () => {
  const actual = await vi.importActual<typeof import("node:fs/promises")>("node:fs/promises")
  const open: typeof actual.open = async (...args) => {
    if (String(args[1]) === "wx") {
      await new Promise<void>((resolve) => {
        releaseLockOpen = resolve
      })
    }
    return actual.open(...args)
  }
  const fs = { ...actual, open }
  return { ...fs, default: fs }
})

const spawned: EventEmitter[] = []
vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process")
  const spawn = () => {
    const child = Object.assign(new EventEmitter(), {
      pid: 999_999,
      stdout: new PassThrough(),
      stderr: new PassThrough(),
      kill: vi.fn()
    })
    spawned.push(child)
    return child
  }
  const childProcess = { ...actual, spawn }
  return { ...childProcess, default: childProcess }
})

const { OnboardingDriver } = await import("../electron/installer/installerDriver")

describe("OnboardingDriver cancellation", () => {
  afterEach(async () => {
    const fs = await vi.importActual<typeof import("node:fs/promises")>("node:fs/promises")
    await fs.rm(stateDir, { recursive: true, force: true })
  })

  // cancelRequested was checked only after the manifest read. A cancel that
  // landed while the install lock was being acquired put the wizard back at
  // Welcome, then the install resumed: it set "local.installing" and spawned
  // an installer nobody would kill.
  it("never spawns an installer after a cancel that lands while the lock is being acquired", async () => {
    const states: string[] = []
    const driver = new OnboardingDriver({ onState: (state) => states.push(state.phase), onLogLine: () => {} })

    const install = driver.startInstall()
    await vi.waitFor(() => expect(releaseLockOpen).not.toBe(undefined))
    await new Promise((resolve) => setTimeout(resolve, 10))
    const cancelled = driver.cancelInstall()
    releaseLockOpen()
    await install
    await cancelled

    expect(spawned).toEqual([])
    expect(driver.getState().phase).toBe("welcome")
    expect(states).not.toContain("local.installing")
    expect(driver.installRunning()).toBe(false)
    const fs = await vi.importActual<typeof import("node:fs/promises")>("node:fs/promises")
    await expect(fs.stat(path.join(stateDir, "install.pid"))).rejects.toThrow()
  })

  // A stale lock was broken only when its PID was dead. An install
  // interrupted by a reboot (the case reboot-resume exists for) leaves the
  // installer's PID behind, and after a reboot PIDs are reused: if anything
  // now runs under it, every install was refused as "already running" until
  // someone deleted the file by hand. A lock written before this boot cannot
  // be held by a running process.
  it("breaks a lock written before the last boot even when its PID is in use", async () => {
    const fs = await vi.importActual<typeof import("node:fs/promises")>("node:fs/promises")
    await fs.mkdir(stateDir, { recursive: true })
    const lockPath = path.join(stateDir, "install.pid")
    await fs.writeFile(lockPath, String(process.pid)) // a live PID
    const beforeBoot = new Date(Date.now() - (os.uptime() + 3600) * 1000)
    await fs.utimes(lockPath, beforeBoot, beforeBoot)

    const driver = new OnboardingDriver({ onState: () => {}, onLogLine: () => {} })
    const install = driver.startInstall()
    for (let attempt = 0; attempt < 50 && spawned.length === 0; attempt += 1) {
      releaseLockOpen()
      await new Promise((resolve) => setTimeout(resolve, 5))
    }
    await install

    expect(driver.getState().phase).toBe("local.installing")
    expect(spawned).toHaveLength(1)
  })
})
