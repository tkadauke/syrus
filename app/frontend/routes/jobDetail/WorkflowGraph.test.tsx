import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { JobDetailPayload } from "../../api/jobs"
import { WorkflowsTab } from "./WorkflowGraph"

function payload(overrides: Partial<JobDetailPayload> = {}): JobDetailPayload {
  return {
    job: {} as JobDetailPayload["job"],
    repository: {} as JobDetailPayload["repository"],
    epic: null,
    origin_chat: null,
    pinned: false,
    tags: [],
    tag_options: [],
    dependencies: [],
    dependents: [],
    unsatisfied_dependencies: [],
    dependency_target_options: [],
    epic_dependency_target_options: [],
    attachments: [],
    typed_artifacts: [],
    coverage: null,
    sccache: null,
    summary: null,
    test_plan: null,
    has_test_results: false,
    feedback_history: [],
    landing_queue_entry: null,
    preview: null,
    current_intent: null,
    active_work: null,
    work_units: [],
    workflows: [],
    workflows_pagination: {
      page: 1,
      per_page: 20,
      total_workflows: 0,
      total_pages: 1,
      first_item: 0,
      last_item: 0,
      previous_path: null,
      next_path: null
    },
    feature_flags: {},
    actions: {} as JobDetailPayload["actions"],
    paths: {} as JobDetailPayload["paths"],
    ...overrides
  }
}

function command() {
  return {
    mutate: vi.fn(),
    isPending: false,
    dialog: null
  } as unknown as Parameters<typeof WorkflowsTab>[0]["command"]
}

describe("WorkflowsTab", () => {
  it("shows desired work for a waiting intent even when no WorkUnit or Workflow exists yet", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            current_intent: {
              id: 77,
              kind: "auto_merge",
              label: "Landing",
              state: "waiting",
              scope_type: "job",
              scope_id: 123,
              wait_reason: "dependency",
              wait_label: "Waiting on dependency",
              wait_until: null,
              wait_details: { blocked_by_job_ids: [9] },
              execution_status: "blocked",
              requested_at: null,
              satisfied_at: null,
              cancelled_at: null
            }
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    expect(screen.getByRole("heading", { name: "Current desired work" })).toBeInTheDocument()
    expect(screen.getByText("Landing")).toBeInTheDocument()
    expect(screen.getByText((_content, element) => element?.textContent === "WI-77")).toBeInTheDocument()
    expect(screen.getByText("Waiting on dependency")).toBeInTheDocument()
    expect(screen.getByText("Desired waiting")).toBeInTheDocument()
    expect(screen.getByText("Attempt blocked")).toBeInTheDocument()
    expect(screen.getByText((_content, element) =>
      Boolean(element?.matches("p") &&
        element.textContent?.includes("\"blocked_by_job_ids\"") &&
        element.textContent.includes("9"))
    )).toBeInTheDocument()
    expect(screen.queryByText("No workflows yet.")).not.toBeInTheDocument()
  })

  it("separates desired intent state from active attempt state", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            current_intent: {
              id: 77,
              kind: "ci_failure",
              label: "CI failure",
              state: "requested",
              scope_type: "job",
              scope_id: 3578,
              wait_reason: null,
              wait_label: null,
              wait_until: null,
              wait_details: null,
              execution_status: "active",
              requested_at: null,
              satisfied_at: null,
              cancelled_at: null
            }
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    expect(screen.getByText("CI failure")).toBeInTheDocument()
    expect(screen.getByText("Desired requested")).toBeInTheDocument()
    expect(screen.getByText("Attempt active")).toBeInTheDocument()
  })

  it("shows blocked WorkUnit reasons and details without requiring the nested Workflow to be open", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            work_units: [{
              id: 88,
              kind: "retry",
              label: "Retry: Auto-retry backoff",
              state: "blocked",
              work_intent_id: 77,
              workflow_id: null,
              workflow_slug: null,
              workflow_trigger_kind: null,
              workflow_state: null,
              workflow_attached_job_id: null,
              member_role: "primary",
              scope_type: "job",
              scope_id: 123,
              blocked_reason: "auto_retry_backoff",
              blocked_label: "Auto-retry backoff",
              blocked_until: "2026-08-23T12:00:00Z",
              blocked_details: { auto_retry_attempt_id: 5 },
              parent_work_unit_id: 77,
              parent_work_unit_kind: "auto_merge",
              parent_work_unit_label: "Auto-merge",
              preemption_reason: "terminal_parent_work_unit",
              preempted_by_work_unit_id: 79,
              preempted_by_work_unit_kind: "merge_train",
              preempted_by_work_unit_label: "Epic merge-train",
              workflow: null,
              current_step: null,
              created_at: null,
              started_at: null,
              finished_at: null
            }]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    expect(screen.getByRole("heading", { name: "Work attempts" })).toBeInTheDocument()
    expect(screen.getByText("Retry: Auto-retry backoff")).toBeInTheDocument()
    expect(screen.getByText("Auto-retry backoff")).toBeInTheDocument()
    expect(screen.getByText("child of WU-77")).toBeInTheDocument()
    expect(screen.getByText("preempted: terminal parent work unit")).toBeInTheDocument()
    expect(screen.getByText("by WU-79")).toBeInTheDocument()
    expect(screen.getByText((_content, element) =>
      Boolean(element?.matches("p") &&
        element.textContent?.includes("\"auto_retry_attempt_id\"") &&
        element.textContent.includes("5"))
    )).toBeInTheDocument()
  })
})
