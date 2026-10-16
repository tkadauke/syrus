import { execFile, spawn, type ChildProcess } from "node:child_process"
import { createWriteStream } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import readline from "node:readline"
import { promisify } from "node:util"
import { app, dialog, shell, type BrowserWindow } from "electron"
import { currentStackIdentity, localStateDir, saveBackendConfig, setOnboardingResumeLocal } from "../settings.js"
import {
  downloadDockerDesktopInstaller,
  runDockerDesktopInstaller,
  stopDockerDesktopInstaller,
  verifyDockerDesktopInstaller
} from "./dockerDesktopInstaller.js"
import { restampEnvPort } from "./envRestamp.js"
import { clearRunOnceResume, registerRunOnceResume } from "./windowsResume.js"
import { fingerprintSyrus } from "./fingerprint.js"
import { analyzeInstanceUrl } from "./instanceUrl.js"
import { installerCommand, installerScriptPath, readBackendManifest } from "./installPaths.js"
import { superviseInstallChild } from "./installChildLifecycle.js"
import { PullProgressAggregator, formatPullProgress, parsePullProgressLine } from "./pullProgress.js"
import {
  composeCommand,
  daemonUp,
  execEnv,
  findDockerBinary,
  installWsl as launchWslInstall,
  installedRuntimeApp,
  portInUse,
  startRuntimeApp,
  syrusHealthy,
  volumeExists,
  wslReady
} from "./dockerRuntime.js"

const execFileAsync = promisify(execFile)

export const ORBSTACK_DOWNLOAD_URL = "https://orbstack.dev/download"
export const DOCKER_DESKTOP_DOWNLOAD_URL = "https://www.docker.com/products/docker-desktop/"

// The per-platform runtime recommendation the guided setup points at:
// OrbStack on macOS, Docker Desktop on Windows (its installer owns the
// WSL 2 setup). RuntimeSetup.tsx renders the matching copy.
export const runtimeDownloadUrl = () =>
  process.platform === "win32" ? DOCKER_DESKTOP_DOWNLOAD_URL : ORBSTACK_DOWNLOAD_URL
// install.sh's own default when --port is omitted — NOT the channel's default
// port. The app passes --port only when its desired port differs from this, so
// a test install (channel default 3001) always forwards its port while a
// stable install (3000) can omit it.
const INSTALLER_BUILTIN_DEFAULT_PORT = 3000

// The channel's namespaced backend resources (project, data volume, default
// port). Recomputed per call — cheap, and always reflects the running build.
const dataVolumeName = () => currentStackIdentity().dataVolume
const searchVolumeName = () => currentStackIdentity().searchVolume
const composeProject = () => currentStackIdentity().project
const channelDefaultPort = () => currentStackIdentity().defaultPort
const RUNTIME_START_POLLS = 90 // × 2s = 180s, matches install.sh's own wait
const RUNTIME_DOWNLOAD_POLLS = 300 // × 2s = 10 minutes for a manual OrbStack install
// Docker Desktop's FIRST start blocks on user interaction (the service
// agreement dialog; an optional sign-in). After this many quiet polls we stop
// pretending it's just slow and tell the user to go click through it…
const RUNTIME_ATTENTION_POLLS = 15 // × 2s = 30s
// …and once we've asked the user to interact, the deadline extends: reading
// and accepting an agreement takes longer than a normal daemon boot, and
// timing out mid-dialog (the old 180s did) is a dead end.
const RUNTIME_FIRST_START_POLLS = 450 // × 2s = 15 minutes
const LOG_TAIL_LIMIT = 400
const TERMINATION_GRACE_MS = 5_000
const INSTALL_LOCK_FILENAME = "install.pid"

// The install steps install.sh emits in --json mode, in order.
// runtime_install never appears: the app always passes --skip-runtime-install
// and owns runtime acquisition through the guided OrbStack flow.
export const INSTALL_STEP_IDS = [
  "runtime_check",
  "runtime_start",
  "compose_resolve",
  "env_check",
  "env_generate",
  "image_pull",
  "stack_up",
  "health"
] as const

export type InstallStepId = (typeof INSTALL_STEP_IDS)[number]
export type InstallStepStatus = "pending" | "running" | "ok" | "skipped"
export type InstallStep = { id: InstallStepId; status: InstallStepStatus }

// Overall image-pull progress for the installing screen's determinate bar.
// `label` is preformatted here ("42% (312 MB / 745 MB)") so the renderer and
// the log pane can't drift — the renderer/main builds can't share a
// formatting module (see instanceUrl.ts's byte-identical-copies note).
export type PullProgress = { percent: number; label: string }

// A transient log line replaces the previous line when that line was also
// transient — the rolling pull-progress summary rewrites itself instead of
// appending hundreds of near-identical lines.
export type OnboardingLogLine = string | { line: string; transient: true }

