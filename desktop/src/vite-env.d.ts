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
    fetchBootstrap: () => Promise<SyrusBootstrapPayload>
    fetchInboxJobs: () => Promise<SyrusJobItem[]>
    fetchAdminControls: () => Promise<SyrusAdminControls>
    toggleAdminControl: (control: SyrusAdminControl, pause: boolean) => Promise<SyrusToggleAdminControlResult>
    openExternal: (url: string) => Promise<void>
    openTokenDocs: () => Promise<void>
    onCredentialsCleared: (callback: () => void) => () => void
  }
}
