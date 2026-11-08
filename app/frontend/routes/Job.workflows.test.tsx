import { jsonResponse } from "../testSupport"
import { act, fireEvent, render, screen, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import type { JobStep } from "../api/jobs"
import { expectRunningPill, jobDetailPayload, jobTimelinePayload, jobWaterfallPayload } from "../test/app/jobPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App Job workflows and timeline", () => {
  installAppTestLifecycle()

  it("shows the workflows tab lazy-load state instead of an empty workflow list", async () => {
    const detailPayload = jobDetailPayload({
      job: { workflows_count: 13, runs_count: 121 },
      workflows: [],
      workflows_pagination: {
        page: 1,
        per_page: 10,
        total_workflows: 13,
        total_pages: 2,
        first_item: 0,
        last_item: 0,
        previous_path: null,
        next_path: "/jobs/42?tab=workflows&workflows_page=2"
      }
    })
    const workflowsPayload = jobDetailPayload()
    let resolveWorkflows!: (response: Response) => void
    const workflowsPromise = new Promise<Response>((resolve) => {
      resolveWorkflows = resolve
    })
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/workflows") return workflowsPromise

      return Promise.resolve(new Response(JSON.stringify(detailPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Workflows (13)" })).toBeInTheDocument()
    expect(await screen.findByText("Loading workflows...")).toBeInTheDocument()
    expect(screen.queryByText("No workflows yet.")).not.toBeInTheDocument()

    await act(async () => {
      resolveWorkflows(new Response(JSON.stringify(workflowsPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      await workflowsPromise
    })

    expect(await screen.findByText("WF-5")).toBeInTheDocument()
  })

  it("keeps the admin-only Job timeline collapsed until opened", async () => {
    const payload = jobDetailPayload({ actions: { can_view_timeline: true } })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Timeline (1 run)" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("Workflow created")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/jobs/42/timeline", expect.objectContaining({ credentials: "same-origin" }))

    fireEvent.click(screen.getByRole("button", { name: "Timeline (1 run)" }))

    expect(await screen.findByText("Workflow created")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Workflow created" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-5")
    expect(screen.getByRole("link", { name: "WF-5" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-5")
    expect(screen.getByRole("button", { name: "Timeline (1 run)" })).toHaveAttribute("aria-expanded", "true")
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/timeline", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("renders workflow pagination on the Job detail workflows tab", async () => {
    const payload = jobDetailPayload({
      job: { workflows_count: 12 },
      workflows: [
        {
          ...jobDetailPayload().workflows[0],
          id: 15,
          slug: "WF-15",
          path: "/jobs/42?tab=workflows&workflows_page=2#workflow-15",
          trigger_kind: "retry",
          steps: []
        },
        {
          ...jobDetailPayload().workflows[0],
          id: 16,
          slug: "WF-16",
          path: "/jobs/42?tab=workflows&workflows_page=2#workflow-16",
          trigger_kind: "pr_comment",
          steps: []
        }
      ],
      workflows_pagination: {
        page: 2,
        per_page: 10,
        total_workflows: 12,
        total_pages: 2,
        first_item: 11,
        last_item: 12,
        previous_path: "/jobs/42?tab=workflows&workflows_page=1",
        next_path: null
      }
    })
    // Both the initial job detail fetch and the dedicated paginated workflows
    // fetch land on this mock; a Response body can only be read once, so a
    // shared instance (mockResolvedValue) would make the second read fail.
    // Build a fresh Response per call instead.
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(payload)))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows&workflows_page=2"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Workflows (12)" })).toBeInTheDocument()
    expect(await screen.findByText("WF-15")).toBeInTheDocument()
    expect(screen.getByText("WF-16")).toBeInTheDocument()
    expect(screen.getAllByText("Showing 11-12 of 12")).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "Previous" })[0]).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows&workflows_page=1")
    expect(screen.getAllByText("Next")[0]).toHaveClass("text-gray-300")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/42?workflows_page=2",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/42/workflows?workflows_page=2",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("shares one workflow-list fetch between the Workflows and Timeline tabs and renders the selected workflow's waterfall", async () => {
    const payload = jobDetailPayload()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/jobs/42/waterfall")) {
        return Promise.resolve(jsonResponse(jobWaterfallPayload({ admin: true })))
      }
      return Promise.resolve(jsonResponse(payload))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=timeline"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("combobox", { name: "Workflow" })).toHaveValue("5")
    expect(await screen.findByText("Workflow #5 · initial · succeeded")).toBeInTheDocument()
    expect(screen.getByText("ran on host worker-a")).toBeInTheDocument()

    const workflowsFetchCount = () => fetchSpy.mock.calls.filter(([input]) => String(input).startsWith("/api/v1/app/jobs/42/workflows")).length
    expect(workflowsFetchCount()).toBe(1)

    fireEvent.click(screen.getByRole("button", { name: "Workflows (1)" }))
    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    expect(workflowsFetchCount()).toBe(1)

    fireEvent.click(screen.getByRole("button", { name: "Timeline" }))
    expect(await screen.findByText("Workflow #5 · initial · succeeded")).toBeInTheDocument()
    expect(workflowsFetchCount()).toBe(1)
  })

  it("fetches a fresh waterfall when a different Workflow is selected on the Timeline tab", async () => {
    const payload = jobDetailPayload({
      job: { workflows_count: 2 },
      workflows: [
        { ...jobDetailPayload().workflows[0], id: 5, trigger_kind: "initial", state: "succeeded" },
        { ...jobDetailPayload().workflows[0], id: 15, trigger_kind: "pr_comment", state: "running", started_at: "2026-06-01T09:00:00Z", finished_at: null }
      ]
    })
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/jobs/42/waterfall?workflow_id=15")) {
        return Promise.resolve(jsonResponse(jobWaterfallPayload({ workflowId: 15, triggerKind: "pr_comment", status: "running" })))
      }
      if (path.startsWith("/api/v1/app/jobs/42/waterfall")) {
        return Promise.resolve(jsonResponse(jobWaterfallPayload({ workflowId: 5 })))
      }
      return Promise.resolve(jsonResponse(payload))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=timeline"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Workflow #5 · initial · succeeded")).toBeInTheDocument()

    fireEvent.change(screen.getByRole("combobox", { name: "Workflow" }), { target: { value: "15" } })

    expect(await screen.findByText("Workflow #15 · pr_comment · running")).toBeInTheDocument()
  })

  it("renders the Timeline tab waterfall without worker-identity fields for a non-admin payload", async () => {
    const payload = jobDetailPayload()
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/jobs/42/waterfall")) {
        return Promise.resolve(jsonResponse(jobWaterfallPayload({ admin: false })))
      }
      return Promise.resolve(jsonResponse(payload))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=timeline"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Workflow #5 · initial · succeeded")).toBeInTheDocument()
    expect(screen.queryByText(/ran on host/)).not.toBeInTheDocument()
    expect(screen.queryByText("undefined")).not.toBeInTheDocument()
    expect(document.body.textContent).not.toContain("undefined")

    const runBar = screen.getByRole("img", { name: "Run #500 · succeeded" })
    fireEvent.mouseEnter(runBar)
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Run #500")
    expect(screen.getByRole("tooltip")).not.toHaveTextContent("undefined")
  })

  it("renders running Job, Step, and Run pills with progress spinners", async () => {
    const payload = jobDetailPayload({ job: { summary_state: "running" } })
    payload.workflows[0].state = "running"
    payload.workflows[0].steps[0].state = "running"
    payload.workflows[0].steps[0].runs[0].state = "running"

    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    expect(screen.getAllByText("running")).toHaveLength(2)
    fireEvent.click(screen.getByRole("button", { name: /Implement/i }))
    const runningLabels = screen.getAllByText("running")

    expect(runningLabels).toHaveLength(3)
    const pillRunningLabels = runningLabels.filter((l) => l.closest("[data-status-pill='true']"))
    expect(pillRunningLabels).toHaveLength(2)
    for (const label of pillRunningLabels) expectRunningPill(label)
  })

  it("shows active retried runs before earlier failed runs on the workflows tab", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const step = workflow.steps[0]
    const failedRun = {
      ...step.runs[0],
      id: 9,
      state: "failed",
      started_at: "2026-05-30T10:01:00Z",
      finished_at: "2026-05-30T10:15:00Z",
      created_at: "2026-05-30T10:00:00Z",
      updated_at: "2026-05-30T10:15:00Z"
    }
    const runningRun = {
      ...step.runs[0],
      id: 10,
      state: "running",
      started_at: "2026-05-30T10:20:00Z",
      finished_at: null,
      created_at: "2026-05-30T10:19:00Z",
      updated_at: "2026-05-30T10:20:00Z",
      can_stop: true,
      can_diagnose: false,
      can_resume: false
    }
    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: { state: "open", summary_state: "running", any_active_run: true },
              workflows: [
                {
                  ...workflow,
                  state: "running",
                  finished_at: null,
                  steps: [
                    {
                      ...step,
                      state: "failed",
                      display_status: "failed",
                      finished_at: null,
                      runs: [failedRun, runningRun]
                    }
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.queryByText(/Run #10 is running/)).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    expect(await screen.findByText(/Run #10 is running/)).toBeInTheDocument()
    expect(screen.getByText("step failed")).toBeInTheDocument()
    expect(screen.getByText("Run #10").compareDocumentPosition(screen.getByText("Run #9"))).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })

  it.each([
    ["ready_waiting_for_slot", { queue_name: "runs", live_worker_count: 2 }, "all of its threads are in use", "bg-info-surface", "pending"],
    [
      "ready_no_consumer",
      { queue_name: "resume-storage-a", live_worker_count: 2 },
      "Worker unavailable; this run will be rerouted automatically",
      "bg-warning-surface",
      "pending"
    ],
    ["concurrency_blocked", { queue_name: "runs" }, "concurrency lock", "bg-warning-surface", "pending"],
    ["scheduled", { queue_name: "runs", scheduled_at: "2026-05-30T12:00:00Z" }, "scheduled to become ready", "bg-info-surface", "pending"],
    ["claimed_not_started", { queue_name: "runs" }, "claimed the RunJob", "bg-info-surface", "workers"],
    ["no_run_job", {}, "Syrus will recover it automatically", "bg-info-surface", null],
    ["no_live_workers", { queue_name: "runs" }, "No live worker heartbeat", "bg-warning-surface", "workers"],
    ["start_blocked", { reason: "no_capable_worker" }, "Waiting on worker capability", "bg-warning-surface", null],
    [
      "host_admission_deferred",
      {
        reason: "host_resource_semaphore_busy",
        deferral_count: 3,
        first_deferred_at: "2026-05-30T11:58:00Z",
        resource_guard_binding_terms: ["memory_reservation"],
        active_reserved_memory_bytes: 4294967296,
        candidate_reserved_memory_bytes: 8589934592,
        candidate_memory_evidence_source: "command_attributed",
        host_memory_budget_bytes: 15032385536,
        grader_memory_reserve_bytes: 4294967296
      },
      "command-attributed evidence",
      "bg-warning-surface",
      "workers"
    ],
    ["unknown", {}, "could not determine", "bg-neutral-surface", "pending"]
  ])("explains queued run diagnosis %s with the appropriate tone", async (kind, details, copy, toneClass, link) => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const step = workflow.steps[0] as JobStep
    const queuedRun = {
      ...step.runs[0],
      id: 30,
      state: "queued",
      started_at: null,
      finished_at: null,
      created_at: "2026-05-30T10:00:00Z",
      updated_at: "2026-05-30T10:00:00Z",
      queue_wait: { kind, details }
    }
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: { state: "open", summary_state: "running", any_active_run: true },
              workflows: [
                {
                  ...workflow,
                  state: "running",
                  finished_at: null,
                  steps: [{ ...step, state: "queued", display_status: "queued", finished_at: null, runs: [queuedRun] }]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    expect(await screen.findByText(/Run #30 is waiting for a worker/)).toBeInTheDocument()
    const message = screen.getByText(new RegExp(copy, "i"))
    expect(message.closest(`.${toneClass}`)).toBeInTheDocument()
    if (link) {
      const label = link === "repair" ? /Stuck Jobs bulk repair/i : new RegExp(`Queue.*${link}`, "i")
      const href = link === "repair" ? "/app-shell/admin/stuck" : `/app-shell/admin/queue/${link}`
      expect(screen.getByRole("link", { name: label })).toHaveAttribute("href", href)
    }
    if (kind === "no_run_job") {
      expect(screen.queryByText(/RunJob/)).not.toBeInTheDocument()
      expect(screen.queryByText(/Retry the Job/)).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: /Queue.*Pending/i })).not.toBeInTheDocument()
    }
  })

  it("renders prepare failures as setup failures on the workflows tab", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const prepareRun = {
      ...template.runs[0],
      id: 16,
      state: "failed",
      agent_provider: null,
      agent_outcome: null,
      agent_turns: 0,
      agent_summary: null,
      agent_diff_present: false,
      agent_diff_bytes: 0,
      step_agent_diff_present: false,
      step_agent_diff_bytes: 0,
      step_diff_matches_diff: false,
      failure_classification: {
        id: 17,
        classification: "application_error",
        confidence: 0.4,
        retryable: false,
        reason: "The run failed with an unclassified application error.",
        diagnostic_summary: "Steps::Base::StepFailed: prepare command failed",
        classified_at: "2026-05-30T10:03:00Z"
      }
    }
    const prepareFailure = {
      command: "npm ci",
      workdir: "/workflows/42/repo",
      exit_status: 1,
      timed_out: false,
      output_tail: "npm ERR! missing package-lock.json"
    }

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: { state: "open", summary_state: "failed" },
              workflows: [
                {
                  ...workflow,
                  state: "failed",
                  failure_count: 1,
                  steps: [
                    {
                      ...template,
                      id: 15,
                      kind: "prepare",
                      display_name: "Prepare workspace",
                      display_status: "failed",
                      position: 0,
                      state: "failed",
                      details: { prepare_failure: prepareFailure },
                      runs: [prepareRun]
                    }
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: /Prepare workspace/i }))

    expect(screen.getByText("Setup failed before the agent started")).toBeInTheDocument()
    expect(screen.getByText("npm ci")).toBeInTheDocument()
    expect(screen.getByText("/workflows/42/repo")).toBeInTheDocument()
    expect(screen.getByText("exit 1")).toBeInTheDocument()
    expect(screen.getByText("npm ERR! missing package-lock.json")).toBeInTheDocument()
  })

  it("groups grader setup and aggregation under one Grade step", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const step = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: null,
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              workflows: [
                {
                  ...workflow,
                  steps: [
                    step({ id: 61, kind: "prepare", display_name: "Prepare workspace", display_status: "succeeded", position: 0, state: "succeeded" }),
                    step({
                      id: 62,
                      kind: "grader_fanout",
                      display_name: "Plan graders",
                      display_status: "succeeded",
                      position: 1,
                      loop_id: "grade-loop",
                      iteration: 1,
                      state: "succeeded"
                    }),
                    step({
                      id: 63,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: "failed",
                      position: 2,
                      loop_id: "grade-loop",
                      iteration: 1,
                      state: "failed",
                      details: {
                        name: "rspec",
                        required: true,
                        exit_code: 1,
                        duration_s: 2.4,
                        log_bytes: 2048,
                        description: "Full RSpec suite.",
                        command: "bin/rspec"
                      }
                    }),
                    step({
                      id: 64,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: "failed",
                      position: 3,
                      loop_id: "grade-loop",
                      iteration: 1,
                      state: "failed"
                    }),
                    step({ id: 65, kind: "push", display_name: "Push", display_status: null, position: 4, state: "queued" })
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: /Prepare workspace/i })).toBeInTheDocument()
    // A single-iteration grade loop whose sole item is the Grade step is
    // flattened: expanding "Grade loop" shows the grader phases directly,
    // with no intervening "Iteration 1" or nested "Grade" wrapper, and the
    // loop's own pills reflect the grader pass/fail counts.
    const gradeLoop = screen.getByRole("button", { name: /Grade loop/i })
    expect(within(gradeLoop).getByText("1 failed")).toBeInTheDocument()

    fireEvent.click(gradeLoop)
    expect(screen.queryByText("Iteration 1")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /^Grade$/i })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Push/i })).toBeInTheDocument()
    expect(screen.queryByText("Plan graders")).not.toBeInTheDocument()
    expect(screen.queryByText("Aggregate graders")).not.toBeInTheDocument()

    // The redundant "Grade summary" table is gone; the per-grader phase
    // cards render directly.
    expect(screen.queryByText("Grade summary")).not.toBeInTheDocument()
    expect(screen.queryByText("Open an individual grader below to view raw logs.")).not.toBeInTheDocument()
    expect(screen.queryByText("exit 1")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Setup/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Result/i })).toBeInTheDocument()

    // Expanding a grader shows the compact details (no raw JSON).
    fireEvent.click(screen.getByRole("button", { name: /rspec/i }))
    expect(screen.getByText("Required to pass")).toBeInTheDocument()
    expect(screen.getByText("Full RSpec suite.")).toBeInTheDocument()
    expect(screen.getByText("bin/rspec")).toBeInTheDocument()
    expect(screen.queryByText(/"log_bytes"/)).not.toBeInTheDocument()
  })

  it("groups preflight graders under one collapsed Preflight graders step with grader names", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const step = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: null,
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              workflows: [
                {
                  ...workflow,
                  steps: [
                    step({
                      id: 71,
                      kind: "preflight_grader_fanout",
                      display_name: "Plan preflight graders",
                      display_status: "succeeded",
                      position: 0,
                      state: "succeeded"
                    }),
                    step({
                      id: 72,
                      kind: "preflight_grader",
                      display_name: "Migration Collisions",
                      display_status: "succeeded",
                      position: 1,
                      state: "succeeded",
                      details: {
                        name: "migration-collisions",
                        required: true,
                        exit_code: 0,
                        duration_s: 1.1,
                        log_bytes: 512,
                        description: "Check for migration timestamp collisions.",
                        command: "bin/check-migration-collisions"
                      }
                    }),
                    step({
                      id: 73,
                      kind: "preflight_grader",
                      display_name: "RSpec",
                      display_status: "failed",
                      position: 2,
                      state: "failed",
                      details: {
                        name: "rspec",
                        required: true,
                        exit_code: 1,
                        duration_s: 5.2,
                        log_bytes: 4096,
                        description: "Full RSpec suite.",
                        command: "bin/rspec"
                      }
                    }),
                    step({
                      id: 74,
                      kind: "preflight_grader_collect",
                      display_name: "Preflight grader check",
                      display_status: "failed",
                      position: 3,
                      state: "failed"
                    }),
                    step({ id: 75, kind: "prepare", display_name: "Prepare workspace", display_status: null, position: 4, state: "queued" })
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const preflightGroup = await screen.findByRole("button", { name: /Preflight graders/i })
    expect(preflightGroup).toBeInTheDocument()
    expect(within(preflightGroup).getAllByText(/failed/i).length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: /Prepare workspace/i })).toBeInTheDocument()

    // Internal step names are hidden while collapsed
    expect(screen.queryByText("Plan preflight graders")).not.toBeInTheDocument()
    expect(screen.queryByText("Preflight grader check")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Migration Collisions/i })).not.toBeInTheDocument()

    fireEvent.click(preflightGroup)

    // Setup and Result phases are shown; individual graders use their humanized names
    expect(screen.getByRole("button", { name: /Setup/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Result/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Migration Collisions/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /rspec/i })).toBeInTheDocument()

    // Expanding a preflight grader shows the compact GraderDetails, not raw JSON
    fireEvent.click(screen.getByRole("button", { name: /rspec/i }))
    expect(screen.getByText("Required to pass")).toBeInTheDocument()
    expect(screen.getByText("Full RSpec suite.")).toBeInTheDocument()
    expect(screen.getByText("bin/rspec")).toBeInTheDocument()
    expect(screen.queryByText(/"log_bytes"/)).not.toBeInTheDocument()
  })

  it("groups repeated loop iterations on the workflows tab", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const run = template.runs[0]
    const loopStep = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: "loop-a",
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: { state: "open", summary_state: "running", any_active_run: true },
              workflows: [
                {
                  ...workflow,
                  state: "running",
                  finished_at: null,
                  steps: [
                    loopStep({
                      id: 61,
                      kind: "implement",
                      display_name: "Implement",
                      display_status: "succeeded",
                      position: 1,
                      iteration: 1,
                      state: "succeeded",
                      runs: [{ ...run, id: 91, state: "succeeded" }]
                    }),
                    loopStep({
                      id: 62,
                      kind: "grader_fanout",
                      display_name: "Plan graders",
                      display_status: "succeeded",
                      position: 2,
                      iteration: 1,
                      state: "succeeded"
                    }),
                    loopStep({
                      id: 63,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: "failed",
                      position: 3,
                      iteration: 1,
                      state: "failed",
                      details: { name: "rspec" }
                    }),
                    loopStep({
                      id: 64,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: "failed",
                      position: 4,
                      iteration: 1,
                      state: "failed"
                    }),
                    loopStep({
                      id: 65,
                      kind: "implement",
                      display_name: "Implement",
                      display_status: "running",
                      position: 5,
                      iteration: 2,
                      state: "running",
                      latest: true,
                      runs: [{ ...run, id: 92, state: "running", started_at: "2026-05-30T10:20:00Z", finished_at: null }]
                    }),
                    loopStep({ id: 66, kind: "grader_fanout", display_name: "Plan graders", display_status: null, position: 6, iteration: 2, state: "queued" }),
                    loopStep({
                      id: 67,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: null,
                      position: 7,
                      iteration: 2,
                      state: "queued",
                      details: { name: "rspec" }
                    }),
                    loopStep({
                      id: 68,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: null,
                      position: 8,
                      iteration: 2,
                      state: "queued"
                    })
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: /Grade loop/ })).toBeInTheDocument()
    expect(within(screen.getByRole("button", { name: /Grade loop/ })).getByText(/running/i)).toBeInTheDocument()
    expect(screen.getByText("2 iterations")).toBeInTheDocument()
    expect(screen.queryByText("Iteration 1")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /rspec/i })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Grade loop/ }))

    expect(screen.getByText("Iteration 1")).toBeInTheDocument()
    expect(screen.getByText("Iteration 2")).toBeInTheDocument()
    expect(screen.queryByText("Plan graders")).not.toBeInTheDocument()
    expect(screen.queryByText("Aggregate graders")).not.toBeInTheDocument()
    const iterationOne = screen.getByText("Iteration 1").parentElement!
    fireEvent.click(within(iterationOne).getByRole("button", { name: /Grade/i }))
    expect(within(iterationOne).getByRole("button", { name: /rspec/i })).toBeInTheDocument()
    expect(within(iterationOne).getByRole("button", { name: /Setup/i })).toBeInTheDocument()
    expect(within(iterationOne).getByRole("button", { name: /Result/i })).toBeInTheDocument()
  })

  it("shows the grade loop status from the latest iteration", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const run = template.runs[0]
    const loopStep = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: "loop-a",
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              workflows: [
                {
                  ...workflow,
                  state: "succeeded",
                  steps: [
                    loopStep({
                      id: 61,
                      kind: "implement",
                      display_name: "Implement",
                      display_status: "succeeded",
                      position: 1,
                      iteration: 1,
                      state: "succeeded"
                    }),
                    loopStep({
                      id: 62,
                      kind: "grader_fanout",
                      display_name: "Plan graders",
                      display_status: "succeeded",
                      position: 2,
                      iteration: 1,
                      state: "succeeded"
                    }),
                    loopStep({
                      id: 63,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: "failed",
                      position: 3,
                      iteration: 1,
                      state: "failed",
                      details: { name: "rspec" }
                    }),
                    loopStep({
                      id: 64,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: "failed",
                      position: 4,
                      iteration: 1,
                      state: "failed"
                    }),
                    loopStep({
                      id: 65,
                      kind: "implement",
                      display_name: "Implement",
                      display_status: "succeeded",
                      position: 5,
                      iteration: 2,
                      state: "succeeded",
                      runs: [{ ...run, id: 92, state: "succeeded" }]
                    }),
                    loopStep({
                      id: 66,
                      kind: "grader_fanout",
                      display_name: "Plan graders",
                      display_status: "succeeded",
                      position: 6,
                      iteration: 2,
                      state: "succeeded"
                    }),
                    loopStep({
                      id: 67,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: "succeeded",
                      position: 7,
                      iteration: 2,
                      state: "succeeded",
                      details: { name: "rspec" }
                    }),
                    loopStep({
                      id: 68,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: "succeeded",
                      position: 8,
                      iteration: 2,
                      state: "succeeded"
                    })
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const gradeLoop = await screen.findByRole("button", { name: /Grade loop/ })
    expect(within(gradeLoop).getByText(/succeeded/i)).toBeInTheDocument()
    expect(within(gradeLoop).queryByText(/failed/i)).not.toBeInTheDocument()
  })

  it("does not show a grade loop status for materialized future queued steps", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const loopStep = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: "loop-a",
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: { state: "open", summary_state: "running", any_active_run: true },
              workflows: [
                {
                  ...workflow,
                  state: "running",
                  finished_at: null,
                  steps: [
                    loopStep({
                      id: 61,
                      kind: "implement",
                      display_name: "Implement",
                      display_status: "succeeded",
                      position: 1,
                      iteration: 1,
                      state: "succeeded"
                    }),
                    loopStep({
                      id: 62,
                      kind: "grader_fanout",
                      display_name: "Plan graders",
                      display_status: "succeeded",
                      position: 2,
                      iteration: 1,
                      state: "succeeded"
                    }),
                    loopStep({
                      id: 63,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: "failed",
                      position: 3,
                      iteration: 1,
                      state: "failed",
                      details: { name: "rspec" }
                    }),
                    loopStep({
                      id: 64,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: "failed",
                      position: 4,
                      iteration: 1,
                      state: "failed"
                    }),
                    loopStep({
                      id: 65,
                      kind: "implement",
                      display_name: "Implement",
                      display_status: "succeeded",
                      position: 5,
                      iteration: 2,
                      state: "succeeded"
                    }),
                    loopStep({ id: 66, kind: "grader_fanout", display_name: "Plan graders", display_status: null, position: 6, iteration: 2, state: "queued" }),
                    loopStep({
                      id: 67,
                      kind: "grader",
                      display_name: "rspec",
                      display_status: null,
                      position: 7,
                      iteration: 2,
                      state: "queued",
                      details: { name: "rspec" }
                    }),
                    loopStep({
                      id: 68,
                      kind: "grader_collect",
                      display_name: "Aggregate graders",
                      display_status: null,
                      position: 8,
                      iteration: 2,
                      state: "queued"
                    })
                  ]
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const gradeLoop = await screen.findByRole("button", { name: /Grade loop/ })
    expect(within(gradeLoop).queryByText(/queued/i)).not.toBeInTheDocument()
    expect(within(gradeLoop).queryByText(/succeeded/i)).not.toBeInTheDocument()
    expect(within(gradeLoop).queryByText(/failed/i)).not.toBeInTheDocument()
  })
})
