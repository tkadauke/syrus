import { getJson } from "./client"
import type { ProviderAvailability } from "./providerAvailability"
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
    role: string
    scheduling_paused: boolean
    landing_paused: boolean
    agent_provider: "claude" | "codex"
    chat_provider: "claude" | "codex" | null
    agent_max_turns: number
    gemini_configured: boolean
    theme: "light" | "dark"
    locale: "en" | "de" | "la"
    notification_unread_count?: number
    seen_tours?: string[]
  } | null
  team_user_count: number
  provider_availability?: Record<string, ProviderAvailability>
  app: {
    revision: string
    revision_url: string | null
    // Release version baked into published backend images (SYRUS_VERSION);
    // null on dev/deploy builds, where the badge falls back to the revision.
    version: string | null
    // When the backend image was built (SYRUS_BUILT_AT, UTC ISO-8601); null
    // when the image predates the stamp. Feeds the badge's hover tooltip.
    built_at: string | null
    // Which submission path the bug-report dialog will take for this user.
    bug_report_mode: "direct_job" | "github_issue" | null
    // The configured report_issue_repo_slug (e.g. "tkadauke/syrus"); used
    // in the GitHub-issue indicator line shown inside the dialog.
    report_issue_repo_slug: string
    // Instance-wide experience mode: "advanced" for developers, "simple" for non-technical users.
    mode: "advanced" | "simple"
    // True once an operator has explicitly chosen a mode (via onboarding or admin settings).
    mode_configured: boolean
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
  unread_notifications_count: number
  csrf_token: string
  feature_flags: Record<string, boolean>
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
