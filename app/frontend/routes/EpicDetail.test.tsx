import { jsonResponse } from "../testSupport"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import type { EpicDetailJob, EpicDetailPayload } from "../api/epics"
import { EpicDetail, EpicDetailRoute, JobsSection, ProgressBar, StateChips } from "./EpicDetail"

function job(state: string, overrides: Partial<EpicDetailJob> = {}): EpicDetailJob {
  return {
    id: Math.random(),
    slug: "JOB-1",
    label: "JOB-1",
    title: "A job",
    path: "/jobs/1",
    state,
    landed: false,
    pr_number: null,
    pr_url: null,
    owner_user_id: null,
    owner_user: null,
    repository_slug: "owner/repo",
    ...overrides
  }
}

function detailPayload(overrides: Partial<EpicDetailPayload["epic"]> = {}): EpicDetailPayload {
  return {
    message: null,
    epic: {
      id: 3,
      number: 3,
      display_number: "EPIC-3",
      title: "Onboarding",
      description: "",
      state: "ready",
      landing: false,
      stuck: false,
      startable: true,
      start_blocked_on: [],
      owner: null,
      owned_by_current_user: false,
      claimable: true,
      claimed_at: null,
      github_issue_url: "",
      updated_at: new Date().toISOString(),
      archived: false,
      jobs_count: 0,
      epic_path: "/epics/3",
      owner_user_id: null,
      owner_status: "unclaimed",
      owner_user: null,
      repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1", epic_dependency_policy: "linear" },
      max_commits_behind_base: null,
      furthest_behind_job_id: null,
      furthest_behind_job_path: null,
      epic_dependency_policy: "linear",
      resolved_epic_dependency_policy: "linear",
      ...overrides
    },
    summary: { done_jobs_count: 0, total_jobs_count: 0, dependency_edge_count: 0, blocked: false, blocked_reason: null, review_summary: null },
    state_transitions: [],
    graph: { empty: true, node_count: 0, epic_dependency_count: 0, job_blocker_count: 0, initially_open: false, nodes: [], edges: [] },
    dependencies: [],
    dependents: [],
    jobs: [],
    versions: [],
    paths: {
      dashboard_epics_path: "/dashboard/epics",
      edit_epic_path: "/epics/3/edit",
      app_state_path: "/api/v1/app/epics/3/state",
      app_start_path: "/api/v1/app/epics/3/start",
      app_archive_path: "/api/v1/app/epics/3/archive",
      app_claim_path: "/api/v1/app/epics/3/claim",
      app_unclaim_path: "/api/v1/app/epics/3/unclaim",
      app_reassign_path: "/api/v1/app/epics/3/reassign",
      app_dependencies_path: "/api/v1/app/epics/3/dependencies"
    }
  }
}

