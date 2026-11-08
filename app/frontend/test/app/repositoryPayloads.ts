import { App } from "../../routes/App"
import { setupStatusPayload } from "./bootstrap"

export function directJobFormPayload() {
  return {
    repositories: [
      {
        id: 3,
        slug: "acme/widgets",
        repository_path: "/repositories/3",
        default_agent_provider: "codex",
        default_agent_provider_label: "Codex"
      }
    ],
    configured_agent_providers: [
      { value: "claude", label: "Claude Code" },
      { value: "codex", label: "Codex" }
    ],
    provider_routing_options: {
      agent_providers: [
        { value: "claude", label: "Claude Code", models: [] },
        { value: "codex", label: "Codex", models: [] }
      ],
      effort_levels: []
    },
    selected_repository_id: "3",
    selected_agent_provider: null,
    selected_model: null,
    selected_effort_level: null,
    selected_epic_id: null,
    epic: null,
    create_more: true,
    prompt_templates: [
      {
        id: "configure-syrus-prep",
        name: "Configure Syrus build dependencies",
        description: "Detect package managers and write .syrus.yml.",
        prompt: "Write a .syrus.yml setup file."
      }
    ],
    priorities: [
      { value: "urgent", label: "Urgent", description: "Runs before all other priorities" },
      { value: "high", label: "High", description: "Runs before medium and low" },
      { value: "medium", label: "Medium", description: "Default" },
      { value: "low", label: "Low", description: "Yields to higher-priority jobs" }
    ],
    accepted_file_content_types: ["text/markdown", "application/pdf", "image/png"],
    new_repository_path: "/repositories/new",
    dashboard_jobs_path: "/dashboard/jobs"
  }
}

export function repositoriesPayload(
  overrides: {
    active_repositories?: Array<Record<string, unknown>>
    archived_repositories?: Array<Record<string, unknown>>
    message?: string
    setup?: Record<string, unknown>
  } = {}
) {
  return {
    active_repositories: overrides.active_repositories ?? [
      {
        id: 3,
        slug: "acme/widgets",
        owner: "acme",
        name: "widgets",
        owner_user: {
          id: 9,
          display_name: "Operator",
          email_address: "operator@example.com",
          admin: true,
          profile_path: "/profiles/9"
        },
        default_branch: "main",
        upstream_owner: "rails",
        upstream_name: "rails",
        upstream_default_branch: "main",
        upstream_slug: "rails/rails",
        trigger_label: "syrus",
        polling_enabled: true,
        archived: false,
        archived_at: null,
        agent_provider: "codex",
        agent_provider_label: "Codex",
        main_health: "unknown",
        open_jobs_count: 0,
        last_job_activity_at: null,
        last_poll_status: "ok",
        last_poll_started_at: "2026-05-30T12:00:00Z",
        last_poll_error: null,
        can_edit: true,
        repository_path: "/repositories/3",
        edit_repository_path: "/repositories/3/edit"
      }
    ],
    archived_repositories: overrides.archived_repositories ?? [
      {
        id: 4,
        slug: "old/repo",
        owner: "old",
        name: "repo",
        owner_user: {
          id: 9,
          display_name: "Operator",
          email_address: "operator@example.com",
          admin: true,
          profile_path: "/profiles/9"
        },
        default_branch: "main",
        upstream_owner: null,
        upstream_name: null,
        upstream_default_branch: null,
        upstream_slug: null,
        trigger_label: "syrus",
        polling_enabled: false,
        archived: true,
        archived_at: "2026-05-29T12:00:00Z",
        agent_provider: null,
        agent_provider_label: "default",
        main_health: "unknown",
        open_jobs_count: 0,
        last_job_activity_at: null,
        last_poll_status: null,
        last_poll_started_at: null,
        last_poll_error: null,
        can_edit: true,
        repository_path: "/repositories/4",
        edit_repository_path: "/repositories/4/edit"
      }
    ],
    new_repository_path: "/repositories/new",
    setup:
      overrides.setup ??
      setupStatusPayload({
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
        },
        credentials: {
          github_token: true,
          selected_agent_provider: "codex",
          selected_agent_provider_configured: true,
          configured_agent_providers: ["codex"],
          ready: true
        },
        repositories: {
          active_count: 1,
          any_app_credential_active: false,
          any_pat_fallback: true,
          first: {
            id: 3,
            slug: "acme/widgets",
            trigger_label: "syrus",
            credential_mode: "pat",
            repository_path: "/repositories/3",
            issues_path: "/repositories/3/plugin/issues"
          }
        }
      }),
    smart_folders: [
      {
        id: 1,
        name: "All",
        i18n_key: "repositories_all",
        position: 0,
        kind: "builtin",
        subject_type: "repository",
        visibility: "always",
        count: 2,
        active: true,
        filter: { and: [] },
        path: "/repositories?smart_folder_id=1"
      },
      {
        id: 2,
        name: "Recent",
        i18n_key: "repositories_recent",
        position: 1,
        kind: "builtin",
        subject_type: "repository",
        visibility: "always",
        count: 0,
        active: false,
        filter: { and: [] },
        path: "/repositories?smart_folder_id=2"
      },
      {
        id: 3,
        name: "Archived",
        i18n_key: "repositories_archived",
        position: 2,
        kind: "builtin",
        subject_type: "repository",
        visibility: "always",
        count: 1,
        active: false,
        filter: { and: [] },
        path: "/repositories?smart_folder_id=3"
      }
    ],
    active_smart_folder_id: null,
    filter: { and: [] },
    filter_schema: [
      { field: "slug", label: "Repository", bucket: "string", operators: ["contains"], free_text_search: true },
      { field: "github_owner", label: "GitHub owner", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [] },
      {
        field: "health",
        label: "Health",
        bucket: "enum",
        operators: ["is", "is_not", "is_one_of", "is_none_of"],
        values: [
          { value: "healthy", label: "Healthy" },
          { value: "broken", label: "Broken" },
          { value: "inconclusive", label: "Inconclusive" },
          { value: "unknown", label: "Unknown" }
        ]
      },
      { field: "agent_provider", label: "Agent", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [] },
      { field: "has_open_jobs", label: "Has open jobs", bucket: "boolean", operators: ["is_true", "is_false"] }
    ],
    message: overrides.message
  }
}