export type OnboardingState =
  | { phase: "welcome" }
  | { phase: "connect.form"; error: string | null }
  | { phase: "connect.checking"; url: string }
  | { phase: "local.precheck" }
  | { phase: "local.adoptRunning"; url: string }
  | { phase: "local.adoptExisting"; error: string | null }
  | { phase: "local.runtimeMissing"; polling: boolean; wslMissing: boolean; installError: string | null }
  | { phase: "local.runtimeInstalling"; step: "downloading" | "installing"; percent: number | null }
  | { phase: "local.runtimeStarting"; needsAttention: boolean }
  | { phase: "local.portConflict"; port: number }
  | { phase: "local.installing"; steps: InstallStep[]; currentStep: InstallStepId | null; pullProgress: PullProgress | null }
  | { phase: "local.failed"; code: number; step: string | null; message: string; logTail: string[] }
  | { phase: "done"; mode: "local" | "remote"; url: string }

type InstallerEvent = {
  event: "start" | "step" | "log" | "error" | "done"
  id?: string
  status?: string
  stream?: string
  line?: string
  code?: number
  step?: string
  message?: string
  url?: string
}

type DriverDeps = {
  onState: (state: OnboardingState) => void
  onLogLine: (line: OnboardingLogLine) => void
}

const errorMessage = (error: unknown, fallback: string) =>
  error instanceof Error && error.message.trim() !== "" ? error.message : fallback

const normalizeUrl = (url: string) => url.trim().replace(/\/+$/, "")

const parsePortFromEnv = (contents: string) => {
  const match = contents.match(/^SYRUS_PORT=(\d+)$/m)
  if (!match) {
    return channelDefaultPort()
  }

  const port = Number.parseInt(match[1], 10)
  return Number.isFinite(port) && port > 0 ? port : channelDefaultPort()
}

const portFromUrl = (url: string): number | null => {
  try {
    const parsed = new URL(url)
    const port = Number.parseInt(parsed.port || (parsed.protocol === "https:" ? "443" : "80"), 10)
    return Number.isFinite(port) && port > 0 ? port : null
  } catch {
    return null
  }
}

// "Does this URL actually serve Syrus?" — a bare 200 from /up is not enough
// (every Rails 7.1+ app ships /up).
const isSyrusInstance = async (url: string) => {
  try {
    await fingerprintSyrus(url)
    return true
  } catch {
    return false
  }
}

export class OnboardingDriver {
  private state: OnboardingState = { phase: "welcome" }
  private child: ChildProcess | null = null
  private installLockPid: number | null = null
  private childCompletion: Promise<void> | null = null
  private installPromise: Promise<void> | null = null
  private cancelRequested = false
  private pollTimer: NodeJS.Timeout | null = null
  private pollResolve: ((ready: boolean) => void) | null = null
  private pollGeneration = 0
  private childKillTimer: NodeJS.Timeout | null = null
  private installAbort: AbortController | null = null
  private runtimeInstallerChild: ChildProcess | null = null
  private port = channelDefaultPort()
  private logTail: string[] = []
  private lastLogTransient = false
  private lastError: { code: number; step: string | null; message: string } | null = null
  private doneUrl: string | null = null
  private pullAggregator: PullProgressAggregator | null = null
  private lastPullLabel: string | null = null
  private lastPullPercent: number | null = null
  private lastPullEmitAt = 0

  constructor(private deps: DriverDeps) {}

  getState() {
    return this.state
  }

  installRunning() {
    return this.child !== null || this.installPromise !== null
  }

  private installLockPath() {
    return path.join(localStateDir(), INSTALL_LOCK_FILENAME)
  }

  private async processIsRunning(pid: number) {
    try {
      process.kill(pid, 0)
      return true
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "EPERM"
    }
  }

  private async acquireInstallLock() {
    const lockPath = this.installLockPath()

    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const lock = await fs.open(lockPath, "wx")
        await lock.writeFile(String(process.pid))
        await lock.close()
        this.installLockPid = process.pid
        return true
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
          throw error
        }

        const pid = Number.parseInt(await fs.readFile(lockPath, "utf8").catch(() => ""), 10)
        if (Number.isFinite(pid) && pid > 0 && (await this.processIsRunning(pid))) {
          return false
        }

