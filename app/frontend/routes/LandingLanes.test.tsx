import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { LandingLanesPayload } from "../api/landingLanes"
import { applyAppEvent } from "../lib/appEvents"
import { LandingLanesPage, LandingLanesRoute, LandingLanesStrip } from "./LandingLanes"

const payload: LandingLanesPayload = {
  estimate_kind: "best_case",
  repositories: [
    {
      id: 1,
      slug: "acme/rocket",
      default_branch: "main",
      landing_concurrency: 2,
      busy_lane_count: 1,
      approved_backlog: [{ id: 13, slug: "JOB-13", app_path: "/jobs/13", position: 1 }],
      lanes: [
        {
          number: 1,
          empty: false,
          draining: false,
          anchor_job: { id: 10, slug: "JOB-10", app_path: "/jobs/10" },
          member_jobs: [{ id: 11, slug: "JOB-11", app_path: "/jobs/11" }],
          workflow: { id: 12, slug: "WF-12", app_path: "/jobs/10?tab=workflows#workflow-12" },
          phase: "grade",
          repair_round: 2,
          rebasing: false,
          progress: 0.68,
          best_case_remaining_seconds: 121,
          estimate_kind: "best_case",
          graders: [
            { name: "rspec", state: "running", carried: false, expected_seconds: 100, progress: 0.4 },
            { name: "lint", state: "carried", carried: true, expected_seconds: 300, progress: 1 }
          ],
          multisect: {
            sub_lanes: [
              { step_id: 1, role: "section-1", round: 3, state: "running" },
              { step_id: 2, role: "section-2", round: 3, state: "queued" }
            ]
          }
        },
        { number: 2, empty: true, draining: false }
      ],
      additional_branches: []
    },
    {
      id: 2,
      slug: "acme/anvil",
      default_branch: "main",
      landing_concurrency: 1,
      busy_lane_count: 1,
      approved_backlog: [],
      lanes: [{ number: 1, empty: false, draining: false, phase: "reconcile", rebasing: true, progress: 0.5, best_case_remaining_seconds: 60 }],
      additional_branches: []
    }
  ]
}

function wrapper(client = new QueryClient({ defaultOptions: { queries: { retry: false } } }), landingLanesEnabled = true) {
  client.setQueryData(["bootstrap"], { feature_flags: { landing_lanes: landingLanesEnabled } })
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return (
      <QueryClientProvider client={client}>
        <MemoryRouter>{children}</MemoryRouter>
      </QueryClientProvider>
    )
  }
}

