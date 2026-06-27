/// <reference types="vite/client" />

type SyrusCredentials = {
  url: string
  token: string
}

type SyrusJobItem = {
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

type SyrusJobDetail = {
  job: SyrusJobItem
  repository: {
    slug: string
  }
  test_plan: SyrusJobTestPlan | null
}

type SyrusBootstrapPayload = {
  current_user: {
    admin: boolean
  } | null
  unread_notifications_count?: number
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
    showPreferences: () => Promise<void>
    copyText: (text: string) => Promise<void>
    fetchBootstrap: () => Promise<SyrusBootstrapPayload>
    fetchRepositories: () => Promise<SyrusRepositoryItem[]>
    getLastUsedRepo: () => Promise<string>
    setLastUsedRepo: (repoSlug: string) => Promise<string>
    fetchInboxJobs: () => Promise<SyrusJobItem[]>
    fetchJobDetail: (jobID: number) => Promise<SyrusJobDetail>
    createDirectJob: (request: SyrusCreateJobRequest) => Promise<SyrusCreateJobResponse>
    confirmApproveJob: (jobID: number) => Promise<boolean>
    approveJob: (jobID: number) => Promise<void>
    retryJob: (jobID: number) => Promise<void>
    fetchAdminControls: () => Promise<SyrusAdminControls>
    toggleAdminControl: (control: SyrusAdminControl, pause: boolean) => Promise<SyrusToggleAdminControlResult>
    openExternal: (url: string) => Promise<void>
    openTokenDocs: () => Promise<void>
    onDesktopSettingsUpdated: (callback: () => void) => () => void
    onCredentialsCleared: (callback: () => void) => () => void
    onCredentialsSaved: (callback: (credentials: SyrusCredentials) => void) => () => void
    onNotificationEvent: (callback: (event: unknown) => void) => () => void
  }
}
