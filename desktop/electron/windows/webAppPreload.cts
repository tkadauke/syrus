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

type ShellNoticeState = {
  updateReadyVersion: string | null
  claudeDetected: boolean
  skillInstalled: boolean
  skillOfferDismissed: boolean
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
  }
})
