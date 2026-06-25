import { getJson } from "./client"
import type { SetupStatusPayload } from "./setup"

export type BootstrapPayload = {
  current_user: {
    id: number
    email_address: string
    name: string | null
    first_name: string | null
    last_name: string | null
    display_name: string
    admin: boolean
    scheduling_paused: boolean
    landing_paused: boolean
    agent_provider: "claude" | "codex"
    agent_max_turns: number
    theme: "light" | "dark"
    layout_version: "v1" | "v2"
    notification_unread_count?: number
  } | null
  team_user_count: number
  app: {
    revision: string
    revision_url: string | null
  }
  setup_status: {
    state: "not_started" | "first_admin" | "credentials_only" | "repository_only" | "ready_for_first_chat" | "first_chat_started" | "first_successful_job"
    next_step: "configure_credentials" | "add_repository" | "start_first_chat" | null
    next_step_path: string | null
    first_admin: boolean
    credentials_configured: boolean
    repository_configured: boolean
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
      active_agent_provider: "claude" | "codex"
    }
    readiness: {
      status: "ok" | "warning" | "error"
      checks: Array<{
        key: string
        label: string
        status: "ok" | "warning" | "error"
        message: string
        remediation: string | null
        optional: boolean
      }>
    }
    counts: {
      repositories: number
      jobs: number
      successful_jobs: number
    }
  } | null
  public: {
    first_signup: boolean
    signups_open: boolean
    signup_path: string
    sign_in_path: string
    docs_url: string
    evaluation_url: string
  }
  navigation?: {
    default_chat_path: string
  }
  setup?: SetupStatusPayload | null
  flash?: {
    alert?: string | null
    notice?: string | null
  }
  system_alerts?: Array<{
    id: string
    severity: "alarm" | "warn" | "info" | string
    title: string
    message: string
    action_steps: string[]
    cta: {
      text: string
      path: string
    } | null
  }>
  csrf_token: string
  feature_flags: {
    migrated_routes: string[]
  }
}

export function fetchBootstrap() {
  return getJson<BootstrapPayload>("/api/v1/app/bootstrap")
}

export function readInitialBootstrap() {
  const element = document.getElementById("syrus-bootstrap-data")
  if (!element?.textContent) return null

  try {
    return JSON.parse(element.textContent) as BootstrapPayload
  } catch {
    return null
  }
}
