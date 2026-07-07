import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import Store from "electron-store"

export const DEFAULT_GLOBAL_HOTKEY = "CommandOrControl+Shift+S"

// "" means onboarding has not completed yet; "local" is a Docker stack this
// app installed and manages; "remote" is an existing Syrus instance we only
// connect to.
export type BackendMode = "local" | "remote" | ""

export type LocalInstall = {
  stateDir: string
  port: number
}

export type WindowBounds = {
  x: number
  y: number
  width: number
  height: number
}

export type DesktopSettings = {
  localProjectsRoot: string
  localRepoPaths: Record<string, string>
  lastUsedRepo: string
}

export type DesktopSettingsInput = Pick<DesktopSettings, "localProjectsRoot" | "localRepoPaths">

export type DesktopStore = DesktopSettings & {
  globalHotkey: string
  backendMode: BackendMode
  serverUrl: string
  localInstall: LocalInstall | null
  webAppWindowBounds: WindowBounds | null
  onboardingCompletedAt: string
  backendConfigMigratedAt: string
  // Legacy: the retired post-setup "Install the Syrus CLI?" dialog was
  // shown. Kept (and still honored) so upgraded installs that answered it
  // aren't re-asked about the skill.
  cliInstallOffered: boolean
  // The one-time "coding agent detected — add the Syrus skill?" dialog was
  // shown (or the skill was already present). Asked-and-answered — never
  // re-prompt. The CLI itself is no longer offered: it installs silently
  // at launch (docs/install-experience-spec.md I1).
  skillInstallOffered: boolean
  // Mid-onboarding save point: the user was in the LOCAL install flow and got
  // sent off to install Docker Desktop / WSL — either can force a Windows
  // reboot that kills the wizard. On the next launch (RunOnce relaunches us
  // after logon; see installer/windowsResume.ts) an unfinished onboarding
  // with this flag set jumps straight back into the local flow instead of
  // restarting from Welcome. Cleared when onboarding completes or the user
  // backs out. The persisted flag — not the RunOnce argv — is the source of
  // truth, so a manual app relaunch resumes too.
  onboardingResumeLocal: boolean
}

export const store = new Store<DesktopStore>({
  defaults: {
    localProjectsRoot: "",
    localRepoPaths: {},
    lastUsedRepo: "",
    globalHotkey: DEFAULT_GLOBAL_HOTKEY,
    backendMode: "",
    serverUrl: "",
    localInstall: null,
    webAppWindowBounds: null,
    onboardingCompletedAt: "",
    backendConfigMigratedAt: "",
    cliInstallOffered: false,
    skillInstallOffered: false,
    onboardingResumeLocal: false
  }
})

export const getOnboardingResumeLocal = () => store.get("onboardingResumeLocal", false)

export const setOnboardingResumeLocal = (value: boolean) => {
  store.set("onboardingResumeLocal", value)
}

// Mutable state of a local install (.env, synced docker-compose.yml,
// install.log). Lives next to ~/.syrus/credentials on EVERY platform —
// including Windows (%USERPROFILE%\.syrus\local), a deliberate decision
// over %LocalAppData%: it keeps the shared Syrus home in one place, keeps
// migrateBackendConfig's adopt-a-CLI-install semantics identical, and users
// can still drive it manually with `docker compose` from that directory.
// Paths are quoted everywhere they reach a shell, so spaces in profile
// names (C:\Users\First Last) are fine.
export const localStateDir = () => path.join(os.homedir(), ".syrus", "local")

export const getBackendMode = (): BackendMode => store.get("backendMode", "")

export const getServerUrl = () => store.get("serverUrl", "").trim()

export const getLocalInstall = (): LocalInstall | null => store.get("localInstall", null)

export type BackendConfig =
  | { mode: "remote"; serverUrl: string }
  | { mode: "local"; serverUrl: string; localInstall: LocalInstall }

export const saveBackendConfig = (config: BackendConfig) => {
  store.set("backendMode", config.mode)
  store.set("serverUrl", config.serverUrl.trim().replace(/\/+$/, ""))
  store.set("localInstall", config.mode === "local" ? config.localInstall : null)
  store.set("onboardingCompletedAt", new Date().toISOString())
}

export const clearBackendConfig = () => {
  store.set("backendMode", "")
  store.set("serverUrl", "")
  store.set("localInstall", null)
  store.set("onboardingCompletedAt", "")
}

const parsePortFromEnvFile = (contents: string) => {
  const match = contents.match(/^SYRUS_PORT=(\d+)$/m)
  if (!match) {
    return 3000
  }

  const port = Number.parseInt(match[1], 10)
  return Number.isFinite(port) && port > 0 ? port : 3000
}

// Zero-prompt adoption for users who already ran Syrus before this app knew
// about backend modes: existing tray credentials mean a reachable instance
// (remote mode), an existing ~/.syrus/local install means we manage it
// (local mode), anything else stays "" so onboarding opens.
export const migrateBackendConfig = async (credentialsUrl: string | null) => {
  if (getBackendMode() !== "") {
    return getBackendMode()
  }

  // Runs at most once per install: afterwards an empty backendMode is a
  // deliberate state (e.g. "Run Setup Again…") and must reopen onboarding,
  // not silently re-adopt the surviving credentials file.
  if (store.get("backendConfigMigratedAt", "") !== "") {
    return "" as const
  }
  store.set("backendConfigMigratedAt", new Date().toISOString())

  if (credentialsUrl && credentialsUrl.trim() !== "") {
    saveBackendConfig({ mode: "remote", serverUrl: credentialsUrl })
    return "remote" as const
  }

  const stateDir = localStateDir()
  try {
    const envContents = await fs.readFile(path.join(stateDir, ".env"), "utf8")
    const port = parsePortFromEnvFile(envContents)
    saveBackendConfig({
      mode: "local",
      serverUrl: `http://localhost:${port}`,
      localInstall: { stateDir, port }
    })
    return "local" as const
  } catch {
    return "" as const
  }
}
