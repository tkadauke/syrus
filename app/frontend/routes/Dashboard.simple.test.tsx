import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import type { DashboardPayload, DashboardEpicItem, DashboardJobItem } from "../api/dashboard"
import { DashboardTable, LegacyEpicsBanner } from "./Dashboard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

describe("Dashboard simple mode", () => {
  it("renders every Job with its own status shown directly, not an epic rollup", () => {
    render(
      <QueryClientProvider client={client()}>
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

  it("shows a Preview & Approve action for an implemented job that can be previewed and approved", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ preview: null }))

    const payload = simpleDashboardPayload()
    payload.items = [
      simpleJob({
        id: 5,
        title: "Add invoice PDF export",
        state: "implemented",
        summary_state: "implemented",
        can_start_preview: true,
        can_approve: true,
        paths: {
          job_path: "/jobs/5",
          source_path: "/jobs/5/source",
          app_approve_path: "/api/v1/app/jobs/5/approve",
          app_preview_path: "/api/v1/app/jobs/5/preview",
          app_preview_logs_path: "/api/v1/app/jobs/5/preview/logs"
        }
      })
    ]

    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <DashboardTable payload={payload} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Ready for your review")).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole("button", { name: "Start Preview" })).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Looks good, approve" })).toBeInTheDocument()
  })

  it("does not show a Preview & Approve action for a job that cannot yet be previewed or approved", () => {
    const payload = simpleDashboardPayload()
    payload.items = [simpleJob({ id: 6, title: "Still in progress", state: "running", summary_state: "running" })]

    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <DashboardTable payload={payload} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.queryByText("Ready for your review")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Looks good, approve" })).not.toBeInTheDocument()
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
