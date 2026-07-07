import { contextBridge, ipcRenderer } from "electron"

type Credentials = {
  url: string
  token: string
}

type NotificationPreferences = {
  desktop_job_implemented: boolean
  desktop_job_failed: boolean
}

type CredentialsUser = {
  admin: boolean
  notification_preferences?: Partial<NotificationPreferences>
}

type JobItem = {
  id: number
  epic_id: number | null
  epic_title: string | null
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

type JobOriginChat = {
  chat_session_id: number
  message_id: number
}

type FeedbackHistoryItem = {
  kind: "chat_feedback" | "pr_comment"
  body: string
  created_at: string
  state: string
}

type JobDetail = {
  job: JobItem
  repository: {
    slug: string
  }
  origin_chat: JobOriginChat | null
  summary: { run_id: number; text: string; finished_at: string } | null
  test_plan: JobTestPlan | null
  feedback_history: FeedbackHistoryItem[]
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
  extraArgs?: string[]
}

type LocalStatus = {
  job_id: number
  branch: string
  behind: number
}

type BootstrapPayload = {
  current_user: CredentialsUser | null
  unread_notifications_count?: number
}

type DesktopNotificationOptions = {
  title: string
  body: string
  jobId: number
}

type NotificationRecord = {
  id: number
  kind: string
  body: string
  read_at: string | null
  job_id: number | null
  pr_url: string | null
  job_title?: string | null
  created_at: string
}

type NotificationsPayload = {
  notifications: NotificationRecord[]
  unread_count: number
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
  }
}

