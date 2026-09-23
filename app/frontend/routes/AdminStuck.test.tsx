import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AdminStuck } from "./AdminStuck"

function stuckItem(overrides: Record<string, unknown> = {}) {
  return {
    kind: "orphaned_run",
    severity: "warn",
    attention_state: "auto_repairable",
    detail: "Run #12 has been queued for 45m",
    age_label: "45m",
    run_id: 12,
    workflow_id: 3,
    workflow_slug: "WF-3",
    workflow_path: "/admin/workflows/3",
    workflow_trigger_kind: "initial",
    step_kind: "implement",
    job_id: 7,
    job_state: "running",
    job_path: "/jobs/7",
    force_fail_path: "/api/v1/app/admin/stuck/12/force_fail",
    has_transcript: true,
    ...overrides
  }
}

function stuckPayload(overrides: Record<string, unknown> = {}) {
  return {
    items: [stuckItem()],
    pagination: { page: 1, per_page: 20, total: 1, total_pages: 1, first_item: 1, last_item: 1, previous_path: null, next_path: null },
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(stuckPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/stuck"]}>
        <AdminStuck />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminStuck configurable columns", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("renders the raw-table-converted stuck grid with its default columns", async () => {
    renderRoute()

    expect(await screen.findByRole("columnheader", { name: "Severity" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Status" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Kind" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Detail" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Run / Step / Workflow" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Age" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Links" })).toBeInTheDocument()
    expect(screen.getByText("Run #12 has been queued for 45m")).toBeInTheDocument()
  })

  it("hides an optional column and persists it under a stuck-specific key", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Detail" })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("checkbox", { name: "Run / Step / Workflow" }))

    await waitFor(() => {
      expect(screen.queryByRole("columnheader", { name: "Run / Step / Workflow" })).not.toBeInTheDocument()
    })
    // Severity stays -- it's the required identity column and never appears in the picker.
    expect(screen.getByRole("columnheader", { name: "Severity" })).toBeInTheDocument()

    // Links is required (pinned to the end) and never appears in the persisted order.
    expect(JSON.parse(window.localStorage.getItem("syrus.admin.stuck.visible_columns") ?? "[]")).toEqual([
      "status",
      "kind",
      "detail",
      "age"
    ])
  })
})
