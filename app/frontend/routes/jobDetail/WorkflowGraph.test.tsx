import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { JobDetailPayload } from "../../api/jobs"
import { stubVirtualizerMeasurements } from "../../test/virtualizerMeasurements"
import { WorkflowsTab } from "./WorkflowGraph"

stubVirtualizerMeasurements()

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
    pr_links: [],
    typed_artifacts: [],
    coverage: null,
    summary: null,
    test_plan: null,
    report: null,
    feedback_history: [],
    landing_queue_entry: null,
    preview: null,
    deploy: null,
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
  it("renders workflow diagnostics through shared section, surface, and code primitives", () => {
    const workflow = workflowWithDiffRun()
    workflow.steps[0].details = {
      command: "bin/check-migrations --with-a-very-long-argument-that-needs-horizontal-scroll",
      output_tail: "line 1\nline 2"
    }

    const { container } = render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ workflows: [workflow] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const workflowSection = container.querySelector("section#workflow-10")
    expect(workflowSection).toHaveClass("rounded-[var(--radius-panel)]", "border-border", "bg-surface")

    const stepListSurface = workflowSection?.querySelector(".mt-4.overflow-hidden")
    expect(stepListSurface).toHaveClass("rounded-[var(--radius-panel)]", "border-border", "bg-surface")

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    const detailsSurface = screen.getByText(/with-a-very-long-argument/).closest("[data-code-surface-mode]")
    expect(detailsSurface).toHaveAttribute("data-code-surface-mode", "multiline")
    expect(detailsSurface).toHaveClass("bg-surface-inset")
    expect(detailsSurface?.querySelector("pre")).toHaveClass("whitespace-pre-wrap", "break-words", "overflow-auto")
    expect(screen.getByRole("button", { name: "Copy code" })).toBeInTheDocument()
  })

  it("renders run artifact diffs read-only, without diff comment feedback UI", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/runs/51/artifacts") {
        return Promise.resolve(new Response(JSON.stringify({
          job_id: 42,
          workflow_id: 10,
          run_id: 51,
          diff_review_version_id: 100,
          base_ref: "base-sha",
          head_ref: "head-sha",
          agent_diff: [
            "diff --git a/app/models/job.rb b/app/models/job.rb",
            "--- a/app/models/job.rb",
            "+++ b/app/models/job.rb",
            "@@ -1 +1 @@",
            "-old",
            "+new"
          ].join("\n"),
          agent_diff_bytes: 120,
          step_agent_diff: null,
          logs_count: 0,
          logs: []
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    // "implemented" is one of the job states where the Review Workspace and
    // Source tabs allow diff-comment feedback -- the workflow tab must stay
    // read-only regardless of job state.
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ job: { id: 42, summary_state: "implemented" } as JobDetailPayload["job"], workflows: [workflowWithDiffRun()] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))
    fireEvent.click(screen.getByRole("button", { name: "Diff" }))

    expect(await screen.findByText("app/models/job.rb")).toBeInTheDocument()
    expect(document.querySelector('[data-diff-file="app/models/job.rb"]')).toBeInTheDocument()
    expect(screen.queryByText("Diff comments")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Submit feedback" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Comment on/ })).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith(expect.stringContaining("/diff_review_comments"), expect.anything())
  })

  it("hides Step diff when it duplicates the full diff, as on a first implement run", () => {
    const workflow = workflowWithDiffRun()
    workflow.steps[0].runs[0].step_agent_diff_present = true
    workflow.steps[0].runs[0].step_agent_diff_bytes = 120
    workflow.steps[0].runs[0].step_diff_matches_diff = true

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ workflows: [workflow] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    expect(screen.getByRole("button", { name: "Diff" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Step diff" })).not.toBeInTheDocument()
  })

  it("shows both Diff and Step diff when the step diff differs from the full diff", () => {
    const workflow = workflowWithDiffRun()
    workflow.steps[0].runs[0].step_agent_diff_present = true
    workflow.steps[0].runs[0].step_agent_diff_bytes = 40
    workflow.steps[0].runs[0].step_diff_matches_diff = false

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ workflows: [workflow] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    expect(screen.getByRole("button", { name: "Diff" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Step diff" })).toBeInTheDocument()
  })

  it("keeps grade log surfaces as the mobile flex child with an internal scroll region", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/jobs/42/runs/51/grade_log") {
        return Promise.resolve(new Response(JSON.stringify({
          name: "migration-lint",
          run_id: 51,
          contents: "\u001b[31mfailed\u001b[0m\nline 2"
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })
    const workflow = workflowWithDiffRun()
    workflow.steps[0].runs[0].app_grade_log_path = "/api/v1/app/jobs/42/runs/51/grade_log"

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ job: { id: 42, summary_state: "implemented" } as JobDetailPayload["job"], workflows: [workflow] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))
    fireEvent.click(screen.getByRole("button", { name: "Grade log" }))

    const stream = await screen.findByTestId("run-grade-log-stream")
    expect(stream.className).toContain("max-md:flex-1")
    expect(stream.className).toContain("max-md:min-h-0")
    expect(stream.className).toContain("max-md:max-h-none")
    expect(stream.querySelector("pre")?.className).toContain("max-md:flex-1")
    expect(stream.querySelector("pre")?.className).toContain("overflow-auto")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/runs/51/grade_log", expect.anything())
  })

  it("shows a bounded failed-test summary inline on a failed grader run, alongside the Grade log button", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/jobs/42/runs/51/grade_log") {
        return Promise.resolve(new Response(JSON.stringify({
          name: "rspec",
          run_id: 51,
          contents: "raw rspec output"
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })
    const workflow = workflowWithDiffRun()
    workflow.steps[0].runs[0].state = "failed"
    workflow.steps[0].runs[0].app_grade_log_path = "/api/v1/app/jobs/42/runs/51/grade_log"
    workflow.steps[0].runs[0].test_failure_summary = {
      grader_name: "rspec",
      failed_count: 7,
      omitted_count: 2,
      failures: [
        { suite_name: "spec/a_spec.rb", name: "does a", file_path: "spec/a_spec.rb" },
        { suite_name: "spec/b_spec.rb", name: "does b", file_path: "spec/b_spec.rb" }
      ]
    }

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ job: { id: 42, summary_state: "implemented" } as JobDetailPayload["job"], workflows: [workflow] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    const summary = screen.getByTestId("run-test-failure-summary")
    expect(summary).toHaveTextContent("7 failed tests")
    expect(summary).toHaveTextContent("does a")
    expect(summary).toHaveTextContent("does b")
    expect(summary).toHaveTextContent("+2 more failed tests")

    // The run card's left column must be able to shrink (min-w-0) so the
    // truncate utility on failed-test rows constrains width instead of
    // overflowing the card on narrow viewports.
    expect(summary.parentElement?.className).toContain("min-w-0")

    fireEvent.click(screen.getByRole("button", { name: "Grade log" }))
    const stream = await screen.findByTestId("run-grade-log-stream")
    expect(stream).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/runs/51/grade_log", expect.anything())
  })

  it("does not show a failed-test summary when the run has none", () => {
    const workflow = workflowWithDiffRun()
    workflow.steps[0].runs[0].state = "failed"

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ workflows: [workflow] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    expect(screen.queryByTestId("run-test-failure-summary")).not.toBeInTheDocument()
  })

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
    expect(screen.getByText("Attempt Waiting")).toBeInTheDocument()
    expect(screen.getByText("Blocked by JOB-9.")).toBeInTheDocument()
    expect(screen.getByText("Diagnostic details")).toBeInTheDocument()
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
              execution_status: "running",
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
    expect(screen.getByText("Attempt running")).toBeInTheDocument()
  })

  it("shows automatic failover copy on workflow cards", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [{
              id: 12,
              slug: "WF-12",
              path: "/jobs/1?tab=workflows#workflow-12",
              trigger_kind: "retry",
              agent_provider: "codex",
              provider_failover: {
                mode: "automatic",
                automatic: true,
                original_provider: "claude",
                original_provider_label: "Claude Code",
                selected_provider: "codex",
                selected_provider_label: "Codex",
                reason: "provider_unavailable",
                decided_at: "2026-08-01T12:01:00Z"
              },
              state: "running",
              failure_count: 0,
              artifacts: {},
              cleaned_up_at: null,
              retry_available: false,
              started_at: null,
              finished_at: null,
              created_at: "2026-08-01T12:01:00Z",
              updated_at: null,
              app_retry_step_path: "/workflows/12/retry",
              app_push_commits_path: "/workflows/12/push_commits",
              app_force_push_branch_path: "/workflows/12/force_push_branch",
              app_discard_branch_output_path: "/workflows/12/discard_branch_output",
              steps: []
            }]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    expect(screen.getByText("Claude Code unavailable; running this workflow with Codex.")).toBeInTheDocument()
  })

  it("labels operator-selected workflow providers separately from automatic failover", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [{
              id: 13,
              slug: "WF-13",
              path: "/jobs/1?tab=workflows#workflow-13",
              trigger_kind: "retry",
              agent_provider: "codex",
              provider_failover: {
                mode: "operator",
                automatic: false,
                original_provider: "claude",
                original_provider_label: "Claude Code",
                selected_provider: "codex",
                selected_provider_label: "Codex",
                reason: "operator_selected_provider",
                decided_at: "2026-08-01T12:01:00Z"
              },
              state: "running",
              failure_count: 0,
              artifacts: {},
              cleaned_up_at: null,
              retry_available: false,
              started_at: null,
              finished_at: null,
              created_at: "2026-08-01T12:01:00Z",
              updated_at: null,
              app_retry_step_path: "/workflows/13/retry",
              app_push_commits_path: "/workflows/13/push_commits",
              app_force_push_branch_path: "/workflows/13/force_push_branch",
              app_discard_branch_output_path: "/workflows/13/discard_branch_output",
              steps: []
            }]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    expect(screen.getByText("Operator selected Codex for this workflow instead of Claude Code.")).toBeInTheDocument()
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
              label: "Retry",
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
              blocked_details: { auto_retry_attempt_id: 5, reason: "auto_retry_backoff" },
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
    expect(screen.getByText("Retry")).toBeInTheDocument()
    expect(screen.getByText("Auto-retry backoff")).toBeInTheDocument()
    expect(screen.getByText("child of WU-77")).toBeInTheDocument()
    expect(screen.getByText("preempted: terminal parent work unit")).toBeInTheDocument()
    expect(screen.getByText("by WU-79")).toBeInTheDocument()
    expect(screen.getByText("Automatic retry is waiting for its backoff window.")).toBeInTheDocument()
    expect(screen.getByText("Diagnostic details")).toBeInTheDocument()
  })

  it("uses readable labels for WorkIntent scopes and attached workflow jobs", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            current_intent: {
              id: 91,
              kind: "merge_train",
              label: "Merge train",
              state: "requested",
              scope_type: "epic",
              scope_id: 260,
              wait_reason: null,
              wait_label: null,
              wait_until: null,
              wait_details: null,
              execution_status: "running",
              requested_at: null,
              satisfied_at: null,
              cancelled_at: null
            },
            work_units: [{
              id: 92,
              kind: "merge_train",
              label: "Merge train",
              state: "running",
              work_intent_id: 91,
              workflow_id: 20071,
              workflow_slug: "WF-171",
              workflow_trigger_kind: "merge_train",
              workflow_state: "running",
              workflow_attached_job_id: 3564,
              workflow_attached_job_slug: "JOB-464",
              member_role: "member",
              scope_type: "epic",
              scope_id: 260,
              blocked_reason: null,
              blocked_label: null,
              blocked_until: null,
              blocked_details: null,
              parent_work_unit_id: null,
              parent_work_unit_kind: null,
              parent_work_unit_label: null,
              preemption_reason: null,
              preempted_by_work_unit_id: null,
              preempted_by_work_unit_kind: null,
              preempted_by_work_unit_label: null,
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

    expect(screen.getByText("EPIC-260")).toBeInTheDocument()
    expect(screen.getByText("attached to JOB-464")).toBeInTheDocument()
  })

  it("summarizes admission-control diagnostics instead of dumping telemetry JSON", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            work_units: [{
              id: 38,
              kind: "initial",
              label: "Initial implementation",
              state: "blocked",
              work_intent_id: 38,
              workflow_id: 20071,
              workflow_slug: "WF-171",
              workflow_trigger_kind: "initial",
              workflow_state: "queued",
              workflow_attached_job_id: 3593,
              member_role: "primary",
              scope_type: "job",
              scope_id: 3593,
              blocked_reason: "admission_control",
              blocked_label: "Admission control",
              blocked_until: "2026-08-23T19:41:05Z",
              blocked_details: {
                action: "delay_until",
                reason: "predicted_budget_pressure_high",
                job_priority: "medium",
                trigger_kind: "initial",
                active_run_count: 4,
                healthy_worker_count: 4,
                repository_active_workflow_count: 5,
                candidate_high_cost: true,
                fallback_reasons: ["insufficient_command_and_host_profile_samples"],
                pressure: {
                  host: { cpu_pressure: 18.2, io_pressure: 76, memory_used_percent: 23.2 },
                  active: { workflow_count: 5, high_cost_count: 5 }
                }
              },
              parent_work_unit_id: null,
              parent_work_unit_kind: null,
              parent_work_unit_label: null,
              preemption_reason: null,
              preempted_by_work_unit_id: null,
              preempted_by_work_unit_kind: null,
              preempted_by_work_unit_label: null,
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

    expect(screen.getByText("Admission control predicts this would exceed the current worker budget.")).toBeInTheDocument()
    expect(screen.getByText("Work: medium priority, initial workflow.")).toBeInTheDocument()
    expect(screen.getByText("4 active runs; 4 healthy workers; 5 active workflows in this repository.")).toBeInTheDocument()
    expect(screen.getByText("This workflow is predicted to be expensive.")).toBeInTheDocument()
    expect(screen.getByText("Diagnostic details")).toBeInTheDocument()
  })

  it("explains stack dependency blockers in human terms", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            current_intent: {
              id: 38,
              kind: "initial",
              label: "Initial implementation",
              state: "waiting",
              scope_type: "job",
              scope_id: 3593,
              wait_reason: "dependency",
              wait_label: "Dependency",
              wait_until: null,
              wait_details: { blocked_by_job_ids: [3592], blocked_by_epic_ids: [] },
              execution_status: "blocked",
              requested_at: null,
              satisfied_at: null,
              cancelled_at: null
            },
            work_units: [{
              id: 38,
              kind: "initial",
              label: "Initial implementation",
              state: "blocked",
              work_intent_id: 38,
              workflow_id: 20071,
              workflow_slug: "WF-171",
              workflow_trigger_kind: "initial",
              workflow_state: "queued",
              workflow_attached_job_id: 3593,
              member_role: "primary",
              scope_type: "job",
              scope_id: 3593,
              blocked_reason: "stack_dependencies_not_ready",
              blocked_label: "Stack dependencies not ready",
              blocked_until: null,
              blocked_details: {
                kind: "stack_parent_not_ready",
                message: "selected stack parent is missing an open PR branch or captured head SHA",
                dependencies: [{ slug: "JOB-492", state: "running", job_id: 3592 }],
                start_blocked_reason: "stack_dependencies_not_ready"
              },
              parent_work_unit_id: null,
              parent_work_unit_kind: null,
              parent_work_unit_label: null,
              preemption_reason: null,
              preempted_by_work_unit_id: null,
              preempted_by_work_unit_kind: null,
              preempted_by_work_unit_label: null,
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

    expect(screen.getByText("Desired waiting")).toBeInTheDocument()
    expect(screen.getByText("Attempt Waiting")).toBeInTheDocument()
    expect(screen.getByText("Stack dependencies not ready")).toBeInTheDocument()
    expect(screen.getByText("This stack item is waiting for its parent branch to be ready.")).toBeInTheDocument()
    expect(screen.getByText("selected stack parent is missing an open PR branch or captured head SHA.")).toBeInTheDocument()
    expect(screen.getByText("JOB-492 is running.")).toBeInTheDocument()
  })

  it("shows when older step runs are omitted from the workflow payload", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [{
              id: 10,
              slug: "WF-10",
              path: "/jobs/1?tab=workflows#workflow-10",
              trigger_kind: "initial",
              agent_provider: "claude",
              state: "succeeded",
              failure_count: 0,
              artifacts: null,
              cleaned_up_at: null,
              retry_available: false,
              started_at: null,
              finished_at: null,
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:00:00Z",
              app_retry_step_path: "/retry",
              app_push_commits_path: "/push",
              app_force_push_branch_path: "/force",
              app_discard_branch_output_path: "/discard",
              steps_total: 1,
              steps_displayed: 1,
              steps_truncated: false,
              steps: [{
                id: 20,
                kind: "prepare",
                display_name: "Prepare workspace",
                display_status: "succeeded",
                position: 1,
                iteration: null,
                loop_id: null,
                state: "succeeded",
                started_at: null,
                finished_at: null,
                created_at: "2026-08-25T12:00:00Z",
                updated_at: "2026-08-25T12:00:00Z",
                details: null,
                warnings: [],
                latest: true,
                runs_total: 5,
                runs_displayed: 0,
                runs_truncated: true,
                runs: []
              }]
            }]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Prepare workspace/ }))

    expect(screen.getByText("Showing latest 0 of 5 runs for this step.")).toBeInTheDocument()
  })

  it("shows only the visual review result for the clicked step iteration", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ workflows: [workflowWithVisualReviews()] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Visual review3 iterations/ }))
    fireEvent.click(screen.getAllByRole("button", { name: /Visual review/ })[1])
    fireEvent.click(screen.getByRole("button", { name: "Review" }))

    expect(screen.getByText("First visual pass")).toBeInTheDocument()
    expect(screen.queryByText("Second visual pass")).not.toBeInTheDocument()
    expect(screen.queryByText("Third visual pass")).not.toBeInTheDocument()
  })

  it("matches visual review results by run provenance when available", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab command={command()} payload={payload({ workflows: [workflowWithVisualReviews()] })} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Visual review3 iterations/ }))
    fireEvent.click(screen.getAllByRole("button", { name: /Visual review/ })[3])
    fireEvent.click(screen.getByRole("button", { name: "Review" }))

    expect(screen.getByText("Third visual pass")).toBeInTheDocument()
    expect(screen.queryByText("First visual pass")).not.toBeInTheDocument()
    expect(screen.queryByText("Second visual pass")).not.toBeInTheDocument()
  })

  it("surfaces cancellation reasons on cancelled workflow steps", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [{
              id: 10,
              slug: "WF-10",
              path: "/jobs/1?tab=workflows#workflow-10",
              trigger_kind: "initial",
              agent_provider: "codex",
              state: "failed",
              failure_count: 1,
              artifacts: null,
              cleaned_up_at: null,
              retry_available: true,
              started_at: null,
              finished_at: null,
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:00:00Z",
              app_retry_step_path: "/retry",
              app_push_commits_path: "/push",
              app_force_push_branch_path: "/force",
              app_discard_branch_output_path: "/discard",
              steps_total: 1,
              steps_displayed: 1,
              steps_truncated: false,
              steps: [{
                id: 24,
                kind: "test_plan",
                display_name: "Test plan",
                display_status: "cancelled",
                position: 6,
                iteration: 1,
                loop_id: null,
                state: "cancelled",
                started_at: null,
                finished_at: "2026-08-25T12:01:00Z",
                created_at: "2026-08-25T12:00:00Z",
                updated_at: "2026-08-25T12:01:00Z",
                details: {
                  cancelled_reason: "cancel_terminal_workflow_active_descendants",
                  cancelled_workflow_state: "failed",
                  cancelled_source_step_id: 23,
                  cancelled_source_step_kind: "grader"
                },
                warnings: [],
                latest: true,
                runs: []
              }]
            }]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Test plan/ }))

    expect(screen.getByText("Cancelled:")).toBeInTheDocument()
    expect(screen.getByText(/parent workflow failed after grader STEP-23; cancel terminal workflow active descendants\./)).toBeInTheDocument()
    // Cancellation is narrated only by the human-readable notice above — the
    // raw cancellation keys never reach the debug disclosure, so there's
    // nothing left to hide behind one.
    expect(screen.queryByText("Debug details")).not.toBeInTheDocument()
    expect(screen.queryByText(/cancelled_workflow_state/)).not.toBeInTheDocument()
  })

  it("hides stale cancellation metadata on a succeeded step instead of showing contradictory raw JSON", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 24,
              kind: "coverage_analyze",
              display_name: "Analyze coverage",
              display_status: "succeeded",
              position: 6,
              iteration: 1,
              loop_id: null,
              state: "succeeded",
              started_at: "2026-08-25T12:00:00Z",
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: {
                cancelled_by: "terminal_workflow_cleanup",
                cancelled_reason: "cancel_terminal_workflow_active_descendants",
                cancelled_workflow_state: "failed",
                cancelled_source_step_id: 23,
                cancelled_source_step_kind: "grader"
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Analyze coverage/ }))

    expect(screen.queryByText("Cancelled:")).not.toBeInTheDocument()
    expect(screen.queryByText("Debug details")).not.toBeInTheDocument()
    expect(screen.queryByText(/cancel_terminal_workflow_active_descendants/)).not.toBeInTheDocument()
  })

  it("links to the opened PR on a succeeded pr_open step", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            job: { id: 42, pr_number: 123, pr_url: "https://github.com/acme/widgets/pull/123" } as JobDetailPayload["job"],
            workflows: [workflowWithStepDetails({
              id: 40,
              kind: "pr_open",
              display_name: "Open PR",
              display_status: "succeeded",
              position: 8,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: "2026-08-25T12:00:00Z",
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: null,
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Open PR/ }))

    const link = screen.getByRole("link", { name: "Opened PR #123" })
    expect(link).toHaveAttribute("href", "https://github.com/acme/widgets/pull/123")
  })

  it("does not show a PR outcome for a pr_open step before the PR exists", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            job: { id: 42, pr_number: null, pr_url: null } as JobDetailPayload["job"],
            workflows: [workflowWithStepDetails({
              id: 40,
              kind: "pr_open",
              display_name: "Open PR",
              display_status: "failed",
              position: 8,
              iteration: null,
              loop_id: null,
              state: "failed",
              started_at: "2026-08-25T12:00:00Z",
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: null,
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Open PR/ }))

    expect(screen.queryByText(/Opened PR/)).not.toBeInTheDocument()
  })

  it("links to the target PR on a succeeded promotion_publish step via the pr_links registry", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            job: { id: 42 } as JobDetailPayload["job"],
            pr_links: [{
              id: 1,
              role: "promotion",
              source_repository_slug: "acme/widgets",
              source_ref: "release/2026-09",
              target_repository_slug: "acme/widgets",
              target_ref: "main",
              pr_number: 456,
              pr_url: "https://github.com/acme/widgets/pull/456",
              pr_state: "open",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:00:00Z"
            }],
            workflows: [workflowWithStepDetails({
              id: 41,
              kind: "promotion_publish",
              display_name: "Publish promotion",
              display_status: "succeeded",
              position: 1,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: "2026-08-25T12:00:00Z",
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: null,
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Publish promotion/ }))

    const link = screen.getByRole("link", { name: "Opened Promotion PR #456" })
    expect(link).toHaveAttribute("href", "https://github.com/acme/widgets/pull/456")
  })

  it("hides an unknown step details payload behind a debug affordance instead of dumping raw JSON", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 30,
              kind: "unspecified_future_step",
              display_name: "Mystery step",
              display_status: "succeeded",
              position: 1,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: null,
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: {
                some_future_planner_output: [ { name: "unclaimed", reason: "no semantic renderer yet" } ]
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Mystery step/ }))

    const toggle = screen.getByText("Debug details")
    const rawPayload = screen.getByText(/some_future_planner_output/)
    expect(toggle).toBeVisible()
    expect(rawPayload).not.toBeVisible()

    fireEvent.click(toggle)
    expect(screen.getByText(/some_future_planner_output/)).toBeVisible()
  })

  it("summarizes grader_fanout target selection instead of dumping grader_target_selections JSON", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 30,
              kind: "grader_fanout",
              display_name: "Plan graders",
              display_status: "succeeded",
              position: 1,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: null,
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: {
                grader_target_selections: [
                  { name: "rspec", target_label: "//:grade/rspec", required: true, affected: true, reason: "own source scope matched a changed file" },
                  { name: "plugins-rails-eslint", target_label: "//plugins/rails:grade/eslint", required: false, affected: false, reason: "no matching files changed" }
                ]
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Grade/ }))
    fireEvent.click(screen.getByRole("button", { name: /Setup/ }))

    expect(screen.getByText("1 grader selected")).toBeInTheDocument()
    expect(screen.getByText("1 grader skipped")).toBeInTheDocument()
    expect(screen.getByText("Plugins Rails Eslint")).toBeInTheDocument()
    expect(screen.getByText(/no matching files changed/)).toBeInTheDocument()
    // The selected grader already has its own sibling grader Step in the
    // group, so it's not re-listed here — only the skipped one is.
    expect(screen.getAllByRole("listitem")).toHaveLength(1)
    expect(screen.queryByText(/grader_target_selections/)).not.toBeInTheDocument()
  })

  it("prefers a skipped grader's resolved display_name over humanizing its machine name", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 30,
              kind: "grader_fanout",
              display_name: "Plan graders",
              display_status: "succeeded",
              position: 1,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: null,
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: {
                grader_target_selections: [
                  {
                    name: "plugins-rails-rspec-focused",
                    display_name: "rails plugin: RSpec (focused)",
                    target_label: "//plugins/rails:grade/rspec-focused",
                    required: true,
                    affected: false,
                    reason: "no matching files changed"
                  }
                ]
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Grade/ }))
    fireEvent.click(screen.getByRole("button", { name: /Setup/ }))

    expect(screen.getByText("rails plugin: RSpec (focused)")).toBeInTheDocument()
    expect(screen.queryByText("Plugins Rails Rspec Focused")).not.toBeInTheDocument()
  })

  it("omits body for grader_collect since the result is already shown on the sibling grader Steps", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 30,
              kind: "grader_collect",
              display_name: "Aggregate graders",
              display_status: "succeeded",
              position: 1,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: null,
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: { transient_only_required_grader_failure: true },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Grade/ }))
    fireEvent.click(screen.getByRole("button", { name: /Result/ }))

    expect(screen.queryByText("Debug details")).not.toBeInTheDocument()
    expect(screen.queryByText(/transient_only_required_grader_failure/)).not.toBeInTheDocument()
  })

  it("consolidates grader target id, gating status, description, and command into one metadata panel", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 30,
              kind: "grader",
              display_name: "plugins/rails: RSpec Focused",
              display_status: "succeeded",
              position: 1,
              iteration: null,
              loop_id: null,
              state: "succeeded",
              started_at: null,
              finished_at: "2026-08-25T12:01:00Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:01:00Z",
              details: {
                name: "plugins-rails-rspec-focused",
                target_label: "//plugins/rails:grade/rspec-focused",
                description: "Runs the focused RSpec suite for plugins/rails.",
                command: "bin/rspec --tag focus",
                required: true
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Grade/ }))
    fireEvent.click(screen.getByRole("button", { name: /RSpec Focused/ }))

    const targetLink = screen.getByRole("link", { name: "//plugins/rails:grade/rspec-focused" })
    const statusPanel = targetLink.closest("dl")!.closest("div")!
    expect(statusPanel).toHaveTextContent("Required to pass")
    expect(statusPanel).toHaveTextContent("Runs the focused RSpec suite for plugins/rails.")
    expect(statusPanel).toHaveTextContent("bin/rspec --tag focus")
  })

  it("renders format/generate soft command failures as a readable notice instead of raw JSON", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 31,
              kind: "format",
              display_name: "Format",
              display_status: "succeeded",
              position: 2,
              iteration: 1,
              loop_id: null,
              state: "succeeded",
              started_at: null,
              finished_at: "2026-08-25T12:02:00Z",
              created_at: "2026-08-25T12:01:00Z",
              updated_at: "2026-08-25T12:02:00Z",
              details: {
                format_failures: [{
                  command: "rubocop -A",
                  workdir: "/workspace",
                  exit_status: 1,
                  timed_out: false,
                  duration_s: 4.2,
                  output_tail: "offense detected",
                  soft: true
                }]
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Format/ }))

    expect(screen.getByText("Command failed (non-fatal)")).toBeVisible()
    expect(screen.getByText("rubocop -A")).toBeVisible()
    expect(screen.getByText("exit 1")).toBeVisible()
    expect(screen.getByText("offense detected")).toBeVisible()
    expect(screen.queryByText("Debug details")).not.toBeInTheDocument()
  })

  it("renders a secondary mise install failure alongside the primary prepare failure panel", () => {
    render(
      <MemoryRouter>
        <WorkflowsTab
          command={command()}
          payload={payload({
            workflows: [workflowWithStepDetails({
              id: 32,
              kind: "prepare",
              display_name: "Prepare",
              display_status: "failed",
              position: 0,
              iteration: null,
              loop_id: null,
              state: "failed",
              started_at: null,
              finished_at: "2026-08-25T12:00:30Z",
              created_at: "2026-08-25T12:00:00Z",
              updated_at: "2026-08-25T12:00:30Z",
              details: {
                prepare_failure: {
                  command: "bundle install",
                  workdir: "/workspace",
                  exit_status: 1,
                  timed_out: false,
                  duration_s: 12.3,
                  output_tail: "Bundler error",
                  soft: false
                },
                mise_install_failure: {
                  command: "mise install",
                  workdir: "/workspace",
                  exit_status: 2,
                  timed_out: false,
                  duration_s: 3.1,
                  output_tail: "mise error output",
                  soft: true
                }
              },
              warnings: [],
              latest: true,
              runs: []
            })]
          })}
          prefix=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: /Prepare/ }))

    expect(screen.getByText("Setup failed before the agent started")).toBeVisible()
    expect(screen.getByText("bundle install")).toBeVisible()
    expect(screen.getByText("Bundler error")).toBeVisible()

    expect(screen.getByText("Command failed (non-fatal)")).toBeVisible()
    expect(screen.getByText("mise install")).toBeVisible()
    expect(screen.getByText("mise error output")).toBeVisible()
  })

  it("renders distributed grader batches with placement metadata and sibling admission blocks", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab
            command={command()}
            payload={payload({
              job: { id: 42, summary_state: "implemented" } as JobDetailPayload["job"],
              workflows: [distributedGradeWorkflow()]
            })}
            prefix=""
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Grade/ }))

    expect(screen.getByText("Batch progress")).toBeInTheDocument()
    expect(screen.getAllByText("2/5 complete").length).toBeGreaterThan(0)
    expect(screen.queryByText("1/1 complete")).not.toBeInTheDocument()
    expect(screen.getByText("1 running")).toBeInTheDocument()
    expect(screen.getByText("1 waiting")).toBeInTheDocument()
    expect(screen.getByText("1 failed")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /beta/ }))

    expect(screen.getAllByText("STEP-22").length).toBeGreaterThan(0)
    expect(screen.getByText("Target //:grade/beta")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Target //:grade/beta" })).toHaveAttribute(
      "href",
      "/jobs/42?tab=target_graph&workflow_id=10&focus_label=%2F%2F%3Agrade%2Fbeta"
    )
    expect(screen.getByText("Placement waiting")).toBeInTheDocument()
    expect(screen.getByText("immutable source checkout")).toBeInTheDocument()
    expect(screen.getByText("refs/heads/main")).toBeInTheDocument()
    expect(screen.getByText("worker beta")).toBeInTheDocument()
    expect(screen.getByText("storage beta")).toBeInTheDocument()
    expect(screen.getByText(/worker slot busy/)).toBeInTheDocument()
    expect(screen.getByText("Waits for")).toBeInTheDocument()
    expect(screen.getByText("STEP-20")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /delta/ }))

    expect(screen.getByRole("link", { name: "Open target graph neighborhood" })).toHaveAttribute(
      "href",
      "/jobs/42?tab=target_graph&workflow_id=10&focus_label=%2F%2F%3Agrade%2Fdelta"
    )
  })

  it("collapses agent metadata and the transcript button into an execution-details disclosure for a happy-path non-agentic run", () => {
    const { container } = render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab
            command={command()}
            payload={payload({
              workflows: [workflowWithStepDetails({
                id: 40,
                kind: "prepare",
                display_name: "Prepare workspace",
                display_status: "succeeded",
                position: 1,
                iteration: null,
                loop_id: null,
                state: "succeeded",
                started_at: null,
                finished_at: null,
                created_at: "2026-08-25T12:00:00Z",
                updated_at: "2026-08-25T12:00:00Z",
                agentic: false,
                details: null,
                warnings: [],
                latest: true,
                runs: [{
                  id: 90,
                  state: "succeeded",
                  trigger_kind: "initial",
                  agent_provider: "claude",
                  agent_outcome: "success",
                  agent_turns: 0,
                  agent_pr_title: null,
                  agent_summary: null,
                  parent_session_id: null,
                  skill_source: null,
                  skill_resolved_path: null,
                  skill_resolved_class: null,
                  head_sha: null,
                  iteration: 1,
                  started_at: null,
                  last_heartbeat_at: null,
                  finished_at: null,
                  created_at: "2026-08-25T12:00:00Z",
                  updated_at: "2026-08-25T12:00:00Z",
                  cost_usd: 0,
                  input_tokens: 0,
                  output_tokens: 0,
                  agent_diff_present: false,
                  agent_diff_bytes: 0,
                  step_agent_diff_present: false,
                  step_agent_diff_bytes: 0,
                  step_diff_matches_diff: false,
                  job_log_count: 20,
                  rate_limited: false,
                  run_diagnostic: null,
                  health_snapshots: [],
                  agent_session: null,
                  can_stop: false,
                  can_diagnose: false,
                  can_resume: false,
                  app_artifacts_path: "/api/v1/app/jobs/1/runs/90/artifacts",
                  app_stop_path: "/stop",
                  app_diagnose_path: "/diagnose",
                  app_resume_path: "/resume",
                  app_grade_log_path: null
                }]
              })]
            })}
            prefix=""
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Prepare workspace/ }))

    const toggle = screen.getByText("Execution details")
    const details = toggle.closest("details")!
    expect(details).not.toHaveAttribute("open")
    // Debug metadata stays reachable inside the (collapsed) disclosure rather
    // than being deleted outright.
    expect(details).toHaveTextContent("claude")
    expect(details.querySelector("button")).toHaveTextContent("Transcript")
    // ...and the Transcript action is not duplicated as a top-level button.
    expect(screen.getAllByRole("button", { name: "Transcript" })).toHaveLength(1)
  })

  it("keeps agent metadata visible by default (no toggle needed) for a failed non-agentic run", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab
            command={command()}
            payload={payload({
              workflows: [workflowWithStepDetails({
                id: 41,
                kind: "prepare",
                display_name: "Prepare workspace",
                display_status: "failed",
                position: 1,
                iteration: null,
                loop_id: null,
                state: "failed",
                started_at: null,
                finished_at: null,
                created_at: "2026-08-25T12:00:00Z",
                updated_at: "2026-08-25T12:00:00Z",
                agentic: false,
                details: null,
                warnings: [],
                latest: true,
                runs: [{
                  id: 91,
                  state: "failed",
                  trigger_kind: "initial",
                  agent_provider: "claude",
                  agent_outcome: null,
                  agent_turns: 0,
                  agent_pr_title: null,
                  agent_summary: null,
                  parent_session_id: null,
                  skill_source: null,
                  skill_resolved_path: null,
                  skill_resolved_class: null,
                  head_sha: null,
                  iteration: 1,
                  started_at: "2026-08-25T12:00:00Z",
                  last_heartbeat_at: null,
                  finished_at: "2026-08-25T12:00:05Z",
                  created_at: "2026-08-25T12:00:00Z",
                  updated_at: "2026-08-25T12:00:05Z",
                  cost_usd: 0,
                  input_tokens: 0,
                  output_tokens: 0,
                  agent_diff_present: false,
                  agent_diff_bytes: 0,
                  step_agent_diff_present: false,
                  step_agent_diff_bytes: 0,
                  step_diff_matches_diff: false,
                  job_log_count: 5,
                  rate_limited: false,
                  run_diagnostic: null,
                  health_snapshots: [],
                  agent_session: null,
                  can_stop: false,
                  can_diagnose: false,
                  can_resume: false,
                  app_artifacts_path: "/api/v1/app/jobs/1/runs/91/artifacts",
                  app_stop_path: "/stop",
                  app_diagnose_path: "/diagnose",
                  app_resume_path: "/resume",
                  app_grade_log_path: null
                }]
              })]
            })}
            prefix=""
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Prepare workspace/ }))

    expect(screen.getByText(/claude/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Transcript" })).toBeInTheDocument()
    expect(screen.queryByText("Execution details")).not.toBeInTheDocument()
  })

  it("avoids repeating status and timing between the step header and its sole successful run", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab
            command={command()}
            payload={payload({
              workflows: [workflowWithStepDetails({
                id: 42,
                kind: "implement",
                display_name: "Implement",
                display_status: "succeeded",
                position: 1,
                iteration: null,
                loop_id: null,
                state: "succeeded",
                started_at: "2026-08-25T12:00:00Z",
                finished_at: "2026-08-25T12:00:05Z",
                created_at: "2026-08-25T12:00:00Z",
                updated_at: "2026-08-25T12:00:05Z",
                details: null,
                warnings: [],
                latest: true,
                runs: [{
                  id: 92,
                  state: "succeeded",
                  trigger_kind: "initial",
                  agent_provider: "codex",
                  agent_outcome: "success",
                  agent_turns: 3,
                  agent_pr_title: null,
                  agent_summary: null,
                  parent_session_id: null,
                  skill_source: null,
                  skill_resolved_path: null,
                  skill_resolved_class: null,
                  head_sha: null,
                  iteration: 1,
                  started_at: "2026-08-25T12:00:00Z",
                  last_heartbeat_at: null,
                  finished_at: "2026-08-25T12:00:05Z",
                  created_at: "2026-08-25T12:00:00Z",
                  updated_at: "2026-08-25T12:00:05Z",
                  cost_usd: 0.05,
                  input_tokens: 0,
                  output_tokens: 0,
                  agent_diff_present: false,
                  agent_diff_bytes: 0,
                  step_agent_diff_present: false,
                  step_agent_diff_bytes: 0,
                  step_diff_matches_diff: false,
                  job_log_count: 0,
                  rate_limited: false,
                  run_diagnostic: null,
                  health_snapshots: [],
                  agent_session: null,
                  can_stop: false,
                  can_diagnose: false,
                  can_resume: false,
                  app_artifacts_path: "/api/v1/app/jobs/1/runs/92/artifacts",
                  app_stop_path: "/stop",
                  app_diagnose_path: "/diagnose",
                  app_resume_path: "/resume",
                  app_grade_log_path: null
                }]
              })]
            })}
            prefix=""
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    // The step header already carries this run's status and timing (single
    // run, exact same started_at/finished_at) -- the run row must not repeat
    // a second "Started"/"finished" line for it.
    expect(screen.queryByText("Started")).not.toBeInTheDocument()
    expect(screen.queryByText("finished")).not.toBeInTheDocument()
  })

  it("collapses PLACEMENT/WORKER/STORAGE execution details for a succeeded step but expands them for an active/failed one", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <WorkflowsTab
            command={command()}
            payload={payload({
              job: { id: 42, summary_state: "implemented" } as JobDetailPayload["job"],
              workflows: [distributedGradeWorkflow()]
            })}
            prefix=""
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /Grade/ }))
    fireEvent.click(screen.getByRole("button", { name: /alpha/ }))

    const alphaToggle = screen.getByText("Execution details")
    expect(alphaToggle.closest("details")).not.toHaveAttribute("open")
    expect(alphaToggle.closest("details")).toHaveTextContent("worker alpha")

    fireEvent.click(screen.getByRole("button", { name: /beta/ }))

    const [, betaToggle] = screen.getAllByText("Execution details")
    expect(betaToggle.closest("details")).toHaveAttribute("open")
    expect(betaToggle.closest("details")).toHaveTextContent("worker beta")
  })
})

