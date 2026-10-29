import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminProcessesIndex } from "./AdminProcesses"
import { AdminQueueRoute } from "./AdminQueue"
import { AdminUsersIndex } from "./AdminUsers"

const preset = { field: "smart_folder_preset", op: "is", value: "primary" }
const schema = [
  {
    field: "smart_folder_preset",
    label: "Folder",
    bucket: "status",
    operators: ["is"],
    values: [
      { value: "primary", label: "Primary" },
      { value: "contradictory", label: "Contradictory" }
    ]
  },
  {
    field: "state",
    label: "State",
    bucket: "status",
    operators: ["is"],
    values: [
      { value: "open", label: "Open" },
      { value: "closed", label: "Closed" }
    ]
  }
]

const pagination = {
  page: 1,
  per_page: 100,
  total: 0,
  total_pages: 0,
  has_previous_page: false,
  has_next_page: false,
  previous_page: null,
  next_page: null,
  first_item: 0,
  last_item: 0
}

const surfaces = [
  {
    name: "Admin Users",
    path: "/admin/users",
    route: "/admin/users",
    element: <AdminUsersIndex />,
    payload: {
      active_smart_folder_id: 7,
      smart_folders: [{ id: 7, name: "Primary", kind: "builtin", position: 0, active: true }],
      filter: { and: [preset] },
      controls: { filter_schema: schema },
      filters: {},
      count: 0,
      pagination,
      sort: { column: "email", direction: "asc" },
      users: []
    }
  },
  {
    name: "Admin Queue",
    path: "/admin/queue/active",
    route: "/admin/queue/:tab",
    element: <AdminQueueRoute />,
    payload: {
      active_smart_folder_id: 7,
      smart_folders: [{ id: 7, name: "Primary", kind: "builtin", position: 0, active: true }],
      filter: { and: [preset] },
      controls: { filter_schema: schema },
      jobs: [],
      pagination,
      sort: { column: "claimed_at", direction: "desc" },
      total: 0
    }
  },
  {
    name: "Admin Processes",
    path: "/admin/processes",
    route: "/admin/processes",
    element: <AdminProcessesIndex />,
    payload: {
      active_smart_folder_id: 7,
      smart_folders: [{ id: 7, name: "Primary", kind: "builtin", position: 0, active: true }],
      filter: { and: [preset] },
      controls: { filter_schema: schema },
      processes: [],
      running_total: 0,
      total: 0,
      pagination,
      sort: { column: "started_at", direction: "desc" }
    }
  }
]

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{location.search}</output>
}

function renderSurface(surface: (typeof surfaces)[number]) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(surface.payload))
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[`${surface.path}?smart_folder_id=7`]}>
        <Routes>
          <Route
            path={surface.route}
            element={
              <>
                {surface.element}
                <LocationProbe />
              </>
            }
          />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function currentFilter() {
  const q = new URLSearchParams(screen.getByTestId("location").textContent || "").get("q")
  if (q == null) return null
  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  return JSON.parse(decodeURIComponent(escape(atob(normalized))))
}

describe.each(surfaces)("$name SmartFolder FilterBar integration", (surface) => {
  afterEach(() => vi.restoreAllMocks())

  it("adds a chip and clears the built-in navigation selection", async () => {
    renderSurface(surface)
    await screen.findByRole("button", { name: "Folder is Primary" })

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "State status" }))

    await waitFor(() => expect(screen.getByTestId("location")).not.toHaveTextContent("smart_folder_id"))
    expect(currentFilter()).toEqual({ and: [preset, { field: "state", op: "is", value: "open" }] })
  })

  it("edits the preset to a contradictory replacement and clears selection", async () => {
    renderSurface(surface)
    fireEvent.click(await screen.findByRole("button", { name: "Folder is Primary" }))
    fireEvent.change(screen.getByRole("combobox", { name: "Value" }), { target: { value: "contradictory" } })

    await waitFor(() => expect(screen.getByTestId("location")).not.toHaveTextContent("smart_folder_id"))
    expect(currentFilter()).toEqual({ and: [{ ...preset, value: "contradictory" }] })
  })

  it("removes the last chip, sends empty q, and clears selection", async () => {
    renderSurface(surface)
    await screen.findByRole("button", { name: "Folder is Primary" })
    fireEvent.click(screen.getByRole("button", { name: "Remove Folder filter" }))

    await waitFor(() => expect(screen.getByTestId("location")).not.toHaveTextContent("smart_folder_id"))
    expect(currentFilter()).toEqual({ and: [] })
  })
})
