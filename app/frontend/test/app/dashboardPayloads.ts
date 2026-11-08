import { jsonResponse } from "../../testSupport"
import { screen } from "@testing-library/react"
import { expect, vi } from "vitest"
import { setupStatusPayload } from "./bootstrap"

export function dashboardPayload(overrides: Record<string, unknown> = {}) {
  const payload = {
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 1,
    total_pages: 1,
    counts: {
      jobs: 4,
      epics: 2,
      workflows: 6
    },
    preferences: {
      sort: { column: "created_at", direction: "desc" },
      visible_columns: ["checkbox", "issue", "state", "repository", "latest", "workflows_count", "started"],
      kanban_lanes: ["queued", "running", "succeeded"],
      ownership_scope: "team",
      owner_user_id: null,
      owner_id: null
    },
    controls: {
      views: ["list", "kanban"],
      ownership_scopes: [
        { value: "mine", label: "Mine" },
        { value: "team", label: "Team" },
        { value: "claimable", label: "Claimable" },
        { value: "user", label: "User" }
      ],
      owners: [
        { id: 1, label: "Operator", current: true },
        { id: 2, label: "Teammate", current: false }
      ],
      sort_columns: ["title", "state", "repository", "created_at", "started_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [
          { key: "checkbox", title: "Checkbox" },
          { key: "issue", title: "Issue" }
        ],
        optional: [
          { key: "state", title: "State" },
          { key: "repository", title: "Repository" },
          { key: "owner", title: "Owner" },
          { key: "latest", title: "Latest" },
          { key: "workflows_count", title: "Workflows count" },
          { key: "started", title: "Started" },
          { key: "created_at", title: "Created at" },
          { key: "updated_at", title: "Updated at" }
        ]
      },
      kanban_lanes: [
        { key: "blocked", title: "Blocked" },
        { key: "queued", title: "Queued" },
        { key: "running", title: "Running" },
        { key: "succeeded", title: "Succeeded" },
        { key: "landing", title: "Landing" },
        { key: "failed", title: "Failed" }
      ],
      filter_suggestions: [],
      filter_schema: [
        {
          field: "state",
          label: "State",
          bucket: "enum",
          operators: ["is"],
          values: [
            { value: "open", label: "Any open" },
            { value: "closed", label: "Closed or merged" }
          ]
        },
        {
          field: "repository_id",
          label: "Repository",
          bucket: "fk",
          operators: ["is"],
          values: [{ value: 3, label: "acme/widgets" }]
        },
        {
          field: "kind",
          label: "Kind",
          bucket: "enum",
          operators: ["is"],
          values: ["issue", "cron", "direct"]
        },
        {
          field: "has_parent",
          label: "Has parent",
          bucket: "boolean",
          operators: ["is_true", "is_false"],
          values: []
        },
        {
          field: "attention",
          label: "Preset",
          bucket: "preset",
          operators: ["is"],
          values: [
            { value: "merged_this_week", label: "Merged this week" },
            { value: "inbox", label: "Inbox" }
          ]
        }
      ]
    },
    filter: { and: [] },
    landing_queue: {
      visible: false,
      paused: false,
      toggle_path: "/api/v1/app/dashboard/landing_pause"
    },
    ownership_scope: {
      scope: "team",
      owner_user_id: null,
      owner_user: null
    },
    ownership: {
      scope: "team",
      owner_id: null,
      team_user_count: 1,
      badges_visible: false
    },
    smart_folders: [
      {
        id: 7,
        name: "My work",
        kind: "user_defined",
        subject_type: "job",
        visibility: "user_defined",
        count: 1,
        active: false,
        path: "/dashboard/jobs?smart_folder_id=7"
      }
    ],
    active_smart_folder_id: null,
    items: [],
    lanes: [],
    kanban_limit: null,
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
    paths: {
      dashboard_path: "/dashboard",
      dashboard_jobs_path: "/dashboard/jobs",
      dashboard_epics_path: "/dashboard/epics",
      dashboard_workflows_path: "/dashboard/workflows",
      new_epic_path: "/epics/new",
      new_job_path: "/jobs/new",
      app_dashboard_path: "/api/v1/app/dashboard"
    }
  }

  const merged = {
    ...payload,
    ...overrides
  }
  const activeFolder = (merged.smart_folders as Array<{ id: number; filter?: Record<string, unknown> }>).find(
    (folder) => folder.id === merged.active_smart_folder_id
  )

  return {
    ...merged,
    active_smart_folder_filter: activeFolder?.filter ?? null
  }
}

