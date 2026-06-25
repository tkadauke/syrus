/// <reference types="vite/client" />

type SyrusCredentials = {
  url: string
  token: string
}

type SyrusJobItem = {
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

type SyrusBootstrapPayload = {
  current_user: {
    admin: boolean
  } | null
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
    createDirectJob: (request: SyrusCreateJobRequest) => Promise<SyrusCreateJobResponse>
    fetchAdminControls: () => Promise<SyrusAdminControls>
    toggleAdminControl: (control: SyrusAdminControl, pause: boolean) => Promise<SyrusToggleAdminControlResult>
    openExternal: (url: string) => Promise<void>
    openTokenDocs: () => Promise<void>
    onDesktopSettingsUpdated: (callback: () => void) => () => void
    onCredentialsCleared: (callback: () => void) => () => void
  }
}
