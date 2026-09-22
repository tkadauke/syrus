import { execFile, spawn, type ChildProcess } from "node:child_process"
import { createWriteStream } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import readline from "node:readline"
import { promisify } from "node:util"
import { currentChannel, currentStackIdentity, getBackendMode, getLocalInstall, localStateDir } from "../settings.js"
import {
  composeCommand,
  daemonUp,
  execEnv,
  findDockerBinary,
  installedRuntimeApp,
  startRuntimeApp,
  syrusHealthy,
  volumeExists
} from "./dockerRuntime.js"
import { removeSupersededSyrusImages } from "./imageCleanup.js"
import { installerCommand, installerScriptPath } from "./installPaths.js"
import { BackendUpdateProgressTracker, type BackendUpdateProgress } from "./updateProgress.js"

export type { BackendUpdateProgress } from "./updateProgress.js"

const execFileAsync = promisify(execFile)

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

const WATCHDOG_INTERVAL_MS = 30_000
const DAEMON_WAIT_DEADLINE_MS = 180_000
const HEALTH_WAIT_POLLS = 60 // × 2s = 120s
// Wall-clock bound on a backend update. install.sh has no overall timeout of
// its own (its health probe curls with no --max-time; a wedged pull can sit
// forever), and a hung installer would otherwise leave `busy` true and the
// sidebar's backendUpdate state non-null FOREVER — watchdog starved, Backend
// menu refusing, gated surfaces suppressed. Generous on purpose: multi-GB
// pulls on slow links are legitimate.
const UPDATE_DEADLINE_MS = 30 * 60_000

// "data-gone" means Docker is healthy but the Syrus data volume no longer
// exists (wiped containers/volumes) — the stack can never recover on its own.
export type BackendDiagnosis = "daemon-down" | "containers-down" | "stopped" | "data-gone"

const stateDir = () => getLocalInstall()?.stateDir ?? localStateDir()
const port = () => getLocalInstall()?.port ?? currentStackIdentity().defaultPort

// The install copied docker-compose.yml + .env into the state dir, so plain
// compose invocations from there see the pinned image and the right env.
// Never `down` (that deletes containers; -v would delete data), and never
// `pull` here — image updates happen only through the installer.
const compose = async (args: string[], timeout = 120_000) => {
  const command = await composeCommand()
  if (!command) {
    throw new Error("Docker Compose is not available.")
  }

  const [binary, ...prefixArgs] = command
  await execFileAsync(binary, [...prefixArgs, "-p", currentStackIdentity().project, ...args], {
    cwd: stateDir(),
    env: execEnv(),
    timeout
  })
}

// TEST-CHANNEL ONLY "clean slate": tear down this channel's stack AND delete
// its data volumes. `down -v` is exactly what the `compose` callers above
// deliberately refuse to do (it destroys data), so it lives behind a hard
// channel guard — on a stable build `currentStackIdentity().project` is
// production's `syrus`, which this must never touch. Best-effort throughout: a
// missing compose file, a stopped daemon, or already-absent volumes must not
// wedge the reset. Powers "Reset Test Setup…" (main.ts) so the initial setup
// flow can be exercised again from scratch.
export const wipeBackendStack = async (): Promise<void> => {
  if (currentChannel() !== "test") {
    throw new Error("wipeBackendStack is only available on the test channel")
  }

  const identity = currentStackIdentity()

  // `down -v` removes the containers + the Compose-managed named volumes, when
  // the state dir still holds the compose file to read.
  try {
    await compose(["down", "-v", "--remove-orphans"])
  } catch {
    // No compose file, a stopped daemon, or nothing running — the by-name
    // volume removal below still gets the slate clean.
  }

  // Belt-and-braces: remove the named volumes directly, scoped strictly to this
  // channel's `<project>_` prefix, in case the compose file was already deleted
  // so `down -v` couldn't enumerate them.
  const dockerBinary = await findDockerBinary()
  if (dockerBinary) {
    for (const volume of [identity.dataVolume, identity.searchVolume]) {
      try {
        await execFileAsync(dockerBinary, ["volume", "rm", "-f", volume], { env: execEnv(), timeout: 30_000 })
      } catch {
        // Absent or still referenced — best-effort.
      }
    }

    // Plugin Runtime's service containers and volumes (e.g. Git Mirror's
    // mirrors) are the runtime manager's, not Compose's, so `down -v` leaves
    // them. They carry the manager's project label; remove them by it.
    const pluginLabel = `label=dev.syrus.runtime.project=${identity.project}`
    for (const [kind, listArgs] of [
      ["rm", ["ps", "-aq", "--filter", pluginLabel]],
      ["volume", ["volume", "ls", "-q", "--filter", pluginLabel]]
    ] as const) {
      try {
        const { stdout } = await execFileAsync(dockerBinary, [...listArgs], { env: execEnv(), timeout: 30_000 })
        const ids = String(stdout).split(/\s+/).filter(Boolean)
        if (ids.length > 0) {
          const removeArgs = kind === "rm" ? ["rm", "-f", ...ids] : ["volume", "rm", "-f", ...ids]
          await execFileAsync(dockerBinary, removeArgs, { env: execEnv(), timeout: 30_000 })
        }
      } catch {
        // Best-effort, like the rest of the reset.
      }
    }
  }
}

