import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { EpicsTable, WorkflowsTable } from "./EpicWorkflowTables"
import { JobsDashboardTable } from "./JobsTable"
import type { DashboardEpicItem, DashboardJobItem, DashboardPayload, DashboardRepository, DashboardWorkflowItem } from "../../api/dashboard"
import type { DashboardSortState } from "./helpers"

const repository: DashboardRepository = {
  id: 1,
  repository_path: "/repositories/1",
  slug: "acme/widgets",
  multiple_members: false
}

const controls = {
  views: [],
  ownership_scopes: [],
  owners: [],
  priorities: [
    { value: "urgent", label: "Urgent" },
    { value: "medium", label: "Medium" }
  ],
  sort_columns: [],
  sort_directions: [],
  columns: { required: [], optional: [] },
  kanban_lanes: [],
  filter_schema: [],
  filter_suggestions: []
} satisfies DashboardPayload["controls"]

// A jobs `controls` fixture with a real required/optional split, for the
// column drag-reorder tests below -- required columns (checkbox, issue)
// must stay pinned and undraggable regardless of where they sit in the
// `columns` prop the parent passes.
const jobControls = {
  ...controls,
  columns: {
    required: [
      { key: "checkbox", title: "Checkbox" },
      { key: "issue", title: "Issue" }
    ],
    optional: [
      { key: "state", title: "State" },
      { key: "repository", title: "Repository" }
    ]
  }
} satisfies DashboardPayload["controls"]

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

function renderWithProviders(children: ReactNode) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function sortState(overrides: Partial<DashboardSortState> = {}): DashboardSortState {
  return {
    column: "title",
    direction: "asc",
    onSort: vi.fn(),
    pending: false,
    sortableColumns: ["title", "state", "landing_queue_position", "started_at", "finished_at"],
    ...overrides
  }
}

function job(overrides: Partial<DashboardJobItem> = {}): DashboardJobItem {
  return {
    type: "job",
    id: 1,
    kind: "issue",
    title: "Fix widgets",
    state: "open",
    summary_state: "running",
    closure_reason: null,
    validity: "valid",
    priority: "medium",
    agent_provider: "codex",
    total_cost_usd: null,
    issue_number: 12,
    issue_url: "https://github.com/acme/widgets/issues/12",
    branch_name: "syrus/job-1",
    pr_number: null,
    active_workflow_trigger_kind: "initial",
    latest_workflow_id: 4,
    latest_workflow_trigger_kind: "initial",
    pr_url: null,
    latest_workflow_state: "running",
    landing_queue_position: null,
    landing_queue_blocked_reason: null,
    landing_queue_wait_reason: null,
    landing_queue_entry_key: null,
    blocked_reason: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-02T00:00:00Z",
    started_at: "2026-01-01T01:00:00Z",
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
    repository,
    epic: null,
    owner_badge: null,
    tags: [],
    source_chat: null,
    needs_attention: false,
    needs_attention_reason: null,
    start_blocked_reason: null,
    start_blocked_at: null,
    start_blocked_next_check_at: null,
    start_blocked_count: null,
    start_blocked_details: null,
    paths: {
      job_path: `/jobs/${overrides.id ?? 1}`,
      source_path: "https://github.com/acme/widgets/issues/12"
    },
    ...overrides
  }
}

function epic(overrides: Partial<DashboardEpicItem> = {}): DashboardEpicItem {
  return {
    type: "epic",
    id: 1,
    number: 1,
    display_number: "EPIC-1",
    title: "Widget reliability",
    description: "Keep widgets steady",
    state: "open",
    landing: false,
    stuck: false,
    all_jobs_closed: false,
    owner: null,
    owned_by_current_user: false,
    claimable: true,
    owner_badge: null,
    claimed_at: null,
    auto_approve_mode: "manual",
    owner_user_id: null,
    owner_status: "unclaimed",
    jobs_count: 2,
    landed_jobs_count: 0,
    job_state_counts: { implemented: 1 },
    max_commits_behind_base: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-02T00:00:00Z",
    done_at: null,
    archived_at: null,
    repository,
    paths: {
      app_claim_path: "/api/epics/1/claim",
      app_state_path: "/api/epics/1/state",
      app_unclaim_path: "/api/epics/1/unclaim",
      edit_epic_path: "/epics/1/edit",
      epic_path: "/epics/1"
    },
    ...overrides
  }
}