function renderDetail(payload: EpicDetailPayload) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <EpicDetail payload={payload} prefix="" />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("EpicDetail", () => {
  it("uses responsive page gutters while keeping the header inset", async () => {
    const payload = detailPayload({ title: "Mobile gutter audit" })
    payload.jobs = [job("ready")]
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/epics/3"]}>
          <Routes>
            <Route element={<EpicDetailRoute />} path="/epics/:id" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByText("Mobile gutter audit")
    const main = screen.getByRole("main")
    expect(main).toHaveClass("px-0", "sm:px-[var(--space-page-x)]")
    expect(main).not.toHaveClass("px-[var(--space-page-x)]")

    const header = main.querySelector("header")
    expect(header).toHaveAttribute("data-page-header-layout", "stacked")
    expect(header).toHaveClass("px-4", "sm:px-0", "block", "space-y-3")
    expect(header).not.toHaveClass("flex", "justify-between")

    const jobsSection = screen.getByRole("heading", { name: "Jobs" }).closest("section")
    expect(jobsSection).not.toHaveClass("px-4", "sm:px-0")
  })

  it("shows the Epic's own state when no child Job is landing", () => {
    renderDetail(detailPayload({ state: "in_progress", landing: false }))

    expect(screen.getByText("In Progress")).toBeInTheDocument()
    expect(screen.queryByText("Landing")).not.toBeInTheDocument()
  })

  it("shows landing as the apparent status when a child Job is landing", () => {
    renderDetail(detailPayload({ state: "in_progress", landing: true }))

    expect(screen.getByText("Landing")).toBeInTheDocument()
    expect(screen.queryByText("In Progress")).not.toBeInTheDocument()
  })

  it("stacks the detail header rows with long metadata and a failed merge-train banner", () => {
    const payload = detailPayload({
      title: "A deliberately long Epic title that should stay in the first stacked header row without distributing metadata",
      repository: {
        id: 1,
        slug: "very-long-owner-name/very-long-repository-name-with-many-segments",
        repository_path: "/repositories/1",
        epic_dependency_policy: "linear"
      }
    })
    payload.origin_chat = { chat_session_id: 7, message_id: 42 }
    payload.jobs = [job("ready"), job("done", { landed: true })]
    payload.summary = {
      ...payload.summary,
      total_jobs_count: 2,
      done_jobs_count: 1,
      dependency_edge_count: 4,
      blocked: true,
      blocked_reason: { key: "waiting_epic_siblings" }
    }
    payload.merge_train_status = {
      id: 22,
      state: "failed",
      phase: "failed",
      branch: "syrus/merge-train/very-long-integration-branch-name-that-must-wrap",
      member_count: 2,
      workflow_id: 99,
      workflow_state: "failed",
      current_step_kind: "merge_train_land",
      current_step_label: "Merge train land",
      reconciliation: null,
      failure_reason: "Base moved while the merge train was landing"
    }
    renderDetail(payload)

    const header = screen.getByRole("heading", { name: /deliberately long Epic title/ }).closest("header")
    expect(header).toHaveAttribute("data-page-header-layout", "stacked")
    expect(header).toHaveClass("block", "space-y-3")
    expect(header).not.toHaveClass("flex", "justify-between")

    const rows = Array.from(header?.children || [])
    expect(rows).toHaveLength(4)
    expect(within(rows[0] as HTMLElement).getByText(/deliberately long Epic title/)).toBeInTheDocument()
    expect(within(rows[0] as HTMLElement).getByText("Ready")).toBeInTheDocument()
    expect(within(rows[1] as HTMLElement).getByRole("link", { name: "very-long-owner-name/very-long-repository-name-with-many-segments" })).toBeInTheDocument()
    expect(within(rows[1] as HTMLElement).getByRole("link", { name: /view in chat/i })).toBeInTheDocument()
    expect(within(rows[2] as HTMLElement).getByRole("button", { name: "Start implementing" })).toBeInTheDocument()
    expect(within(rows[3] as HTMLElement).getByText("Merge train needs attention")).toBeInTheDocument()
    expect(within(rows[3] as HTMLElement).getByText(/Base moved while the merge train was landing/)).toBeInTheDocument()
  })
})

describe("EpicDetail origin_chat link", () => {
  it("renders a View in Chat link when origin_chat is present", () => {
    const payload = detailPayload()
    payload.origin_chat = { chat_session_id: 7, message_id: 42 }
    renderDetail(payload)

    const link = screen.getByRole("link", { name: /view in chat/i })
    expect(link).toBeInTheDocument()
    expect(link).toHaveAttribute("href", "/chats/7#message-42")
  })

  it("omits the View in Chat link when origin_chat is absent", () => {
    renderDetail(detailPayload())

    expect(screen.queryByRole("link", { name: /view in chat/i })).not.toBeInTheDocument()
  })
})