function workflowWithStepDetails(step: JobDetailPayload["workflows"][number]["steps"][number]) {
  return {
    id: 10,
    slug: "WF-10",
    path: "/jobs/1?tab=workflows#workflow-10",
    trigger_kind: "initial",
    agent_provider: "codex",
    state: "succeeded",
    failure_count: 0,
    artifacts: null,
    cleaned_up_at: null,
    retry_available: false,
    started_at: null,
    finished_at: null,
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    app_retry_step_path: "/retry",
    app_push_commits_path: "/push",
    app_force_push_branch_path: "/force",
    app_discard_branch_output_path: "/discard",
    steps_total: 1,
    steps_displayed: 1,
    steps_truncated: false,
    steps: [step]
  } as JobDetailPayload["workflows"][number]
}

function workflowWithDiffRun() {
  return {
    id: 10,
    slug: "WF-10",
    path: "/jobs/42?tab=workflows#workflow-10",
    trigger_kind: "initial",
    agent_provider: "codex",
    state: "succeeded",
    failure_count: 0,
    artifacts: null,
    cleaned_up_at: null,
    retry_available: false,
    started_at: null,
    finished_at: null,
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    app_retry_step_path: "/retry",
    app_push_commits_path: "/push",
    app_force_push_branch_path: "/force",
    app_discard_branch_output_path: "/discard",
    steps_total: 1,
    steps_displayed: 1,
    steps_truncated: false,
    steps: [{
      id: 20,
      kind: "implement",
      display_name: "Implement",
      display_status: "succeeded",
      position: 1,
      iteration: null,
      loop_id: null,
      state: "succeeded",
      started_at: null,
      finished_at: null,
      created_at: "2026-08-25T12:00:00Z",
      updated_at: "2026-08-25T12:00:00Z",
      details: null,
      warnings: [],
      latest: true,
      runs: [{
        id: 51,
        state: "succeeded",
        trigger_kind: "initial",
        agent_provider: "codex",
        agent_outcome: "success",
        agent_turns: 1,
        agent_pr_title: null,
        agent_summary: null,
        parent_session_id: null,
        skill_source: null,
        skill_resolved_path: null,
        skill_resolved_class: null,
        head_sha: "head-sha",
        iteration: 1,
        started_at: null,
        last_heartbeat_at: null,
        finished_at: null,
        created_at: "2026-08-25T12:00:00Z",
        updated_at: "2026-08-25T12:00:00Z",
        cost_usd: 0,
        input_tokens: 0,
        output_tokens: 0,
        agent_diff_present: true,
        agent_diff_bytes: 120,
        step_agent_diff_present: false,
        step_agent_diff_bytes: 0,
        step_diff_matches_diff: false,
        job_log_count: 0,
        rate_limited: false,
        run_diagnostic: null,
        health_snapshots: [],
        agent_session: null,
        can_stop: false,
        can_diagnose: false,
        can_resume: false,
        app_artifacts_path: "/api/v1/app/jobs/42/runs/51/artifacts",
        app_stop_path: "/stop",
        app_diagnose_path: "/diagnose",
        app_resume_path: "/resume",
        app_grade_log_path: null
      }]
    }]
  } as JobDetailPayload["workflows"][number]
}