describe("landing lanes", () => {
  it("groups lanes by landing branch when another branch has an active landing", () => {
    const branched: LandingLanesPayload = {
      estimate_kind: "best_case",
      repositories: [
        {
          id: 3,
          slug: "acme/branchy",
          default_branch: "main",
          landing_concurrency: 1,
          busy_lane_count: 1,
          approved_backlog: [],
          lanes: [{ number: 1, empty: true, draining: false }],
          additional_branches: [
            {
              branch: "release",
              busy_lane_count: 1,
              lanes: [
                {
                  number: 1,
                  empty: false,
                  draining: false,
                  anchor_job: { id: 21, slug: "JOB-21", app_path: "/jobs/21" },
                  phase: "grade",
                  progress: 0.5,
                  best_case_remaining_seconds: 60
                }
              ]
            }
          ]
        }
      ]
    }

    render(<LandingLanesPage payload={branched} />, { wrapper: wrapper() })

    expect(screen.getByText("Branch main")).toBeInTheDocument()
    expect(screen.getByText("Branch release")).toBeInTheDocument()
    expect(screen.getByText("1 of 2 lanes busy · 0 approved waiting")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-21" })).toHaveAttribute("href", "/jobs/21")
  })

  it("does not label the lanes of a repository landing only to its default branch", () => {
    render(<LandingLanesPage payload={payload} />, { wrapper: wrapper() })

    expect(screen.queryByText(/^Branch /)).not.toBeInTheDocument()
  })

  it("keeps the desktop app-shell route prefix on job and workflow links", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/landing_lanes"]}>
          <LandingLanesPage payload={payload} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/app-shell/jobs/10")
    expect(screen.getByRole("link", { name: "JOB-11" })).toHaveAttribute("href", "/app-shell/jobs/11")
    expect(screen.getByRole("link", { name: "WF-12" })).toHaveAttribute("href", "/app-shell/jobs/10?tab=workflows#workflow-12")
    expect(screen.getByRole("link", { name: "1. JOB-13" })).toHaveAttribute("href", "/app-shell/jobs/13")
  })

  it("does not render or fetch the dashboard strip while the feature is disabled", () => {
    const fetchSpy = vi.spyOn(window, "fetch")

    render(<LandingLanesStrip />, { wrapper: wrapper(undefined, false) })

    expect(screen.queryByText("Landing lanes")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("renders the unavailable page without fetching on direct navigation while disabled", () => {
    const fetchSpy = vi.spyOn(window, "fetch")

    render(<LandingLanesRoute />, { wrapper: wrapper(undefined, false) })

    expect(screen.getByRole("heading", { name: "Page unavailable" })).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("fetches the full experience on direct navigation while enabled", async () => {
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockResolvedValue(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(<LandingLanesRoute />, { wrapper: wrapper() })

    expect(await screen.findByText("acme/rocket")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("groups full lane details by repository and renders empty, repair, rebase, multisect, backlog, and best-case states", () => {
    render(<LandingLanesPage payload={payload} />, { wrapper: wrapper() })

    expect(screen.getByText("acme/rocket")).toBeInTheDocument()
    expect(screen.getByText("1 of 2 lanes busy · 1 approved waiting")).toBeInTheDocument()
    expect(screen.getByText("Empty lane")).toBeInTheDocument()
    expect(screen.getByText("repair round 2")).toBeInTheDocument()
    expect(screen.getByText(/lint \(carried\)/)).toBeInTheDocument()
    expect(screen.getByText("rebasing onto main")).toBeInTheDocument()
    expect(screen.getByText("section-1 · round 3")).toBeInTheDocument()
    expect(screen.getByText("~3 min best case")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /JOB-13/ })).toHaveAttribute("href", "/jobs/13")
    expect(screen.getByRole("progressbar", { name: "acme/rocket Lane 1 section-1 · round 3 landing progress" })).toHaveAttribute("aria-valuenow", "35")
    expect(screen.getByRole("progressbar", { name: "acme/rocket Lane 1 section-2 · round 3 landing progress" })).toHaveAttribute("aria-valuenow", "0")
    expect(screen.getByRole("progressbar", { name: "acme/anvil Lane 1 landing progress" })).toBeInTheDocument()
  })

  it("weights grading by rerun graders without carried-forward runtime", () => {
    const gradingLane = { ...payload.repositories[0].lanes[0], multisect: null }
    const gradingPayload = {
      ...payload,
      repositories: [{ ...payload.repositories[0], lanes: [gradingLane] }]
    }
    render(<LandingLanesPage payload={gradingPayload} />, { wrapper: wrapper() })

    const progress = screen.getByRole("progressbar", { name: "acme/rocket Lane 1 landing progress" })
    expect(progress.children[4]).toHaveStyle({ flex: 100 / 30 })
  })

  it("uses the strip as the full page entry point and applies a landing-lanes broadcast without polling", async () => {
    let current = payload
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(() => Promise.resolve(new Response(JSON.stringify(current), { status: 200, headers: { "Content-Type": "application/json" } })))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(<LandingLanesStrip />, { wrapper: wrapper(client) })

    const link = await screen.findByRole("link", { name: "View all lanes" })
    expect(link).toHaveAttribute("href", "/landing_lanes")
    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/jobs/10")
    expect(screen.queryByText("Empty lane")).not.toBeInTheDocument()
    expect(screen.queryByRole("progressbar", { name: "acme/rocket Lane 2 landing progress" })).not.toBeInTheDocument()
    current = {
      ...payload,
      repositories: [
        { ...payload.repositories[0], lanes: [{ ...payload.repositories[0].lanes[0], anchor_job: { id: 99, slug: "JOB-99", app_path: "/jobs/99" } }] }
      ]
    }
    applyAppEvent(client, { type: "landing_lanes.updated", resource: "landing_lanes", id: 1 })

    expect(await screen.findByText("JOB-99")).toBeInTheDocument()
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2))
  })

  it("shows every occupied branch lane and omits empty sections and repositories", () => {
    const activePayload: LandingLanesPayload = {
      estimate_kind: "best_case",
      repositories: [
        {
          ...payload.repositories[0],
          landing_concurrency: 1,
          lanes: [
            payload.repositories[0].lanes[0],
            payload.repositories[0].lanes[1],
            {
              number: 3,
              empty: false,
              draining: true,
              anchor_job: { id: 30, slug: "JOB-30", app_path: "/jobs/30" },
              phase: "land",
              progress: 0.9
            }
          ],
          additional_branches: [
            {
              branch: "release",
              busy_lane_count: 1,
              lanes: [
                {
                  number: 1,
                  empty: false,
                  draining: false,
                  anchor_job: { id: 31, slug: "JOB-31", app_path: "/jobs/31" },
                  phase: "grade",
                  progress: 0.4
                }
              ]
            }
          ]
        },
        {
          ...payload.repositories[1],
          lanes: [
            {
              ...payload.repositories[1].lanes[0],
              anchor_job: { id: 32, slug: "JOB-32", app_path: "/jobs/32" }
            }
          ]
        },
        {
          ...payload.repositories[1],
          id: 3,
          slug: "acme/empty",
          busy_lane_count: 0,
          lanes: [{ number: 1, empty: true, draining: false }]
        }
      ]
    }
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(["landing_lanes"], activePayload)

    render(<LandingLanesStrip />, { wrapper: wrapper(client) })

    expect(screen.getByText("acme/rocket")).toBeInTheDocument()
    expect(screen.getByText("acme/anvil")).toBeInTheDocument()
    expect(screen.queryByText("acme/empty")).not.toBeInTheDocument()
    expect(screen.queryByText("Empty lane")).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-10" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-30" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-31" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-32" })).toBeInTheDocument()
    expect(screen.getByText("Branch release")).toBeInTheDocument()
  })

  it("prefixes strip job links for the app shell", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(["bootstrap"], { feature_flags: { landing_lanes: true } })
    client.setQueryData(["landing_lanes"], payload)

    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell"]}>
          <LandingLanesStrip prefix="/app-shell" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/app-shell/jobs/10")
    expect(screen.getByRole("link", { name: "View all lanes" })).toHaveAttribute("href", "/app-shell/landing_lanes")
  })

  it("omits the strip when no lanes are active", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(["landing_lanes"], {
      estimate_kind: "best_case",
      repositories: payload.repositories.map((repository) => ({
        ...repository,
        busy_lane_count: 0,
        lanes: repository.lanes.map((lane) => ({ number: lane.number, empty: true, draining: lane.draining })),
        additional_branches: []
      }))
    } satisfies LandingLanesPayload)

    render(<LandingLanesStrip />, { wrapper: wrapper(client) })

    expect(screen.queryByText("Landing lanes")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "View all lanes" })).not.toBeInTheDocument()
  })
})
