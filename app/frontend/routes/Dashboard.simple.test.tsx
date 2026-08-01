import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

describe("Dashboard simple mode", () => {
  it("renders feature rows only", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("link", { name: /checkout polish ready for your review/i })).toHaveAttribute("href", "/epics/1")
    expect(screen.getByText("Ready for your review")).toBeInTheDocument()
    expect(screen.queryByText("Hidden job")).not.toBeInTheDocument()
    expect(screen.queryByText("Workflow")).not.toBeInTheDocument()
  })
})

function simpleDashboardPayload(): DashboardPayload {
  return {
    simple_mode: true,
    subject: "epic",
    view: "list",
    page: 1,
    per_page: 25,
    total: 1,
    total_pages: 1,
    counts: { jobs: 1, epics: 1, workflows: 1 },
    preferences: { sort: { column: "updated_at", direction: "desc" }, visible_columns: [], kanban_lanes: [], ownership_scope: "mine", owner_user_id: null, owner_id: null, raw: {} },
    controls: { views: ["list"], ownership_scopes: [], owners: [], sort_columns: ["updated_at"], sort_directions: ["asc", "desc"], columns: { required: [], optional: [] }, kanban_lanes: [], filter_schema: [], filter_suggestions: [] },
    landing_queue: { visible: false, paused: false, toggle_path: "" },
    ownership_scope: { scope: "mine", owner_user_id: null, owner_user: null },
    ownership: { scope: "mine", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [
      {
        type: "epic",
        id: 1,
        number: 1,
        display_number: "EPIC-1",
        title: "Checkout polish",
        description: "",
        state: "in_progress",
        simple_status: "ready_for_your_review",
        stuck: false,
        all_jobs_closed: true,
        owner: null,
        owned_by_current_user: true,
        claimable: false,
        owner_badge: null,
        claimed_at: null,
        auto_approve_mode: "off",
        owner_user_id: null,
        owner_status: "mine",
        jobs_count: 1,
        landed_jobs_count: 1,
        job_state_counts: {},
        max_commits_behind_base: null,
        created_at: null,
        updated_at: "2026-07-30T12:00:00Z",
        done_at: null,
        archived_at: null,
        repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
        paths: { epic_path: "/epics/1", edit_epic_path: "/epics/1/edit", app_state_path: "", app_claim_path: "", app_unclaim_path: "" }
      },
      {
        type: "job",
        id: 2,
        kind: "direct",
        title: "Hidden job",
        state: "open",
        summary_state: "open",
        validity: "valid",
        priority: "medium",
        agent_provider: "codex",
        total_cost_usd: null,
        issue_number: null,
        issue_url: null,
        branch_name: null,
        pr_number: null,
        active_workflow_trigger_kind: null,
        latest_workflow_id: null,
        latest_workflow_trigger_kind: null,
        pr_url: null,
        latest_workflow_state: "queued",
        landing_queue_position: null,
        landing_queue_blocked_reason: null,
        landing_queue_entry_key: null,
        blocked_reason: null,
        created_at: null,
        updated_at: null,
        started_at: null,
        finished_at: null,
        approved_at: null,
        owner_user_id: null,
        owner_user: null,
        claimed_at: null,
        claimed_by_user: null,
        claimed_by_current_user: false,
        dependencies_overridden_at: null,
        last_feedback_addressed_at: null,
        last_seen_comment_at: null,
        pr_mergeable_checked_at: null,
        commits_behind_base: null,
        workflows_count: 1,
        repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
        epic: null,
        owner_badge: null,
        tags: [],
        source_chat: null,
        needs_attention: false,
        needs_attention_reason: null,
        start_blocked_reason: null,
        start_blocked_at: null,
        paths: { job_path: "/jobs/2", source_path: "/jobs/2/source" }
      }
    ],
    lanes: [],
    kanban_limit: null,
    paths: { dashboard_path: "/dashboard/epics", dashboard_jobs_path: "/dashboard/jobs", dashboard_epics_path: "/dashboard/epics", dashboard_workflows_path: "/dashboard/workflows", new_epic_path: "/epics/new", new_job_path: "/jobs/new", app_dashboard_path: "/api/v1/app/dashboard" }
  }
}
