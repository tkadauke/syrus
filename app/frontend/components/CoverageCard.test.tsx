import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { CoverageArtifact } from "../api/jobs"
import { CoverageCard } from "./CoverageCard"

const fullCoverage: CoverageArtifact = {
  summary: { lines_pct: 85.2, branches_pct: 72.1, functions_pct: 91.0 },
  files: {
    "app/models/user.rb": { lines_pct: 95.0, branches_pct: 88.0 },
    "app/models/post.rb": { lines_pct: 55.0, branches_pct: null },
    "app/services/runner.rb": { lines_pct: 71.0, branches_pct: 60.0 }
  },
  pr_delta: { covered: 45, total: 50, pct: 90.0, uncovered_files: [] },
  threshold_miss: false,
  hit_map_attached: true,
  coverage_unavailable: false
}

describe("CoverageCard", () => {
  it("renders the coverage summary badges when summary data is present", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    const badges = screen.getAllByTestId("coverage-badge")
    expect(badges).toHaveLength(3)
    expect(badges[0]).toHaveTextContent("85.2%")
    expect(badges[1]).toHaveTextContent("72.1%")
    expect(badges[2]).toHaveTextContent("91.0%")
  })

  it("renders coverage-unavailable message instead of summary when coverage_unavailable is true", () => {
    render(<CoverageCard coverage={{ coverage_unavailable: true }} />)

    expect(screen.queryByTestId("coverage-card")).not.toBeInTheDocument()
    expect(screen.queryByTestId("coverage-summary")).not.toBeInTheDocument()
    expect(screen.getByText(/not available/i)).toBeInTheDocument()
  })

  it("renders the PR delta row when pr_delta.total > 0", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    expect(screen.getByTestId("coverage-pr-delta")).toBeInTheDocument()
    expect(screen.getByTestId("coverage-pr-delta")).toHaveTextContent("45")
    expect(screen.getByTestId("coverage-pr-delta")).toHaveTextContent("50")
  })

  it("omits the PR delta row when pr_delta.total is 0", () => {
    render(<CoverageCard coverage={{ ...fullCoverage, pr_delta: { covered: 0, total: 0, pct: null, uncovered_files: [] } }} />)

    expect(screen.queryByTestId("coverage-pr-delta")).not.toBeInTheDocument()
  })

  it("omits the PR delta row when pr_delta is absent", () => {
    render(<CoverageCard coverage={{ ...fullCoverage, pr_delta: undefined }} />)

    expect(screen.queryByTestId("coverage-pr-delta")).not.toBeInTheDocument()
  })

  it("shows green threshold status when threshold_miss is false and summary is present", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    const statusEl = screen.getByTestId("coverage-threshold-status")
    expect(statusEl).toHaveTextContent("✓")
    expect(within(statusEl).getByText(/thresholds met/i)).toBeInTheDocument()
  })

  it("shows red threshold status when threshold_miss is true", () => {
    render(<CoverageCard coverage={{ ...fullCoverage, threshold_miss: true }} />)

    const statusEl = screen.getByTestId("coverage-threshold-status")
    expect(statusEl).toHaveTextContent("✗")
    expect(within(statusEl).getByText(/below threshold/i)).toBeInTheDocument()
  })

  it("shows threshold detail rows when threshold_miss_details is present", () => {
    render(<CoverageCard coverage={{
      ...fullCoverage,
      threshold_miss: true,
      threshold_miss_details: {
        lines_pct: 75.0,
        threshold_lines: 80,
        pr_delta_pct: null,
        threshold_pr_lines: null
      }
    }} />)

    expect(screen.getByTestId("coverage-threshold-status")).toHaveTextContent("75.0%")
    expect(screen.getByTestId("coverage-threshold-status")).toHaveTextContent("threshold: 80%")
  })

  it("shows the hit map available hint when hit_map_attached is true", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    expect(screen.getByText(/hit.*data available/i)).toBeInTheDocument()
  })

  it("omits the hit map hint when hit_map_attached is false", () => {
    render(<CoverageCard coverage={{ ...fullCoverage, hit_map_attached: false }} />)

    expect(screen.queryByText(/hit.*data available/i)).not.toBeInTheDocument()
  })

  it("shows a file count button that expands to the file table", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    expect(screen.queryByTestId("coverage-file-table")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /3/ }))
    expect(screen.getByTestId("coverage-file-table")).toBeInTheDocument()
  })

  it("sorts files ascending by lines_pct in the expanded table", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    fireEvent.click(screen.getByRole("button", { name: /3/ }))

    const rows = within(screen.getByTestId("coverage-file-table")).getAllByRole("row")
    const rowTexts = rows.slice(1).map((r) => r.textContent || "")
    expect(rowTexts[0]).toContain("post.rb")
    expect(rowTexts[1]).toContain("runner.rb")
    expect(rowTexts[2]).toContain("user.rb")
  })

  it("collapses the file table when the button is clicked again", () => {
    render(<CoverageCard coverage={fullCoverage} />)

    const btn = screen.getByRole("button", { name: /3/ })
    fireEvent.click(btn)
    expect(screen.getByTestId("coverage-file-table")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button"))
    expect(screen.queryByTestId("coverage-file-table")).not.toBeInTheDocument()
  })

  it("omits the file table toggle when there are no files", () => {
    render(<CoverageCard coverage={{ summary: { lines_pct: 90, branches_pct: null, functions_pct: null }, files: {} }} />)

    expect(screen.queryByRole("button")).not.toBeInTheDocument()
  })

  it("uses a dash for null summary values", () => {
    render(<CoverageCard coverage={{ summary: { lines_pct: null, branches_pct: null, functions_pct: null } }} />)

    const badges = screen.getAllByTestId("coverage-badge")
    badges.forEach((badge) => expect(badge).toHaveTextContent("—"))
  })
})