function workflowWithVisualReviews() {
  const visualRun = (id: number, iteration: number) => ({
    id,
    state: "succeeded",
    trigger_kind: "initial",
    agent_provider: "codex",
    agent_outcome: "success",
    agent_turns: 1,
    agent_pr_title: null,
    agent_summary: null,
    parent_session_id: null,
    skill_source: null,
    skill_resolved_path: null,
    skill_resolved_class: null,
    head_sha: null,
    iteration,
    started_at: null,
    last_heartbeat_at: null,
    finished_at: null,
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    cost_usd: 0,
    input_tokens: 0,
    output_tokens: 0,
    agent_diff_present: false,
    agent_diff_bytes: 0,
    step_agent_diff_present: false,
    step_agent_diff_bytes: 0,
    step_diff_matches_diff: false,
    job_log_count: 0,
    rate_limited: false,
    run_diagnostic: null,
    health_snapshots: [],
    agent_session: null,
    can_stop: false,
    can_diagnose: false,
    can_resume: false,
    app_artifacts_path: `/api/v1/app/jobs/42/runs/${id}/artifacts`,
    app_stop_path: "/stop",
    app_diagnose_path: "/diagnose",
    app_resume_path: "/resume",
    app_grade_log_path: null
  })
  const visualStep = (id: number, position: number, iteration: number) => ({
    id,
    kind: "visual_review",
    display_name: `Visual review ${iteration}`,
    display_status: "succeeded",
    position,
    iteration,
    loop_id: "visual-review-loop",
    state: "succeeded",
    started_at: null,
    finished_at: null,
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    details: null,
    warnings: [],
    latest: true,
    runs: [visualRun(50 + iteration, iteration)]
  })

  return {
    id: 10,
    slug: "WF-10",
    path: "/jobs/42?tab=workflows#workflow-10",
    trigger_kind: "initial",
    agent_provider: "codex",
    state: "succeeded",
    failure_count: 0,
    artifacts: {
      visual_review_iterations: [
        { iteration: 1, critique: "First visual pass", verdict: "needs_work", artifacts: [] },
        { iteration: 2, critique: "Second visual pass", verdict: "needs_work", artifacts: [] },
        { iteration: 3, step_id: 33, run_id: 53, critique: "Third visual pass", verdict: "approved", artifacts: [] }
      ]
    },
    cleaned_up_at: null,
    retry_available: false,
    started_at: null,
    finished_at: null,
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    app_retry_step_path: "/retry",
    app_push_commits_path: "/push",
    app_force_push_branch_path: "/force",
    app_discard_branch_output_path: "/discard",
    steps_total: 3,
    steps_displayed: 3,
    steps_truncated: false,
    steps: [
      visualStep(31, 1, 1),
      visualStep(32, 2, 2),
      visualStep(33, 3, 3)
    ]
  } as JobDetailPayload["workflows"][number]
}