describe("EpicDetail state transition confirm", () => {
  afterEach(() => vi.restoreAllMocks())

  function payloadWithTransition(confirmMessage: string | null) {
    const payload = detailPayload({ startable: false })
    payload.state_transitions = [{ label: "Close", target_state: "done", confirm: confirmMessage }]
    return payload
  }

  it("shows a ConfirmDialog before firing the state transition when confirm is set", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(detailPayload()))
    renderDetail(payloadWithTransition("Close this epic?"))

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Close" }))

    await waitFor(() => expect(screen.getByRole("dialog")).toBeInTheDocument())
    expect(screen.getByText("Close this epic?")).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("fires the transition request when the operator confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(detailPayload()))
    renderDetail(payloadWithTransition("Close this epic?"))

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Close" }))
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/epics/3/state", expect.objectContaining({ method: "PATCH" })))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("does not fire the request when the operator cancels", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(detailPayload()))
    renderDetail(payloadWithTransition("Close this epic?"))

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Close" }))
    await waitFor(() => screen.getByRole("button", { name: "Cancel" }))
    await act(async () => screen.getByRole("button", { name: "Cancel" }).click())

    expect(fetchSpy).not.toHaveBeenCalled()
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("fires the transition immediately when confirm is null", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(detailPayload()))
    renderDetail(payloadWithTransition(null))

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    await act(async () => fireEvent.click(screen.getByRole("menuitem", { name: "Close" })))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})

describe("EpicDetail start implementing", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows Start implementing for a startable Epic and POSTs to the start path", async () => {
    const started = detailPayload({ state: "in_progress", startable: false })
    started.message = "Epic started — ready child Jobs are dispatching."
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(started))
    renderDetail(detailPayload())

    fireEvent.click(screen.getByRole("button", { name: "Start implementing" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/epics/3/start")
    expect(init?.method).toBe("POST")
  })

  it("hides Start implementing when the Epic is not startable", () => {
    renderDetail(detailPayload({ state: "in_progress", startable: false }))

    expect(screen.queryByRole("button", { name: "Start implementing" })).not.toBeInTheDocument()
  })

  it("shows a muted waiting hint when the Epic is blocked on dependencies", () => {
    renderDetail(detailPayload({ state: "backlog", startable: false, start_blocked_on: ["Pave the road first", "JOB-19"] }))

    expect(screen.queryByRole("button", { name: "Start implementing" })).not.toBeInTheDocument()
    expect(screen.getByText("Waiting on Pave the road first, JOB-19")).toBeInTheDocument()
  })

  it("does not show the waiting hint for startable Epics", () => {
    renderDetail(detailPayload({ start_blocked_on: [] }))

    expect(screen.queryByText(/^Waiting on /)).not.toBeInTheDocument()
  })
})

describe("EpicDetail dependency graph", () => {
  it("keeps a wide graph inside a horizontal scroll region", () => {
    const payload = detailPayload({ startable: false })
    payload.graph = {
      empty: false,
      node_count: 2,
      epic_dependency_count: 1,
      job_blocker_count: 0,
      initially_open: true,
      nodes: [
        {
          id: "epic_3",
          kind: "epic",
          label: "EPIC-3 Onboarding",
          state: "ready",
          epic_id: null,
          url: "/epics/3",
          is_focal: true
        },
        {
          id: "epic_4",
          kind: "epic",
          label: "EPIC-4 Follow-up",
          state: "ready",
          epic_id: null,
          url: "/epics/4",
          is_focal: false
        }
      ],
      edges: [{ from_id: "epic_3", to_id: "epic_4" }]
    }

    renderDetail(payload)

    expect(screen.getByLabelText("Dependency graph scroll region")).toHaveClass("overflow-x-auto")
  })
})

