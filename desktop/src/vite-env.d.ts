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

interface Window {
  syrusDesktop: {
    getCredentials: () => Promise<SyrusCredentials | null>
    saveCredentials: (credentials: SyrusCredentials) => Promise<SyrusCredentials>
    getDesktopSettings: () => Promise<SyrusDesktopSettings>
    saveDesktopSettings: (settings: SyrusDesktopSettingsInput) => Promise<SyrusDesktopSettings>
    getGlobalHotkey: () => Promise<string>
    saveGlobalHotkey: (globalHotkey: string) => Promise<{ globalHotkey: string }>
    chooseLocalProjectsRoot: () => Promise<string | null>
    syrusCliStatus: () => Promise<{ available: boolean }>
    checkoutAvailability: (repoSlug: string) => Promise<SyrusCheckoutAvailability>
    checkoutJob: (request: SyrusCheckoutRequest) => Promise<{ branchName: string }>
    localStatus: () => Promise<SyrusLocalStatus | null>
    showPreferences: () => Promise<void>
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
    onDesktopSettingsUpdated: (callback: () => void) => () => void
    onCredentialsCleared: (callback: () => void) => () => void
    onCredentialsSaved: (callback: (credentials: SyrusCredentials) => void) => () => void
    onNotificationEvent: (callback: (event: unknown) => void) => () => void
    onNavigateToJob: (callback: (jobId: number) => void) => () => void
  }
}
