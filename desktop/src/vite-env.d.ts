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

interface Window {
  syrusDesktop: {
    getCredentials: () => Promise<SyrusCredentials | null>
    saveCredentials: (credentials: SyrusCredentials) => Promise<SyrusCredentials>
    getDesktopSettings: () => Promise<SyrusDesktopSettings>
    saveDesktopSettings: (settings: SyrusDesktopSettings) => Promise<SyrusDesktopSettings>
    chooseLocalProjectsRoot: () => Promise<string | null>
    syrusCliStatus: () => Promise<{ available: boolean }>
    checkoutAvailability: (repoSlug: string) => Promise<SyrusCheckoutAvailability>
    checkoutJob: (request: SyrusCheckoutRequest) => Promise<{ branchName: string }>
    showPreferences: () => Promise<void>
    copyText: (text: string) => Promise<void>
    fetchInboxJobs: () => Promise<SyrusJobItem[]>
    openExternal: (url: string) => Promise<void>
    openTokenDocs: () => Promise<void>
    onDesktopSettingsUpdated: (callback: () => void) => () => void
    onCredentialsCleared: (callback: () => void) => () => void
  }
}
