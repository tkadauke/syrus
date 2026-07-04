import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { EpicDetailJob } from "../api/epics"
import { JobsSection, ProgressBar, StateChips } from "./EpicDetail"

function job(state: string): EpicDetailJob {
  return { id: Math.random(), label: "JOB-1", title: "A job", path: "/jobs/1", state, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" }
}

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