function workflow(overrides: Partial<DashboardWorkflowItem> = {}): DashboardWorkflowItem {
  return {
    type: "workflow",
    id: 8,
    slug: "WF-8",
    path: "/admin/workflows/8",
    state: "running",
    trigger_kind: "initial",
    agent_provider: "codex",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    started_at: "2026-01-01T00:05:00Z",
    finished_at: null,
    cleaned_up_at: null,
    steps_count: 3,
    job: {
      id: 1,
      owner_badge: null,
      owner_user: null,
      path: "/jobs/1",
      repository,
      state: "open",
      title: "Fix widgets"
    },
    ...overrides
  }
}

function setDesktop(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      addEventListener: vi.fn(),
      addListener: vi.fn(),
      dispatchEvent: vi.fn(),
      matches,
      media: query,
      onchange: null,
      removeEventListener: vi.fn(),
      removeListener: vi.fn()
    }))
  })
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("dashboard DataTable migrations", () => {
  it("preserves job sorting, checkbox selection, and overflow table semantics", () => {
    setDesktop(true)
    const onSort = vi.fn()

    renderWithProviders(
      <JobsDashboardTable
        columns={["checkbox", "issue", "state"]}
        controls={controls}
        items={[job(), job({ id: 2, issue_number: 13, title: "Ship widgets" })]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState({ onSort })}
        t={(key, opts) => key === "selected_count" ? `${opts?.count} selected` : key}
      />
    )

    const table = screen.getByRole("table")
    expect(table.parentElement).toHaveAttribute("data-data-table-overflow-wrapper", "true")
    expect(screen.getByRole("columnheader", { name: /Issue/ })).toHaveAttribute("aria-sort", "ascending")

    fireEvent.click(screen.getByRole("button", { name: "Sort by Issue descending" }))
    expect(onSort).toHaveBeenCalledWith("issue")

    fireEvent.click(screen.getByRole("checkbox", { name: "select_all_jobs" }))
    expect(screen.getByText("2 selected")).toBeInTheDocument()
  })

  it("renders the untagged issues banner directly above the data table", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["issue"]}
        controls={controls}
        items={[job()]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key, opts) => key === "untagged_issues_summary" ? `${opts?.count} unlabeled open issues` : key === "untagged_issues_repo_count" ? `across ${opts?.count} repositories` : key}
        untaggedIssues={{ total: 4, repositories: [{ id: 1, slug: "acme/widgets", count: 4, issues_path: "/repositories/1/plugin/issues" }] }}
      />
    )

    const banner = screen.getByRole("status")
    expect(banner).toHaveTextContent("4 unlabeled open issues")
    expect(banner.compareDocumentPosition(screen.getByRole("table"))).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })

  it("omits the untagged issues banner when there is nothing untagged", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["issue"]}
        controls={controls}
        items={[job()]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("preserves landing-queue grouping and expandable blocker rows", () => {
    setDesktop(true)
    const approved = job({
      epic: { display_number: "EPIC-1", id: 1, jobs_count: 2, landed_jobs_count: 0, number: 1, path: "/epics/1" },
      landing_queue_entry_key: "epic:1",
      landing_queue_position: 1
    })

    renderWithProviders(
      <JobsDashboardTable
        columns={["landing_queue_position", "issue", "state"]}
        controls={controls}
        items={[approved]}
        landingQueueEntries={[{
          blocker_jobs: [{
            created_at: "2026-01-01T00:00:00Z",
            id: 9,
            job_path: "/jobs/9",
            latest_workflow_id: null,
            latest_workflow_state: null,
            latest_workflow_trigger_kind: null,
            pr_number: null,
            pr_path: null,
            repository,
            started_at: null,
            state: "open",
            title: "Blocking job"
          }],
          dependency_edges: [],
          job_ids: [approved.id],
          key: "epic:1",
          position: 1
        }]}
        prefix=""
        sortState={sortState({ column: "landing_queue_position" })}
        t={(key, opts) => key === "blocker_one" ? `${opts?.count} blocker` : key}
      />
    )

    expect(screen.getByRole("button", { name: "1 blocker" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("Blocking job")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "1 blocker" }))

    expect(screen.getByRole("button", { name: "1 blocker" })).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByText("Blocking job")).toBeInTheDocument()
  })

  it("preserves epic checkbox selection and sortable headers", () => {
    setDesktop(true)
    const onSort = vi.fn()

    renderWithProviders(
      <EpicsTable
        columns={["checkbox", "epic", "state"]}
        items={[epic()]}
        prefix=""
        sortState={sortState({ onSort })}
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Sort by Epic descending" }))
    expect(onSort).toHaveBeenCalledWith("epic")

    fireEvent.click(screen.getByRole("checkbox", { name: "Select all Epics" }))
    expect(screen.getByText("1 selected")).toBeInTheDocument()
  })

  it("preserves workflow mobile fallback while desktop uses DataTable", () => {
    setDesktop(false)

    renderWithProviders(
      <WorkflowsTable
        columns={["workflow", "job", "state"]}
        items={[workflow()]}
        prefix=""
        sortState={sortState()}
      />
    )

    expect(screen.queryByRole("table")).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: /WF-8 Fix widgets/ })).toHaveAttribute("href", "/admin/workflows/8")
  })
})

