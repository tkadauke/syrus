import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it } from "vitest"
import type { DashboardEpicItem } from "../api/dashboard"
import { EpicProgressBar } from "./dashboard/components"
import { EpicsTable } from "./dashboard/EpicWorkflowTables"
import type { DashboardSortState } from "./dashboard/helpers"

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")

function epicItem(overrides: Partial<DashboardEpicItem> = {}): DashboardEpicItem {
  return {
    type: "epic",
    id: 1,
    number: 1,
    display_number: "EPIC-1",
    title: "Test Epic",
    description: "",
    state: "in_progress",
    stuck: false,
    all_jobs_closed: false,
    owner: null,
    owned_by_current_user: false,
    claimable: false,
    owner_badge: null,
    claimed_at: null,
    auto_approve_mode: "off",
    owner_user_id: null,
    owner_status: "unclaimed",
    jobs_count: 4,
    landed_jobs_count: 1,
    job_state_counts: {},
    max_commits_behind_base: null,
    created_at: null,
    updated_at: null,
    done_at: null,
    archived_at: null,
    repository: {
      id: 1,
      slug: "owner/repo",
      repository_path: "/repositories/1"
    },
    paths: {
      epic_path: "/epics/1",
      edit_epic_path: "/epics/1/edit",
      app_state_path: "/api/v1/app/epics/1/state",
      app_claim_path: "/api/v1/app/epics/1/claim",
      app_unclaim_path: "/api/v1/app/epics/1/unclaim"
    },
    ...overrides
  }
}

describe("EpicProgressBar", () => {
  it("renders nothing when the epic is not in_progress", () => {
    const { container } = render(<EpicProgressBar epic={epicItem({ state: "open", jobs_count: 4 })} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("renders nothing when there are no jobs", () => {
    const { container } = render(<EpicProgressBar epic={epicItem({ jobs_count: 0 })} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("renders a progress bar for an in_progress epic with jobs", () => {
    render(<EpicProgressBar epic={epicItem({ jobs_count: 4, job_state_counts: { approved: 1, implemented: 1 } })} />)
    expect(screen.getByRole("progressbar")).toBeInTheDocument()
  })

  it("shows a title tooltip with counts for non-zero states", () => {
    render(
      <EpicProgressBar
        epic={epicItem({ jobs_count: 4, job_state_counts: { approved: 2, implemented: 1 } })}
      />
    )
    const bar = screen.getByRole("progressbar")
    expect(bar.title).toContain("2 Approved")
    expect(bar.title).toContain("1 Implemented")
    expect(bar.title).not.toContain("Blocked by epic")
  })

  it("renders one colored segment per non-zero state", () => {
    const { container } = render(
      <EpicProgressBar
        epic={epicItem({ jobs_count: 4, job_state_counts: { approved: 1, implemented: 2 } })}
      />
    )
    const bar = screen.getByRole("progressbar")
    const segments = bar.querySelectorAll("div")
    expect(segments).toHaveLength(2)
  })

  it("sets segment widths proportional to jobs_count", () => {
    const { container } = render(
      <EpicProgressBar
        epic={epicItem({ jobs_count: 4, job_state_counts: { implemented: 2 } })}
      />
    )
    const bar = screen.getByRole("progressbar")
    const segment = bar.querySelector("div") as HTMLElement
    expect(segment.style.width).toBe("50%")
  })
})

describe("EpicsTable progress placement", () => {
  afterEach(() => {
    if (originalMatchMedia) {
      Object.defineProperty(window, "matchMedia", originalMatchMedia)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  })

  it("places the mobile progress bar after the epic content", () => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({
        matches: false,
        addEventListener: () => undefined,
        removeEventListener: () => undefined
      })
    })

    renderEpicsTable()

    const title = screen.getByRole("link", { name: "EPIC-1 Test Epic" })
    const progress = screen.getByRole("progressbar")
    expect(title.compareDocumentPosition(progress) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(progress.parentElement).toHaveClass("col-span-2")
  })

  it("places the desktop state-cell progress bar after the badges", () => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({
        matches: true,
        addEventListener: () => undefined,
        removeEventListener: () => undefined
      })
    })

    renderEpicsTable()

    const badge = screen.getByText("9 commits behind")
    const progress = screen.getByRole("progressbar")
    expect(badge.compareDocumentPosition(progress) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(progress).toHaveClass("w-full")
  })
})

function renderEpicsTable() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <EpicsTable
          columns={["checkbox", "state", "epic"]}
          items={[epicItem({ max_commits_behind_base: 9, job_state_counts: { implemented: 1 } })]}
          prefix=""
          sortState={sortState()}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function sortState(): DashboardSortState {
  return {
    column: "updated_at",
    direction: "desc",
    onSort: () => undefined,
    pending: false,
    sortableColumns: []
  }
}
