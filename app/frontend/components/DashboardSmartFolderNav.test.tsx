import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { DashboardPayload, DashboardSmartFolder } from "../api/dashboard"
import * as smartFoldersApi from "../api/smartFolders"
import { DashboardSmartFolderNav } from "./DashboardSmartFolderNav"

vi.mock("../api/smartFolders", () => ({
  deleteSmartFolder: vi.fn(),
  updateSmartFolder: vi.fn()
}))

function renderNav(folders: DashboardSmartFolder[], options: { payload?: Partial<DashboardPayload>; search?: string } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const renderedPayload = payload({ smart_folders: folders, ...options.payload })
  let currentLocation = ""

  function LocationProbe() {
    const location = useLocation()
    currentLocation = `${location.pathname}${location.search}`
    return null
  }

  const result = render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[`/dashboard/jobs${options.search || ""}`]}>
        <LocationProbe />
        <DashboardSmartFolderNav payload={renderedPayload} prefix="" search={options.search || ""} />
      </MemoryRouter>
    </QueryClientProvider>
  )

  return { ...result, currentLocation: () => currentLocation }
}

function payload(overrides: Partial<DashboardPayload> = {}): DashboardPayload {
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
    landing_queue: { visible: false, paused: false, toggle_path: "/api/v1/app/landing_queue/pause" },
    ownership_scope: { scope: "team", owner_user_id: null, owner_user: null },
    ownership: { scope: "team", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [],
    lanes: [],
    kanban_limit: null,
    setup: null,
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
  } as DashboardPayload
}

function folder(values: Partial<DashboardSmartFolder>): DashboardSmartFolder {
  return {
    id: 101,
    name: "Saved work",
    key: null,
    kind: "user_defined",
    subject_type: "job",
    visibility: "always",
    position: 4,
    count: 3,
    active: false,
    attention_preset: null,
    path: "/dashboard/jobs?smart_folder_id=101",
    ...values
  }
}

const savedFilter = {
  and: [
    { field: "repository", op: "is", value: "tkadauke/syrus" }
  ]
}

const changedFilter = {
  and: [
    { field: "repository", op: "is", value: "tkadauke/raytracer" }
  ]
}

function showFolderActions(name = "Saved work", count = 3) {
  fireEvent.mouseEnter(screen.getByRole("link", { name: `${name} ${count}` }).parentElement!)
}

function dragSavedFolder(sourceName: string, targetName: string) {
  const savedNav = screen.getByRole("navigation", { name: "Saved smart folders" })
  const source = within(savedNav).getByRole("link", { name: `${sourceName} 0` }).parentElement!
  const target = within(savedNav).getByRole("link", { name: `${targetName} 0` }).parentElement!
  const dataTransfer = { dropEffect: "", effectAllowed: "", setData: vi.fn(), getData: vi.fn() }

  fireEvent.dragStart(source, { dataTransfer })
  fireEvent.dragOver(target, { dataTransfer })

  return { dataTransfer, target }
}

