export type SetupStatusPayload = {
  complete: boolean
  chat_started: boolean
  onboarding_chat_path: string | null
  next_step: "credentials" | "repository" | "chat" | "epic" | "complete"
  progress: { completed: number; total: number; steps: Array<{ key: string; label: string; complete: boolean }> }
  credentials: Record<string, unknown>
  system: Record<string, unknown>
  github_app: Record<string, unknown>
  repositories: Record<string, unknown>
  first_job: Record<string, unknown>
  paths: { setup_path: string; credentials_path: string; new_repository_path: string; repositories_path: string; new_job_path: string; dashboard_jobs_path: string }
}

export type FullSetupStatusPayload = {
  state: "not_started" | "first_admin" | "credentials_only" | "repository_only" | "ready_for_first_chat" | "first_chat_started" | "first_successful_job"
  next_step: "configure_credentials" | "add_repository" | "start_first_chat" | null
  next_step_path: string | null
  first_admin: boolean
  credentials_configured: boolean
  repository_configured: boolean
  onboarding_repository_id?: number | null
  first_job_started: boolean
  first_successful_job_completed: boolean
  first_epic_created: boolean
  first_epic_started: boolean
  first_epic_landed: boolean
  onboarding_chat_started: boolean
  credential_status: {
    github: boolean
    github_pat: boolean
    github_app: boolean
    agent: boolean
    active_agent_provider: string
    active_agent_provider_label?: string
  }
  readiness: {
    status: "ok" | "warning" | "error"
    checks: Array<{ key: string; label: string; status: "ok" | "warning" | "error"; message: string; remediation: string | null; optional: boolean }>
  }
  counts: { repositories: number; jobs: number; successful_jobs: number }
}

import { getJson } from "./client"

export function fetchSetup() {
  return getJson<FullSetupStatusPayload>("/api/v1/app/setup")
}
