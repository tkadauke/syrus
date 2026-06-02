import { getJson } from "./client"

export type SetupStepKey = "credentials" | "repository" | "first_job" | "watch_job"
export type SetupNextStep = SetupStepKey | "complete"

export type SetupStatusPayload = {
  complete: boolean
  next_step: SetupNextStep
  progress: {
    completed: number
    total: number
    steps: Array<{
      key: SetupStepKey
      label: string
      complete: boolean
    }>
  }
  credentials: {
    github_token: boolean
    selected_agent_provider: "claude" | "codex" | string
    selected_agent_provider_configured: boolean
    configured_agent_providers: string[]
    ready: boolean
  }
  system: {
    data_root: string
    revision: string
    polling_paused: boolean
    runs_paused: boolean
    ready: boolean
  }
  github_app: {
    registered: boolean
    explanation: string
    register_path: string | null
    installations_path: string | null
  }
  repositories: {
    active_count: number
    any_app_credential_active: boolean
    any_pat_fallback: boolean
    first: {
      id: number
      slug: string
      trigger_label: string
      credential_mode: "app" | "pat"
      repository_path: string
      issues_path: string
    } | null
  }
  first_job: {
    any: boolean
    successful: boolean
    job: {
      id: number
      title: string
      state: string
      closure_reason: string | null
      pr_number: number | null
      repository_slug: string
      job_path: string
    } | null
  }
  paths: {
    setup_path: string
    credentials_path: string
    new_repository_path: string
    repositories_path: string
    new_job_path: string
    dashboard_jobs_path: string
  }
}

export function fetchSetupStatus() {
  return getJson<SetupStatusPayload>("/api/v1/app/setup")
}