describe("DashboardSmartFolderNav", () => {
  beforeEach(() => {
    vi.mocked(smartFoldersApi.updateSmartFolder).mockResolvedValue({} as never)
    vi.mocked(smartFoldersApi.deleteSmartFolder).mockResolvedValue({} as never)
  })

  it("renames a user-defined folder on Enter", async () => {
    renderNav([folder({})])

    showFolderActions()
    fireEvent.click(screen.getByRole("button", { name: "Actions for Saved work" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Rename Saved work" }), { target: { value: "Renamed work" } })
    fireEvent.keyDown(screen.getByRole("textbox", { name: "Rename Saved work" }), { key: "Enter" })

    await waitFor(() => {
      expect(smartFoldersApi.updateSmartFolder).toHaveBeenCalledWith(101, { name: "Renamed work", position: 4 })
    })
  })

  it("cancels rename on Escape", () => {
    renderNav([folder({})])

    showFolderActions()
    fireEvent.click(screen.getByRole("button", { name: "Actions for Saved work" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Rename Saved work" }), { target: { value: "Renamed work" } })
    fireEvent.keyDown(screen.getByRole("textbox", { name: "Rename Saved work" }), { key: "Escape" })

    expect(smartFoldersApi.updateSmartFolder).not.toHaveBeenCalled()
    expect(screen.queryByRole("textbox", { name: "Rename Saved work" })).not.toBeInTheDocument()
    expect(screen.getByText("Saved work")).toBeInTheDocument()
  })

  it("deletes a user-defined folder after two clicks", async () => {
    renderNav([folder({})])

    showFolderActions()
    fireEvent.click(screen.getByRole("button", { name: "Actions for Saved work" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }))

    expect(smartFoldersApi.deleteSmartFolder).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("menuitem", { name: "Confirm delete" }))

    await waitFor(() => {
      expect(smartFoldersApi.deleteSmartFolder).toHaveBeenCalledWith(101)
    })
  })

  it("renders the action menu through a body portal", () => {
    renderNav([folder({})])

    const savedNav = screen.getByRole("navigation", { name: "Saved smart folders" })
    showFolderActions()
    fireEvent.click(screen.getByRole("button", { name: "Actions for Saved work" }))

    const menu = screen.getByRole("menu")
    expect(menu.parentElement).toBe(document.body)
    expect(savedNav).not.toContainElement(menu)
  })

  it("keeps saved folder text aligned while floating the drag handle inside the row target", () => {
    renderNav([folder({})])

    const savedLink = screen.getByRole("link", { name: "Saved work 3" })
    const savedRow = savedLink.parentElement

    expect(savedRow).not.toBeNull()
    expect(savedLink.querySelector("svg")).toBeNull()
    expect(savedRow).toHaveClass("-ml-4", "pl-4")
    expect(savedRow!.querySelector("svg")).toHaveClass("absolute", "left-0")
  })

  it("patches saved folder positions after drag reordering", async () => {
    renderNav([
      folder({ id: 1, name: "Review", position: 0, count: 0 }),
      folder({ id: 2, name: "Blocked", position: 1, count: 0 }),
      folder({ id: 3, name: "Landing", position: 2, count: 0 })
    ])

    const { target } = dragSavedFolder("Review", "Landing")
    fireEvent.drop(target)

    await waitFor(() => {
      expect(smartFoldersApi.updateSmartFolder).toHaveBeenCalledTimes(3)
      expect(smartFoldersApi.updateSmartFolder).toHaveBeenNthCalledWith(1, 2, { name: "Blocked", position: 0 })
      expect(smartFoldersApi.updateSmartFolder).toHaveBeenNthCalledWith(2, 3, { name: "Landing", position: 1 })
      expect(smartFoldersApi.updateSmartFolder).toHaveBeenNthCalledWith(3, 1, { name: "Review", position: 2 })
    })
  })

  it("keeps the reordered saved folder as a valid drop target", () => {
    renderNav([
      folder({ id: 1, name: "Review", position: 0, count: 0 }),
      folder({ id: 2, name: "Blocked", position: 1, count: 0 }),
      folder({ id: 3, name: "Landing", position: 2, count: 0 })
    ])

    const { dataTransfer, target } = dragSavedFolder("Review", "Landing")

    expect(fireEvent.dragOver(target, { dataTransfer })).toBe(false)
    expect(dataTransfer.dropEffect).toBe("move")
  })

  it("does not render menu controls for builtin folders", () => {
    renderNav([folder({ id: 7, name: "Inbox", key: "inbox", kind: "builtin", position: 0, path: "/dashboard/jobs?smart_folder_id=7" })])

    expect(screen.getByRole("link", { name: "Inbox 3" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Actions for Inbox" })).not.toBeInTheDocument()
  })

  it("links the queued blocked count to the blocked queued subset", () => {
    const { currentLocation } = renderNav([
      folder({ id: 7, name: "Queued", key: "queued", kind: "builtin", position: 0, count: 4, blocked_count: 2, path: "/dashboard/jobs?smart_folder_id=7" })
    ])

    fireEvent.click(screen.getByRole("button", { name: "Show 2 blocked queued jobs" }))

    expect(currentLocation()).toBe("/dashboard/jobs?smart_folder_id=7&start_blocked=1")
  })

  it("uses the folder name as fallback when no translation key is set on a builtin folder", () => {
    renderNav([folder({ id: 7, name: "Custom Builtin", key: null, kind: "builtin", position: 0, path: "/dashboard/jobs?smart_folder_id=7" })])

    expect(screen.getByRole("link", { name: "Custom Builtin 3" })).toBeInTheDocument()
  })

  it("does not make builtin folders draggable", () => {
    renderNav([
      folder({ id: 1, name: "Inbox", key: "inbox", kind: "builtin", visibility: "always", count: 0 }),
      folder({ id: 2, name: "Saved review", kind: "user_defined", visibility: "user_defined", position: 0, count: 0 })
    ])

    const foldersNav = screen.getByRole("navigation", { name: "Dashboard smart folders" })
    expect(within(foldersNav).getByRole("link", { name: "Inbox 0" })).toHaveAttribute("draggable", "false")
    expect(screen.getByRole("link", { name: "Saved review 0" }).parentElement).toHaveAttribute("draggable", "true")
  })

  it("hides folder save controls when the selected user-defined folder has not changed", () => {
    renderNav([
      folder({ active: true, filter: savedFilter })
    ], {
      payload: { active_smart_folder_id: 101, filter: savedFilter },
      search: "?smart_folder_id=101"
    })

    expect(screen.queryByRole("button", { name: "Update Saved work" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
  })

  it("shows update and save controls when a selected user-defined folder filter changes", () => {
    renderNav([
      folder({ active: true, filter: savedFilter })
    ], {
      payload: { active_smart_folder_id: 101, filter: changedFilter },
      search: "?smart_folder_id=101&q=changed"
    })

    expect(screen.getByRole("button", { name: "Update Saved work" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save folder" })).toBeInTheDocument()
  })

  it("shows only save controls when a selected builtin folder filter changes", () => {
    renderNav([
      folder({ id: 7, name: "Inbox", key: "inbox", kind: "builtin", active: true, filter: savedFilter, path: "/dashboard/jobs?smart_folder_id=7" })
    ], {
      payload: { active_smart_folder_id: 7, filter: changedFilter },
      search: "?smart_folder_id=7&q=changed"
    })

    expect(screen.queryByRole("button", { name: "Update Inbox" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save folder" })).toBeInTheDocument()
  })

  it("hides save controls when filters remain but no folder is selected", () => {
    renderNav([
      folder({ filter: savedFilter })
    ], {
      payload: { active_smart_folder_id: null, filter: changedFilter },
      search: "?q=changed"
    })

    expect(screen.queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
  })

  it("compares selected folder filters independent of object key order", () => {
    renderNav([
      folder({
        active: true,
        filter: { and: [{ value: "open", op: "is", field: "state" }] }
      })
    ], {
      payload: { active_smart_folder_id: 101, filter: { and: [{ field: "state", op: "is", value: "open" }] } },
      search: "?smart_folder_id=101&q=unchanged"
    })

    expect(screen.queryByRole("button", { name: "Update Saved work" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
  })
})