export function dashboardPayloadPath(url: URL) {
  return url.pathname === "/api/v1/app/dashboard" || url.pathname === "/api/v1/app/dashboard/controls"
}

export function dashboardPathMatches(input: unknown, expectedPath: string) {
  const actual = new URL(String(input), "http://example.test")
  const expected = new URL(expectedPath, "http://example.test")
  if (actual.pathname === "/api/v1/app/dashboard/controls" && expected.pathname === "/api/v1/app/dashboard") {
    return actual.searchParams.get("subject") === expected.searchParams.get("subject")
  }
  const actualSection = actual.searchParams.get("section")
  actual.searchParams.delete("section")
  if (actualSection === "chrome" && !actual.searchParams.has("smart_folder_id")) {
    expected.searchParams.delete("smart_folder_id")
  }

  return actual.pathname === expected.pathname && actual.searchParams.toString() === expected.searchParams.toString()
}

export function dashboardPathStartsWith(input: unknown, expectedPrefix: string) {
  const actual = new URL(String(input), "http://example.test")
  actual.searchParams.delete("section")

  return `${actual.pathname}${actual.search}`.startsWith(expectedPrefix)
}

export function expectDashboardFetch(fetchSpy: { mock: { calls: Array<[unknown, unknown?]> } }, expectedPath: string, expectedOptions?: unknown) {
  const matchingCall = fetchSpy.mock.calls.find(([input]) => !String(input).includes("/dashboard/controls") && dashboardPathMatches(input, expectedPath))
  expect(matchingCall).toBeTruthy()
  if (expectedOptions) expect(matchingCall?.[1]).toEqual(expectedOptions)
}

export function dashboardSectionPayload(payload: ReturnType<typeof dashboardPayload>, input: unknown) {
  const url = new URL(String(input), "http://example.test")
  const section = url.searchParams.get("section")

  if (url.pathname === "/api/v1/app/dashboard/controls") {
    return { subject: payload.subject, controls: payload.controls }
  }

  if (section === "chrome") {
    const { total: _total, total_pages: _totalPages, items: _items, lanes: _lanes, kanban_limit: _kanbanLimit, ...chrome } = payload

    return chrome
  }

  if (section === "rows") {
    const { subject, view, page, per_page, total, total_pages, landing_queue, items, lanes, kanban_limit } = payload

    return { subject, view, page, per_page, total, total_pages, landing_queue, items, lanes, kanban_limit }
  }

  return payload
}

export function dashboardResponse(payload: ReturnType<typeof dashboardPayload>, input: unknown) {
  return jsonResponse(dashboardSectionPayload(payload, input))
}

export function mockDashboardFetch(payload: ReturnType<typeof dashboardPayload>) {
  return vi.spyOn(window, "fetch").mockImplementation((input) => Promise.resolve(dashboardResponse(payload, input)))
}

export function mockDashboardFetchWithChatPreview(payload: ReturnType<typeof dashboardPayload>, chatPreview: Record<string, unknown>) {
  return vi.spyOn(window, "fetch").mockImplementation((input) => {
    if (typeof input === "string" && input.includes("/preview")) {
      return Promise.resolve(jsonResponse(chatPreview))
    }

    return Promise.resolve(dashboardResponse(payload, input))
  })
}

export function decodeFilterQueryParam(q: string) {
  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")

  return JSON.parse(decodeURIComponent(escape(atob(padded)))) as { and: Array<{ field: string; op: string; value?: unknown }> }
}

