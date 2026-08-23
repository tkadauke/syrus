import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardPayload, DashboardEpicItem, DashboardJobItem } from "../api/dashboard"
import { DashboardTable, LegacyEpicsBanner } from "./Dashboard"

describe("Dashboard simple mode", () => {
  it("renders every Job with its own status shown directly, not an epic rollup", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Checkout polish")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("Ship the invoice PDF export")).toBeInTheDocument()
    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getByText("Pr merged")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /checkout polish/i })).not.toBeInTheDocument()
    expect(screen.queryByText("Workflow")).not.toBeInTheDocument()
  })

  it("renders the legacy epic list unchanged when subject is epic, instead of the job list", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleEpicsDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const link = screen.getByRole("link", { name: /legacy checkout revamp/i })
    expect(link).toHaveAttribute("href", "/epics/9")
    expect(screen.queryByText("Ship the invoice PDF export")).not.toBeInTheDocument()
  })
})

describe("LegacyEpicsBanner", () => {
  it("explains that these are older features and new requests appear on the main dashboard", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <LegacyEpicsBanner />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("status")).toHaveTextContent(/older, multi-step features/i)
    expect(screen.getByRole("status")).toHaveTextContent(/individual tasks on the main dashboard/i)
  })
})

  }
}

function simpleEpicItem(overrides: Partial<DashboardEpicItem>): DashboardEpicItem {
  return {
    type: "epic",
    id: 9,
    number: 9,
    display_number: "EPIC-9",
    title: "Legacy checkout revamp",
    description: "",
    state: "in_progress",
    simple_status: "working_on_it",
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
    jobs_count: 2,
    landed_jobs_count: 0,
    job_state_counts: {},
    max_commits_behind_base: null,
    created_at: null,
    updated_at: "2026-07-30T12:00:00Z",
    done_at: null,
    archived_at: null,
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    paths: {
      epic_path: "/epics/9",
      edit_epic_path: "/epics/9/edit",
      app_state_path: "/api/v1/app/epics/9/state",
      app_claim_path: "/api/v1/app/epics/9/claim",
      app_unclaim_path: "/api/v1/app/epics/9/unclaim"
    },
    ...overrides
  }
}

function simpleEpicsDashboardPayload(): DashboardPayload {
  const base = simpleDashboardPayload()
  return {
    ...base,
    subject: "epic",
    counts: { jobs: 0, epics: 1, workflows: 0 },
    items: [simpleEpicItem({})]
  }
}