describe("job subtitle attention row", () => {
  function attentionRows(title: string) {
    const cell = screen.getByText(title).closest("td")
    return cell!.querySelectorAll('div[class*="gap-x-1.5"]')
  }

  it("renders a single structural metadata line when nothing needs attention", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["issue"]}
        controls={controls}
        items={[job()]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    expect(attentionRows("Fix widgets")).toHaveLength(1)
  })

  it("does not add a second line for a desktop row's own blocked_reason (it has its own column)", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["issue"]}
        controls={controls}
        items={[job({ blocked_reason: { key: "landing_paused" } })]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    expect(attentionRows("Fix widgets")).toHaveLength(1)
  })

  it("renders a second attention line with the provider-mismatch pill", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["issue"]}
        controls={controls}
        items={[job({
          provider_mismatch: {
            job_provider: "codex",
            job_provider_label: "Codex",
            repository_provider: "claude",
            repository_provider_label: "Claude"
          }
        })]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    const rows = attentionRows("Fix widgets")
    expect(rows).toHaveLength(2)
    expect(rows[1]).toHaveTextContent("Codex")
  })

  it("renders a second attention line for a manually paused job", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["issue"]}
        controls={controls}
        items={[job({ manual_paused: true })]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    const rows = attentionRows("Fix widgets")
    expect(rows).toHaveLength(2)
    expect(rows[1]).toHaveTextContent("Manually paused")
  })
})