        await fs.unlink(lockPath).catch(() => {})
      }
    }

    return false
  }

  private async updateInstallLock(pid: number) {
    await fs.writeFile(this.installLockPath(), String(pid))
    this.installLockPid = pid
  }

  private async releaseInstallLock(force = false) {
    const lockPath = this.installLockPath()
    const pid = Number.parseInt(await fs.readFile(lockPath, "utf8").catch(() => ""), 10)
    // A failed write may have truncated the file, so there may be no PID left
    // to compare. No competing installer can acquire the still-existing path;
    // the lifecycle supervisor may therefore force-release our acquired lock.
    if (force || pid === this.installLockPid) {
      await fs.unlink(lockPath).catch(() => {})
    }
    this.installLockPid = null
  }

  private setState(state: OnboardingState) {
    this.state = state
    this.deps.onState(state)

    // The reboot-resume save point ends when onboarding resolves: done (any
    // mode) or a deliberate return to Welcome. Cheap + idempotent, so keying
    // it off the state transition beats sprinkling clears on every exit path.
    if (state.phase === "done" || state.phase === "welcome") {
      this.clearRebootResume()
    }
  }

  // Set when we send the user off to install Docker Desktop / WSL — both can
  // force a Windows reboot that kills the wizard (the field failure: setup
  // never came back). The persisted flag makes the next launch jump straight
  // back into the local flow; RunOnce makes that launch happen at logon.
  private armRebootResume() {
    if (process.platform !== "win32") {
      return
    }

    setOnboardingResumeLocal(true)
    void registerRunOnceResume(currentStackIdentity().channel)
  }

  private clearRebootResume() {
    if (process.platform !== "win32") {
      return
    }

    setOnboardingResumeLocal(false)
    void clearRunOnceResume(currentStackIdentity().channel)
  }

  async backToWelcome() {
    this.stopPolling()
    const installAbort = this.installAbort
    const runtimeInstallerChild = this.runtimeInstallerChild
    if (installAbort && runtimeInstallerChild) {
      await stopDockerDesktopInstaller(runtimeInstallerChild, installAbort)
    } else {
      installAbort?.abort()
    }
    this.installAbort = null
    if (this.installPromise) {
      this.cancelRequested = true
    }
    if (this.child) {
      this.cancelRequested = true
      this.killInstallChild()
      return // handleExit finishes the transition once the child dies
    }

    this.setState({ phase: "welcome" })
  }

  chooseMode(mode: "local" | "remote") {
    this.stopPolling()
    if (mode === "remote") {
      this.setState({ phase: "connect.form", error: null })
      return
    }

    void this.precheck()
  }

  // Advisory connectivity probe for the connect form's live feedback: the
  // green check must mean "a Syrus answered here", not "the string parses".
  // Stateless on purpose — never touches wizard state, so a stale result
  // can't race navigation; the renderer discards out-of-date responses.
  async probeInstance(request: { url: string }): Promise<{ ok: boolean; url: string | null; message: string }> {
    const analysis = analyzeInstanceUrl(request.url)
    if (analysis.state === "empty" || analysis.state === "invalid" || analysis.normalized === null) {
      return { ok: false, url: null, message: analysis.hint }
    }

    const serverUrl = normalizeUrl(analysis.normalized)
    try {
      await fingerprintSyrus(serverUrl)
      return { ok: true, url: serverUrl, message: "" }
    } catch (error) {
      return { ok: false, url: serverUrl, message: errorMessage(error, "Could not connect to that address.") }
    }
  }

  // URL-only by design: sign-in happens in the app window afterwards, and
  // the tray token is minted from that session (tokenProvisioner). Bare
  // hosts/IPs are accepted — analyzeInstanceUrl assumes http:// and Syrus's
  // default :3000 the same way the form's live preview showed the user.
  async connectRemote(request: { url: string }) {
    const analysis = analyzeInstanceUrl(request.url)
    if (analysis.state === "empty") {
      this.setState({ phase: "connect.form", error: "Enter your Syrus instance address." })
      return
    }

    if (analysis.state === "invalid" || analysis.normalized === null) {
      this.setState({ phase: "connect.form", error: analysis.hint || "That doesn't look like a server address." })
      return
    }

    const serverUrl = normalizeUrl(analysis.normalized)
    this.setState({ phase: "connect.checking", url: serverUrl })

    // Back stays enabled while checking (deliberately — a black-holed host
    // must not be a dead end), so this probe can lose a race against the
    // user navigating away. Re-check the phase AND the url after the await,
    // like startRuntime/openOrbStackDownload do: a stale success must not
    // persist a backend choice the user abandoned, and a stale failure must
    // not yank the wizard out of wherever they went.
    const stillChecking = () => this.state.phase === "connect.checking" && this.state.url === serverUrl

    try {
      await fingerprintSyrus(serverUrl)
      if (!stillChecking()) {
        return
      }
      saveBackendConfig({ mode: "remote", serverUrl })
      this.setState({ phase: "done", mode: "remote", url: serverUrl })
    } catch (error) {
      if (!stillChecking()) {
        return
      }
      this.setState({ phase: "connect.form", error: errorMessage(error, "Could not connect to that address.") })
    }
  }

  // The decision tree for "Install Syrus on this Mac". Ordering matters:
  // Syrus-on-port needs no docker; the volume check needs the daemon up.
  async precheck() {
    this.stopPolling()
    this.setState({ phase: "local.precheck" })

    const stateDir = localStateDir()
    const envPath = path.join(stateDir, ".env")
    let hasEnv = false
    try {
      const contents = await fs.readFile(envPath, "utf8")
      hasEnv = true
      this.port = parsePortFromEnv(contents)
    } catch {
      this.port = channelDefaultPort()
    }

    // A healthy Syrus already answering that we don't own: offer to adopt it
    // as remote-at-localhost (no lifecycle control) instead of clobbering.
    // Fingerprinted — a foreign app's /up must not masquerade as Syrus.
    if (!hasEnv && (await syrusHealthy(this.port))) {
      const localUrl = `http://localhost:${this.port}`
      if (await isSyrusInstance(localUrl)) {
        this.setState({ phase: "local.adoptRunning", url: localUrl })
        return
      }
    }

    const binary = await findDockerBinary()
    if (!binary) {
      if (installedRuntimeApp()) {
        await this.startRuntime()
        return
      }

      await this.showRuntimeMissing(false)
      return
    }

    if (!(await daemonUp())) {
      await this.startRuntime()
      return
    }

    // The encryption-key guard, surfaced before install.sh would exit 20:
    // a data volume encrypted with keys from a .env we don't have.
    if (!hasEnv && (await volumeExists(dataVolumeName()))) {
      this.setState({ phase: "local.adoptExisting", error: null })
      return
    }

    // Port-conflict resolution is only meaningful for a fresh install: with
    // an existing .env the port is owned by that file (install.sh ignores
    // --port), and a busy-but-unhealthy port there is usually our own stack
    // still booting — let the install proceed; a genuine foreign bind
    // surfaces as compose exit 40.
    if (!hasEnv && !(await syrusHealthy(this.port)) && (await portInUse(this.port))) {
      this.setState({ phase: "local.portConflict", port: this.port })
      return
    }

    await this.startInstall()
  }

  private async startRuntime() {
    const runtimeApp = installedRuntimeApp()
    if (!runtimeApp) {
      await this.showRuntimeMissing(false)
      return
    }

    this.setState({ phase: "local.runtimeStarting", needsAttention: false })
    try {
      await startRuntimeApp(runtimeApp)
    } catch {
      // The poll below reports failure either way.
    }

    // Two-stage wait. A normal daemon boot answers within the first stage. A
    // FIRST Docker Desktop start blocks on user interaction (service
    // agreement, optional sign-in) — the field failure: Syrus said
    // "Starting…" forever while Docker Desktop sat waiting for a click. After
    // a quiet 30s, flip the screen to explicit go-interact-with-Docker
    // guidance and keep polling on a much longer deadline instead of dying
    // mid-dialog.
    let ready = await this.pollForDaemon(RUNTIME_ATTENTION_POLLS)
    if (this.state.phase !== "local.runtimeStarting") {
      return // user navigated away while we waited
    }

    if (!ready) {
      this.setState({ phase: "local.runtimeStarting", needsAttention: true })
      ready = await this.pollForDaemon(RUNTIME_FIRST_START_POLLS)
      if (this.state.phase !== "local.runtimeStarting") {
        return
      }
    }

    if (ready) {
      void this.precheck()
    } else {
      this.setState({
        phase: "local.failed",
        code: 11,
        step: "runtime_start",
        message: `${runtimeApp} is installed but its Docker daemon never became ready. Open ${runtimeApp}, finish its first-run setup (accept the service agreement; sign-in is optional and can be skipped), then retry.`,
        logTail: []
      })
    }
  }

  // "Open Docker Desktop" on the needs-attention screen: bring the runtime
  // app (back) up so the user can finish its first-run dialogs. The daemon
  // poll already running picks the flow up the moment the engine answers.
  async openRuntimeApp() {
    const runtimeApp = installedRuntimeApp()
    if (!runtimeApp) {
      return
    }

    try {
      await startRuntimeApp(runtimeApp)
    } catch {
      // Best-effort — the screen's guidance still stands.
    }
  }

  // Every path into the runtime-missing screen goes through here so the
  // WSL preflight rides along: on Windows the screen leads with a one-click
  // WSL 2 install when WSL itself is absent (Docker Desktop needs it, and
  // its own installer punts that to a manual PowerShell step).
  private async showRuntimeMissing(polling: boolean, installError: string | null = null) {
    this.setState({ phase: "local.runtimeMissing", polling, wslMissing: !(await wslReady()), installError })
  }

  // One-click Docker Desktop acquisition (Windows): download the official
  // installer and run it unattended with --accept-license --user --quiet —
  // no UAC (per-user install), no license dialog on first start, no manual
  // download. The field flow this replaces: browser download page → manual
  // installer → forced reboot → first-run agreement modal Syrus couldn't see.
  async installRuntime() {
    if (process.platform !== "win32" || this.state.phase !== "local.runtimeMissing") {
      return
    }

    // A Docker Desktop install can still end in a WSL-related reboot — make
    // sure setup comes back afterwards.
    this.armRebootResume()

    this.installAbort = new AbortController()
    this.setState({ phase: "local.runtimeInstalling", step: "downloading", percent: 0 })
    let installerDir: string
    try {
      installerDir = await fs.mkdtemp(path.join(app.getPath("temp"), "syrus-docker-desktop-"))
    } catch (error) {
      this.installAbort = null
      await this.showRuntimeMissing(false, errorMessage(error, "Could not create a temporary installer directory."))
      return
    }
    const installerPath = path.join(installerDir, "Docker Desktop Installer.exe")

    // setState mutates this.state across awaits, which TS's narrowing can't
    // see — same widening-closure pattern as connectRemote's stillChecking().
    const stillInstalling = (step?: "downloading" | "installing") => {
      const current = this.state as OnboardingState
      return current.phase === "local.runtimeInstalling" && (step === undefined || current.step === step)
    }

    try {
      await downloadDockerDesktopInstaller(
        installerPath,
        (percent) => {
          if (stillInstalling("downloading")) {
            this.setState({ phase: "local.runtimeInstalling", step: "downloading", percent })
          }
        },
        this.installAbort.signal
      )
      await verifyDockerDesktopInstaller(installerPath)
    } catch (error) {
      this.installAbort = null
      void fs.rm(installerDir, { recursive: true, force: true }).catch(() => {})
      if (!stillInstalling()) {
        return // user backed out; the abort landed here
      }
      await this.showRuntimeMissing(
        false,
        `${errorMessage(error, "The download failed.")} You can retry, or download Docker Desktop manually.`
      )
      return
    }

    if (!stillInstalling()) {
      this.installAbort = null
      void fs.rm(installerDir, { recursive: true, force: true }).catch(() => {})
      return
    }

    this.setState({ phase: "local.runtimeInstalling", step: "installing", percent: null })
    try {
      await runDockerDesktopInstaller(installerPath, this.installAbort.signal, (child) => {
        this.runtimeInstallerChild = child
      })
    } catch (error) {
      if (!stillInstalling()) {
        return
      }
      await this.showRuntimeMissing(
        false,
        `${errorMessage(error, "The installer did not finish.")} You can retry, or download Docker Desktop manually.`
      )
      return
    } finally {
      this.runtimeInstallerChild = null
      this.installAbort = null
      void fs.rm(installerDir, { recursive: true, force: true }).catch(() => {})
    }

    if (!stillInstalling()) {
      return
    }

    // License pre-accepted at install time, so the first engine start needs
    // no interaction — precheck finds the per-user install and startRuntime
    // brings the daemon up. (If Windows scheduled a WSL reboot, the resume
    // flag carries setup across it.)
    void this.precheck()
  }

  // One-click WSL 2 install (elevates via UAC), then watch for WSL to
  // appear so the screen's guidance advances on its own. Windows may still
  // require a restart — the copy says so, and precheck picks the flow back
  // up on relaunch.
  async installWsl() {
    if (process.platform !== "win32") {
      return
    }

    // WSL installs routinely end in a Windows restart — make sure setup
    // comes back afterwards instead of stranding the user at square one.
    this.armRebootResume()

    try {
      await launchWslInstall()
    } catch {
      // UAC declined or spawn failed: the screen simply keeps offering it.
    }

    for (let attempt = 0; attempt < 100; attempt += 1) {
      if (this.state.phase !== "local.runtimeMissing") {
        return
      }

      if (await wslReady()) {
        await this.showRuntimeMissing(this.state.polling)
        return
      }

      await new Promise((resolve) => setTimeout(resolve, 3_000))
    }
  }

  // Named for the IPC channel it serves; the URL is per-platform (OrbStack
  // on macOS, Docker Desktop on Windows).
  openOrbStackDownload() {
    // On Windows the user is now going to run Docker Desktop's installer,
    // which can force a reboot mid-setup — arm the resume save point first.
    this.armRebootResume()
    void shell.openExternal(runtimeDownloadUrl())
    if (this.state.phase === "local.runtimeMissing" && !this.state.polling) {
      const wslMissing = this.state.wslMissing
      this.setState({ phase: "local.runtimeMissing", polling: true, wslMissing, installError: null })
      void this.pollForDaemon(RUNTIME_DOWNLOAD_POLLS).then((ready) => {
        if (this.state.phase !== "local.runtimeMissing") {
          return
        }

        if (ready) {
          void this.precheck()
        } else {
          void this.showRuntimeMissing(false)
        }
      })
    }
  }

  private pollForDaemon(maxPolls: number): Promise<boolean> {
    this.stopPolling()
    const generation = this.pollGeneration

    return new Promise((resolve) => {
      this.pollResolve = resolve
      let polls = 0
      const finish = (ready: boolean) => {
        if (this.pollResolve !== resolve) return
        if (this.pollTimer) clearTimeout(this.pollTimer)
        this.pollTimer = null
        this.pollResolve = null
        resolve(ready)
      }
      const tick = async () => {
        if (this.pollResolve !== resolve) return
        if (generation !== this.pollGeneration) {
          finish(false)
          return
        }
        if ((await findDockerBinary()) && (await daemonUp())) {
          if (generation !== this.pollGeneration) {
            finish(false)
            return
          }
          finish(true)
          return
        }

        polls += 1
        if (polls >= maxPolls) {
          finish(false)
          return
        }

        if (generation === this.pollGeneration) {
          this.pollTimer = setTimeout(() => void tick(), 2_000)
        } else {
          resolve(false)
        }
      }

      void tick()
    })
  }

  private stopPolling() {
    this.pollGeneration += 1
    if (this.pollTimer) {
      clearTimeout(this.pollTimer)
      this.pollTimer = null
    }
    const resolve = this.pollResolve
    this.pollResolve = null
    resolve?.(false)
  }

  adoptRunning() {
    if (this.state.phase !== "local.adoptRunning") {
      return
    }

    const url = this.state.url
    saveBackendConfig({ mode: "remote", serverUrl: url })
    this.setState({ phase: "done", mode: "remote", url })
  }

  // Copy (never move) the user's original .env into the state dir so the
  // existing data volume stays decryptable, then re-run the checks.
  async locateEnv(parentWindow: BrowserWindow | null) {
    const options: Electron.OpenDialogOptions = {
      title: "Locate your original .env",
      message:
        currentStackIdentity().channel === "test"
          ? "Choose the .env file from your ORIGINAL Syrus Test install (~/.syrus/local-test). Do not use your production Syrus .env — its keys and port belong to the other stack."
          : "Choose the .env file from your existing Syrus install (usually next to your Syrus checkout).",
      properties: ["openFile", "showHiddenFiles"]
    }
    const result = parentWindow
      ? await dialog.showOpenDialog(parentWindow, options)
      : await dialog.showOpenDialog(options)

    if (result.canceled || result.filePaths.length === 0) {
      return
    }

    try {
      const stateDir = localStateDir()
      await fs.mkdir(stateDir, { recursive: true })
      const envTarget = path.join(stateDir, ".env")
      await fs.copyFile(result.filePaths[0], envTarget)
      // TEST channel ONLY: force the port to the test default. If the user
      // picked the production .env (port 3000), the test stack must still bind
      // 3001, and restampEnvPort APPENDS the line when the picked .env has none
      // (else compose falls back to ${SYRUS_PORT:-3000} = production's port).
      // The STABLE channel copies the .env verbatim — a deliberately non-default
      // production port must be preserved, so no re-stamp there.
      const identity = currentStackIdentity()
      if (identity.channel === "test") {
        const contents = await fs.readFile(envTarget, "utf8")
        const restamped = restampEnvPort(contents, identity.defaultPort)
        if (restamped !== contents) {
          await fs.writeFile(envTarget, restamped)
        }
      }
    } catch (error) {
      // Surface the copy failure on the screen instead of silently
      // re-prechecking into the same state with no explanation.
      this.setState({
        phase: "local.adoptExisting",
        error: errorMessage(error, "Couldn't copy that .env file.")
      })
      return
    }

    await this.precheck()
  }

  // The renderer gates this behind a typed confirmation; one final native
  // dialog stands between the click and `compose down -v`.
  async wipeData(parentWindow: BrowserWindow | null) {
    const options: Electron.MessageBoxOptions = {
      type: "warning",
      buttons: ["Delete all Syrus data", "Cancel"],
      defaultId: 1,
      cancelId: 1,
      message: "Delete the existing Syrus data?",
      detail: "This permanently deletes the Docker volumes holding the previous install's database, clone cache, and search index. There is no undo."
    }
    const confirmation = parentWindow
      ? await dialog.showMessageBox(parentWindow, options)
      : await dialog.showMessageBox(options)

    if (confirmation.response !== 0) {
      return
    }

    const compose = await composeCommand()
    if (compose) {
      try {
        const [command, ...prefixArgs] = compose
        await execFileAsync(command, [...prefixArgs, "-p", composeProject(), "down", "-v"], {
          env: execEnv(),
          timeout: 120_000
        })
      } catch {
        // Fall through: the volume may not have containers attached.
      }
    }

    const binary = await findDockerBinary()
    if (binary && (await volumeExists(dataVolumeName()))) {
      try {
        await execFileAsync(binary, ["volume", "rm", dataVolumeName(), searchVolumeName()], {
          env: execEnv(),
          timeout: 60_000
        })
      } catch {
        // precheck() reports the volume still existing.
      }
    }

    await this.precheck()
  }

  async startInstall(portOverride?: number) {
    if (this.child || this.installPromise) return
    this.cancelRequested = false
    const promise = this.performStartInstall(portOverride)
    this.installPromise = promise
    try {
      await promise
    } finally {
      if (this.installPromise === promise) this.installPromise = null
    }
  }

  private async performStartInstall(portOverride?: number) {
    const stateDir = localStateDir()
    await fs.mkdir(stateDir, { recursive: true })

    if (typeof portOverride === "number" && Number.isFinite(portOverride) && portOverride > 0) {
      this.port = Math.floor(portOverride)
    }

    const manifest = await readBackendManifest()
    if (this.cancelRequested) return
    const identity = currentStackIdentity()
    const flags = ["--docker", "--non-interactive", "--json", "--skip-runtime-install", "--target-dir", stateDir]
    // Isolate this channel's Compose project + volumes; a test stack also
    // seeds repository polling paused so it does not race production to file
    // Jobs (install.sh applies --pause-polling only when generating a fresh
    // .env, so re-installs are unaffected).
    flags.push("--project", identity.project)
    if (identity.channel === "test") {
      flags.push("--pause-polling")
    }
    if (manifest?.image) {
      flags.push("--image", manifest.image)
    }
    if (this.port !== INSTALLER_BUILTIN_DEFAULT_PORT) {
      flags.push("--port", String(this.port))
    }

    if (!(await this.acquireInstallLock())) {
      this.setState({
        phase: "local.failed",
        code: 1,
        step: null,
        message: "A Syrus installation is already running. Wait for it to finish, then try again.",
        logTail: []
      })
      return
    }

    const steps: InstallStep[] = INSTALL_STEP_IDS.map((id) => ({ id, status: "pending" }))
    this.logTail = []
    this.lastLogTransient = false
    this.lastError = null
    this.doneUrl = null
    this.pullAggregator = null
    this.lastPullLabel = null
    this.lastPullPercent = null
    this.lastPullEmitAt = 0
    this.setState({ phase: "local.installing", steps, currentStep: null, pullProgress: null })

    const logStream = createWriteStream(path.join(stateDir, "install.log"), { flags: "a" })
    logStream.on("error", (error) => {
      this.appendLog(`Unable to write install.log: ${errorMessage(error, "Unknown error")}`)
    })
    logStream.write(`\n--- install started ${new Date().toISOString()} ---\n`)

    // POSIX: detached puts the script's docker/compose grandchildren in one
    // process group, so cancel can signal the whole group instead of
    // orphaning an in-flight multi-GB pull. Windows has no process groups —
    // cancel uses taskkill /T there instead (killInstallChild), and detached
    // would pop a new console. The spec knobs are scrubbed so a stray value
    // in the user's environment can't silently gate a real install.
    const env = execEnv()
    delete env.SYRUS_HEALTH_POLLS
    delete env.SYRUS_PULL_RETRY_DELAY
    const { command, args: spawnArgs } = installerCommand(installerScriptPath(), flags)
    const child =
      process.platform === "win32"
        ? spawn(command, spawnArgs, { env, windowsHide: true })
        : spawn(command, spawnArgs, { env, detached: true })
    this.child = child

    this.childCompletion = superviseInstallChild({
      child,
      updateLock: (pid) => this.updateInstallLock(pid),
      releaseLock: (force) => this.releaseInstallLock(force),
      terminate: () => this.killInstallChild(),
      onError: (error) => logStream.write(`installer process error: ${String(error)}\n`),
      onSettled: (code) => {
        if (this.child === child) this.child = null
        if (this.childKillTimer) {
          clearTimeout(this.childKillTimer)
          this.childKillTimer = null
        }
        logStream.end()
        this.handleExit(code)
      }
    })

    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      logStream.write(`${line}\n`)
      this.handleInstallerEvent(line)
    })

    readline.createInterface({ input: child.stderr }).on("line", (line) => {
      logStream.write(`${line}\n`)
      this.appendLog(line)
    })

  }

  // Kill the whole tree so docker/compose grandchildren die with the script
  // instead of racing a retried install: POSIX signals the detached process
  // group; Windows (no process groups) walks the tree with taskkill /T.
  private killInstallChild() {
    if (!this.child?.pid) {
      return
    }

    if (process.platform === "win32") {
      execFile("taskkill", ["/pid", String(this.child.pid), "/T", "/F"], { windowsHide: true }, () => {})
      return
    }

    try {
      process.kill(-this.child.pid, "SIGTERM")
    } catch {
      this.child.kill("SIGTERM")
    }

    const child = this.child
    if (!this.childKillTimer) {
      this.childKillTimer = setTimeout(() => {
        this.childKillTimer = null
        if (this.child !== child || !child.pid) return
        try {
          process.kill(-child.pid, "SIGKILL")
        } catch {
          child.kill("SIGKILL")
        }
      }, TERMINATION_GRACE_MS)
    }
  }

  cancelInstall(): Promise<void> {
    if (!this.child && !this.installPromise) {
      return this.childCompletion ?? Promise.resolve()
    }

    this.cancelRequested = true
    if (this.installPromise && !this.child) {
      this.setState({ phase: "welcome" })
      return this.installPromise
    }
    this.killInstallChild()
    return this.childCompletion ?? this.installPromise ?? Promise.resolve()
  }

  // Forget all wizard progress so a reopened onboarding starts at Welcome —
  // used by "Run Setup Again…", which clears the backend config.
  reset() {
    this.stopPolling()
    if (this.child) {
      this.cancelRequested = true
      this.killInstallChild()
    }

    this.logTail = []
    this.lastError = null
    this.doneUrl = null
    this.setState({ phase: "welcome" })
  }

  // Transient lines are rolling status updates (the pull-progress summary):
  // consecutive transient lines overwrite each other in the visible tail and
  // in the renderer, so the log stays readable. The install.log FILE is
  // written upstream from here and keeps every raw line.
  private appendLog(line: string, options: { transient?: boolean } = {}) {
    const transient = options.transient === true
    if (transient && this.lastLogTransient && this.logTail.length > 0) {
      this.logTail[this.logTail.length - 1] = line
    } else {
      this.logTail.push(line)
      if (this.logTail.length > LOG_TAIL_LIMIT) {
        this.logTail.shift()
      }
    }

    this.lastLogTransient = transient
    this.deps.onLogLine(transient ? { line, transient: true } : line)
  }

  private pullStepRunning() {
    return (
      this.state.phase === "local.installing" &&
      this.state.steps.some((step) => step.id === "image_pull" && step.status === "running")
    )
  }

  // `docker compose --progress=json pull` emits one NDJSON object per layer
  // update — hundreds of lines that would drown the visible log. While the
  // image_pull step runs, fold them into the aggregate instead and surface a
  // single rolling summary + the determinate progress bar. Returns false for
  // anything that isn't a pull-progress object (older compose prints plain
  // text) so the caller logs it normally — that's the no-progress-bar
  // degradation path.
  private handlePullProgressLine(rawLine: string): boolean {
    if (!this.pullStepRunning()) {
      return false
    }

    const event = parsePullProgressLine(rawLine)
    if (!event) {
      return false
    }

    this.pullAggregator ??= new PullProgressAggregator()
    this.pullAggregator.observe(event)
    const snapshot = this.pullAggregator.snapshot()
    const label = formatPullProgress(snapshot)
    if (label === null || label === this.lastPullLabel) {
      return true // consumed, but nothing new to show
    }

    // Byte counts tick many times a second on fast connections; re-render on
    // every percent change but rate-limit label-only (MB counter) updates.
    const now = Date.now()
    if (snapshot.percent === this.lastPullPercent && now - this.lastPullEmitAt < 500) {
      return true
    }

    this.lastPullLabel = label
    this.lastPullPercent = snapshot.percent
    this.lastPullEmitAt = now
    this.appendLog(`Downloading Syrus image — ${label}`, { transient: true })
    if (this.state.phase === "local.installing" && snapshot.percent !== null) {
      this.setState({ ...this.state, pullProgress: { percent: snapshot.percent, label } })
    }

    return true
  }

  private handleInstallerEvent(line: string) {
    let event: InstallerEvent
    try {
      event = JSON.parse(line) as InstallerEvent
    } catch {
      this.appendLog(line)
      return
    }

    if (typeof event !== "object" || event === null) {
      this.appendLog(line)
      return
    }

    if (event.event === "log" && typeof event.line === "string") {
      if (this.handlePullProgressLine(event.line)) {
        return
      }

      this.appendLog(event.line)
      return
    }

    if (event.event === "error") {
      this.lastError = {
        code: typeof event.code === "number" ? event.code : 1,
        step: typeof event.step === "string" && event.step !== "" ? event.step : null,
        message: typeof event.message === "string" ? event.message : "Install failed."
      }
      return
    }

    if (event.event === "done" && typeof event.url === "string") {
      this.doneUrl = event.url
      return
    }

    if (
      event.event === "step" &&
      this.state.phase === "local.installing" &&
      typeof event.id === "string" &&
      (INSTALL_STEP_IDS as readonly string[]).includes(event.id)
    ) {
      const steps = this.state.steps.map((step): InstallStep => {
        if (step.id !== event.id) {
          return step
        }

        if (event.status === "start") {
          return { ...step, status: "running" }
        }

        if (event.status === "ok" || event.status === "skipped") {
          return { ...step, status: event.status }
        }

        return step
      })
      const currentStep = event.status === "start" ? (event.id as InstallStepId) : this.state.currentStep
      // The bar belongs to the pull; clear it the moment image_pull ends so a
      // later screen can't show a stale percent.
      const pullEnded = event.id === "image_pull" && event.status !== "start"
      const pullProgress = pullEnded ? null : this.state.pullProgress
      this.setState({ phase: "local.installing", steps, currentStep, pullProgress })
      return
    }

    // Parsed as JSON but not an install.sh event: if install.sh ever streams
    // compose's --progress=json objects through unwrapped, fold them into the
    // pull progress the same way (otherwise they stay invisible, as before).
    this.handlePullProgressLine(line)
  }

  private handleExit(code: number) {
    if (this.cancelRequested) {
      this.cancelRequested = false
      this.setState({ phase: "welcome" })
      return
    }

    if (code === 0) {
      const stateDir = localStateDir()
      const url = this.doneUrl ?? `http://localhost:${this.port}`
      // The done URL carries the port .env actually owns (install.sh ignores
      // --port when .env pre-exists); deriving localInstall.port from it
      // keeps the lifecycle watchdog probing the port the stack serves.
      const port = portFromUrl(url) ?? this.port
      saveBackendConfig({
        mode: "local",
        serverUrl: url,
        localInstall: { stateDir, port }
      })
      this.setState({ phase: "done", mode: "local", url })
      return
    }

    if (code === 10) {
      void this.showRuntimeMissing(false)
      return
    }

    // Exit 11 means a runtime exists but its daemon never became ready —
    // the download-OrbStack screen would be misleading here.
    if (code === 11) {
      this.setState({
        phase: "local.failed",
        code,
        step: "runtime_start",
        message:
          "Your Docker runtime is installed but its daemon never became ready. Open it, finish any setup prompt, then retry.",
        logTail: [...this.logTail].slice(-40)
      })
      return
    }

    if (code === 20) {
      this.setState({ phase: "local.adoptExisting", error: null })
      return
    }

    this.setState({
      phase: "local.failed",
      code,
      step: this.lastError?.step ?? null,
      message: this.lastError?.message ?? "The installer failed. Open the log for details.",
      logTail: [...this.logTail].slice(-40)
    })
  }
}