function distributedGradeWorkflow() {
  const run = (id: number, state: string, hostname: string | null = null) => ({
    id,
    state,
    trigger_kind: "initial",
    agent_provider: "codex",
    agent_outcome: null,
    agent_turns: 0,
    agent_pr_title: null,
    agent_summary: null,
    parent_session_id: null,
    skill_source: null,
    skill_resolved_path: null,
    skill_resolved_class: null,
    head_sha: null,
    iteration: 1,
    started_at: "2026-08-25T12:00:00Z",
    last_heartbeat_at: null,
    finished_at: state === "running" || state === "queued" ? null : "2026-08-25T12:01:00Z",
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    cost_usd: 0,
    input_tokens: 0,
    output_tokens: 0,
    agent_diff_present: false,
    agent_diff_bytes: 0,
    step_agent_diff_present: false,
    step_agent_diff_bytes: 0,
    step_diff_matches_diff: false,
    job_log_count: 0,
    rate_limited: false,
    run_diagnostic: null,
    health_snapshots: [],
    command_spans: hostname ? [{
      id: id + 100,
      run_id: id,
      job_id: 42,
      workflow_id: 10,
      step_id: id,
      spawned_process_id: null,
      sequence: 1,
      name: "grader",
      command_excerpt: "bin/grader",
      started_at: "2026-08-25T12:00:00Z",
      finished_at: state === "running" || state === "queued" ? null : "2026-08-25T12:01:00Z",
      duration_ms: null,
      duration_s: null,
      exit_status: state === "failed" ? 1 : 0,
      outcome: state,
      hostname,
      metadata: null,
      sample_count: 0,
      samples_missing: true,
      retention_limited: false,
      summary: {},
      pressure: { level: "unknown", reasons: [] }
    }] : [],
    agent_session: null,
    can_stop: false,
    can_diagnose: false,
    can_resume: false,
    app_artifacts_path: `/api/v1/app/jobs/42/runs/${id}/artifacts`,
    app_stop_path: "/stop",
    app_diagnose_path: "/diagnose",
    app_resume_path: "/resume",
    app_grade_log_path: null
  })

  const grader = (id: number, name: string, state: string, extra: Partial<JobDetailPayload["workflows"][number]["steps"][number]> = {}) => ({
    id,
    kind: "grader",
    display_name: name,
    display_status: state,
    position: id,
    iteration: 1,
    loop_id: "grade-loop",
    state,
    started_at: "2026-08-25T12:00:00Z",
    finished_at: state === "running" || state === "queued" ? null : "2026-08-25T12:01:00Z",
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    placement: {
      policy: "immutable_source_checkout",
      projected_target_label: `//:grade/${name}`,
      source_snapshot: {
        id: 9,
        source_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        source_ref: "refs/heads/main",
        tree_sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      worker_hostname: `worker ${name}`,
      worker_storage_key: `storage ${name}`,
      admission: state === "queued" ? { reason: "worker_slot_busy", retry_at: "2026-08-25T12:02:00Z" } : null
    },
    dependencies: {
      depends_on_step_ids: [20],
      dependent_step_ids: [30],
      barrier_group: "workflow:10:grader_collect",
      barrier_labels: ["grader_collect"],
      barrier_progress: {
        total: 1,
        completed: 1,
        queued: 0,
        running: 0,
        succeeded: 1,
        failed: 0,
        cancelled: 0,
        skipped: 0
      }
    },
    details: { name, required: true, command: `bin/${name}` },
    warnings: [],
    latest: false,
    runs: state === "skipped" ? [] : [run(id, state, `worker ${name}`)],
    ...extra
  })

  return {
    id: 10,
    slug: "WF-10",
    path: "/jobs/42?tab=workflows#workflow-10",
    trigger_kind: "initial",
    agent_provider: "codex",
    state: "running",
    failure_count: 0,
    artifacts: null,
    cleaned_up_at: null,
    retry_available: false,
    started_at: "2026-08-25T12:00:00Z",
    finished_at: null,
    created_at: "2026-08-25T12:00:00Z",
    updated_at: "2026-08-25T12:00:00Z",
    app_retry_step_path: "/retry",
    app_push_commits_path: "/push",
    app_force_push_branch_path: "/force",
    app_discard_branch_output_path: "/discard",
    steps_total: 7,
    steps_displayed: 7,
    steps_truncated: false,
    steps: [
      {
        id: 20,
        kind: "grader_fanout",
        display_name: "Grade setup",
        display_status: "succeeded",
        position: 1,
        iteration: 1,
        loop_id: "grade-loop",
        state: "succeeded",
        started_at: "2026-08-25T12:00:00Z",
        finished_at: "2026-08-25T12:00:01Z",
        created_at: "2026-08-25T12:00:00Z",
        updated_at: "2026-08-25T12:00:00Z",
        placement: { policy: "control_plane" },
        dependencies: { depends_on_step_ids: [], dependent_step_ids: [21, 22, 23, 24, 25] },
        details: null,
        warnings: [],
        latest: false,
        runs: []
      },
      grader(21, "alpha", "succeeded"),
      grader(22, "beta", "queued"),
      grader(23, "gamma", "running"),
      grader(24, "delta", "failed"),
      grader(25, "epsilon", "skipped"),
      {
        id: 30,
        kind: "grader_collect",
        display_name: "Grade result",
        display_status: "queued",
        position: 7,
        iteration: 1,
        loop_id: "grade-loop",
        state: "queued",
        started_at: null,
        finished_at: null,
        created_at: "2026-08-25T12:00:00Z",
        updated_at: "2026-08-25T12:00:00Z",
        placement: { policy: "control_plane" },
        dependencies: {
          depends_on_step_ids: [21, 22, 23, 24, 25],
          dependent_step_ids: [],
          barrier_progress: {
            total: 5,
            completed: 2,
            queued: 1,
            running: 1,
            succeeded: 1,
            failed: 1,
            cancelled: 0,
            skipped: 1
          }
        },
        details: null,
        warnings: [],
        latest: true,
        runs: []
      }
    ]
  } as JobDetailPayload["workflows"][number]
}
