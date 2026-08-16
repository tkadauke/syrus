import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it } from "vitest"
import type { DashboardUntaggedIssues } from "../api/dashboard"
import { UntaggedIssuesBanner } from "./Dashboard"

const UNTAGGED_ISSUES_DISMISSAL_KEY = "syrus.untagged_issues_banner_dismissed"

function makeUntaggedIssues(overrides: Partial<DashboardUntaggedIssues> = {}): DashboardUntaggedIssues {
  return {
    total: 12,
    repositories: [
      { id: 1, slug: "tkadauke/widgets", count: 9, issues_path: "/repositories/1?tab=github_issues" },
      { id: 2, slug: "tkadauke/gadgets", count: 3, issues_path: "/repositories/2?tab=github_issues" }
    ],
    ...overrides
  }
}

function renderBanner(untaggedIssues: DashboardUntaggedIssues | undefined) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <UntaggedIssuesBanner prefix="" untaggedIssues={untaggedIssues} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("UntaggedIssuesBanner", () => {
  beforeEach(() => {
    window.sessionStorage.removeItem(UNTAGGED_ISSUES_DISMISSAL_KEY)
  })

  it("shows the aggregate count and per-repository links when untagged issues are present", () => {
    renderBanner(makeUntaggedIssues())

    expect(screen.getByRole("status")).toBeInTheDocument()
    expect(screen.getByText("12 unlabeled open issues", { exact: false })).toBeInTheDocument()
    expect(screen.getByText("across 2 repositories", { exact: false })).toBeInTheDocument()

    const widgetsLink = screen.getByRole("link", { name: "tkadauke/widgets (9)" })
    expect(widgetsLink).toHaveAttribute("href", "/repositories/1?tab=github_issues")
    const gadgetsLink = screen.getByRole("link", { name: "tkadauke/gadgets (3)" })
    expect(gadgetsLink).toHaveAttribute("href", "/repositories/2?tab=github_issues")
  })

  it("renders nothing when there are no untagged issues", () => {
    const { container } = renderBanner(makeUntaggedIssues({ total: 0, repositories: [] }))
    expect(container.firstChild).toBeNull()
  })

  it("renders nothing when untaggedIssues is undefined", () => {
    const { container } = renderBanner(undefined)
    expect(container.firstChild).toBeNull()
  })

  it("hides the banner after the user dismisses it", () => {
    renderBanner(makeUntaggedIssues())

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }))

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("persists the dismissal in sessionStorage", () => {
    renderBanner(makeUntaggedIssues())

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }))

    expect(window.sessionStorage.getItem(UNTAGGED_ISSUES_DISMISSAL_KEY)).toBe("12:1:9,2:3")
  })

  it("does not show the banner when a matching dismissal is already in sessionStorage", () => {
    window.sessionStorage.setItem(UNTAGGED_ISSUES_DISMISSAL_KEY, "12:1:9,2:3")

    renderBanner(makeUntaggedIssues())

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("shows the banner again when the untagged issue counts change after a prior dismissal", () => {
    window.sessionStorage.setItem(UNTAGGED_ISSUES_DISMISSAL_KEY, "12:1:9,2:3")

    renderBanner(makeUntaggedIssues({ total: 15, repositories: [
      { id: 1, slug: "tkadauke/widgets", count: 12, issues_path: "/repositories/1?tab=github_issues" },
      { id: 2, slug: "tkadauke/gadgets", count: 3, issues_path: "/repositories/2?tab=github_issues" }
    ] }))

    expect(screen.getByRole("status")).toBeInTheDocument()
  })
})
