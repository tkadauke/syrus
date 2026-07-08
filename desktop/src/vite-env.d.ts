/// <reference types="vite/client" />

type SyrusCredentials = {
  url: string
  token: string
}

type SyrusNotificationPreferences = {
  desktop_job_implemented?: boolean
  desktop_job_failed?: boolean
}

type SyrusJobItem = {
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

type SyrusDesktopSettings = {
  localProjectsRoot: string
  localRepoPaths: Record<string, string>
  lastUsedRepo: string
}

type SyrusDesktopSettingsInput = Pick<SyrusDesktopSettings, "localProjectsRoot" | "localRepoPaths">

type SyrusRepositoryItem = {
  id: number
  slug: string
}

type SyrusCliInstallResult = {
  installed: boolean
  target: string | null
  onPath: boolean
  signedIn: boolean
  skillInstalled: boolean
  skillError: string | null
  error: string | null
}

type SyrusCheckoutAvailability = {
  cliAvailable: boolean
  localPath: string | null
}

type SyrusCheckoutRequest = {
  jobRef: string
  repoSlug: string
  branchName: string
  extraArgs?: string[]
}

type SyrusLocalStatus = {
  job_id: number
  branch: string
  behind: number
}

type SyrusCreateJobRequest = {
  repositoryId: number
  prompt: string
}

type SyrusCreateJobResponse = {
  message: string
  redirect_to: string
  job: SyrusJobItem
}

type SyrusJobTestPlan = {
  workflow_id: number
  steps: string[]
  notes: string | null
}

type SyrusJobOriginChat = {
  chat_session_id: number
  message_id: number
}

type SyrusFeedbackHistoryItem = {
  kind: "chat_feedback" | "pr_comment"
  body: string
  created_at: string
  state: string
}

type SyrusJobDetail = {
  job: SyrusJobItem
  repository: {
    slug: string
  }
  origin_chat: SyrusJobOriginChat | null
  summary: { run_id: number; text: string; finished_at: string } | null
  test_plan: SyrusJobTestPlan | null
  feedback_history: SyrusFeedbackHistoryItem[]
}

type SyrusBootstrapPayload = {
  current_user: {
    admin: boolean
    notification_preferences?: SyrusNotificationPreferences
  } | null
  unread_notifications_count?: number
}

type SyrusDesktopNotificationOptions = {
  title: string
  body: string
  jobId: number
}

type SyrusNotificationRecord = {
  id: number
  kind: string
  body: string
  read_at: string | null
  job_id: number | null
  pr_url: string | null
  job_title?: string | null
  created_at: string
}

type SyrusNotificationsPayload = {
  notifications: SyrusNotificationRecord[]
  unread_count: number
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
  }
}

type SyrusNotificationPayload = {
  notification: SyrusNotificationRecord
  unread_count: number
}

type SyrusAdminControls = {
  polling_paused: boolean
  runs_paused: boolean
}

type SyrusAdminControl = "polling" | "runs"

type SyrusToggleAdminControlResult = {
  cancelled: boolean
  controls: SyrusAdminControls
}

type SyrusInstallStepId =
  | "runtime_check"
  | "runtime_start"
  | "compose_resolve"
  | "env_check"
  | "env_generate"
  | "image_pull"
  | "stack_up"
  | "health"

type SyrusInstallStep = {
  id: SyrusInstallStepId
  status: "pending" | "running" | "ok" | "skipped"
}

// Overall image-pull progress for the installing screen's determinate bar.
// `label` is preformatted by the driver ("42% (312 MB / 745 MB)") so the
// renderer and the log summary can't drift.
type SyrusPullProgress = {
  percent: number
  label: string
}

// Plain string, or a transient rolling status line (the image-pull progress
// summary) that replaces the previous log line when that was also transient.
type SyrusOnboardingLogLine = string | { line: string; transient: true }

type SyrusOnboardingState =
  | { phase: "welcome" }
  | { phase: "connect.form"; error: string | null }
  | { phase: "connect.checking"; url: string }
  | { phase: "local.precheck" }
  | { phase: "local.adoptRunning"; url: string }
  | { phase: "local.adoptExisting"; error: string | null }
  | { phase: "local.runtimeMissing"; polling: boolean; wslMissing: boolean; installError: string | null }
  | { phase: "local.runtimeInstalling"; step: "downloading" | "installing"; percent: number | null }
  | { phase: "local.runtimeStarting"; needsAttention: boolean }
  | { phase: "local.portConflict"; port: number }
  | {
      phase: "local.installing"
      steps: SyrusInstallStep[]
      currentStep: SyrusInstallStepId | null
      pullProgress: SyrusPullProgress | null
    }
  | { phase: "local.failed"; code: number; step: string | null; message: string; logTail: string[] }
  | { phase: "done"; mode: "local" | "remote"; url: string }

