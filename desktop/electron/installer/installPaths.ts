import fs from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { app } from "electron"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

// Packaged builds bundle install.sh/.ps1 + uninstall.sh/.ps1 +
// docker-compose.yml + compose.env.example
// (+ manifest.json) under <Resources>/backend via electron-builder
// extraResources; everything there is sealed by the code signature and must
// never be written to. In dev the repo root plays that role:
// desktop/dist-electron/installer/ -> ../../.. = the repo checkout.
export const installerAssetsDir = () => {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "backend")
  }

  return path.resolve(__dirname, "../../..")
}

// The installer script and its interpreter, per platform. install.ps1
// implements the identical --docker machine interface (NDJSON events, step
// ids, exit codes) — spec/desktop/install_parity_spec.rb keeps the two
// scripts' contract strings in lockstep.
export const installerScriptPath = () =>
  path.join(installerAssetsDir(), process.platform === "win32" ? "install.ps1" : "install.sh")

export const installerCommand = (scriptPath: string, flags: string[]): { command: string; args: string[] } =>
  process.platform === "win32"
    ? {
        command: "powershell.exe",
        // -File (not -Command) so the script's exit code propagates.
        args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, ...flags]
      }
    : { command: "/bin/bash", args: [scriptPath, ...flags] }

// The uninstaller script, per platform — staged next to the installer by
// desktop/scripts/stage-backend-assets.mjs. uninstall.ps1 mirrors
// uninstall.sh's flag surface (--yes / --keep-data / --json); the app's
// "Uninstall Syrus…" flow (main.ts) spawns this detached and quits.
export const uninstallScriptPath = () =>
  path.join(installerAssetsDir(), process.platform === "win32" ? "uninstall.ps1" : "uninstall.sh")

// Written by desktop/scripts/stage-backend-assets.mjs at build time: pins the
// backend image tag to this app release. Absent in dev — install.sh then
// falls back to ghcr.io/tkadauke/syrus-backend:latest.
export type BackendManifest = {
  image?: string
  // The app's own build sha (git short sha at packaging time), announced as
  // a User-Agent token so the web UI's BuildBadge can show it.
  appBuild?: string
  // The app's release version (package.json version at packaging time).
  // "0.0.0" for dev builds; the real tag for release builds
  // (SYRUS_RELEASE_BUILD=1 stamps it). Release builds announce THIS in the
  // UA token instead of appBuild so the BuildBadge reads "app 0.1.2".
  appVersion?: string
  // When this app build was staged (UTC ISO-8601). Announced via the
  // SyrusDesktopBuiltAt UA token so the BuildBadge tooltip can show the
  // app's build time next to the backend's.
  builtAt?: string
}

export const readBackendManifest = async (): Promise<BackendManifest | null> => {
  try {
    const contents = await fs.readFile(path.join(installerAssetsDir(), "manifest.json"), "utf8")
    const parsed = JSON.parse(contents) as BackendManifest
    return typeof parsed.image === "string" && parsed.image.trim() !== "" ? parsed : null
  } catch {
    return null
  }
}