describe("ProgressBar", () => {
  it("renders an empty bar when there are no jobs", () => {
    render(<ProgressBar jobs={[]} totalCount={0} />)
    const bar = screen.getByRole("progressbar")
    expect(bar.children).toHaveLength(0)
  })

  it("renders a segment only for states with jobs", () => {
    const jobs = [job("merged"), job("open"), job("open")]
    render(<ProgressBar jobs={jobs} totalCount={3} />)
    const bar = screen.getByRole("progressbar")
    // Only merged segment rendered; open/approved/implemented/blocked_by_epic have 0 count
    expect(bar.children).toHaveLength(1)
    const segment = bar.firstElementChild as HTMLElement
    expect(segment.style.width).toMatch(/33/)
  })

  it("renders separate segments for each tracked state with jobs", () => {
    const jobs = [job("merged"), job("approved"), job("implemented"), job("blocked_by_epic")]
    render(<ProgressBar jobs={jobs} totalCount={4} />)
    const bar = screen.getByRole("progressbar")
    expect(bar.children).toHaveLength(4)
  })

  it("segments are proportional to totalCount including untracked states", () => {
    // 1 merged out of 4 total = 25%
    const jobs = [job("merged"), job("open"), job("open"), job("open")]
    render(<ProgressBar jobs={jobs} totalCount={4} />)
    const bar = screen.getByRole("progressbar")
    expect(bar.children).toHaveLength(1)
    const segment = bar.firstElementChild as HTMLElement
    expect(segment.style.width).toBe("25%")
  })
})

describe("StateChips", () => {
  it("renders nothing when there are no jobs", () => {
    const { container } = render(<StateChips jobs={[]} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("renders one chip per unique state", () => {
    const jobs = [job("open"), job("open"), job("approved")]
    render(<StateChips jobs={jobs} />)
    expect(screen.getByText("2 Open")).toBeInTheDocument()
    expect(screen.getByText("1 Approved")).toBeInTheDocument()
  })

  it("renders chips in a defined state order matching the progress bar", () => {
    const jobs = [job("merged"), job("open"), job("approved")]
    const { container } = render(<StateChips jobs={jobs} />)
    const chips = container.querySelectorAll("span")
    // merged (as "Landed") comes first, then approved, then open
    expect(chips[0]).toHaveTextContent("Landed")
    expect(chips[1]).toHaveTextContent("Approved")
    expect(chips[2]).toHaveTextContent("Open")
  })

  it("labels merged jobs as Landed and blocked_by_epic jobs as Blocked", () => {
    render(<StateChips jobs={[job("merged"), job("blocked_by_epic")]} />)
    expect(screen.getByText("1 Landed")).toBeInTheDocument()
    expect(screen.getByText("1 Blocked")).toBeInTheDocument()
  })

  it("omits zero-count states", () => {
    render(<StateChips jobs={[job("merged")]} />)
    expect(screen.queryByText(/open/i)).not.toBeInTheDocument()
    expect(screen.getByText("1 Landed")).toBeInTheDocument()
  })
})

describe("JobsSection", () => {
  it("renders an Add Job link in the header pointing to the new-job form", () => {
    render(
      <MemoryRouter>
        <JobsSection jobs={[]} newJobPath="/jobs/new?repository_id=42" prefix="" />
      </MemoryRouter>
    )
    const link = screen.getByRole("link", { name: "+ Add Job" })
    expect(link).toBeInTheDocument()
    expect(link).toHaveAttribute("href", "/jobs/new?repository_id=42")
  })

  it("prefixes the Add Job link when inside app-shell", () => {
    render(
      <MemoryRouter>
        <JobsSection jobs={[]} newJobPath="/jobs/new?repository_id=7" prefix="/app-shell" />
      </MemoryRouter>
    )
    const link = screen.getByRole("link", { name: "+ Add Job" })
    expect(link).toHaveAttribute("href", "/app-shell/jobs/new?repository_id=7")
  })

  it("renders a state pill for each job row", () => {
    const jobs = [job("open"), job("merged"), job("approved")]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.getByText("Open")).toBeInTheDocument()
    expect(screen.getByText("Merged")).toBeInTheDocument()
    expect(screen.getByText("Approved")).toBeInTheDocument()
  })

  it("shows the empty state when there are no jobs", () => {
    render(
      <MemoryRouter>
        <JobsSection jobs={[]} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.getByText("No Jobs in this Epic.")).toBeInTheDocument()
  })

  it("renders the job slug as a copyable button", () => {
    const jobs = [job("open", { id: 42, slug: "JOB-42" })]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.getByRole("button", { name: /JOB-42/ })).toBeInTheDocument()
  })

  it("renders a PR link when pr_number and pr_url are present", () => {
    const jobs = [job("open", { id: 7, slug: "JOB-7", pr_number: 99, pr_url: "https://github.com/acme/repo/pull/99" })]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    const prLink = screen.getByRole("link", { name: "PR #99" })
    expect(prLink).toBeInTheDocument()
    expect(prLink).toHaveAttribute("href", "https://github.com/acme/repo/pull/99")
  })

  it("omits the PR link when pr_number is absent", () => {
    const jobs = [job("open", { pr_number: null, pr_url: null })]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.queryByText(/PR #/)).not.toBeInTheDocument()
  })

  it("shows the issue label in the second row for issue-sourced jobs", () => {
    const jobs = [job("open", { slug: "JOB-5", label: "#12" })]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.getByText("#12")).toBeInTheDocument()
  })

  it("omits the second-row label for direct jobs", () => {
    const jobs = [job("open", { slug: "JOB-5", label: "Direct" })]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.queryByText("Direct")).not.toBeInTheDocument()
  })

  it("does not render owner email addresses", () => {
    const owner = { id: 1, email_address: "alice@example.com" }
    const jobs = [job("open", { owner_user_id: 1, owner_user: owner })]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )
    expect(screen.queryByText("alice@example.com")).not.toBeInTheDocument()
  })

  it("renders a plain job list regardless of per-job deployment stage data", () => {
    const jobs = [
      job("closed", {
        landed: true,
        deployment_stages: [
          { name: "staging", label: "Staging", reached: true, reached_at: "2026-07-30T12:00:00Z", tag_sha: "abc123" },
          { name: "production", label: "Production", reached: false, reached_at: null, tag_sha: null }
        ]
      })
    ]
    render(
      <MemoryRouter>
        <JobsSection jobs={jobs} newJobPath="/jobs/new" prefix="" />
      </MemoryRouter>
    )

    expect(screen.queryByRole("columnheader")).not.toBeInTheDocument()
    expect(screen.getByText("Closed")).toBeInTheDocument()
    expect(screen.queryByText("Staging")).not.toBeInTheDocument()
  })
})

