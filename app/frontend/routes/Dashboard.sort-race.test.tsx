import { render } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

// Simulates the stale-chrome / fresh-rows race that corrupts the landing queue
// sort preference. Chrome still reports landing_queue as the active smart folder,
// but the rows response (for the newly-selected folder) returns
// landing_queue.visible = false. The buggy check (!landing_queue.visible) fired a
// reset mutation that stamped sort_column = "created_at" onto the LQ folder slot.
// The fix derives "are we on the LQ?" from chrome-only fields (smart_folders +
// active_smart_folder_id), which are always in sync, so the reset never fires
// during the mixed-payload window.

const LQ_FOLDER_ID = 42

function buildPayload(overrides: Partial<DashboardPayload> = {}): DashboardPayload {
  return {
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 0,
    total_pages: 1,
    counts: { jobs: 0, epics: 0, workflows: 0 },
    ownership_scope: { scope: "mine", owner_user_id: null, owner_user: null },
    preferences: {
      sort: { column: "landing_queue_position", direction: "asc" },
      visible_columns: [],
      kanban_lanes: [],
      ownership_scope: "mine",
      owner_user_id: null,
      owner_id: null,
      raw: {}
    },
    filter: null,
    controls: {
      views: ["list", "kanban"],
      ownership_scopes: [],
      owners: [],
      sort_columns: ["landing_queue_position", "created_at"],
      sort_directions: ["asc", "desc"],
      columns: { required: [], optional: [] },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: {
      visible: false,
      paused: false,
      toggle_path: "/api/v1/app/landing_queue/toggle",
      entries: []
    },
    ownership: { scope: "mine", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [
      {
        id: LQ_FOLDER_ID,
        name: "Landing queue",
        kind: "builtin",
        position: 6,
        subject_type: "job",
        visibility: "when_present",
        count: 2,
        active: true,
        filter: { and: [{ field: "attention", op: "is", value: "landing_queue" }] },
        attention_preset: "landing_queue",
        path: `/dashboard/jobs?smart_folder_id=${LQ_FOLDER_ID}`
      }
    ],
    active_smart_folder_id: LQ_FOLDER_ID,
    items: [],
    lanes: [],
    kanban_limit: null,
    paths: {
      dashboard_path: "/dashboard",
      dashboard_jobs_path: "/dashboard/jobs",
      dashboard_epics_path: "/dashboard/epics",
      dashboard_workflows_path: "/dashboard/workflows",
      new_epic_path: "/epics/new",
      new_job_path: "/jobs/new",
      app_dashboard_path: "/api/v1/app/dashboard"
    },
    ...overrides
  }
}

function renderTable(payload: DashboardPayload) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardTable payload={payload} prefix="" setupStatus={null} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DashboardTable landing queue sort race condition", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("does not reset the sort preference when chrome shows we are on the landing queue folder", async () => {
    // This simulates the race: rows returned landing_queue.visible = false (fresh,
    // navigated to another folder), but chrome still reports active_smart_folder_id
    // pointing to the LQ folder (stale). The bug fired a sort reset targeting the
    // LQ folder ID, corrupting its sort preference.
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "ok", dashboard_preferences: {} })
    )

    const payload = buildPayload({
      // landing_queue.visible = false: rows response for the NEW folder
      landing_queue: { visible: false, paused: false, toggle_path: "", entries: [] },
      // active_smart_folder_id = LQ_FOLDER_ID: chrome response still stale (on LQ)
      active_smart_folder_id: LQ_FOLDER_ID
    })

    renderTable(payload)

    // Allow any pending effects/mutations to flush
    await new Promise((resolve) => setTimeout(resolve, 50))

    const prefCalls = fetchSpy.mock.calls.filter(([input]) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : (input as Request).url
      return url.includes("/api/v1/app/dashboard/preferences")
    })

    expect(prefCalls).toHaveLength(0)
  })

  it("does reset the sort preference when we are genuinely outside the landing queue folder", async () => {
    // This confirms the normal reset path: stored sort is landing_queue_position but the
    // active folder (from chrome) is a different one — no LQ folder in smart_folders
    // matches active_smart_folder_id.
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "ok", dashboard_preferences: {} })
    )

    const payload = buildPayload({
      smart_folders: [
        {
          id: 99,
          name: "Inbox",
          kind: "builtin",
          position: 5,
          subject_type: "job",
          visibility: "always",
          count: 3,
          active: true,
          filter: {},
          attention_preset: "inbox",
          path: "/dashboard/jobs?smart_folder_id=99"
        }
      ],
      active_smart_folder_id: 99,
      landing_queue: { visible: false, paused: false, toggle_path: "", entries: [] }
    })

    renderTable(payload)

    await new Promise((resolve) => setTimeout(resolve, 50))

    const prefCalls = fetchSpy.mock.calls.filter(([input]) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : (input as Request).url
      return url.includes("/api/v1/app/dashboard/preferences")
    })

    expect(prefCalls).toHaveLength(1)
  })
})
