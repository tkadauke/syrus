import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardSmartFolderNav } from "./DashboardSmartFolderNav"

describe("DashboardSmartFolderNav", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("patches saved folder positions after drag reordering", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({ smart_folders: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    ))
    renderNav(dashboardPayload({
      smart_folders: [
        smartFolder({ id: 1, name: "Review", position: 0 }),
        smartFolder({ id: 2, name: "Blocked", position: 1 }),
        smartFolder({ id: 3, name: "Landing", position: 2 })
      ]
    }))

    const savedNav = screen.getByRole("navigation", { name: "Saved smart folders" })
    const review = within(savedNav).getByRole("link", { name: "Review 0" })
    const landing = within(savedNav).getByRole("link", { name: "Landing 0" })
    const dataTransfer = { dropEffect: "", effectAllowed: "", setData: vi.fn(), getData: vi.fn() }

    fireEvent.dragStart(review, { dataTransfer })
    fireEvent.dragOver(landing, { dataTransfer })
    fireEvent.drop(landing, { dataTransfer })

    await waitFor(() => {
      const patchCalls = fetchSpy.mock.calls.filter(([, init]) => init?.method === "PATCH")
      expect(patchCalls).toHaveLength(3)
      expect(patchCalls.map(([path]) => path)).toEqual([
        "/api/v1/app/smart_folders/2",
        "/api/v1/app/smart_folders/3",
        "/api/v1/app/smart_folders/1"
      ])
      expect(patchCalls.map(([, init]) => JSON.parse(String(init?.body)))).toEqual([
        { smart_folder: { name: "Blocked", position: 0 } },
        { smart_folder: { name: "Landing", position: 1 } },
        { smart_folder: { name: "Review", position: 2 } }
      ])
    })
  })

  it("does not make builtin folders draggable", () => {
    renderNav(dashboardPayload({
      smart_folders: [
        smartFolder({ id: 1, name: "Inbox", kind: "builtin", visibility: "always" }),
        smartFolder({ id: 2, name: "Saved review", kind: "user_defined", visibility: "user_defined", position: 0 })
      ]
    }))

    const foldersNav = screen.getByRole("navigation", { name: "Dashboard smart folders" })
    expect(within(foldersNav).getByRole("link", { name: "Inbox 0" })).toHaveAttribute("draggable", "false")
    expect(screen.getByRole("link", { name: "Saved review 0" })).toHaveAttribute("draggable", "true")
  })
})

function renderNav(payload: DashboardPayload) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        <DashboardSmartFolderNav payload={payload} prefix="" search="" />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function dashboardPayload(overrides: Partial<DashboardPayload> = {}): DashboardPayload {
  return {
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 0,
    total_pages: 1,
    counts: { jobs: 0, epics: 0, workflows: 0 },
    preferences: {
      sort: { column: "created_at", direction: "desc" },
      visible_columns: [],
      kanban_lanes: [],
      ownership_scope: "team",
      owner_user_id: null,
      owner_id: null,
      raw: {}
    },
    controls: {
      views: ["list"],
      ownership_scopes: [],
      owners: [],
      sort_columns: [],
      sort_directions: [],
      columns: { required: [], optional: [] },
      kanban_lanes: [],
      filter_suggestions: [],
      filter_schema: []
    },
    filter: { and: [] },
    landing_queue: { visible: false, paused: false, toggle_path: "/api/v1/app/dashboard/landing_pause" },
    ownership_scope: { scope: "team", owner_user_id: null, owner_user: null },
    ownership: { scope: "team", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [],
    lanes: [],
    kanban_limit: null,
    setup: null,
    paths: {
      new_job_path: "/jobs/new",
      new_epic_path: "/epics/new"
    },
    ...overrides
  } as DashboardPayload
}

function smartFolder(overrides: Partial<DashboardPayload["smart_folders"][number]> = {}): DashboardPayload["smart_folders"][number] {
  return {
    id: 1,
    name: "Folder",
    kind: "user_defined",
    subject_type: "job",
    visibility: "user_defined",
    position: 0,
    count: 0,
    active: false,
    path: "/dashboard/jobs?view=list&smart_folder_id=1",
    ...overrides
  }
}