type NotificationPayload = {
  notification: NotificationRecord
  unread_count: number
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

// The full discriminated union lives in the renderer's vite-env.d.ts and the
// main process's installerDriver.ts; the bridge passes it through opaquely.
type OnboardingState = { phase: string } & Record<string, unknown>

// URL-only: sign-in in the app window mints the tray token automatically;
// the manual-token path for non-admin accounts lives in Preferences.
type ConnectRemoteRequest = {
  url: string
}

contextBridge.exposeInMainWorld("syrusDesktop", {
  // Static, not IPC: lets the renderer adapt copy/affordances per platform
  // (e.g. the Welcome screen's local-install card on Windows).
  platform: process.platform,
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
  installSyrusCli: (options?: { withSkill?: boolean }) =>
    ipcRenderer.invoke("install-syrus-cli", options) as Promise<{
      installed: boolean
      target: string | null
      onPath: boolean
      signedIn: boolean
      skillInstalled: boolean
      skillError: string | null
      error: string | null
    }>,
  checkoutAvailability: (repoSlug: string) =>
    ipcRenderer.invoke("checkout-availability", repoSlug) as Promise<CheckoutAvailability>,
  checkoutJob: (request: CheckoutRequest) =>
    ipcRenderer.invoke("checkout-job", request) as Promise<{ branchName: string }>,
  localStatus: () => ipcRenderer.invoke("syrus:local-status") as Promise<LocalStatus | null>,
  showPreferences: () => ipcRenderer.invoke("show-preferences") as Promise<void>,
  openSyrusWindow: () => ipcRenderer.invoke("open-syrus") as Promise<void>,
  quitApp: () => ipcRenderer.invoke("quit-app") as Promise<void>,
  copyText: (text: string) => ipcRenderer.invoke("copy-text", text) as Promise<void>,
  showNotification: (opts: DesktopNotificationOptions) =>
    ipcRenderer.invoke("syrusDesktop:showNotification", opts) as Promise<void>,
  fetchBootstrap: () => ipcRenderer.invoke("fetch-bootstrap") as Promise<BootstrapPayload>,
  fetchRepositories: () => ipcRenderer.invoke("fetch-repositories") as Promise<RepositoryItem[]>,
  getLastUsedRepo: () => ipcRenderer.invoke("get-last-used-repo") as Promise<string>,
  setLastUsedRepo: (repoSlug: string) => ipcRenderer.invoke("set-last-used-repo", repoSlug) as Promise<string>,
  fetchInboxJobs: () => ipcRenderer.invoke("fetch-inbox-jobs") as Promise<JobItem[]>,
  fetchJobDetail: (jobID: number) => ipcRenderer.invoke("fetch-job-detail", jobID) as Promise<JobDetail>,
  fetchNotificationUnreadCount: () =>
    ipcRenderer.invoke("fetch-notification-unread-count") as Promise<number>,
  fetchNotifications: () => ipcRenderer.invoke("fetch-notifications") as Promise<NotificationsPayload>,
  markNotificationRead: (id: number) =>
    ipcRenderer.invoke("mark-notification-read", id) as Promise<NotificationPayload>,
  markAllNotificationsRead: () =>
    ipcRenderer.invoke("mark-all-notifications-read") as Promise<NotificationsPayload>,
  createDirectJob: (request: CreateJobRequest) =>
    ipcRenderer.invoke("create-direct-job", request) as Promise<CreateJobResponse>,
  confirmApproveJob: (jobID: number) => ipcRenderer.invoke("confirm-approve-job", jobID) as Promise<boolean>,
  approveJob: (jobID: number) => ipcRenderer.invoke("approve-job", jobID) as Promise<void>,
  retryJob: (jobID: number) => ipcRenderer.invoke("retry-job", jobID) as Promise<void>,
  submitJobFeedback: (jobID: number, body: string) =>
    ipcRenderer.invoke("submit-job-feedback", jobID, body) as Promise<void>,
  fetchAdminControls: () => ipcRenderer.invoke("fetch-admin-controls") as Promise<AdminControls>,
  toggleAdminControl: (control: AdminControl, pause: boolean) =>
    ipcRenderer.invoke("toggle-admin-control", control, pause) as Promise<ToggleAdminControlResult>,
  openExternal: (url: string) => ipcRenderer.invoke("open-external", url) as Promise<void>,
  openTokenDocs: () => ipcRenderer.invoke("open-token-docs") as Promise<void>,
  getAppVersion: () => ipcRenderer.invoke("get-app-version") as Promise<string>,
  getServerUrl: () => ipcRenderer.invoke("get-server-url") as Promise<string>,
  getOnboardingState: () => ipcRenderer.invoke("onboarding:get-state") as Promise<OnboardingState>,
  chooseOnboardingMode: (mode: "local" | "remote") =>
    ipcRenderer.invoke("onboarding:choose-mode", mode) as Promise<void>,
  connectRemote: (request: ConnectRemoteRequest) =>
    ipcRenderer.invoke("onboarding:connect-remote", request) as Promise<void>,
  probeInstance: (request: ConnectRemoteRequest) =>
    ipcRenderer.invoke("onboarding:probe-instance", request) as Promise<{
      ok: boolean
      url: string | null
      message: string
    }>,
  installWsl: () => ipcRenderer.invoke("onboarding:install-wsl") as Promise<void>,
  startInstall: (port?: number) => ipcRenderer.invoke("onboarding:start-install", port) as Promise<void>,
  cancelInstall: () => ipcRenderer.invoke("onboarding:cancel-install") as Promise<void>,
  retryOnboarding: () => ipcRenderer.invoke("onboarding:retry") as Promise<void>,
  onboardingBack: () => ipcRenderer.invoke("onboarding:back") as Promise<void>,
  locateEnvFile: () => ipcRenderer.invoke("onboarding:locate-env") as Promise<void>,
  wipeLocalData: () => ipcRenderer.invoke("onboarding:wipe-data") as Promise<void>,
  openOrbStackDownload: () => ipcRenderer.invoke("onboarding:open-orbstack-download") as Promise<void>,
  openRuntimeApp: () => ipcRenderer.invoke("onboarding:open-runtime") as Promise<void>,
  adoptRunningInstance: () => ipcRenderer.invoke("onboarding:adopt-running") as Promise<void>,
  finishOnboarding: () => ipcRenderer.invoke("onboarding:finish") as Promise<void>,
  onOnboardingState: (callback: (state: OnboardingState) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, state: OnboardingState) => callback(state)
    ipcRenderer.on("onboarding:state-changed", listener)
    return () => ipcRenderer.removeListener("onboarding:state-changed", listener)
  },
  onOnboardingLogLine: (callback: (line: string) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, line: string) => callback(line)
    ipcRenderer.on("onboarding:log-line", listener)
    return () => ipcRenderer.removeListener("onboarding:log-line", listener)
  },
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
  },
  onNavigateToJob: (callback: (jobId: number) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, jobId: number) => callback(jobId)
    ipcRenderer.on("syrusDesktop:navigateToJob", listener)
    return () => ipcRenderer.removeListener("syrusDesktop:navigateToJob", listener)
  }
})
