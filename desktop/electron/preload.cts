import { contextBridge, ipcRenderer } from "electron"

type Credentials = {
  url: string
  token: string
}

type JobItem = {
  id: number
  epic_id: number | null
  state: string
  summary_state: string
  title: string
  issue_title: string
  repository_id: number
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

type CreateJobRequest = {
  repositoryId: number
  prompt: string
}

type CreateJobResponse = {
  message: string
  redirect_to: string
  job: JobItem
}

type JobTestPlan = {
  workflow_id: number
  steps: string[]
  notes: string | null
}

type JobDetail = {
  job: JobItem
  repository: {
    slug: string
  }
  test_plan: JobTestPlan | null
}

type DesktopSettings = {
  localProjectsRoot: string
  localRepoPaths: Record<string, string>
  lastUsedRepo: string
}

type DesktopSettingsInput = Pick<DesktopSettings, "localProjectsRoot" | "localRepoPaths">

type RepositoryItem = {
  id: number
  slug: string
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

type BootstrapPayload = {
  current_user: {
    admin: boolean
  } | null
  unread_notifications_count?: number
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
  getDesktopSettings: () => ipcRenderer.invoke("get-desktop-settings") as Promise<DesktopSettings>,
  saveDesktopSettings: (settings: DesktopSettingsInput) =>
    ipcRenderer.invoke("save-desktop-settings", settings) as Promise<DesktopSettings>,
  getGlobalHotkey: () => ipcRenderer.invoke("get-global-hotkey") as Promise<string>,
  saveGlobalHotkey: (globalHotkey: string) =>
    ipcRenderer.invoke("save-global-hotkey", globalHotkey) as Promise<{ globalHotkey: string }>,
  chooseLocalProjectsRoot: () => ipcRenderer.invoke("choose-local-projects-root") as Promise<string | null>,
  syrusCliStatus: () => ipcRenderer.invoke("syrus-cli-status") as Promise<{ available: boolean }>,
  checkoutAvailability: (repoSlug: string) =>
    ipcRenderer.invoke("checkout-availability", repoSlug) as Promise<CheckoutAvailability>,
  checkoutJob: (request: CheckoutRequest) =>
    ipcRenderer.invoke("checkout-job", request) as Promise<{ branchName: string }>,
  showPreferences: () => ipcRenderer.invoke("show-preferences") as Promise<void>,
  copyText: (text: string) => ipcRenderer.invoke("copy-text", text) as Promise<void>,
  fetchBootstrap: () => ipcRenderer.invoke("fetch-bootstrap") as Promise<BootstrapPayload>,
  fetchRepositories: () => ipcRenderer.invoke("fetch-repositories") as Promise<RepositoryItem[]>,
  getLastUsedRepo: () => ipcRenderer.invoke("get-last-used-repo") as Promise<string>,
  setLastUsedRepo: (repoSlug: string) => ipcRenderer.invoke("set-last-used-repo", repoSlug) as Promise<string>,
  fetchInboxJobs: () => ipcRenderer.invoke("fetch-inbox-jobs") as Promise<JobItem[]>,
  fetchJobDetail: (jobID: number) => ipcRenderer.invoke("fetch-job-detail", jobID) as Promise<JobDetail>,
  createDirectJob: (request: CreateJobRequest) =>
    ipcRenderer.invoke("create-direct-job", request) as Promise<CreateJobResponse>,
  confirmApproveJob: (jobID: number) => ipcRenderer.invoke("confirm-approve-job", jobID) as Promise<boolean>,
  approveJob: (jobID: number) => ipcRenderer.invoke("approve-job", jobID) as Promise<void>,
  retryJob: (jobID: number) => ipcRenderer.invoke("retry-job", jobID) as Promise<void>,
  fetchAdminControls: () => ipcRenderer.invoke("fetch-admin-controls") as Promise<AdminControls>,
  toggleAdminControl: (control: AdminControl, pause: boolean) =>
    ipcRenderer.invoke("toggle-admin-control", control, pause) as Promise<ToggleAdminControlResult>,
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
  },
  onCredentialsSaved: (callback: (credentials: Credentials) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, credentials: Credentials) => callback(credentials)
    ipcRenderer.on("credentials-saved", listener)
    return () => ipcRenderer.removeListener("credentials-saved", listener)
  },
  onNotificationEvent: (callback: (event: unknown) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, notificationEvent: unknown) => callback(notificationEvent)
    ipcRenderer.on("notification-event", listener)
    return () => ipcRenderer.removeListener("notification-event", listener)
  }
})