export function decodeFilterQ(q: string) {
  const padded = q
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(q.length / 4) * 4, "=")
  return JSON.parse(decodeURIComponent(escape(atob(padded))))
}

export function dashboardJobItem(overrides: Record<string, unknown> = {}) {
  return {
    type: "job",
    id: 42,
    kind: "issue",
    title: "Repair aqueduct",
    state: "open",
    summary_state: "running",
    validity: "valid",
    priority: "high",
    total_cost_usd: 0,
    issue_number: 12,
    issue_url: "https://github.com/acme/widgets/issues/12",
    branch_name: "syrus/issue-12",
    pr_number: 34,
    active_workflow_trigger_kind: "rebase",
    latest_workflow_id: 77,
    latest_workflow_trigger_kind: "rebase",
    pr_url: "https://github.com/acme/widgets/pull/34",
    latest_workflow_state: "running",
    landing_queue_position: null,
    landing_queue_blocked_reason: null,
    landing_queue_entry_key: null,
    blocked_reason: null,
    start_blocked_reason: null,
    start_blocked_at: null,
    start_blocked_details: null,
    manual_paused: false,
    manual_paused_at: null,
    manual_paused_by_user: null,
    created_at: "2026-05-30T10:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    started_at: "2026-05-30T10:01:00Z",
    finished_at: null,
    approved_at: null,
    claimed_at: null,
    claimed_by_user: { id: 2, display_name: "Ada Lovelace", profile_path: "/profiles/2" },
    claimed_by_current_user: false,
    dependencies_overridden_at: null,
    last_feedback_addressed_at: null,
    last_seen_comment_at: null,
    pr_mergeable_checked_at: null,
    workflows_count: 1,
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    epic: null,
    owner_user: { id: 1, name: "Operator", email_address: "operator@example.com" },
    owner_badge: null,
    tags: [{ id: 5, name: "urgent", color: "red" }],
    source_chat: null,
    paths: {
      job_path: "/jobs/42",
      source_path: "/jobs/42/source",
      app_pause_path: "/api/v1/app/jobs/42/pause",
      app_unpause_path: "/api/v1/app/jobs/42/unpause"
    },
    ...overrides
  }
}

export function dashboardEpicItem(overrides: Record<string, unknown> = {}) {
  return {
    type: "epic",
    id: 7,
    number: 7,
    display_number: "EPIC-7",
    title: "Raise the forum",
    description: "Build columns.",
    state: "ready",
    stuck: false,
    all_jobs_closed: false,
    owner: null,
    owned_by_current_user: false,
    claimable: true,
    owner_badge: null,
    auto_approve_mode: "never",
    owner_user_id: null,
    owner_status: "unclaimed",
    owner_user: null,
    jobs_count: 1,
    landed_jobs_count: 0,
    job_state_counts: {},
    execution_blocked_on: [],
    created_at: "2026-05-30T10:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    done_at: null,
    archived_at: null,
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    paths: {
      epic_path: "/epics/7",
      edit_epic_path: "/epics/7/edit",
      app_state_path: "/api/v1/app/epics/7/state"
    },
    ...overrides
  }
}

export function dashboardWorkflowItem(overrides: Record<string, unknown> = {}) {
  return {
    type: "workflow",
    id: 9,
    slug: "WF-9",
    path: "/jobs/42?tab=workflows#workflow-9",
    state: "running",
    trigger_kind: "manual",
    agent_provider: "codex",
    created_at: "2026-05-30T10:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    started_at: "2026-05-30T10:01:00Z",
    finished_at: "2026-05-30T10:04:00Z",
    cleaned_up_at: null,
    steps_count: 3,
    job: {
      id: 42,
      title: "Repair aqueduct",
      state: "open",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      owner_user: { id: 1, name: "Operator", email_address: "operator@example.com" },
      owner_badge: null,
      path: "/jobs/42"
    },
    ...overrides
  }
}

export function mobileFiltersSummary(label: string) {
  return screen.getByText(label, { selector: "summary > span" })
}
