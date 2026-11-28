import { execFile } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"
import { app, autoUpdater as nativeAutoUpdater, dialog } from "electron"
import electronUpdater from "electron-updater"
import { resolveChannel } from "./channel.js"
import { t } from "./i18n.js"
import { isPinnedTestBuild } from "./pinnedTestBuild.js"
import { installedBundleVersion } from "./selfInstall.js"
import { shouldRecoverStrandedUpdate, type ShipItState } from "./strandedUpdate.js"

const { autoUpdater } = electronUpdater

const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1_000
const execFileAsync = promisify(execFile)
const UPDATE_LOG_BASENAME = "auto-update.log"

// Auto-update rides the GitHub Releases feed baked in by electron-builder's
// publish config (latest-mac.yml + zip). macOS updates only install into a
// signed app — Squirrel.Mac validates the signature — so everything here is
// inert for unsigned dev builds (!app.isPackaged) and can be switched off
// with SYRUS_DISABLE_AUTO_UPDATE (CI, tests).

// Only the STABLE channel auto-updates. Gating on the channel (not just the
// -test.N version shape) also covers a packaged local dev build (version
// 0.0.0 — the test channel per resolveChannel), which would otherwise arm the
// updater against the baked-in stable feed and download the next published
// release OVER the dev/test install (semver orders 0.0.0 and X.Y.Z-test.N
// below every release). isPinnedTestBuild stays as a belt-and-braces signal.
const isStableChannel = () =>
  resolveChannel({ env: process.env.SYRUS_CHANNEL, productName: app.getName(), version: app.getVersion() }) === "stable"

const updatesEnabled = () =>
  app.isPackaged &&
  !process.env.SYRUS_DISABLE_AUTO_UPDATE &&
  isStableChannel() &&
  !isPinnedTestBuild(app.getVersion())

let downloadedVersion: string | null = null
let checkTimer: NodeJS.Timeout | null = null

const appendUpdateLog = (event: string, detail = "") => {
  try {
    const suffix = detail === "" ? "" : ` ${detail.replace(/\s+/g, " ").trim()}`
    fs.appendFileSync(path.join(app.getPath("userData"), UPDATE_LOG_BASENAME), `${new Date().toISOString()} ${event}${suffix}\n`)
  } catch {
    // Update logging must never stop the updater itself.
  }
}

const readPlistValue = async (plist: string, key: string): Promise<string | null> => {
  try {
    const { stdout } = await execFileAsync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, plist])
    return stdout.trim() || null
  } catch {
    return null
  }
}

const bundlePathFromURL = (value: string): string => {
  try {
    return value.startsWith("file:") ? fileURLToPath(value) : value
  } catch {
    return value
  }
}

const recoverStrandedMacUpdate = async (deps: UpdateDeps) => {
  if (process.platform !== "darwin" || !app.isPackaged) {
    return false
  }

  const runningInfoPlist = path.resolve(path.dirname(process.execPath), "..", "Info.plist")
  const bundleId = await readPlistValue(runningInfoPlist, "CFBundleIdentifier")
  const uid = process.getuid?.()
  if (!bundleId || uid === undefined) {
    return false
  }

  const statePlist = path.join(os.homedir(), "Library", "Caches", `${bundleId}.ShipIt`, "ShipItState.plist")
  const updateBundleURL = await readPlistValue(statePlist, "updateBundleURL")
  const state: ShipItState | null = updateBundleURL ? { updateBundleURL } : null
  const stagedVersion = state ? await installedBundleVersion(bundlePathFromURL(state.updateBundleURL)) : null
  if (!shouldRecoverStrandedUpdate({ state, stagedVersion, runningVersion: app.getVersion() })) {
    return false
  }

  appendUpdateLog("stranded-install-detected", `version=${stagedVersion}`)
  await dialog.showMessageBox({
    type: "info",
    message: t("updates.recovering", { version: stagedVersion }),
    detail: t("updates.recovering_detail")
  })

  try {
    // ShipIt waits for this process to terminate. Arm it first so launchd is
    // already committed to the swap before the app exits.
    await execFileAsync("/bin/launchctl", ["kickstart", "-k", `gui/${uid}/${bundleId}.ShipIt`])
    appendUpdateLog("install-armed", `recovery version=${stagedVersion}`)
    deps.onBeforeQuitForUpdate()
    app.quit()
    return true
  } catch (error) {
    appendUpdateLog("recovery-failed", error instanceof Error ? error.message : String(error))
    await dialog.showMessageBox({
      type: "error",
      message: t("updates.recovery_failed"),
      detail: t("updates.recovery_failed_detail")
    })
    return false
  }
}

const checkForUpdates = () => {
  appendUpdateLog("check")
  return autoUpdater.checkForUpdates()
}

type UpdateDeps = {
  // main.ts re-renders the app menu and tray menu with a
  // "Restart to update Syrus (vX)" item.
  onUpdateDownloaded: (version: string) => void
  // main.ts sets its isQuitting flag: quitAndInstall closes all windows
  // before any quit event fires, so the tray's hide-on-close handler would
  // otherwise preventDefault and silently abort the install.
  onBeforeQuitForUpdate: () => void
}

export const initAutoUpdates = (deps: UpdateDeps) => {
  if (!updatesEnabled() || checkTimer) {
    return
  }

  autoUpdater.autoDownload = true

  autoUpdater.on("update-available", (info) => {
    appendUpdateLog("download", `version=${info.version}`)
  })

  autoUpdater.on("update-downloaded", (info) => {
    appendUpdateLog("downloaded", `version=${info.version}`)
    downloadedVersion = info.version
    deps.onUpdateDownloaded(info.version)
  })

  // Fired by Squirrel.Mac for any install path, including electron-updater's
  // autoInstallOnAppQuit — belt-and-braces beyond our own menu item.
  nativeAutoUpdater.on("before-quit-for-update", deps.onBeforeQuitForUpdate)

  // File-only: a tray app that dialogs about failed update checks would spam
  // every offline user, while stdout is invisible for Finder launches.
  autoUpdater.on("error", (error) => {
    appendUpdateLog("error", error instanceof Error ? error.message : String(error))
  })

  void recoverStrandedMacUpdate(deps).then((recovering) => recovering ? undefined : checkForUpdates()).catch(() => {})
  checkTimer = setInterval(() => {
    void checkForUpdates().catch(() => {})
  }, CHECK_INTERVAL_MS)
}

export const downloadedUpdateVersion = () => downloadedVersion

// Callers MUST set the tray lifecycle's isQuitting flag first:
// quitAndInstall closes all windows before any quit event fires, so the
// hide-on-close handler would otherwise preventDefault and abort the install.
export const quitAndInstallUpdate = () => {
  appendUpdateLog("install-armed", downloadedVersion ? `version=${downloadedVersion}` : "")
  autoUpdater.quitAndInstall()
}

export type InteractiveCheckResult =
  | { outcome: "disabled" }
  | { outcome: "downloaded"; version: string }
  | { outcome: "downloading"; version: string }
  | { outcome: "up-to-date"; version: string }
  | { outcome: "error" }

export const checkForUpdatesInteractive = async (): Promise<InteractiveCheckResult> => {
  if (!updatesEnabled()) {
    return { outcome: "disabled" }
  }

  if (downloadedVersion) {
    return { outcome: "downloaded", version: downloadedVersion }
  }

  try {
    const result = await checkForUpdates()
    const available = result?.updateInfo?.version
    if (available && available !== app.getVersion()) {
      return { outcome: "downloading", version: available }
    }

    return { outcome: "up-to-date", version: app.getVersion() }
  } catch {
    return { outcome: "error" }
  }
}
