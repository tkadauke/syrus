import { repositoryTabsPayload } from "./repositoryPayloads"

export function scheduledTaskOptions() {
  return {
    kinds: ["cron", "one_shot"],
    pr_pileup_policies: ["skip", "pile", "replace"],
    auto_approve_modes: [
      { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
      { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." }
    ]
  }
}

export function scheduledTaskDetailPayload(overrides: { state?: string; message?: string } = {}) {
  return {
    task: {
      id: 12,
      name: "Weekly tests",
      kind: "cron",
      state: overrides.state || "scheduled",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      schedule_label: "0 9 * * 1",
      schedule_explanation: "Every Monday at 9:00 AM UTC",
      schedule_timezone: "UTC",
      schedule_expression: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
      last_fired_at: null,
      archived_at: null,
      consecutive_failure_count: 0,
      scheduled_task_path: "/scheduled_tasks/12",
      prompt: "Keep tests moving.",
      cron_expression: "0 9 * * 1",
      hourly_cron_expression: "0 9 * * 1",
      schedule_input: "0 9 * * 1",
      schedule_format: "rrule",
      legacy_cron_expression: "0 9 * * 1",
      fire_at: null,
      next_fire_at: "2026-05-31T09:17:00Z",
      pr_pileup_policy: "skip",
      auto_approve_mode: "never",
      auto_approve_preview: "No direct rule; Jobs can still inherit a repository or user default.",
      last_successful_fire_at: null,
      archived: false,
      fireable: true,
      pausable: overrides.state !== "paused",
      resumable: overrides.state === "paused",
      editable: true
    },
    recent_jobs: [
      {
        id: 44,
        state: "open",
        closure_reason: null,
        pr_number: 101,
        external_pr_number: null,
        created_at: "2026-05-30T12:00:00Z",
        job_path: "/jobs/44"
      }
    ],
    options: scheduledTaskOptions(),
    message: overrides.message
  }
}

export function repositoryScheduledTasksPayload(overrides: { state?: string; active?: boolean; message?: string } = {}) {
  const detail = scheduledTaskDetailPayload({ state: overrides.state || "scheduled" }).task
  return {
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    tabs: repositoryTabsPayload(3),
    tasks: [
      {
        ...detail,
        name: "Daily review",
        prompt: "Review the project.",
        active: overrides.active ?? true
      }
    ],
    new_scheduled_task_path: "/repositories/3/scheduled_tasks/new",
    options: scheduledTaskOptions(),
    message: overrides.message
  }
}

export function profilePayload(overrides: Record<string, unknown> = {}) {
  return {
    team_user_count: 2,
    profile: {
      id: 2,
      first_name: "Ada",
      last_name: "Lovelace",
      display_name: "Ada Lovelace",
      github_handle: "ada-lovelace",
      role_label: "Operator",
      profile_bio: "Mathematician and operator.",
      profile_location: "London",
      profile_company: "Analytical Engines Ltd",
      profile_website: "https://example.com/ada",
      avatar_url: null,
      counts: { repositories: 1, epics: 2, jobs: 3, open_jobs: 1 },
      profile_path: "/profiles/2",
      repositories: [{ id: 3, slug: "acme/widgets", path: "/repositories/3" }],
      epics: [],
      jobs: [
        {
          id: 55,
          title: "Add profile page",
          state: "running",
          kind: "issue",
          repository: { id: 3, slug: "acme/widgets", path: "/repositories/3" },
          updated_at: "2026-05-30T12:00:00Z",
          path: "/jobs/55",
          owner: {
            id: 2,
            display_name: "Ada Lovelace",
            profile_path: "/profiles/2"
          }
        }
      ],
      recent_activity: [],
      ...overrides
    }
  }
}

export function credentialsPayload(
  overrides: {
    name?: string
    apiToken?: boolean
    newApiToken?: string
    message?: string
    agentProvider?: string
    chatProvider?: string | null
    chatProviders?: string[]
    codexAuthMode?: string
    codexAuthJson?: boolean
    schedulingPaused?: boolean
  } = {}
) {
  return {
    user: {
      id: 1,
      email_address: "operator@example.com",
      name: overrides.name ?? "Operator",
      handle: "operator",
      first_name: null,
      last_name: null,
      profile_bio: null,
      profile_location: null,
      profile_company: null,
      profile_website: null,
      display_name: overrides.name ?? "Operator",
      github_handle: "operator",
      admin: true,
      agent_provider: overrides.agentProvider ?? "claude",
      chat_provider: overrides.chatProvider ?? null,
      codex_auth_mode: overrides.codexAuthMode ?? "api_key",
      agent_max_turns: 200,
      recent_chats_group_size: 10,
      scheduling_paused: overrides.schedulingPaused ?? false,
      auto_approve_mode: "never"
    },
    credential_status: {
      github_token: true,
      claude_oauth_token: true,
      codex_api_key: false,
      codex_auth_json: overrides.codexAuthJson ?? false,
      api_token: overrides.apiToken ?? false
    },
    github_rate_limit: {
      remaining: 4999,
      limit: 5000,
      resource: "core",
      reset_at: "2026-05-30T13:00:00Z",
      observed_at: "2026-05-30T12:00:00Z"
    },
    options: {
      agent_providers: ["claude", "codex"],
      chat_providers: overrides.chatProviders ?? ["claude"],
      codex_auth_modes: ["api_key", "chatgpt_login"],
      agent_max_turns: { min: 0, max: 1000 },
      recent_chats_group_size: { min: 1, max: 50 },
      clearable_credentials: [
        { value: "github_token", label: "GitHub token" },
        { value: "claude_oauth_token", label: "Claude OAuth token" }
      ],
      auto_approve_modes: [
        { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
        { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." }
      ]
    },
    message: overrides.message,
    new_api_token: overrides.newApiToken
  }
}

export function notificationPreferencesPayload(
  overrides: Partial<
    Record<
      "job_failed" | "job_implemented" | "pr_comment_addressed" | "pr_merged" | "epic_completed" | "main_inconclusive" | "investigation_escalated",
      boolean
    >
  > & { message?: string } = {}
) {
  return {
    notification_preferences: {
      job_failed: overrides.job_failed ?? true,
      job_implemented: overrides.job_implemented ?? true,
      pr_comment_addressed: overrides.pr_comment_addressed ?? true,
      pr_merged: overrides.pr_merged ?? true,
      epic_completed: overrides.epic_completed ?? false,
      main_inconclusive: overrides.main_inconclusive ?? true,
      investigation_escalated: overrides.investigation_escalated ?? true
    },
    message: overrides.message
  }
}

export function personalDocumentsPayload(
  overrides: {
    documents?: Array<Record<string, unknown>>
    message?: string
  } = {}
) {
  return {
    documents: overrides.documents || [],
    message: overrides.message
  }
}

export function repositoryDocumentsPayload(
  overrides: {
    documents?: Array<Record<string, unknown>>
    message?: string
  } = {}
) {
  return {
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    tabs: repositoryTabsPayload(3),
    documents: overrides.documents || [],
    accepted_file_content_types: ["text/markdown", "application/pdf", "image/png"],
    message: overrides.message
  }
}