// URL-only: sign-in in the app window mints the tray token automatically;
// the manual-token path for non-admin accounts lives in Preferences.
type SyrusConnectRemoteRequest = {
  url: string
}

// Advisory result of the connect form's live probe — the green check only
// fires when a Syrus actually answered at the normalized address.
type SyrusInstanceProbeResult = {
  ok: boolean
  url: string | null
  message: string
}

interface Window {
  syrusDesktop: {
    platform: string
    getCredentials: () => Promise<SyrusCredentials | null>
    saveCredentials: (credentials: SyrusCredentials) => Promise<SyrusCredentials>
    getDesktopSettings: () => Promise<SyrusDesktopSettings>
    saveDesktopSettings: (settings: SyrusDesktopSettingsInput) => Promise<SyrusDesktopSettings>
    getGlobalHotkey: () => Promise<string>
    saveGlobalHotkey: (globalHotkey: string) => Promise<{ globalHotkey: string }>
    chooseLocalProjectsRoot: () => Promise<string | null>
    syrusCliStatus: () => Promise<{ available: boolean; bundledAvailable: boolean }>
    installSyrusCli: (options?: { withSkill?: boolean }) => Promise<SyrusCliInstallResult>
    checkoutAvailability: (repoSlug: string) => Promise<SyrusCheckoutAvailability>
    checkoutJob: (request: SyrusCheckoutRequest) => Promise<{ branchName: string }>
    localStatus: () => Promise<SyrusLocalStatus | null>
    showPreferences: () => Promise<void>
    openSyrusWindow: () => Promise<void>
    openInSyrus: (target?: string) => Promise<void>
    quitApp: () => Promise<void>
    copyText: (text: string) => Promise<void>
    showNotification: (opts: SyrusDesktopNotificationOptions) => Promise<void>
    fetchBootstrap: () => Promise<SyrusBootstrapPayload>
    fetchRepositories: () => Promise<SyrusRepositoryItem[]>
    getLastUsedRepo: () => Promise<string>
    setLastUsedRepo: (repoSlug: string) => Promise<string>
    fetchInboxJobs: () => Promise<SyrusJobItem[]>
    fetchJobDetail: (jobID: number) => Promise<SyrusJobDetail>
    fetchNotificationUnreadCount: () => Promise<number>
    fetchNotifications: () => Promise<SyrusNotificationsPayload>
    markNotificationRead: (id: number) => Promise<SyrusNotificationPayload>
    markAllNotificationsRead: () => Promise<SyrusNotificationsPayload>
    createDirectJob: (request: SyrusCreateJobRequest) => Promise<SyrusCreateJobResponse>
    confirmApproveJob: (jobID: number) => Promise<boolean>
    approveJob: (jobID: number) => Promise<void>
    retryJob: (jobID: number) => Promise<void>
    submitJobFeedback: (jobID: number, body: string) => Promise<void>
    fetchAdminControls: () => Promise<SyrusAdminControls>
    toggleAdminControl: (control: SyrusAdminControl, pause: boolean) => Promise<SyrusToggleAdminControlResult>
    openExternal: (url: string) => Promise<void>
    openTokenDocs: () => Promise<void>
    getAppVersion: () => Promise<string>
    getServerUrl: () => Promise<string>
    getOnboardingState: () => Promise<SyrusOnboardingState>
    chooseOnboardingMode: (mode: "local" | "remote") => Promise<void>
    connectRemote: (request: SyrusConnectRemoteRequest) => Promise<void>
    probeInstance: (request: SyrusConnectRemoteRequest) => Promise<SyrusInstanceProbeResult>
    startInstall: (port?: number) => Promise<void>
    cancelInstall: () => Promise<void>
    retryOnboarding: () => Promise<void>
    onboardingBack: () => Promise<void>
    locateEnvFile: () => Promise<void>
    wipeLocalData: () => Promise<void>
    openOrbStackDownload: () => Promise<void>
    openRuntimeApp: () => Promise<void>
    installRuntime: () => Promise<void>
    installWsl: () => Promise<void>
    adoptRunningInstance: () => Promise<void>
    finishOnboarding: () => Promise<void>
    onOnboardingState: (callback: (state: SyrusOnboardingState) => void) => () => void
    onOnboardingLogLine: (callback: (line: SyrusOnboardingLogLine) => void) => () => void
    onDesktopSettingsUpdated: (callback: () => void) => () => void
    onCredentialsCleared: (callback: () => void) => () => void
    onCredentialsSaved: (callback: (credentials: SyrusCredentials) => void) => () => void
    onNotificationEvent: (callback: (event: unknown) => void) => () => void
    onNavigateToJob: (callback: (jobId: number) => void) => () => void
  }
}
