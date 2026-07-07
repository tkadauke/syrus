import { execFile, spawn, type ChildProcess } from "node:child_process"
import { createWriteStream } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import readline from "node:readline"
import { promisify } from "node:util"
import { app, dialog, shell, type BrowserWindow } from "electron"
import { localStateDir, saveBackendConfig, setOnboardingResumeLocal } from "../settings.js"
import { downloadDockerDesktopInstaller, runDockerDesktopInstaller } from "./dockerDesktopInstaller.js"
import { clearRunOnceResume, registerRunOnceResume } from "./windowsResume.js"
import { fingerprintSyrus } from "./fingerprint.js"
import { analyzeInstanceUrl } from "./instanceUrl.js"
import { installerCommand, installerScriptPath, readBackendManifest } from "./installPaths.js"
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
export const DATA_VOLUME_NAME = "syrus_syrus-data"
const DEFAULT_PORT = 3000
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
  | { phase: "local.installing"; steps: InstallStep[]; currentStep: InstallStepId | null }
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
  onLogLine: (line: string) => void
}

const errorMessage = (error: unknown, fallback: string) =>
  error instanceof Error && error.message.trim() !== "" ? error.message : fallback

const normalizeUrl = (url: string) => url.trim().replace(/\/+$/, "")

const parsePortFromEnv = (contents: string) => {
  const match = contents.match(/^SYRUS_PORT=(\d+)$/m)
  if (!match) {
    return DEFAULT_PORT
  }

  const port = Number.parseInt(match[1], 10)
  return Number.isFinite(port) && port > 0 ? port : DEFAULT_PORT
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
  private cancelRequested = false
  private pollTimer: NodeJS.Timeout | null = null
  private installAbort: AbortController | null = null
  private port = DEFAULT_PORT
  private logTail: string[] = []
  private lastError: { code: number; step: string | null; message: string } | null = null
  private doneUrl: string | null = null

  constructor(private deps: DriverDeps) {}

  getState() {
    return this.state
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
    void registerRunOnceResume()
  }

  private clearRebootResume() {
    if (process.platform !== "win32") {
      return
    }

    setOnboardingResumeLocal(false)
    void clearRunOnceResume()
  }

  backToWelcome() {
    this.stopPolling()
    this.installAbort?.abort()
    this.installAbort = null
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
      this.port = DEFAULT_PORT
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
    if (!hasEnv && (await volumeExists(DATA_VOLUME_NAME))) {
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
    const installerPath = path.join(app.getPath("temp"), "syrus-docker-desktop-installer.exe")

    // setState mutates this.state across awaits, which TS's narrowing can't
    // see — same widening-closure pattern as connectRemote's stillChecking().
    const stillInstalling = (step?: "downloading" | "installing") => {
      const current = this.state as OnboardingState
      return current.phase === "local.runtimeInstalling" && (step === undefined || current.step === step)
    }

    this.setState({ phase: "local.runtimeInstalling", step: "downloading", percent: 0 })
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
    } catch (error) {
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
      return
    }

    this.setState({ phase: "local.runtimeInstalling", step: "installing", percent: null })
    try {
      await runDockerDesktopInstaller(installerPath)
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
      void fs.rm(installerPath, { force: true }).catch(() => {})
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

    return new Promise((resolve) => {
      let polls = 0
      const tick = async () => {
        if ((await findDockerBinary()) && (await daemonUp())) {
          this.stopPolling()
          resolve(true)
          return
        }

        polls += 1
        if (polls >= maxPolls) {
          this.stopPolling()
          resolve(false)
          return
        }

        this.pollTimer = setTimeout(() => void tick(), 2_000)
      }

      void tick()
    })
  }

  private stopPolling() {
    if (this.pollTimer) {
      clearTimeout(this.pollTimer)
      this.pollTimer = null
    }
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
      message: "Choose the .env file from your existing Syrus install (usually next to your Syrus checkout).",
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
      await fs.copyFile(result.filePaths[0], path.join(stateDir, ".env"))
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
        await execFileAsync(command, [...prefixArgs, "-p", "syrus", "down", "-v"], {
          env: execEnv(),
          timeout: 120_000
        })
      } catch {
        // Fall through: the volume may not have containers attached.
      }
    }

    const binary = await findDockerBinary()
    if (binary && (await volumeExists(DATA_VOLUME_NAME))) {
      try {
        await execFileAsync(binary, ["volume", "rm", DATA_VOLUME_NAME, "syrus_syrus-search"], {
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
    if (this.child) {
      return
    }

    const stateDir = localStateDir()
    await fs.mkdir(stateDir, { recursive: true })

    if (typeof portOverride === "number" && Number.isFinite(portOverride) && portOverride > 0) {
      this.port = Math.floor(portOverride)
    }

    const manifest = await readBackendManifest()
    const flags = ["--docker", "--non-interactive", "--json", "--skip-runtime-install", "--target-dir", stateDir]
    if (manifest?.image) {
      flags.push("--image", manifest.image)
    }
    if (this.port !== DEFAULT_PORT) {
      flags.push("--port", String(this.port))
    }

    const steps: InstallStep[] = INSTALL_STEP_IDS.map((id) => ({ id, status: "pending" }))
    this.logTail = []
    this.lastError = null
    this.doneUrl = null
    this.cancelRequested = false
    this.setState({ phase: "local.installing", steps, currentStep: null })

    const logStream = createWriteStream(path.join(stateDir, "install.log"), { flags: "a" })
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

    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      logStream.write(`${line}\n`)
      this.handleInstallerEvent(line)
    })

    readline.createInterface({ input: child.stderr }).on("line", (line) => {
      logStream.write(`${line}\n`)
      this.appendLog(line)
    })

    child.on("error", (error) => {
      logStream.write(`spawn error: ${String(error)}\n`)
    })

    // "close", not "exit": close fires only after stdio has drained, so the
    // final NDJSON error/done lines are guaranteed to have been parsed and
    // nothing writes to the log stream after end().
    child.on("close", (code) => {
      this.child = null
      logStream.end()
      this.handleExit(code ?? 1)
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
  }

  cancelInstall() {
    if (!this.child) {
      return
    }

    this.cancelRequested = true
    this.killInstallChild()
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

  private appendLog(line: string) {
    this.logTail.push(line)
    if (this.logTail.length > LOG_TAIL_LIMIT) {
      this.logTail.shift()
    }

    this.deps.onLogLine(line)
  }

  private handleInstallerEvent(line: string) {
    let event: InstallerEvent
    try {
      event = JSON.parse(line) as InstallerEvent
    } catch {
      this.appendLog(line)
      return
    }

    if (event.event === "log" && typeof event.line === "string") {
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
      this.setState({ phase: "local.installing", steps, currentStep })
    }
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
