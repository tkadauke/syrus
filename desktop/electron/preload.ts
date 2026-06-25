import { contextBridge, ipcRenderer } from "electron"

type Credentials = {
  url: string
  token: string
}

type JobItem = {
  id: number
  state: string
  summary_state: string
  title: string
  issue_title: string
  repository_slug: string
  branch_name: string
  pr_number: number
  pr_url: string
  created_at: string
  updated_at: string
  started_at: string
  finished_at: string
  current_step: string
  latest_run_id: number
}

type DesktopSettings = {
  localProjectsRoot: string
  localRepoPaths: Record<string, string>
}

type CheckoutAvailability = {
  cliAvailable: boolean
  localPath: string | null
}

type CheckoutRequest = {
  jobRef: string
  repoSlug: string
  branchName: string
}

contextBridge.exposeInMainWorld("syrusDesktop", {
  getCredentials: () => ipcRenderer.invoke("get-credentials") as Promise<Credentials | null>,
  saveCredentials: (credentials: Credentials) =>
    ipcRenderer.invoke("save-credentials", credentials) as Promise<Credentials>,
  getDesktopSettings: () => ipcRenderer.invoke("get-desktop-settings") as Promise<DesktopSettings>,
  saveDesktopSettings: (settings: DesktopSettings) =>
    ipcRenderer.invoke("save-desktop-settings", settings) as Promise<DesktopSettings>,
  chooseLocalProjectsRoot: () => ipcRenderer.invoke("choose-local-projects-root") as Promise<string | null>,
  syrusCliStatus: () => ipcRenderer.invoke("syrus-cli-status") as Promise<{ available: boolean }>,
  checkoutAvailability: (repoSlug: string) =>
    ipcRenderer.invoke("checkout-availability", repoSlug) as Promise<CheckoutAvailability>,
  checkoutJob: (request: CheckoutRequest) =>
    ipcRenderer.invoke("checkout-job", request) as Promise<{ branchName: string }>,
  showPreferences: () => ipcRenderer.invoke("show-preferences") as Promise<void>,
  copyText: (text: string) => ipcRenderer.invoke("copy-text", text) as Promise<void>,
  fetchInboxJobs: () => ipcRenderer.invoke("fetch-inbox-jobs") as Promise<JobItem[]>,
  openExternal: (url: string) => ipcRenderer.invoke("open-external", url) as Promise<void>,
  openTokenDocs: () => ipcRenderer.invoke("open-token-docs") as Promise<void>,
  onDesktopSettingsUpdated: (callback: () => void) => {
    const listener = () => callback()
    ipcRenderer.on("desktop-settings-updated", listener)
    return () => ipcRenderer.removeListener("desktop-settings-updated", listener)
  },
  onCredentialsCleared: (callback: () => void) => {
    const listener = () => callback()
    ipcRenderer.on("credentials-cleared", listener)
    return () => ipcRenderer.removeListener("credentials-cleared", listener)
  }
})