export function repositoryFormPayload(
  overrides: Partial<{
    repository: Record<string, unknown>
  }> = {}
) {
  return {
    repository: overrides.repository || {
      id: null,
      owner: "",
      name: "",
      slug: null,
      default_branch: "main",
      upstream_owner: "",
      upstream_name: "",
      upstream_default_branch: "",
      trigger_label: "syrus",
      polling_enabled: true,
      prepare_enabled: true,
      pr_cost_footer_enabled: true,
      auto_merge_enabled: false,
      trust_clean_rebase_grade: false,
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      main_branch_repair_blocks_work: true,
      main_branch_repair_auto_approve: false,
      treat_grader_timeouts_as_failures: false,
      agent_provider: "",
      auto_approve_mode: "never",
      feedback_policy: "confirm",
      github_owner_id: null,
      github_repository_id: null,
      repository_path: null
    },
    configured_agent_providers: [
      { value: "claude", label: "Claude Code" },
      { value: "codex", label: "Codex" }
    ],
    user_agent_provider_label: "Claude Code",
    auto_approve_modes: [
      { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
      { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." },
      {
        value: "if_graders_pass_and_tagged_safe",
        label: "If graders pass and tagged safe",
        preview: "Jobs using this rule also need the safe tag before landing."
      }
    ],
    repositories_path: "/repositories"
  }
}

export function closedProviderCircuit(provider: string) {
  return {
    provider,
    open: false,
    reason: null,
    retry_after: null,
    failure_count: 0,
    job_count: 0,
    signature: null
  }
}

export function repositoryTabsPayload(repositoryId: number) {
  return [
    { key: "overview", label: "Overview", path: `/repositories/${repositoryId}` },
    { key: "github_issues", label: "GitHub Issues", path: `/repositories/${repositoryId}?tab=github_issues` },
    { key: "documents", label: "Documents", path: `/repositories/${repositoryId}/documents` },
    { key: "scheduled_tasks", label: "Scheduled Tasks", path: `/repositories/${repositoryId}/scheduled_tasks` }
  ]
}

export function repositoryDetailPayload() {
  return {
    message: null,
    repository: {
      id: 3,
      slug: "acme/widgets",
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      upstream_owner: "rails",
      upstream_name: "rails",
      upstream_default_branch: "main",
      upstream_slug: "rails/rails",
      trigger_label: "syrus",
      polling_enabled: true,
      archived: false,
      effective_agent_provider: "codex",
      effective_agent_provider_label: "Codex",
      github_url: "https://github.com/acme/widgets",
      created_at: "2026-05-30T12:00:00Z",
      owner_user: {
        id: 9,
        display_name: "Operator",
        email_address: "operator@example.com",
        admin: true,
        profile_path: "/profiles/9"
      },
      github_rate_limit: {
        remaining: 4990,
        limit: 5000,
        resource: "core",
        observed_at: "2026-05-30T12:00:00Z"
      }
    },
    tabs: repositoryTabsPayload(3),
    counts: {
      running: 1,
      queued: 1,
      failed_7d: 1
    },
    provider_retry_status: {
      agent_provider: "codex",
      agent_provider_label: "Codex",
      provider_circuit: closedProviderCircuit("codex")
    },
    can_edit: true,
    credential_status: {
      mode: "pat",
      label: "PAT fallback: no active App installation",
      installation_account: null,
      github_app_registered: true,
      install_url: "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=100&repository_ids[]=200",
      register_path: null,
      previous_installation_removed: false,
      missing_github_ids: false
    },
    jobs: [
      {
        id: 44,
        state: "open",
        priority: "high",
        issue_number: 1,
        issue_title: "Fix forum",
        job_path: "/jobs/44",
        source: {
          label: "#1",
          path: "https://github.com/acme/widgets/issues/1",
          external: true
        },
        pr_number: 12,
        pr_url: "https://github.com/acme/widgets/pull/12",
        external_pr_number: null,
        external_pr_url: null,
        current_step_caption: "currently: Implement (workflow: Initial)",
        runs_count: 2,
        updated_at: "2026-05-30T12:00:00Z"
      }
    ],
    pagination: {
      page: 1,
      per_page: 20,
      total_jobs: 1,
      total_pages: 1,
      first_item: 1,
      last_item: 1,
      previous_path: null,
      next_path: null
    },
    paths: {
      new_job_path: "/jobs/new?repository_id=3",
      new_repository_skill_job_path: "/repositories/3/skills/new",
      edit_repository_path: "/repositories/3/edit",
      app_poll_repository_path: "/api/v1/app/repositories/3/poll",
      app_archive_repository_path: "/api/v1/app/repositories/3/archive",
      repositories_path: "/repositories",
      repository_documents_path: "/repositories/3/documents",
      repository_scheduled_tasks_path: "/repositories/3/scheduled_tasks",
      app_flaky_tests_path: "/api/v1/app/repositories/3/flaky_tests"
    }
  }
}

export function repositoryIssuesPayload(overrides: { message?: string; delegated?: boolean } = {}) {
  const detail = repositoryDetailPayload()
  return {
    message: overrides.message || null,
    error_message: null,
    repository: detail.repository,
    tabs: detail.tabs,
    state: "open",
    issue_count: 1,
    issues: [
      {
        number: 7,
        title: "Fix the forum",
        state: "open",
        html_url: "https://github.com/acme/widgets/issues/7",
        body_excerpt: "The forum is missing tasteful columns.",
        user_login: "alice",
        created_at: "2026-05-30T12:00:00Z",
        labels: [{ name: "bug", color: "0075ca" }],
        delegated: overrides.delegated || false
      }
    ],
    state_paths: {
      open: "/repositories/3?tab=github_issues&state=open",
      closed: "/repositories/3?tab=github_issues&state=closed"
    },
    paths: {
      github_issues_path: "https://github.com/acme/widgets/issues",
      app_close_issue_path: "/api/v1/app/repositories/3/issues/close",
      app_delegate_issue_path: "/api/v1/app/repositories/3/issues/delegate",
      app_bulk_issues_path: "/api/v1/app/repositories/3/issues/bulk"
    }
  }
}

export function epicFormPayload() {
  return {
    epic: {
      id: null,
      title: "",
      description: "",
      owner_user_id: null,
      owner_status: "unclaimed",
      owner_user: null,
      repository_id: null,
      github_issue_url: "",
      epic_path: null
    },
    repositories: [
      {
        id: 3,
        slug: "acme/widgets"
      }
    ],
    dashboard_epics_path: "/dashboard/epics"
  }
}

export function epicDetailPayload(
  overrides: {
    message?: string
    state?: string
    stateTransitions?: Array<Record<string, unknown>>
    epic?: Record<string, unknown>
    dependencies?: Array<Record<string, unknown>>
    dependents?: Array<Record<string, unknown>>
    jobs?: Array<Record<string, unknown>>
  } = {}
) {
  return {
    message: overrides.message,
    epic: {
      id: 7,
      number: 7,
      display_number: "EPIC-7",
      title: "Raise the forum",
      description: "Build **columns**.",
      state: overrides.state || "ready",
      stuck: false,
      owner: null,
      owned_by_current_user: false,
      claimable: true,
      claimed_at: null,
      github_issue_url: "https://github.com/acme/widgets/issues/12",
      updated_at: "2026-05-30T12:00:00Z",
      archived: false,
      jobs_count: 1,
      epic_path: "/epics/7",
      owner_user_id: null,
      owner_status: "unclaimed",
      owner_user: null,
      repository: {
        id: 3,
        slug: "acme/widgets",
        repository_path: "/repositories/3"
      },
      ...overrides.epic
    },
    summary: {
      done_jobs_count: 1,
      total_jobs_count: 1,
      dependency_edge_count: 1,
      blocked: false,
      blocked_reason: null
    },
    state_transitions: overrides.stateTransitions || [
      { label: "Move to backlog", target_state: "backlog", confirm: null },
      { label: "Start", target_state: "in_progress", confirm: null },
      { label: "Archive", target_state: "archived", confirm: "Archive this Epic?" }
    ],
    graph: {
      empty: false,
      node_count: 2,
      epic_dependency_count: 1,
      job_blocker_count: 0,
      initially_open: true,
      nodes: [
        { id: "epic_7", kind: "epic", label: "EPIC-7 Raise the forum", state: "ready", epic_id: 7, url: "/epics/EPIC-7", is_focal: true },
        {
          id: "epic_6",
          kind: "epic",
          label: "the Kubernetes write-tool feature Deliver marble",
          state: "done",
          epic_id: 6,
          url: "/epics/the Kubernetes write-tool feature",
          is_focal: false
        }
      ],
      edges: [{ from_id: "epic_7", to_id: "epic_6" }]
    },
    dependencies: overrides.dependencies || [{ epic_id: 6, title: "Deliver marble", state: "done", url: "/epics/6" }],
    dependents: overrides.dependents || [],
    jobs: overrides.jobs || [
      {
        id: 42,
        label: "#12",
        title: "Survey forum",
        path: "/jobs/42",
        state: "closed",
        owner_user_id: null,
        owner_user: null,
        repository_slug: "acme/widgets"
      }
    ],
    paths: {
      dashboard_epics_path: "/dashboard/epics",
      edit_epic_path: "/epics/7/edit",
      app_state_path: "/api/v1/app/epics/7/state",
      app_archive_path: "/api/v1/app/epics/7/archive",
      app_claim_path: "/api/v1/app/epics/7/claim",
      app_unclaim_path: "/api/v1/app/epics/7/unclaim",
      app_reassign_path: "/api/v1/app/epics/7/reassign",
      app_dependencies_path: "/api/v1/app/epics/7/dependencies",
      app_unland_path: "/api/v1/app/epics/7/unland"
    }
  }
}
