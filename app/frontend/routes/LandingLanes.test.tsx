import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { LandingLanesPayload } from "../api/landingLanes"
import { applyAppEvent } from "../lib/appEvents"
import { LandingLanesPage, LandingLanesStrip } from "./LandingLanes"

const payload: LandingLanesPayload = {
  estimate_kind: "best_case",
  repositories: [
    {
      id: 1,
      slug: "acme/rocket",
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
            { name: "lint", state: "carried", carried: true, expected_seconds: 0, progress: 1 }
          ],
          multisect: {
            sub_lanes: [
              { step_id: 1, role: "section-1", round: 3, state: "running" },
              { step_id: 2, role: "section-2", round: 3, state: "queued" }
            ]
          }
        },
        { number: 2, empty: true, draining: false }
      ]
    },
    {
      id: 2,
      slug: "acme/anvil",
      landing_concurrency: 1,
      busy_lane_count: 1,
      approved_backlog: [],
      lanes: [{ number: 1, empty: false, draining: false, phase: "reconcile", rebasing: true, progress: 0.5, best_case_remaining_seconds: 60 }]
    }
  ]
}

function wrapper(client = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={client}><MemoryRouter>{children}</MemoryRouter></QueryClientProvider>
  }
}

describe("landing lanes", () => {
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
  })

  it("uses the strip as the full page entry point and applies a landing-lanes broadcast without polling", async () => {
    let current = payload
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify(current), { status: 200, headers: { "Content-Type": "application/json" } }))
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(<LandingLanesStrip />, { wrapper: wrapper(client) })

    const link = await screen.findByRole("link", { name: "View all lanes" })
    expect(link).toHaveAttribute("href", "/landing_lanes")
    expect(screen.getByText("JOB-10")).toBeInTheDocument()
    current = {
      ...payload,
      repositories: [{ ...payload.repositories[0], lanes: [{ ...payload.repositories[0].lanes[0], anchor_job: { id: 99, slug: "JOB-99", app_path: "/jobs/99" } }] }]
    }
    applyAppEvent(client, { type: "landing_lanes.updated", resource: "landing_lanes", id: 1 })

    expect(await screen.findByText("JOB-99")).toBeInTheDocument()
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2))
    expect(within(screen.getByText("Landing lanes").parentElement!).getAllByRole("link")).toHaveLength(1)
  })
})
