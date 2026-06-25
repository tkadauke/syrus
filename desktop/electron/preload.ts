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

type BootstrapPayload = {
  current_user: {
    admin: boolean
  } | null
}

type AdminControls = {
  polling_paused: boolean
  runs_paused: boolean
}

type AdminControl = "polling" | "runs"

type ToggleAdminControlResult = {
  cancelled: boolean
  controls: AdminControls
}

contextBridge.exposeInMainWorld("syrusDesktop", {
  getCredentials: () => ipcRenderer.invoke("get-credentials") as Promise<Credentials | null>,
  saveCredentials: (credentials: Credentials) =>
    ipcRenderer.invoke("save-credentials", credentials) as Promise<Credentials>,
  fetchBootstrap: () => ipcRenderer.invoke("fetch-bootstrap") as Promise<BootstrapPayload>,
  fetchInboxJobs: () => ipcRenderer.invoke("fetch-inbox-jobs") as Promise<JobItem[]>,
  fetchAdminControls: () => ipcRenderer.invoke("fetch-admin-controls") as Promise<AdminControls>,
  toggleAdminControl: (control: AdminControl, pause: boolean) =>
    ipcRenderer.invoke("toggle-admin-control", control, pause) as Promise<ToggleAdminControlResult>,
  openExternal: (url: string) => ipcRenderer.invoke("open-external", url) as Promise<void>,
  openTokenDocs: () => ipcRenderer.invoke("open-token-docs") as Promise<void>,
  onCredentialsCleared: (callback: () => void) => {
    const listener = () => callback()
    ipcRenderer.on("credentials-cleared", listener)
    return () => ipcRenderer.removeListener("credentials-cleared", listener)
  }
})
