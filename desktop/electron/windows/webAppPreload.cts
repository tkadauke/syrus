// The web-app window's ONLY preload. The full tray bridge (preload.cts)
// stays off this window on purpose — it loads remote content, and remote
// content must never see credential, filesystem, or job-control IPC. What
// IS exposed here is the minimal shell-notice contract the web app's
// sidebar renders instead of the old interruptive native dialogs:
//
//   window.syrusShell = {
//     getState(): Promise<ShellNoticeState>
//     onStateChanged(cb): () => void        // ipc "shell:state-changed"
//     relaunchToUpdate(): void
//     installSkill(): Promise<{ ok, message }>
//     dismissSkillOffer(): void
//   }
//
// Nothing sensitive crosses the bridge: booleans, a version string, and two
// actions the main process re-validates (relaunch no-ops unless an update is
// actually staged; installSkill runs the same audited install path as
// Preferences). Safe to expose regardless of which origin is loaded.
// contextIsolation and sandbox stay ON — this file is compiled to CommonJS
// (.cts → .cjs), which sandboxed preloads require.
import { contextBridge, ipcRenderer } from "electron"

// A local backend update in flight: coarse phase + overall docker-pull
// percent (only during "downloading", null when compose streams no parseable
// progress). The sidebar renders it as a progress notice for the WHOLE
// update; `outage` (true from container recreation on — during the long
// image pull the old backend still serves requests) is what the web app's
// tri-state gating keys off, so failed checks during the actual outage are
// never read as "unconfigured".
type BackendUpdateProgress = {
  phase: "starting" | "downloading" | "migrating"
  percent: number | null
  outage: boolean
}

type ShellNoticeState = {
  updateReadyVersion: string | null
  claudeDetected: boolean
  skillInstalled: boolean
  skillOfferDismissed: boolean
  backendUpdate: BackendUpdateProgress | null
}

contextBridge.exposeInMainWorld("syrusShell", {
  getState: () => ipcRenderer.invoke("shell:get-state") as Promise<ShellNoticeState>,
  onStateChanged: (callback: (state: ShellNoticeState) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, state: ShellNoticeState) => callback(state)
    ipcRenderer.on("shell:state-changed", listener)
    return () => ipcRenderer.removeListener("shell:state-changed", listener)
  },
  relaunchToUpdate: () => {
    void ipcRenderer.invoke("shell:relaunch-to-update")
  },
  installSkill: () =>
    ipcRenderer.invoke("shell:install-skill") as Promise<{ ok: boolean; message: string | null }>,
  dismissSkillOffer: () => {
    void ipcRenderer.invoke("shell:dismiss-skill-offer")
  },
  dictation: {
    prewarmMicrophone: () =>
      ipcRenderer.invoke("dictation:prewarm-microphone") as Promise<{ granted: boolean }>
  },
  // Red-pen screen annotation for the walkthrough recorder. Present only in
  // the desktop shell, so `available` (true here) is the web UI's STATIC
  // feature gate — a plain browser has no window.syrusShell.annotation at all
  // and shows no annotation affordance. enable() spins up the transparent
  // always-on-top overlay + the CommandOrControl+Shift+A draw-mode toggle on
  // record start and RESOLVES the main process's boolean: true only when the
  // overlay AND the shortcut actually came up, false when the overlay can't be
  // created or the accelerator is already taken. The recorder gates its runtime
  // HUD hint on that boolean so it never advertises a dead affordance.
  // disable() tears both down on stop/discard. onModeChanged fires on every
  // draw-mode transition so the recording HUD can reflect it.
  annotation: {
    available: true,
    // reason (present only when hold could not start) names the obstacle —
    // "no-module" | "no-accessibility" | "start-failed" — so the recorder can
    // tell the user how to get hold mode instead of silently degrading.
    enable: () =>
      ipcRenderer.invoke("annotation:enable") as Promise<{
        available: boolean
        hold: boolean
        reason?: "no-module" | "no-accessibility" | "start-failed"
      }>,
    disable: () => ipcRenderer.invoke("annotation:disable") as Promise<void>,
    onModeChanged: (callback: (drawing: boolean) => void) => {
      const listener = (_event: Electron.IpcRendererEvent, drawing: boolean) => callback(drawing)
      ipcRenderer.on("annotation:mode-changed", listener)
      return () => ipcRenderer.removeListener("annotation:mode-changed", listener)
    }
  },
  // The floating recording HUD — a separate always-on-top, DRAGGABLE window
  // carrying the recording controls, so they live OUTSIDE the Syrus web-app
  // window and stay reachable while the user demonstrates another app.
  // `available` (true here) is the web UI's static feature gate: a plain browser
  // has no window.syrusShell.recorderHud and keeps its in-page HUD. show() at
  // record start, update() each tick, hide() on stop/discard; onAction fires
  // when the user clicks the HUD's Stop / Discard.
  recorderHud: {
    available: true,
    show: (state: Record<string, unknown>) => ipcRenderer.invoke("recorderHud:show", state) as Promise<void>,
    update: (state: Record<string, unknown>) => ipcRenderer.invoke("recorderHud:update", state) as Promise<void>,
    hide: () => ipcRenderer.invoke("recorderHud:hide") as Promise<void>,
    onAction: (callback: (kind: "stop" | "discard") => void) => {
      const listener = (_event: Electron.IpcRendererEvent, kind: "stop" | "discard") => callback(kind)
      ipcRenderer.on("recorderHud:action", listener)
      return () => ipcRenderer.removeListener("recorderHud:action", listener)
    }
  }
})
