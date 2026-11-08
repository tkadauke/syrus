import { it } from "vitest"
import { App } from "../../routes/App"
import type { BootstrapPayload } from "../../api/bootstrap"

// A signed-in operator partway through onboarding: credentials + repo done,
// but the onboarding chat has not started and no Epic has landed.
export function incompleteOnboardingBootstrap() {
  return bootstrapPayload({
    setup: setupStatusPayload({ complete: false, chat_started: false, next_step: "chat" }),
    setup_status: setupStatus({
      state: "ready_for_first_chat",
      next_step: "start_first_chat",
      next_step_path: "/onboarding",
      first_successful_job_completed: false,
      first_epic_created: false,
      first_epic_started: false,
      first_epic_landed: false,
      onboarding_chat_started: false
    })
  })
}

export function sidebarPluginPagesPayload() {
  return {
    pages: [
      {
        id: "spending.dashboard",
        label: "Spending",
        label_key: "spending:nav_spending",
        path: "/insights/spending",
        paths: ["/insights/spending"],
        component: "spending_insights/SpendingInsights",
        icon: "spending",
        order: 60
      }
    ]
  }
}

export function bootstrapPayload(overrides: Record<string, unknown> & { setupStatus?: ReturnType<typeof bootstrapSetupStatusPayload> | null } = {}) {
  const { setupStatus: setupStatusOverride, setup_status: setupStatusPayloadOverride, ...payloadOverrides } = overrides

  return {
    current_user: {
      id: 1,
      email_address: "operator@example.com",
      name: "Operator",
      first_name: null,
      last_name: null,
      display_name: "Operator",
      admin: true,
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      agent_max_turns: 200,
      theme: "light"
    },
    team_user_count: 1,
    app: {
      revision: "dev",
      revision_url: null
    },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    navigation: {
      default_chat_path: "/chats/9"
    },
    setup: setupStatusPayload({
      complete: true,
      next_step: "complete",
      progress: {
        completed: 4,
        total: 4,
        steps: [
          { key: "credentials", label: "Add credentials", complete: true },
          { key: "repository", label: "Add a repository", complete: true },
          { key: "first_job", label: "Start the first Job", complete: true },
          { key: "watch_job", label: "Watch the first successful Job or PR", complete: true }
        ]
      }
    }),
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    setup_status: setupStatusOverride ?? (setupStatusPayloadOverride as ReturnType<typeof bootstrapSetupStatusPayload> | undefined) ?? defaultSetupStatus(),
    slug_refs: {
      types: [
        {
          prefix: "JOB",
          type: "job",
          display_label: "Job",
          copyable: true,
          linkable: true,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: "/jobs/JOB-:id",
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        },
        {
          prefix: "EPIC",
          type: "epic",
          display_label: "Epic",
          copyable: true,
          linkable: true,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: "/epics/EPIC-:id",
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        },
        {
          prefix: "CHAT",
          type: "chat",
          display_label: "Chat",
          copyable: true,
          linkable: false,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: null,
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        },
        {
          prefix: "DOC",
          type: "design_doc",
          display_label: "Design Doc",
          copyable: true,
          linkable: true,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: "/design_docs/:id",
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        }
      ]
    },
    feature_flags: {},
    ...payloadOverrides
  }
}

export function appendBootstrapScript(payload: unknown = bootstrapPayload()) {
  const script = document.createElement("script")
  script.id = "syrus-bootstrap-data"
  script.type = "application/json"
  script.textContent = JSON.stringify(payload)
  document.body.appendChild(script)
  return script
}

export function defaultSetupStatus() {
  return setupStatus()
}

export function setupStatus(overrides: Record<string, unknown> = {}) {
  return {
    state: "first_successful_job",
    next_step: null,
    next_step_path: null,
    first_admin: true,
    credentials_configured: true,
    repository_configured: true,
    first_job_started: true,
    first_successful_job_completed: true,
    first_epic_created: true,
    first_epic_started: true,
    first_epic_landed: true,
    onboarding_chat_started: true,
    credential_status: {
      github: true,
      agent: true,
      active_agent_provider: "claude"
    },
    readiness: {
      status: "ok",
      checks: []
    },
    counts: {
      repositories: 1,
      jobs: 1,
      successful_jobs: 1
    },
    ...overrides
  }
}

