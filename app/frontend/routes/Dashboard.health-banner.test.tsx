import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it } from "vitest"
import type { DashboardHealthBlockedRepository } from "../api/dashboard"
import { RepositoryHealthBanners } from "./Dashboard"

const HEALTH_BANNER_DISMISSALS_KEY = "syrus.health_banner_dismissals"

const defaultRepairStatus = {
  enabled: false,
  failed_open_jobs_count: 0,
  max_open_failed_jobs: 3,
  blocked_reason: null,
  can_request: false,
  can_spawn: false,
  blocking_job: null,
  failed_jobs: []
}

function makeRepo(overrides: Partial<DashboardHealthBlockedRepository> = {}): DashboardHealthBlockedRepository {
  return {
    id: 1,
    slug: "tkadauke/my-repo",
    main_health: "inconclusive",
    ci_health: "inconclusive",
    grader_health: "unknown",
    landing_paused: false,
    repository_path: "/repos/1",
    repair_path: "/api/v1/app/repositories/1/repair_main_branch",
    main_branch_repair: defaultRepairStatus,
    ...overrides
  }
}

function renderBanners(repositories: DashboardHealthBlockedRepository[]) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <RepositoryHealthBanners prefix="" repositories={repositories} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryHealthBanners", () => {
  beforeEach(() => {
    window.localStorage.removeItem(HEALTH_BANNER_DISMISSALS_KEY)
  })

  it("shows the banner for a health-blocked repository", () => {
    renderBanners([makeRepo()])

    expect(screen.getByRole("alert")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/my-repo", { exact: false })).toBeInTheDocument()
  })

  it("hides the banner after the user dismisses it", () => {
    renderBanners([makeRepo()])

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }))

    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("persists the dismissal in localStorage", () => {
    renderBanners([makeRepo()])

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }))

    const stored = JSON.parse(window.localStorage.getItem(HEALTH_BANNER_DISMISSALS_KEY) ?? "{}")
    expect(stored["1"]).toBe("inconclusive:unknown")
  })

  it("does not show the banner when a matching dismissal is already in localStorage", () => {
    const repo = makeRepo()
    window.localStorage.setItem(
      HEALTH_BANNER_DISMISSALS_KEY,
      JSON.stringify({ [repo.id]: "inconclusive:unknown" })
    )

    renderBanners([repo])

    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("shows the banner again when health evidence changes after a prior dismissal", () => {
    window.localStorage.setItem(
      HEALTH_BANNER_DISMISSALS_KEY,
      JSON.stringify({ 1: "inconclusive:unknown" })
    )

    // A new grader result came in — grader_health is now "broken"
    const repo = makeRepo({ grader_health: "broken", main_health: "broken" })
    renderBanners([repo])

    expect(screen.getByRole("alert")).toBeInTheDocument()
  })

  it("renders nothing when the repository list is empty", () => {
    const { container } = renderBanners([])
    expect(container.firstChild).toBeNull()
  })
})