export const backendHealthy = () => syrusHealthy(port())

const ensureDaemon = async () => {
  if (await daemonUp()) {
    return true
  }

  const runtimeApp = installedRuntimeApp()
  if (!runtimeApp) {
    return false
  }

  try {
    await startRuntimeApp(runtimeApp)
  } catch {
    return false
  }

  // Wall-clock deadline with a short per-poll probe: a wedged daemon can
  // hang `docker info` for its full timeout, so an iteration-counted loop
  // with 10s probes silently stretched "3 minutes" to ~18.
  const deadline = Date.now() + DAEMON_WAIT_DEADLINE_MS
  while (Date.now() < deadline) {
    if (await daemonUp(2_000)) {
      return true
    }

    await sleep(2_000)
  }

  return false
}

let busy = false
let lastHealthy = true
let updateChild: ChildProcess | null = null

// Whether a lifecycle action (start/stop/update) is in flight. Exposed so
// main can defer actions that must not race an update — most importantly
// "Relaunch to update", whose quitAndInstall would orphan the installer
// mid-pin-rewrite and relaunch into a churning stack with no update state.
export const backendBusy = () => busy

// Kill the whole in-flight installer tree (same technique as the onboarding
// driver's killInstallChild): POSIX signals the detached process group so
// docker/compose grandchildren die too; Windows (no process groups) walks
// the tree with taskkill /T. Used by the update deadline and by main's
// before-quit, so neither a wedged pull nor a quitting app can orphan a
// half-applied update. Best-effort by contract.
export const killUpdateChild = () => {
  const child = updateChild
  if (!child?.pid) {
    return
  }

  console.warn("[backend-update] killing the in-flight installer (deadline exceeded or app quitting)")
  if (process.platform === "win32") {
    execFile("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true }, () => {})
    return
  }

  try {
    process.kill(-child.pid, "SIGTERM")
  } catch {
    child.kill("SIGTERM")
  }
}

export const startBackend = async (): Promise<boolean> => {
  if (getBackendMode() !== "local" || busy) {
    return false
  }

  busy = true
  try {
    if (!(await ensureDaemon())) {
      return false
    }

    await compose(["up", "-d"])

    for (let poll = 0; poll < HEALTH_WAIT_POLLS; poll += 1) {
      if (await backendHealthy()) {
        return true
      }

      await sleep(2_000)
    }

    return false
  } catch {
    return false
  } finally {
    busy = false
  }
}

export const stopBackend = async (): Promise<boolean> => {
  if (getBackendMode() !== "local" || busy) {
    return false
  }

  busy = true
  try {
    await compose(["stop"])
    // A deliberate stop is not an outage: pre-marking the transition keeps
    // the watchdog from overwriting the "stopped" status page with a
    // "containers-down" failure within the next tick.
    lastHealthy = false
    return true
  } catch {
    return false
  } finally {
    busy = false
  }
}

// The SYRUS_IMAGE pin the local install actually runs; null when .env is
// missing or has no pin (pre-pin installs float on :latest).
export const currentImagePin = async (): Promise<string | null> => {
  try {
    const contents = await fs.readFile(path.join(stateDir(), ".env"), "utf8")
    return contents.match(/^SYRUS_IMAGE=(.*)$/m)?.[1]?.trim() || null
  } catch {
    return null
  }
}

// The update's live progress feed for the web sidebar: called with each new
// phase/percent snapshot, then with null once the update ends (either way).
// Progress is strictly cosmetic — a throwing callback must never be able to
// fail or wedge the update itself.
type UpdateBackendDeps = {
  onProgress?: (progress: BackendUpdateProgress | null) => void
}

// Applies a new pinned image by re-running the bundled installer against the
// existing state dir — the same audited path a fresh install takes: rewrite
// the SYRUS_IMAGE pin, pull, recreate containers, health-gate. Output appends
// to install.log so Backend → Open Install Log covers updates too.
export const updateBackend = async (image: string, deps: UpdateBackendDeps = {}): Promise<boolean> => {
  if (getBackendMode() !== "local" || busy) {
    return false
  }

  busy = true
  const report = (progress: BackendUpdateProgress | null) => {
    try {
      deps.onProgress?.(progress)
    } catch {
      // Progress display must never break the update.
    }
  }
  try {
    const tracker = new BackendUpdateProgressTracker()
    // Report "starting" before the daemon wait so the sidebar notice covers
    // the whole outage window, not just the installer's own runtime.
    report(tracker.snapshot())
    if (!(await ensureDaemon())) {
      return false
    }

    const env = execEnv()
    // Test-pacing overrides are for onboarding-driver specs only.
    delete env.SYRUS_HEALTH_POLLS
    delete env.SYRUS_PULL_RETRY_DELAY

    const log = createWriteStream(path.join(stateDir(), "install.log"), { flags: "a" })
    try {
      const ok = await new Promise<boolean>((resolve) => {
        // Same platform-selected interpreter as the onboarding driver — the
        // image-update path IS the installer (bash install.sh on POSIX,
        // powershell install.ps1 on Windows).
        const { command, args } = installerCommand(installerScriptPath(), [
          "--docker",
          "--non-interactive",
          "--json",
          "--skip-runtime-install",
          "--target-dir",
          stateDir(),
          // Pin the update to THIS channel's Compose project so a test-stack
          // update never recreates the production containers (or vice versa).
          "--project",
          currentStackIdentity().project,
          "--image",
          image
        ])
        // POSIX: detached puts the script's docker/compose grandchildren in
        // one process group so killUpdateChild can signal the whole tree;
        // Windows has no process groups and uses taskkill /T instead (same
        // split as the onboarding driver's install spawn).
        const child =
          process.platform === "win32"
            ? spawn(command, args, { env, windowsHide: true })
            : spawn(command, args, { env, detached: true })
        updateChild = child
        // Wall-clock deadline: a wedged pull / compose / health probe must
        // not leave `busy` true and the update state stuck forever. The kill
        // surfaces as a non-zero close, which resolves false through the
        // existing failure path (finally clears the progress state).
        const deadline = setTimeout(() => {
          log.write(`backend update exceeded ${UPDATE_DEADLINE_MS / 60_000} minutes — killing the installer\n`)
          killUpdateChild()
        }, UPDATE_DEADLINE_MS)
        // Parse the installer's --json NDJSON line-by-line (the same protocol
        // the onboarding driver consumes) so the update reports phases and
        // docker-pull percentages; every raw line still lands in install.log.
        readline.createInterface({ input: child.stdout }).on("line", (line) => {
          log.write(`${line}\n`)
          const progress = tracker.observeLine(line)
          if (progress) {
            report(progress)
          }
        })
        readline.createInterface({ input: child.stderr }).on("line", (line) => {
          log.write(`${line}\n`)
        })
        // Both exits clear the deadline + child registration — a spawn
        // error may never be followed by "close".
        const settle = (ok: boolean) => {
          clearTimeout(deadline)
          updateChild = null
          resolve(ok)
        }
        child.on("error", () => settle(false))
        // "close", not "exit": close fires only after stdio has drained, so
        // the final NDJSON lines are parsed and nothing writes after end().
        child.on("close", (code) => settle(code === 0))
      })

      // Superseded-image cleanup runs ONLY on the update path (first installs
      // go through the onboarding driver and have nothing to retire) and only
      // once the stack is re-confirmed healthy on the new pin — a stack left
      // stopped by a wedged update keeps all its images. Each auto-update
      // otherwise strands a multi-GB syrus-backend image on the Docker VM
      // disk until it fills. Best-effort by contract: cleanup can never fail
      // the update that triggered it.
      if (ok && (await backendHealthy())) {
        await removeSupersededSyrusImages({
          pinnedRef: image,
          log: (line) => log.write(`${line}\n`)
        })
      }

      return ok
    } finally {
      log.end()
    }
  } catch {
    return false
  } finally {
    // The notice must disappear on EVERY exit — success, failure, or throw.
    report(null)
    busy = false
  }
}

export const restartBackend = async (): Promise<boolean> => {
  const stopped = await stopBackend()
  if (!stopped) {
    return false
  }

  return startBackend()
}

// On app launch: quitting the app leaves the stack running by design, so
// most launches find a healthy backend and this is a single /up probe.
export const ensureRunning = async () => {
  if (getBackendMode() !== "local") {
    return
  }

  if (await backendHealthy()) {
    return
  }

  await startBackend()
}

type WatchdogDeps = {
  onHealthyChanged: (healthy: boolean, diagnosis: BackendDiagnosis | null) => void
}

let watchdogTimer: NodeJS.Timeout | null = null
let watchdogTickInFlight = false

// Reports transitions only; it never auto-restarts (a crash-looping stack
// would otherwise fight the user). Recovery actions live in the Backend
// menu, and the web window reloads itself once /up answers again.
export const startWatchdog = (deps: WatchdogDeps) => {
  if (watchdogTimer) {
    return
  }

  watchdogTimer = setInterval(() => {
    if (watchdogTickInFlight || busy || getBackendMode() !== "local") {
      return
    }

    watchdogTickInFlight = true
    void (async () => {
      try {
        const healthy = await backendHealthy()
        if (healthy === lastHealthy) {
          return
        }

        lastHealthy = healthy
        let diagnosis: BackendDiagnosis | null = null
        if (!healthy) {
          if (!(await daemonUp())) {
            diagnosis = "daemon-down"
          } else if (!(await volumeExists(currentStackIdentity().dataVolume))) {
            diagnosis = "data-gone"
          } else {
            diagnosis = "containers-down"
          }
        }

        deps.onHealthyChanged(healthy, diagnosis)
      } finally {
        watchdogTickInFlight = false
      }
    })()
  }, WATCHDOG_INTERVAL_MS)
}

export const stopWatchdog = () => {
  if (watchdogTimer) {
    clearInterval(watchdogTimer)
    watchdogTimer = null
  }
}
