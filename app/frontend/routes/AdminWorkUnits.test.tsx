import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminWorkUnits } from "./AdminWorkUnits"

function payload(overrides: Record<string, unknown> = {}) {
  return {
    intents: [
      {
        id: 8,
        kind: "ci_failure",
        label: "CI failure",
        state: "requested",
        priority: null,
        scope_type: "job",
        scope_id: 3578,
        delivery_track: null,
        wait_reason: null,
        wait_until: null,
        wait_details: {},
        requested_at: "2026-08-23T16:30:00Z",
        satisfied_at: null,
        cancelled_at: null,
        source_type: null,
        source_id: null,
        source_ref: "syrus/foo",
        target_ref: "main",
        repository: { id: 2, slug: "tkadauke/syrus", path: "/repositories/2" },
        source_repository: null,
        target_repository: null,
        actor: { id: 1, display_name: "Thomas Kadauke", email_address: "thomas@example.com" },
        jobs: [ { id: 3578, slug: "JOB-3578", title: "Fix CI", state: "running", path: "/jobs/3578" } ],
        units: [
          {
            id: 8,
            kind: "ci_failure",
            label: "CI failure",
            state: "running",
            scope_type: "job",
            scope_id: 3578,
            delivery_track: null,
            blocked_reason: null,
            blocked_until: null,
            blocked_details: {},
            pause_requested: false,
            preemption_reason: null,
            source_ref: "syrus/foo",
            target_ref: "main",
            created_at: "2026-08-23T16:30:00Z",
            started_at: "2026-08-23T16:31:00Z",
            finished_at: null,
            repository: { id: 2, slug: "tkadauke/syrus", path: "/repositories/2" },
            source_repository: null,
            target_repository: null,
            workflow: { id: 20041, slug: "WF-20041", trigger_kind: "ci_failure", state: "running", path: "/jobs/3578?tab=workflows#workflow-20041" },
            members: [ { role: "primary", job: { id: 3578, slug: "JOB-3578", title: "Fix CI", state: "running", path: "/jobs/3578" } } ]
          }
        ]
      }
    ],
    pagination: {
      page: 1,
      per_page: 50,
      total: 1,
      total_pages: 1,
      first_item: 1,
      last_item: 1,
      previous_path: null,
      next_path: null
    },
    filter_schema: [
      { field: "intent_state", label: "Intent state", bucket: "enum", operators: [ "is" ], values: [ { value: "requested", label: "requested" } ] },
      { field: "job_id", label: "Job ID", bucket: "number", operators: [ "is" ] }
    ],
    filter: { and: [] },
    filters: { sort: "requested", direction: "desc" },
    settings: { show_work_unit_debug: false },
    ...overrides
  }
}

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ "/admin/work_units" ]}>
        <AdminWorkUnits />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminWorkUnits", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders work intents, linked units, chip filters, and the debug visibility toggle", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/work_units") return Promise.resolve(jsonResponse(payload()))
      if (url === "/api/v1/app/admin/settings" && init?.method === "PATCH") return Promise.resolve(jsonResponse({ settings: { show_work_unit_debug: true } }))
      return Promise.resolve(jsonResponse(payload({ settings: { show_work_unit_debug: true } })))
    })

    renderRoute()

    expect(await screen.findByRole("heading", { name: "Work Units" })).toBeInTheDocument()
    expect((await screen.findAllByRole("link", { name: "JOB-3578" }))[0]).toHaveAttribute("href", "/jobs/3578")
    expect(screen.getByRole("link", { name: "WF-20041" })).toHaveAttribute("href", "/jobs/3578?tab=workflows#workflow-20041")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByText("Intent state")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show on job pages" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings", expect.objectContaining({ method: "PATCH" }))
    })
    const patchCall = fetchSpy.mock.calls.find(([input, init]) => String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH")
    expect(JSON.parse(String(patchCall?.[1]?.body))).toEqual({ app_setting: { show_work_unit_debug: true } })
  })
})
