import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { stubVirtualizerMeasurementsForTest } from "../test/virtualizerMeasurements"
import { App } from "./App"
import { actionCable } from "../test/app/appMocks"
import { jobDetailPayload, jobTimelinePayload } from "../test/app/jobPayloads"
import { mockClipboardWrite, setScrollMetrics } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App Job detail", () => {
  installAppTestLifecycle()

  it("renders a Job detail page and runs commands through the app API", async () => {
    // Renders a workflow-artifact diff, which goes through ReviewableDiff's
    // file-level virtualizer -- see virtualizerMeasurements.ts.
    stubVirtualizerMeasurementsForTest()
    const payload = jobDetailPayload({
      landing_queue_entry: {
        position: 1,
        blocked_reason: { key: "waiting_epic_siblings" },
        waiting_for_jobs: [{ id: 43, label: "#43", title: "Approve sibling aqueduct", job_path: "/jobs/43" }]
      },
      dependencies: [
        {
          id: 13,
          source: "parsed",
          manual: false,
          pending: false,
          succeeded: true,
          unresolved_slug: null,
          depends_on_job: {
            id: 44,
            kind: "issue",
            state: "closed",
            summary_state: "closed",
            repository_slug: "acme/widgets",
            issue_number: 84,
            issue_title: "Polish the dependency",
            branch_name: "syrus/issue-84",
            pr_number: 101,
            job_path: "/jobs/44"
          }
        }
      ],
      dependents: [
        {
          id: 12,
          source: "manual",
          job: {
            id: 41,
            kind: "issue",
            state: "open",
            summary_state: "implemented",
            repository_slug: "acme/widgets",
            issue_number: 11,
            issue_title: "Build hill",
            branch_name: "syrus/issue-11",
            pr_number: 76,
            job_path: "/jobs/41"
          }
        }
      ]
    })
    const gradeStep = payload.workflows[0].steps[0] as {
      kind: string
      display_name: string
      details: unknown
      runs: Array<{ app_grade_log_path: string | null }>
    }
    gradeStep.kind = "grader"
    gradeStep.display_name = "tests"
    gradeStep.details = { name: "tests", command: "bin/rspec" }
    gradeStep.runs[0].app_grade_log_path = "/api/v1/app/jobs/42/runs/9/grade_log?name=tests&workflow_id=5"
    const clipboardWrite = mockClipboardWrite()
    let artifactFetchCount = 0
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/claim" && init?.method === "POST") {
        Object.assign(payload.job as Record<string, unknown>, {
          claimed_by_user: { id: 2, display_name: "Ada Lovelace", profile_path: "/profiles/2" },
          claimed_at: "2026-06-03T05:50:00Z",
          claimed_by_current_user: true
        })
        Object.assign(payload.actions as Record<string, unknown>, { can_claim: false, can_unclaim: true })
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Job claimed.", job: payload.job }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/poll_feedback" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Checking PR feedback now..." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/runs/9/grade_log?name=tests&workflow_id=5") {
        return Promise.resolve(
          new Response(JSON.stringify({ job_id: 42, run_id: 9, name: "tests", contents: "rspec output\n" }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/jobs/42/runs/9/artifacts?artifact=transcript&page=1") {
        artifactFetchCount += 1
        return Promise.resolve(
          new Response(
            JSON.stringify({
              job_id: 42,
              run_id: 9,
              artifact: "transcript",
              logs_count: artifactFetchCount > 1 ? 3 : 2,
              logs_page: 1,
              logs_per_page: 100,
              logs_total_pages: 1,
              logs_has_older: false,
              logs: [
                { id: 1, sequence: 0, kind: "assistant_text", chunk: "digging trench", created_at: "2026-05-30T10:02:00Z" },
                { id: 2, sequence: 1, kind: "tool_call", chunk: "found marble", created_at: "2026-05-30T10:03:00Z" },
                ...(artifactFetchCount > 1 ? [{ id: 3, sequence: 2, kind: "system", chunk: "new marble", created_at: "2026-05-30T10:04:00Z" }] : [])
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/jobs/42/runs/9/artifacts?artifact=agent_diff&page=1") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              job_id: 42,
              run_id: 9,
              artifact: "agent_diff",
              agent_diff:
                "diff --git a/app.rb b/app.rb\nindex 1111111..2222222 100644\n--- a/app.rb\n+++ b/app.rb\n@@ -1,2 +1,2 @@\n-puts 'old forum'\n+puts 'forum'\n context\n",
              agent_diff_bytes: 140
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
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

    expect(await screen.findByRole("main", { name: "Job" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { level: 1, name: /Repair aqueduct/ })).toHaveClass("text-text-primary")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("target", "_blank")
    const copySlugButton = screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })
    expect(copySlugButton).toHaveTextContent("JOB-42")
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-42"))
    expect(screen.getByRole("button", { name: "Copy JOB-41 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByText(/acme\/widgets JOB-41/)).not.toBeInTheDocument()
    expect(screen.getByText("Water should climb the hill.")).toBeInTheDocument()
    expect(screen.getByText("Moved the uphill water simulation.")).toBeInTheDocument()
    expect(screen.getByText(/In landing queue: position #1/)).toHaveTextContent("Waiting for Epic siblings to be approved")
    expect(screen.getByRole("link", { name: "#43 Approve sibling aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/43")
    expect(screen.getByRole("button", { name: "Copy JOB-44 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByText(/acme\/widgets JOB-44/)).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /^Timeline \(/ })).not.toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Add tag")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add tag" })).toBeInTheDocument()
    expect(screen.getByText("No work claim")).toBeInTheDocument()

    // One landmark per page: the chrome's scroll container used to be a
    // second <main> wrapped around the route's own, which is invalid HTML and
    // left getByRole("main") ambiguous.
    expect(screen.getAllByRole("main")).toHaveLength(1)

    fireEvent.click(screen.getByRole("button", { name: "Claim work" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/claim", expect.objectContaining({ method: "POST", credentials: "same-origin" }))
    })
    expect(await screen.findByText("Job claimed.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Check feedback" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/poll_feedback", expect.objectContaining({ method: "POST", credentials: "same-origin" }))
    })
    expect(await screen.findByText("Checking PR feedback now...")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Workflows (1)" }))
    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    expect(screen.getByText("WF-5").closest("section")).toHaveClass("bg-surface", "border-border")
    fireEvent.click(screen.getByRole("button", { name: /Grade/i }))
    fireEvent.click(screen.getByRole("button", { name: /tests/i }))
    expect(screen.getByText("Run #9")).toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Add tag")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Transcript" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/runs/9/artifacts?artifact=transcript&page=1",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
    expect(await screen.findByText("digging trench")).toBeInTheDocument()
    expect(screen.getByTestId("run-transcript-log-assistant")).not.toHaveTextContent("Agent")
    expect(screen.getByTestId("run-transcript-log-stream")).toHaveClass("min-w-0", "overflow-x-hidden")
    expect(screen.getByText("Tool")).toBeInTheDocument()
    expect(screen.queryByText("assistant_text")).not.toBeInTheDocument()
    expect(screen.queryByText("tool_call")).not.toBeInTheDocument()
    const transcriptStream = screen.getByTestId("run-transcript-log-stream")
    expect(transcriptStream.closest("section")).toHaveClass("max-md:fixed", "max-md:inset-0", "max-md:h-[100dvh]")
    expect(screen.getByRole("button", { name: "Close artifact viewer" })).toBeInTheDocument()
    setScrollMetrics(transcriptStream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 600 })
    fireEvent.scroll(transcriptStream)
    setScrollMetrics(transcriptStream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 600 })

    const subscriptionCalls = actionCable.createSubscription.mock.calls as unknown[][]
    const appEventSubscription = subscriptionCalls.at(-1)?.[1] as { received?: (event: unknown) => void } | undefined
    act(() => {
      appEventSubscription?.received?.({
        type: "job.updated",
        resource: "job",
        id: 42,
        changed: ["run.updated", "job_logs"],
        occurred_at: "2026-05-30T10:04:00.000Z"
      })
    })
    await waitFor(() => {
      expect(fetchSpy.mock.calls.filter(([path]) => String(path) === "/api/v1/app/jobs/42/runs/9/artifacts?artifact=transcript&page=1")).toHaveLength(2)
    })
    expect(await screen.findByText("new marble")).toBeInTheDocument()
    expect(screen.getByText("System")).toBeInTheDocument()
    expect(screen.queryByText("system")).not.toBeInTheDocument()
    await waitFor(() => expect(transcriptStream.scrollTop).toBe(1200))

    fireEvent.click(screen.getByRole("button", { name: "Diff" }))
    expect(await screen.findByText(/diff --git a\/app.rb b\/app.rb/)).toBeInTheDocument()
    expect(screen.getByTestId("agent-diff-viewer").closest("section")).toHaveClass("max-md:fixed", "max-md:inset-0", "max-md:h-[100dvh]")
    // Word highlighting wraps each token in its own <span>, so a multi-token
    // line's text is spread across siblings; match on the code cell's full
    // textContent instead of getByText's direct-text-node-only default.
    const codeCellText = (text: string) => screen.getByText((_, element) => Boolean(element && element.tagName === "TD" && element.textContent === text))
    expect(codeCellText("puts 'old forum'").closest("tr")).toHaveAttribute("data-diff-kind", "delete")
    expect(codeCellText("puts 'forum'").closest("tr")).toHaveAttribute("data-diff-kind", "add")
    expect(codeCellText("context").closest("tr")).toHaveAttribute("data-diff-kind", "context")

    fireEvent.click(screen.getByRole("button", { name: "Grade log" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/runs/9/grade_log?name=tests&workflow_id=5",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
    expect(await screen.findByText("tests grade log")).toBeInTheDocument()
    expect(screen.getByText("rspec output")).toBeInTheDocument()
    const gradeLogStream = screen.getByTestId("run-grade-log-stream")
    expect(gradeLogStream.closest("section")).toHaveClass("max-md:fixed", "max-md:inset-0", "max-md:h-[100dvh]")
    fireEvent.click(screen.getByRole("button", { name: "Close artifact viewer" }))
    expect(screen.queryByText("rspec output")).not.toBeInTheDocument()
  })

  it("keeps legacy transcript rows separate instead of coalescing tool output", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/runs/9/artifacts?artifact=transcript&page=1") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              job_id: 42,
              run_id: 9,
              agent_diff: null,
              agent_diff_bytes: 0,
              logs_count: 6,
              logs: [
                { id: 1, sequence: 0, kind: "system", chunk: "[prepare] (1/2) $ bundle install", created_at: "2026-05-30T10:02:00Z" },
                { id: 2, sequence: 1, kind: "system", chunk: "Fetching rack 3.2.6", created_at: "2026-05-30T10:02:01Z" },
                { id: 3, sequence: 2, kind: "system", chunk: "Fetching rack-session 2.1.2", created_at: "2026-05-30T10:02:02Z" },
                { id: 4, sequence: 3, kind: "system", chunk: "[prepare] (2/2) $ npm ci", created_at: "2026-05-30T10:02:03Z" },
                { id: 5, sequence: 4, kind: "system", chunk: "added 42 packages", created_at: "2026-05-30T10:02:04Z" },
                { id: 6, sequence: 5, kind: "tool_call", chunk: "bundle install", created_at: "2026-05-30T10:02:05Z" }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Workflows (1)" }))
    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    fireEvent.click(screen.getByRole("button", { name: "Transcript" }))

    await screen.findByText("bundle install")
    const systemRows = screen.getAllByTestId("run-transcript-log-system")
    expect(systemRows).toHaveLength(6)
    expect(systemRows[0]).toHaveTextContent("[prepare] (1/2) $ bundle install")
    expect(systemRows[1]).toHaveTextContent("Fetching rack 3.2.6")
    expect(systemRows[2]).toHaveTextContent("Fetching rack-session 2.1.2")
    expect(systemRows[3]).toHaveTextContent("[prepare] (2/2) $ npm ci")
    expect(systemRows[4]).toHaveTextContent("added 42 packages")
    expect(systemRows[5]).toHaveTextContent("bundle install")
  })

  it("uses the job name as the Job detail title and moves source metadata below it", async () => {
    const payload = jobDetailPayload({
      job: {
        kind: "direct",
        issue_number: null,
        issue_title: "Investigate viewport report"
      }
    })
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { level: 1, name: /Investigate viewport report/ })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByText("Direct Job")).toBeInTheDocument()
    expect(screen.getAllByText("implemented").length).toBeGreaterThan(0)
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.queryByText("pat")).not.toBeInTheDocument()
  })

  it("links to the Epic from the Job detail summary when the Job belongs to one", async () => {
    const payload = jobDetailPayload({
      epic: {
        id: 7,
        number: 7,
        display_number: "EPIC-7",
        title: "Raise the aqueduct",
        state: "in_progress",
        epic_path: "/epics/7"
      }
    })
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Raise the aqueduct" })).toHaveAttribute("href", "/app-shell/epics/7")
    expect(screen.getByRole("button", { name: "Copy EPIC-7 to clipboard" })).toBeInTheDocument()
  })

  it("dispatches Job header commands through the app API", async () => {
    const commandPaths = new Map([
      ["/api/v1/app/jobs/42/start", "Initial workflow enqueued."],
      ["/api/v1/app/jobs/42/poll_feedback", "Feedback poll enqueued."],
      ["/api/v1/app/jobs/42/rebase", "Rebase workflow enqueued."],
      ["/api/v1/app/jobs/42/check_mergeability", "Checking mergeability now..."],
      ["/api/v1/app/jobs/42/visual_review", "Visual review enqueued."],
      ["/api/v1/app/jobs/42/visual_diff", "Before/after comparison enqueued."],
      ["/api/v1/app/jobs/42/run_again", "Retry workflow enqueued."],
      ["/api/v1/app/jobs/42/restart", "Started over."],
      ["/api/v1/app/jobs/42/approve", "Job approved."],
      ["/api/v1/app/jobs/42/unapprove", "Job unapproved."],
      ["/api/v1/app/jobs/42/cancel", "Cancellation requested."],
      ["/api/v1/app/jobs/42/reopen", "Thread reopened."],
      ["/api/v1/app/jobs/42/mark_valid", "Job marked valid and re-queued."],
      ["/api/v1/app/jobs/42/pin", "Job unpinned."]
    ])
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (commandPaths.has(path)) {
        return Promise.resolve(
          new Response(JSON.stringify({ message: commandPaths.get(path) }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              pinned: true,
              actions: {
                can_start: true,
                can_release_from_backlog: false,
                can_poll_feedback: true,
                can_recheck_pr_checks: true,
                can_rebase: true,
                can_check_mergeability: true,
                can_send_job_upstream: true,
                can_retry_pr_ingestion: true,
                can_run_visual_review: true,
                can_run_visual_diff: true,
                can_retry: true,
                retry_implementation_action: {
                  key: "retry_implementation",
                  label: "Retry implementation",
                  path: "/api/v1/app/jobs/42/run_again"
                },
                retry_failed_step_action: null,
                retry_agent_options: ["claude"],
                can_restart: true,
                can_cancel: true,
                can_open_in_coding_mode: true,
                can_open_in_local_mode: true,
                can_cancel_local_mode: true,
                can_approve: true,
                can_unapprove: true,
                can_reopen: true,
                can_mark_valid: true
              },
              paths: {
                app_recheck_pr_checks_path: "/api/v1/app/jobs/42/recheck_pr_checks",
                app_retry_pr_ingestion_path: "/api/v1/app/jobs/42/retry_pr_ingestion",
                app_open_in_coding_mode_path: "/api/v1/app/jobs/42/open_in_coding_mode",
                app_open_in_local_mode_path: "/api/v1/app/jobs/42/open_in_local_mode",
                app_cancel_local_mode_path: "/api/v1/app/jobs/42/cancel_local_mode",
                app_ref_movement_actions_path: "/api/v1/app/jobs/42/ref_movement_actions"
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const visibleCommands = [["Approve", "POST", "/api/v1/app/jobs/42/approve"]]
    const overflowCommands = [
      ["Open in Coding Mode", "POST", "/api/v1/app/jobs/42/open_in_coding_mode"],
      ["Open in Local Mode", "POST", "/api/v1/app/jobs/42/open_in_local_mode"],
      ["Cancel Local Mode", "POST", "/api/v1/app/jobs/42/cancel_local_mode"],
      ["Check feedback", "POST", "/api/v1/app/jobs/42/poll_feedback"],
      ["Recheck checks", "POST", "/api/v1/app/jobs/42/recheck_pr_checks"],
      ["Check mergeability", "POST", "/api/v1/app/jobs/42/check_mergeability"],
      ["Rebase now", "POST", "/api/v1/app/jobs/42/rebase"],
      ["Send upstream", "POST", "/api/v1/app/jobs/42/ref_movement_actions"],
      ["Retry PR ingestion", "POST", "/api/v1/app/jobs/42/retry_pr_ingestion"],
      ["Run visual review", "POST", "/api/v1/app/jobs/42/visual_review"],
      ["Run before/after comparison", "POST", "/api/v1/app/jobs/42/visual_diff"],
      ["Start over", "POST", "/api/v1/app/jobs/42/restart"],
      ["Unapprove", "POST", "/api/v1/app/jobs/42/unapprove"],
      ["Reopen", "POST", "/api/v1/app/jobs/42/reopen"],
      ["Mark valid", "POST", "/api/v1/app/jobs/42/mark_valid"],
      ["Start Run", "POST", "/api/v1/app/jobs/42/start"],
      ["Unpin", "DELETE", "/api/v1/app/jobs/42/pin"],
      ["Cancel", "POST", "/api/v1/app/jobs/42/cancel"]
    ]
    const overflowLabels = [
      "Give feedback",
      "Open in Coding Mode",
      "Open in Local Mode",
      "Cancel Local Mode",
      "Check feedback",
      "Recheck checks",
      "Check mergeability",
      "Rebase now",
      "Send upstream",
      "Retry PR ingestion",
      "Run visual review",
      "Run before/after comparison",
      "Retry with ...",
      "Start over",
      "Unapprove",
      "Reopen",
      "Mark valid",
      "Start Run",
      "Unpin",
      "Cancel"
    ]

    expect(await screen.findByRole("button", { name: "Approve" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Start Run" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.getByRole("menu")).toBeInTheDocument()
    expect(
      within(screen.getByRole("menu"))
        .getAllByRole("menuitem")
        .map((item) => item.textContent)
    ).toEqual(overflowLabels)
    expect(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Retry with ..." })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    await waitFor(() => {
      expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    })
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.getByRole("menu")).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    await waitFor(() => {
      expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    })

    for (const [label, method, path] of visibleCommands) {
      fireEvent.click(screen.getByRole("button", { name: label }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }

    for (const [label, method, path] of overflowCommands) {
      fireEvent.click(screen.getByRole("button", { name: "More actions" }))
      fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: label }))
      // Some commands guard with a ConfirmDialog; click through it when present
      const confirmBtn = await screen.findByRole("button", { name: "Confirm" }, { timeout: 200 }).catch(() => null)
      if (confirmBtn) await act(async () => fireEvent.click(confirmBtn))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Retry with ..." }))
    const retryDialog = await screen.findByRole("dialog", { name: "Retry with feedback" })
    fireEvent.change(within(retryDialog).getByLabelText("Provider"), { target: { value: "claude" } })
    fireEvent.change(within(retryDialog).getByLabelText("Feedback"), { target: { value: "Try the waterwheel route." } })
    fireEvent.click(within(retryDialog).getByRole("button", { name: "Retry" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/run_again",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ agent_provider: "claude", retry_context: "Try the waterwheel route." })
        })
      )
    })
  }, 60000)

  it("labels approval as reapproval after a landing failure", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: {
                landing_failure_reason: 'auto_merge: PR mergeable_state is "dirty" and rebase cap reached'
              },
              actions: {
                can_approve: true,
                can_retry: false,
                can_poll_feedback: false,
                can_rebase: false,
                can_check_mergeability: false,
                can_restart: false,
                can_cancel: false
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Reapprove" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()
  })

  it("shows a Stop Landing button for a landing job and stops landing on click", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/stop_landing" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Landing stopped." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              job: { state: "landing", summary_state: "landing" },
              actions: {
                can_approve: false,
                can_retry: false,
                can_poll_feedback: false,
                can_rebase: false,
                can_check_mergeability: false,
                can_restart: false,
                can_cancel: true,
                can_stop_landing: true
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stopLandingButton = await screen.findByRole("button", { name: "Stop Landing" })
    fireEvent.click(stopLandingButton)

    const confirmButton = await screen.findByRole("button", { name: "Confirm" })
    fireEvent.click(confirmButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/stop_landing", expect.objectContaining({ method: "POST" }))
    })
  })

  it("sends retry feedback from the Job header More menu", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/run_again" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Retry workflow enqueued." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              actions: {
                can_retry: true,
                retry_implementation_action: {
                  key: "retry_implementation",
                  label: "Retry implementation",
                  path: "/api/v1/app/jobs/42/run_again"
                },
                retry_failed_step_action: null,
                retry_agent_options: ["claude"],
                can_approve: false,
                can_poll_feedback: false,
                can_rebase: false,
                can_check_mergeability: false,
                can_restart: false,
                can_cancel: false
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Retry with ..." }))

    const dialog = screen.getByRole("dialog", { name: "Retry with feedback" })
    fireEvent.change(within(dialog).getByLabelText("Provider"), { target: { value: "claude" } })
    fireEvent.change(within(dialog).getByLabelText("Feedback"), { target: { value: "Please use the marble route this time." } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Retry" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/run_again",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ agent_provider: "claude", retry_context: "Please use the marble route this time." })
        })
      )
    })
    expect(await screen.findByText("Retry workflow enqueued.")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Retry with feedback" })).not.toBeInTheDocument()
    })
  })

  it("dispatches Job metadata controls through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/tags" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Tag added." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/tags/4" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Tag removed." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/stack_base" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Stack base updated." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/dependencies" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Dependency added." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/dependencies/9" && init?.method === "DELETE") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Dependency removed." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/admin/jobs/42/dependencies/override" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Dependency gate overridden." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              actions: { can_override_dependencies: true },
              dependencies: [
                {
                  id: 9,
                  source: "manual",
                  manual: true,
                  pending: false,
                  succeeded: false,
                  unresolved_slug: null,
                  depends_on_job: {
                    id: 41,
                    kind: "issue",
                    state: "open",
                    summary_state: "open",
                    repository_slug: "acme/widgets",
                    issue_number: 11,
                    issue_title: "Build hill",
                    branch_name: "syrus/issue-11",
                    pr_number: null,
                    job_path: "/jobs/41"
                  }
                }
              ],
              dependents: [
                {
                  id: 10,
                  source: "manual",
                  job: {
                    id: 43,
                    kind: "issue",
                    state: "open",
                    summary_state: "approved",
                    repository_slug: "acme/widgets",
                    issue_number: 13,
                    issue_title: "Pour aqueduct",
                    branch_name: "syrus/issue-13",
                    pr_number: 78,
                    job_path: "/jobs/43"
                  }
                }
              ],
              unsatisfied_dependencies: [
                {
                  id: 9,
                  source: "manual",
                  manual: true,
                  pending: false,
                  succeeded: false,
                  unresolved_slug: null,
                  depends_on_job: {
                    id: 41,
                    kind: "issue",
                    state: "open",
                    summary_state: "open",
                    repository_slug: "acme/widgets",
                    issue_number: 11,
                    issue_title: "Build hill",
                    branch_name: "syrus/issue-11",
                    pr_number: null,
                    job_path: "/jobs/41"
                  }
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
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findAllByRole("button", { name: "Copy JOB-41 to clipboard" })).toHaveLength(2)
    expect(screen.getByRole("button", { name: "Copy JOB-43 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByText(/acme\/widgets JOB-4/)).not.toBeInTheDocument()

    fireEvent.click(await screen.findByRole("button", { name: "+ Add tag" }))
    fireEvent.change(screen.getByPlaceholderText("Add tag"), { target: { value: "urgent" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Add" })[0])
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/tags",
        expect.objectContaining({ method: "POST", body: JSON.stringify({ tag_name: "urgent" }) })
      )
    })

    fireEvent.click(screen.getByTitle("Remove priority:forum"))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/tags/4", expect.objectContaining({ method: "DELETE" }))
    })

    fireEvent.change(screen.getByDisplayValue("auto"), { target: { value: "main" } })
    fireEvent.click(screen.getByRole("button", { name: "Update" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/stack_base",
        expect.objectContaining({ method: "PATCH", body: JSON.stringify({ stack_base: "main" }) })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "+ Add dependency" }))
    fireEvent.click(screen.getByRole("button", { name: "JOB-41 - Build hill" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/dependencies",
        expect.objectContaining({ method: "POST", body: JSON.stringify({ dependency_target: "issue:3:11" }) })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "Remove" }))
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/dependencies/9", expect.objectContaining({ method: "DELETE" }))
    })

    fireEvent.click(screen.getByRole("button", { name: "Override and force-run" }))
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/jobs/42/dependencies/override", expect.objectContaining({ method: "POST" }))
    })
  }, 30000)

  it("dispatches Job workflow and run commands through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/workflows/5/retry_step" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Retrying implement for WF-5..." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/workflows/5/push_commits" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Pushing commits to GitHub..." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/runs/9/stop" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Run stopped." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/runs/9/diagnose" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Diagnostic queued." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/resume" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Resume workflow enqueued." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            jobDetailPayload({
              workflows: [
                {
                  ...jobDetailPayload().workflows[0],
                  state: "failed",
                  cleaned_up_at: null,
                  retry_available: true,
                  steps: [
                    {
                      ...jobDetailPayload().workflows[0].steps[0],
                      state: "failed",
                      display_status: "failed",
                      runs: [
                        {
                          ...jobDetailPayload().workflows[0].steps[0].runs[0],
                          state: "failed",
                          can_stop: true,
                          can_diagnose: true,
                          can_resume: true
                        }
                      ]
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

    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /Implement/i }))
    const commands = [
      ["Retry failed step", "POST", "/api/v1/app/jobs/42/workflows/5/retry_step"],
      ["Push commits", "POST", "/api/v1/app/jobs/42/workflows/5/push_commits"],
      ["Stop", "POST", "/api/v1/app/jobs/42/runs/9/stop"],
      ["Diagnose", "POST", "/api/v1/app/jobs/42/runs/9/diagnose"]
    ]
    for (const [label, method, path] of commands) {
      fireEvent.click(screen.getByRole("button", { name: label }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }

    fireEvent.click(screen.getByRole("button", { name: "Resume" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/resume",
        expect.objectContaining({ method: "POST", body: JSON.stringify({ source_run_id: 9 }) })
      )
    })
  })

  it("adds and removes Job attachments through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/attachments" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Attachment added." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/attachments/8" && init?.method === "DELETE") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Attachment removed." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=attachments"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const file = new File(["notes"], "notes.md", { type: "text/markdown" })
    fireEvent.change(await screen.findByLabelText("Files"), { target: { files: [file] } })
    fireEvent.change(screen.getByLabelText("Google Doc URL"), { target: { value: "https://docs.google.com/document/d/context/edit" } })
    fireEvent.click(within(screen.getByRole("heading", { name: "Add attachment" }).closest("form")!).getByRole("button", { name: "Add" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/attachments", expect.objectContaining({ method: "POST", body: expect.any(FormData) }))
    })
    const formData = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/jobs/42/attachments" && init?.method === "POST")?.[1]?.body as FormData
    expect(formData.get("job_attachment[google_doc_url]")).toBe("https://docs.google.com/document/d/context/edit")
    expect(formData.get("job_attachment[files][]")).toBe(file)

    fireEvent.click(screen.getByRole("button", { name: "Remove" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/attachments/8", expect.objectContaining({ method: "DELETE" }))
    })
  })
})
