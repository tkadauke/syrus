import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { EpicDetailJob } from "../api/epics"
import { ProgressBar, StateChips } from "./EpicDetail"

function job(state: string): EpicDetailJob {
  return { id: Math.random(), label: "JOB-1", title: "A job", path: "/jobs/1", state, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" }
}

describe("ProgressBar", () => {
  it("renders an empty bar when there are no jobs", () => {
    render(<ProgressBar jobs={[]} totalCount={0} />)
    const bar = screen.getByRole("progressbar")
    expect(bar).toHaveAttribute("aria-valuenow", "0")
    expect(bar).toHaveAttribute("aria-valuemax", "0")
    const fill = bar.firstElementChild as HTMLElement
    expect(fill.style.width).toBe("0%")
  })

  it("fills proportionally based on merged and approved jobs", () => {
    const jobs = [job("merged"), job("approved"), job("open"), job("open")]
    render(<ProgressBar jobs={jobs} totalCount={4} />)
    const bar = screen.getByRole("progressbar")
    expect(bar).toHaveAttribute("aria-valuenow", "2")
    const fill = bar.firstElementChild as HTMLElement
    expect(fill.style.width).toBe("50%")
  })

  it("shows 100% when all jobs are merged or approved", () => {
    const jobs = [job("merged"), job("approved"), job("merged")]
    render(<ProgressBar jobs={jobs} totalCount={3} />)
    const fill = (screen.getByRole("progressbar").firstElementChild) as HTMLElement
    expect(fill.style.width).toBe("100%")
  })

  it("counts only merged and approved as done, not other terminal states", () => {
    const jobs = [job("closed"), job("landing_failed"), job("merged")]
    render(<ProgressBar jobs={jobs} totalCount={3} />)
    const bar = screen.getByRole("progressbar")
    expect(bar).toHaveAttribute("aria-valuenow", "1")
    const fill = bar.firstElementChild as HTMLElement
    expect(fill.style.width).toBe("33%")
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

  it("renders chips in a defined state order", () => {
    const jobs = [job("merged"), job("open"), job("approved")]
    const { container } = render(<StateChips jobs={jobs} />)
    const chips = container.querySelectorAll("span")
    expect(chips[0]).toHaveTextContent("Open")
    expect(chips[1]).toHaveTextContent("Approved")
    expect(chips[2]).toHaveTextContent("Merged")
  })

  it("omits zero-count states", () => {
    render(<StateChips jobs={[job("merged")]} />)
    expect(screen.queryByText(/open/i)).not.toBeInTheDocument()
    expect(screen.getByText("1 Merged")).toBeInTheDocument()
  })
})
