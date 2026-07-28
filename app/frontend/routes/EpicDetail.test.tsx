import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { EpicDetailJob, EpicDetailPayload } from "../api/epics"
import { EpicDetail, JobsSection, ProgressBar, StateChips } from "./EpicDetail"

function job(state: string): EpicDetailJob {
  return { id: Math.random(), label: "JOB-1", title: "A job", path: "/jobs/1", state, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" }
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
      repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
      ...overrides
    },
    summary: { done_jobs_count: 0, total_jobs_count: 0, dependency_edge_count: 0, blocked: false, blocked_reason: null },
    state_transitions: [],
    graph: { empty: true, definition: "", node_count: 0, epic_dependency_count: 0, job_blocker_count: 0, initially_open: false },
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
})