describe("dashboard table header drag reordering", () => {
  it("reorders job header and body cells together while dragging, and commits once on drop", () => {
    setDesktop(true)
    const onReorderColumns = vi.fn()

    renderWithProviders(
      <JobsDashboardTable
        columns={["checkbox", "issue", "state", "repository"]}
        controls={jobControls}
        items={[job()]}
        landingQueueEntries={[]}
        onReorderColumns={onReorderColumns}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    const stateHeader = screen.getByRole("columnheader", { name: /State/ })
    const repositoryHeader = screen.getByRole("columnheader", { name: /Repository/ })
    const transfer = dataTransfer()

    fireEvent.dragStart(stateHeader, { dataTransfer: transfer })
    fireEvent.dragOver(repositoryHeader, { dataTransfer: transfer })

    const headersDuringDrag = screen.getAllByRole("columnheader").map((cell) => cell.textContent)
    expect(headersDuringDrag).toEqual(["", "Issue↑", "Repository", "State"])
    expect(onReorderColumns).not.toHaveBeenCalled()

    fireEvent.drop(repositoryHeader, { dataTransfer: transfer })
    expect(onReorderColumns).toHaveBeenCalledTimes(1)
    expect(onReorderColumns).toHaveBeenCalledWith(["repository", "state"])
  })

  it("never attaches drag handlers to a job table's required columns", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["checkbox", "issue", "state"]}
        controls={jobControls}
        items={[job()]}
        landingQueueEntries={[]}
        onReorderColumns={vi.fn()}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    expect(screen.getByRole("columnheader", { name: /Issue/ })).not.toHaveAttribute("draggable")
  })

  it("dragging a job header does not trigger a sort, but a plain click still does", () => {
    setDesktop(true)
    const onSort = vi.fn()

    renderWithProviders(
      <JobsDashboardTable
        columns={["checkbox", "issue", "state"]}
        controls={jobControls}
        items={[job()]}
        landingQueueEntries={[]}
        onReorderColumns={vi.fn()}
        prefix=""
        sortState={sortState({ onSort })}
        t={(key) => key}
      />
    )

    const issueHeader = screen.getByRole("columnheader", { name: /Issue/ })
    const stateHeader = screen.getByRole("columnheader", { name: /State/ })
    const transfer = dataTransfer()

    fireEvent.dragStart(stateHeader, { dataTransfer: transfer })
    fireEvent.dragOver(issueHeader, { dataTransfer: transfer })
    fireEvent.drop(issueHeader, { dataTransfer: transfer })
    expect(onSort).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Sort by Issue descending" }))
    expect(onSort).toHaveBeenCalledWith("issue")
  })

  it("does not allow dragging when no reorder handler is wired up", () => {
    setDesktop(true)

    renderWithProviders(
      <JobsDashboardTable
        columns={["checkbox", "issue", "state"]}
        controls={jobControls}
        items={[job()]}
        landingQueueEntries={[]}
        prefix=""
        sortState={sortState()}
        t={(key) => key}
      />
    )

    expect(screen.getByRole("columnheader", { name: /State/ })).not.toHaveAttribute("draggable")
  })

  it("reorders epic header and body cells together, keeping checkbox/epic pinned", () => {
    setDesktop(true)
    const onReorderColumns = vi.fn()

    renderWithProviders(
      <EpicsTable
        columns={["checkbox", "epic", "state", "repository"]}
        items={[epic()]}
        onReorderColumns={onReorderColumns}
        prefix=""
        sortState={sortState()}
      />
    )

    expect(screen.getByRole("columnheader", { name: "Epic" })).not.toHaveAttribute("draggable")

    const stateHeader = screen.getByRole("columnheader", { name: /State/ })
    const repositoryHeader = screen.getByRole("columnheader", { name: /Repository/ })
    const transfer = dataTransfer()

    fireEvent.dragStart(stateHeader, { dataTransfer: transfer })
    fireEvent.dragOver(repositoryHeader, { dataTransfer: transfer })
    fireEvent.drop(repositoryHeader, { dataTransfer: transfer })

    expect(onReorderColumns).toHaveBeenCalledWith(["repository", "state"])
  })

  it("reorders workflow header and body cells together", () => {
    setDesktop(true)
    const onReorderColumns = vi.fn()

    renderWithProviders(
      <WorkflowsTable
        columns={["workflow", "job", "trigger", "agent"]}
        items={[workflow()]}
        onReorderColumns={onReorderColumns}
        prefix=""
        sortState={sortState()}
      />
    )

    expect(screen.getByRole("columnheader", { name: "Workflow" })).not.toHaveAttribute("draggable")

    const triggerHeader = screen.getByRole("columnheader", { name: "Trigger" })
    const agentHeader = screen.getByRole("columnheader", { name: "Agent" })
    const transfer = dataTransfer()

    fireEvent.dragStart(triggerHeader, { dataTransfer: transfer })
    fireEvent.dragOver(agentHeader, { dataTransfer: transfer })
    fireEvent.drop(agentHeader, { dataTransfer: transfer })

    expect(onReorderColumns).toHaveBeenCalledWith(["agent", "trigger"])
  })
})
