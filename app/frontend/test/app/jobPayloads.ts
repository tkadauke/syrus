import { expect } from "vitest"
import type { JobSourcePayload } from "../../api/jobs"

export function jobDetailPayload(overrides: Record<string, unknown> = {}) {
  const payload = {
    job: {
      id: 42,
      kind: "issue",
      state: "open",
      summary_state: "implemented",
      priority: "medium",
      validity: "valid",
      credential_mode: "pat",
      agent_provider: "codex",
      job_provider_setting: "default",
      job_provider_setting_options: [
        { value: "default", label: "Default", configured: true },
        { value: "claude", label: "Claude Code", configured: true },
        { value: "codex", label: "Codex", configured: true }
      ],
      stack_base: "auto",
      issue_number: 12,
      issue_url: "https://github.com/acme/widgets/issues/12",
      issue_title: "Repair aqueduct",
      issue_body: "Water should climb the hill.",
      branch_name: "syrus/issue-12",
      pr_number: 77,
      pr_url: "https://github.com/acme/widgets/pull/77",
      external_pr_number: null,
      external_pr_url: null,
      pr_mergeable: true,
      pr_mergeable_checked_at: "2026-05-30T12:00:00Z",
      closure_reason: null,
      landing_failure_reason: null,
      approved_at: null,
      approved_via: null,
      claimed_at: null,
      claimed_by_user: null,
      claimed_by_current_user: false,
      total_cost_usd: 0.1234,
      billed_runs_count: 1,
      workflows_count: 1,
      runs_count: 1,
      any_active_run: false,
      prepare_skipped: false,
      prepare_skip_reason: null,
      created_at: "2026-05-30T10:00:00Z",
      updated_at: "2026-05-30T12:00:00Z",
      started_at: "2026-05-30T10:01:00Z",
      finished_at: null
    },
    repository: {
      id: 3,
      slug: "acme/widgets",
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      repository_path: "/repositories/3"
    },
    epic: null,
    pinned: false,
    tags: [{ id: 4, name: "priority:forum", color: "gray" }],
    tag_options: [{ id: 4, name: "priority:forum", color: "gray" }],
    dependencies: [],
    dependents: [],
    unsatisfied_dependencies: [],
    dependency_target_options: [{ label: "JOB-41 - Build hill ", value: "issue:3:11" }],
    epic_dependency_target_options: [],
    attachments: [
      {
        id: 8,
        kind: "google_doc",
        attachment_type: "google_doc_link",
        title: "Hydraulic notes",
        filename: null,
        content_type: null,
        byte_size: null,
        google_doc_url: "https://docs.google.com/document/d/aqueduct/edit",
        uploaded_file: false,
        file_path: null,
        created_at: "2026-05-30T10:02:00Z",
        app_delete_path: "/api/v1/app/jobs/42/attachments/8"
      }
    ],
    pr_links: [],
    typed_artifacts: [],
    coverage: null,
    summary: {
      run_id: 9,
      text: "Moved the uphill water simulation.",
      finished_at: "2026-05-30T12:00:00Z"
    },
    test_plan: null,
    feedback_history: [],
    landing_queue_entry: null,
    workflows: [
      {
        id: 5,
        slug: "WF-5",
        path: "/jobs/42?tab=workflows#workflow-5",
        trigger_kind: "initial",
        agent_provider: "codex",
        state: "succeeded",
        failure_count: 0,
        artifacts: {},
        cleaned_up_at: null,
        retry_available: false,
        started_at: "2026-05-30T10:01:00Z",
        finished_at: "2026-05-30T12:00:00Z",
        created_at: "2026-05-30T10:00:00Z",
        updated_at: "2026-05-30T12:00:00Z",
        app_retry_step_path: "/api/v1/app/jobs/42/workflows/5/retry_step",
        app_push_commits_path: "/api/v1/app/jobs/42/workflows/5/push_commits",
        app_force_push_branch_path: "/api/v1/app/jobs/42/workflows/5/force_push_branch",
        app_discard_branch_output_path: "/api/v1/app/jobs/42/workflows/5/discard_branch_output",
        steps: [
          {
            id: 6,
            kind: "implement",
            display_name: "Implement",
            display_status: "succeeded",
            position: 1,
            iteration: null,
            loop_id: null,
            state: "succeeded",
            started_at: "2026-05-30T10:01:00Z",
            finished_at: "2026-05-30T12:00:00Z",
            created_at: "2026-05-30T10:00:00Z",
            updated_at: "2026-05-30T12:00:00Z",
            details: null,
            warnings: [],
            latest: true,
            runs: [
              {
                id: 9,
                state: "succeeded",
                trigger_kind: "initial",
                agent_provider: "codex",
                agent_outcome: "success",
                agent_turns: 4,
                agent_pr_title: "Repair aqueduct",
                agent_summary: "Moved the uphill water simulation.",
                parent_session_id: null,
                skill_source: null,
                skill_resolved_path: null,
                skill_resolved_class: null,
                head_sha: "deadbeef",
                iteration: null,
                started_at: "2026-05-30T10:01:00Z",
                last_heartbeat_at: "2026-05-30T11:59:00Z",
                finished_at: "2026-05-30T12:00:00Z",
                created_at: "2026-05-30T10:00:00Z",
                updated_at: "2026-05-30T12:00:00Z",
                cost_usd: 0.1234,
                input_tokens: 1200,
                output_tokens: 300,
                agent_diff_present: true,
                agent_diff_bytes: 2048,
                step_agent_diff_present: false,
                step_agent_diff_bytes: 0,
                step_diff_matches_diff: false,
                job_log_count: 12,
                rate_limited: false,
                run_diagnostic: null,
                health_snapshots: [],
                agent_session: { session_id: "session-9", provider: "codex", transcript_pruned: false, transcript_bytes: 1024, transcript_lines: 12 },
                can_stop: false,
                can_diagnose: false,
                can_resume: false,
                app_artifacts_path: "/api/v1/app/jobs/42/runs/9/artifacts",
                app_stop_path: "/api/v1/app/jobs/42/runs/9/stop",
                app_diagnose_path: "/api/v1/app/jobs/42/runs/9/diagnose",
                app_resume_path: "/api/v1/app/jobs/42/resume",
                app_grade_log_path: null
              }
            ]
          }
        ]
      }
    ],
    workflows_pagination: {
      page: 1,
      per_page: 10,
      total_workflows: 1,
      total_pages: 1,
      first_item: 1,
      last_item: 1,
      previous_path: null,
      next_path: null
    },
    actions: {
      can_start: false,
      can_release_from_backlog: false,
      can_poll_feedback: true,
      can_rebase: true,
      can_check_mergeability: true,
      can_run_visual_review: false,
      can_run_visual_diff: false,
      can_retry: true,
      can_retry_from_failed_step: false,
      can_restart: false,
      can_cancel: true,
      can_stop_landing: false,
      can_approve: true,
      can_unapprove: false,
      can_reopen: false,
      can_mark_valid: false,
      can_claim: true,
      can_unclaim: false,
      can_override_dependencies: false,
      can_view_timeline: false,
      can_manage_tags: true,
      feedback_agent_options: [],
      rebase_agent_options: [],
      retry_agent_options: []
    },
    paths: {
      job_path: "/jobs/42",
      source_path: "/jobs/42/source",
      app_detail_path: "/api/v1/app/jobs/42",
      app_source_path: "/api/v1/app/jobs/42/source",
      app_timeline_path: "/api/v1/app/jobs/42/timeline",
      app_start_path: "/api/v1/app/jobs/42/start",
      app_release_from_backlog_path: "/api/v1/app/jobs/42/release_from_backlog",
      app_run_again_path: "/api/v1/app/jobs/42/run_again",
      app_restart_path: "/api/v1/app/jobs/42/restart",
      app_cancel_path: "/api/v1/app/jobs/42/cancel",
      app_stop_landing_path: "/api/v1/app/jobs/42/stop_landing",
      app_approve_path: "/api/v1/app/jobs/42/approve",
      app_unapprove_path: "/api/v1/app/jobs/42/unapprove",
      app_reopen_path: "/api/v1/app/jobs/42/reopen",
      app_poll_feedback_path: "/api/v1/app/jobs/42/poll_feedback",
      app_rebase_path: "/api/v1/app/jobs/42/rebase",
      app_check_mergeability_path: "/api/v1/app/jobs/42/check_mergeability",
      app_visual_review_path: "/api/v1/app/jobs/42/visual_review",
      app_visual_diff_path: "/api/v1/app/jobs/42/visual_diff",
      app_resume_path: "/api/v1/app/jobs/42/resume",
      app_tags_path: "/api/v1/app/jobs/42/tags",
      app_claim_path: "/api/v1/app/jobs/42/claim",
      app_dependencies_path: "/api/v1/app/jobs/42/dependencies",
      app_epic_dependencies_path: "/api/v1/app/jobs/42/epic_dependencies",
      app_dependency_override_path: "/api/v1/app/admin/jobs/42/dependencies/override",
      app_stack_base_path: "/api/v1/app/jobs/42/stack_base",
      app_mark_valid_path: "/api/v1/app/jobs/42/mark_valid",
      app_attachments_path: "/api/v1/app/jobs/42/attachments",
      app_pin_path: "/api/v1/app/jobs/42/pin"
    }
  }

  return {
    ...payload,
    ...overrides,
    job: { ...payload.job, ...objectOverrides(overrides.job) },
    repository: { ...payload.repository, ...objectOverrides(overrides.repository) },
    summary: overrides.summary === undefined ? payload.summary : overrides.summary,
    landing_queue_entry: overrides.landing_queue_entry === undefined ? payload.landing_queue_entry : overrides.landing_queue_entry,
    workflows_pagination: { ...payload.workflows_pagination, ...objectOverrides(overrides.workflows_pagination) },
    actions: { ...payload.actions, ...objectOverrides(overrides.actions) },
    paths: { ...payload.paths, ...objectOverrides(overrides.paths) }
  }
}