describe("EpicDetail deployment stages panel", () => {
  it("renders the aggregate deployment stage pipeline as the first item in Details", () => {
    const payload = detailPayload()
    payload.deployment_stages = [
      { name: "staging", label: "On Staging", reached_count: 3, total: 3, reached_at: "2026-07-30T12:00:00Z" },
      { name: "production", label: "In Production", reached_count: 1, total: 3, reached_at: null },
      { name: "public", label: "Released to Public", reached_count: 0, total: 3, reached_at: null }
    ]

    renderDetail(payload)

    const details = screen.getByRole("heading", { name: "Details" }).closest("section")!
    const pipeline = screen.getByTestId("epic-deployment-stage-pipeline")
    expect(details).toContainElement(pipeline)
    expect(details.children[0]).toHaveTextContent("Details")
    expect(details.children[1]).toContainElement(pipeline)

    expect(pipeline.querySelector("li[data-state='reached']")).not.toBeNull()
    const partialStage = pipeline.querySelector("li[data-state='partial']")
    expect(partialStage).not.toBeNull()
    expect(partialStage!.querySelector(".w-1\\/2")).not.toBeNull()
    expect(pipeline.querySelector("li[data-state='pending']")).not.toBeNull()

    const owner = screen.getByText("Owner")
    expect(pipeline.compareDocumentPosition(owner) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("omits the Jobs table's stage columns now that stages live in the Details panel", () => {
    const payload = detailPayload()
    payload.deployment_stages = [{ name: "staging", label: "On Staging", reached_count: 1, total: 1, reached_at: "2026-07-30T12:00:00Z" }]
    payload.jobs = [job("closed", { landed: true })]

    renderDetail(payload)

    expect(screen.queryByRole("columnheader")).not.toBeInTheDocument()
  })

  it("omits the pipeline entirely when the epic has no aggregate deployment stages", () => {
    renderDetail(detailPayload())

    expect(screen.queryByTestId("epic-deployment-stage-pipeline")).not.toBeInTheDocument()
  })
})