export function setupStatusPayload(overrides: Record<string, unknown> = {}) {
  return {
    complete: false,
    chat_started: false,
    onboarding_chat_path: null,
    next_step: "credentials",
    progress: {
      completed: 0,
      total: 4,
      steps: [
        { key: "credentials", label: "Add credentials", complete: false },
        { key: "repository", label: "Add a repository", complete: false },
        { key: "chat", label: "Meet Syrus in chat", complete: false },
        { key: "epic", label: "Land your first Epic", complete: false }
      ]
    },
    credentials: {
      github_token: false,
      selected_agent_provider: "claude",
      selected_agent_provider_configured: false,
      configured_agent_providers: [],
      ready: false
    },
    system: {
      data_root: "~/.syrus",
      revision: "dev",
      polling_paused: false,
      runs_paused: false,
      ready: true
    },
    github_app: {
      registered: false,
      explanation:
        "Repositories use a GitHub App installation when one is active for that owner. Syrus falls back to your GitHub PAT for repositories without an active installation.",
      register_path: "/admin/github_app/register",
      installations_path: "/admin/installations"
    },
    repositories: {
      active_count: 0,
      any_app_credential_active: false,
      any_pat_fallback: false,
      first: null
    },
    first_job: {
      any: false,
      successful: false,
      job: null
    },
    paths: {
      setup_path: "/setup",
      credentials_path: "/credentials",
      new_repository_path: "/repositories/new",
      repositories_path: "/repositories",
      new_job_path: "/jobs/new",
      dashboard_jobs_path: "/dashboard/jobs"
    },
    ...overrides
  }
}

// Marks the jsdom navigator as the desktop shell (isDesktopShell matches the
// SyrusDesktop/ UA token). Returns a restore function — call it in finally.
export function stubDesktopUserAgent() {
  const original = window.navigator.userAgent
  Object.defineProperty(window.navigator, "userAgent", {
    value: `${original} SyrusDesktop/1.0`,
    configurable: true
  })
  return () => {
    Object.defineProperty(window.navigator, "userAgent", { value: original, configurable: true })
  }
}

export function publicBootstrapPayload(overrides: Partial<BootstrapPayload["public"]> = {}) {
  return {
    ...bootstrapPayload(),
    current_user: null,
    navigation: {
      default_chat_path: "/session/new"
    },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose",
      ...overrides
    }
  }
}

export function bootstrapSetupStatusPayload(
  overrides: { nextStep?: "configure_credentials" | "add_repository" | "start_first_job" | "watch_first_job" | null } = {}
) {
  const nextStep = overrides.nextStep ?? "start_first_job"
  const nextStepPath =
    {
      configure_credentials: "/credentials",
      add_repository: "/repositories/new",
      start_first_job: "/jobs/new",
      watch_first_job: "/dashboard/jobs?view=list"
    }[nextStep || "start_first_job"] || null

  return {
    state:
      nextStep === "configure_credentials"
        ? "not_started"
        : nextStep === "add_repository"
          ? "credentials_only"
          : nextStep === "start_first_job"
            ? "ready_for_first_job"
            : nextStep === "watch_first_job"
              ? "first_job_started"
              : "first_successful_job",
    next_step: nextStep,
    next_step_path: nextStep ? nextStepPath : null,
    first_admin: false,
    credentials_configured: nextStep !== "configure_credentials",
    repository_configured: nextStep === "start_first_job" || nextStep === "watch_first_job" || nextStep === null,
    first_job_started: nextStep === "watch_first_job" || nextStep === null,
    first_successful_job_completed: nextStep === null,
    credential_status: {
      github: nextStep !== "configure_credentials",
      agent: nextStep !== "configure_credentials",
      active_agent_provider: "claude"
    },
    readiness: {
      status: "ok",
      checks: []
    },
    counts: {
      repositories: nextStep === "add_repository" || nextStep === "configure_credentials" ? 0 : 1,
      jobs: nextStep === "watch_first_job" || nextStep === null ? 1 : 0,
      successful_jobs: nextStep === null ? 1 : 0
    }
  }
}
