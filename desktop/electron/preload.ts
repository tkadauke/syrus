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

contextBridge.exposeInMainWorld("syrusDesktop", {
  getCredentials: () => ipcRenderer.invoke("get-credentials") as Promise<Credentials | null>,
  saveCredentials: (credentials: Credentials) =>
    ipcRenderer.invoke("save-credentials", credentials) as Promise<Credentials>,
  fetchInboxJobs: () => ipcRenderer.invoke("fetch-inbox-jobs") as Promise<JobItem[]>,
  openExternal: (url: string) => ipcRenderer.invoke("open-external", url) as Promise<void>,
  openTokenDocs: () => ipcRenderer.invoke("open-token-docs") as Promise<void>,
  onCredentialsCleared: (callback: () => void) => {
    const listener = () => callback()
    ipcRenderer.on("credentials-cleared", listener)
    return () => ipcRenderer.removeListener("credentials-cleared", listener)
  }
})
