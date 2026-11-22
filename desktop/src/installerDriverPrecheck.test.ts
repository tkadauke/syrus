import os from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"

const stateDir = path.join(os.tmpdir(), `syrus-installer-precheck-${process.pid}`)

vi.mock("electron", () => ({ app: { getAppPath: () => "/app", isPackaged: false }, dialog: {}, shell: {} }))
vi.mock("../electron/settings.js", () => ({
  currentStackIdentity: () => ({ channel: "stable", project: "syrus", dataVolume: "syrus_syrus-data", defaultPort: 3000 }),
  localStateDir: () => stateDir,
  saveBackendConfig: vi.fn(),
  setOnboardingResumeLocal: vi.fn()
}))
vi.mock("../electron/installer/installPaths.js", () => ({
  installerCommand: () => ({ command: "/bin/sh", args: ["install.sh"] }),
  installerScriptPath: () => "install.sh",
  readBackendManifest: async () => null
}))

// The daemon probe is held until the test answers it.
let answerDaemon: (up: boolean) => void = () => {}
vi.mock("../electron/installer/dockerRuntime.js", () => ({
  composeCommand: async () => ["docker", "compose"],
  daemonUp: () =>
    new Promise<boolean>((resolve) => {
      answerDaemon = resolve
    }),
  execEnv: () => ({}),
  findDockerBinary: async () => "docker",
  installWsl: async () => {},
  installedRuntimeApp: () => null,
  portInUse: async () => false,
  startRuntimeApp: async () => {},
  syrusHealthy: async () => false,
  volumeExists: async () => false,
  wslReady: async () => true
}))

const spawn = vi.fn(() => {
  throw new Error("an installer was spawned")
})
vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process")
  const childProcess = { ...actual, spawn }
  return { ...childProcess, default: childProcess }
})

const { OnboardingDriver } = await import("../electron/installer/installerDriver")

describe("OnboardingDriver precheck", () => {
  afterEach(async () => {
    const fs = await vi.importActual<typeof import("node:fs/promises")>("node:fs/promises")
    await fs.rm(stateDir, { recursive: true, force: true })
  })

  // precheck awaits several probes (the daemon probe alone can take seconds)
  // and then sets the wizard state or starts the install outright. It never
  // re-checked that it was still current, so "Run Setup Again…" (reset) while
  // it ran was overridden by the stale result, which went on to install.
  it("drops its result when the wizard was reset while it probed", async () => {
    const phases: string[] = []
    const driver = new OnboardingDriver({ onState: (state) => phases.push(state.phase), onLogLine: () => {} })

    const precheck = driver.precheck()
    await vi.waitFor(() => expect(phases).toContain("local.precheck"))
    await new Promise((resolve) => setTimeout(resolve, 10))
    driver.reset()
    answerDaemon(true)
    await precheck

    expect(driver.getState().phase).toBe("welcome")
    expect(phases.at(-1)).toBe("welcome")
    expect(spawn).not.toHaveBeenCalled()
    expect(driver.installRunning()).toBe(false)
  })
})