export function objectOverrides(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

export function expectRunningPill(label: HTMLElement) {
  const pill = label.closest("[data-status-pill='true']")

  expect(pill).toHaveClass("bg-info-surface", "text-info-text")
  expect(pill?.querySelector("[data-running-spinner='true']")).toHaveClass("animate-spin")
}

export function jobTimelinePayload() {
  return {
    job_id: 42,
    events: [
      {
        at: "2026-05-30T10:00:00Z",
        kind: "created",
        source: "workflow",
        transition_source: null,
        title: "Workflow created",
        detail: "Initial workflow queued.",
        ref: { workflow_id: 5 },
        ref_label: "WF-5",
        workflow_path: "/jobs/42?tab=workflows#workflow-5"
      }
    ]
  }
}

export function jobWaterfallPayload(overrides: { workflowId?: number; triggerKind?: string; status?: string; admin?: boolean } = {}) {
  const workflowId = overrides.workflowId ?? 5
  const identityFields = overrides.admin ? { hostname: "worker-a", pid: 4242 } : {}
  return {
    workflow: {
      id: workflowId,
      job_id: 42,
      trigger_kind: overrides.triggerKind ?? "initial",
      status: overrides.status ?? "succeeded",
      started_at: "2026-05-30T10:01:00Z",
      finished_at: overrides.status === "running" ? null : "2026-05-30T12:00:00Z",
      ...identityFields
    },
    steps: [
      {
        id: workflowId * 10,
        kind: "implement",
        status: "succeeded",
        position: 1,
        iteration: 1,
        started_at: "2026-05-30T10:01:00Z",
        finished_at: "2026-05-30T11:00:00Z",
        ...identityFields,
        runs: [
          {
            id: workflowId * 100,
            status: "succeeded",
            iteration: 1,
            started_at: "2026-05-30T10:01:00Z",
            finished_at: "2026-05-30T11:00:00Z",
            last_heartbeat_at: "2026-05-30T10:59:00Z"
          }
        ]
      }
    ]
  }
}

export function jobSourcePayload(overrides: { withFile?: boolean; treeItems?: JobSourcePayload["tree_items"]; treePath?: string } = {}) {
  return {
    job_id: 42,
    repository: { id: 3, slug: "acme/widgets", default_branch: "main", repository_path: "/repositories/3" },
    branch_name: "syrus/issue-12",
    default_ref: "main",
    selected_ref: "deadbeef12345678",
    selected_path: overrides.withFile ? "app/models/user.rb" : null,
    tree_path: overrides.treePath ?? "",
    merge_base_sha: "aabbccdd1234567",
    branch_commits: [{ sha: "deadbeef12345678", short_sha: "deadbee", message: "Repair aqueduct", date: "2026-05-30T11:00:00Z" }],
    tree_items: overrides.treeItems ?? [
      { path: "app", name: "app", size: 0, language: "plaintext", type: "directory" },
      { path: "README.md", name: "README.md", size: 128, language: "markdown", type: "file" }
    ],
    tree_truncated: false,
    file: overrides.withFile ? { path: "app/models/user.rb", name: "user.rb", size: 15, language: "ruby", content: "class User\nend\n" } : null,
    source_error: null,
    file_error: null,
    paths: {
      job_path: "/jobs/42",
      source_path: "/jobs/42/source",
      app_source_path: "/api/v1/app/jobs/42/source"
    }
  }
}

export function jobSourceDiffPayload(overrides: { baseRef?: string; headRef?: string } = {}) {
  return {
    job_id: 42,
    base_ref: overrides.baseRef || "aabbccdd1234567",
    head_ref: overrides.headRef || "deadbeef12345678",
    merge_base_sha: "aabbccdd1234567",
    default_ref: "main",
    branch_commits: [{ sha: "deadbeef12345678", short_sha: "deadbee", message: "Repair aqueduct", date: "2026-05-30T11:00:00Z" }],
    files: [
      { path: "app/models/user.rb", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" },
      { path: "pycon/tests/unit/homes/helpers/yaml/__init__.py", status: "added", additions: 0, deletions: 0, patch: null }
    ],
    truncated: false,
    diff_error: null,
    version: {
      id: 100,
      version_index: 1,
      base_sha: overrides.baseRef || "aabbccdd1234567",
      head_sha: overrides.headRef || "deadbeef12345678",
      label: "Version 1",
      reason: "initial"
    },
    versions: [
      {
        id: 100,
        version_index: 1,
        base_sha: overrides.baseRef || "aabbccdd1234567",
        head_sha: overrides.headRef || "deadbeef12345678",
        label: "Version 1",
        reason: "initial",
        created_at: null
      }
    ]
  }
}
