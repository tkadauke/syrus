import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { AdminSmartFolderNav } from "./AdminSmartFolderNav"

describe("AdminSmartFolderNav", () => {
  it("renames user-defined smart folders inline", async () => {
    const onMutationSuccess = vi.fn()
    const fetchSpy = mockSmartFolderFetch()
    renderNav({ onMutationSuccess })

    fireEvent.click(screen.getByRole("button", { name: "Manage Saved queue" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Rename" }))
    fireEvent.change(screen.getByLabelText("Rename Saved queue"), { target: { value: "Needs attention" } })
    fireEvent.keyDown(screen.getByLabelText("Rename Saved queue"), { key: "Enter" })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/smart_folders/10",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ smart_folder: { name: "Needs attention", position: 0 } })
        })
      )
    })
    await waitFor(() => {
      expect(onMutationSuccess).toHaveBeenCalledTimes(1)
    })
  })

  it("deletes user-defined smart folders after confirmation", async () => {
    const onMutationSuccess = vi.fn()
    const fetchSpy = mockSmartFolderFetch()
    renderNav({ onMutationSuccess })

    fireEvent.click(screen.getByRole("button", { name: "Manage Saved queue" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Delete" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Confirm delete" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/smart_folders/10",
        expect.objectContaining({ method: "DELETE" })
      )
    })
    await waitFor(() => {
      expect(onMutationSuccess).toHaveBeenCalledTimes(1)
    })
  })

  it("renders the action menu through a body portal", () => {
    renderNav()

    const savedNav = screen.getByRole("navigation", { name: "Admin queue smart folders saved" })
    fireEvent.click(screen.getByRole("button", { name: "Manage Saved queue" }))

    const menu = screen.getByRole("menu")
    expect(menu.parentElement).toBe(document.body)
    expect(savedNav).not.toContainElement(menu)
  })

  it("patches positions when user-defined smart folders are reordered by drag and drop", async () => {
    const onMutationSuccess = vi.fn()
    const fetchSpy = mockSmartFolderFetch()
    renderNav({ folders: smartFolders(), onMutationSuccess })
    const dataTransfer = dataTransferStub()

    fireEvent.dragStart(screen.getByRole("link", { name: "Saved queue 3" }).parentElement!, { dataTransfer })
    fireEvent.dragOver(screen.getByRole("link", { name: "Escalations 1" }).parentElement!, { dataTransfer })
    fireEvent.drop(screen.getByRole("link", { name: "Escalations 1" }).parentElement!, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/smart_folders/11",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ smart_folder: { name: "Escalations", position: 0 } })
        })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/smart_folders/10",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ smart_folder: { name: "Saved queue", position: 1 } })
        })
      )
    })
    await waitFor(() => {
      expect(onMutationSuccess).toHaveBeenCalledTimes(1)
    })
  })

  it("keeps built-in smart folders unmanaged", () => {
    renderNav()

    expect(screen.getByRole("link", { name: "Stuck 2" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Manage Stuck" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Drag Stuck")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Manage" })).not.toBeInTheDocument()
  })

  it("hides save controls when the active folder filter has not changed", () => {
    renderNav({
      activeFolderId: 10,
      currentFilter: savedFilter(),
      search: "?smart_folder_id=10&q=unchanged",
      subjectType: "admin_queue"
    })

    expect(screen.queryByRole("button", { name: "Update Saved queue" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
  })

  it("shows update and save controls when the active saved folder filter changes", () => {
    renderNav({
      activeFolderId: 10,
      currentFilter: changedFilter(),
      search: "?smart_folder_id=10&q=changed",
      subjectType: "admin_queue"
    })

    expect(screen.getByRole("button", { name: "Update Saved queue" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
  })

  it("hides save controls when filters remain but no folder is selected", () => {
    renderNav({
      activeFolderId: null,
      currentFilter: changedFilter(),
      search: "?q=changed",
      subjectType: "admin_queue"
    })

    expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
  })
})

function renderNav({
  activeFolderId = null,
  currentFilter,
  folders = smartFolders(),
  onMutationSuccess = vi.fn(),
  search,
  subjectType
}: {
  activeFolderId?: number | null
  currentFilter?: Record<string, unknown>
  folders?: AdminSmartFolder[]
  onMutationSuccess?: () => void
  search?: string
  subjectType?: string
} = {}) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        <AdminSmartFolderNav
          activeFolderId={activeFolderId}
          allLabel="All queue"
          allPath="/admin/queue/active"
          ariaLabel="Admin queue smart folders"
          currentFilter={currentFilter}
          folders={folders}
          heading="Queues"
          onMutationSuccess={onMutationSuccess}
          prefix=""
          search={search}
          subjectType={subjectType}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function smartFolders(): AdminSmartFolder[] {
  return [
    {
      id: 1,
      name: "Stuck",
      kind: "builtin",
      subject_type: "admin_queue",
      visibility: "primary",
      position: 0,
      count: 2,
      active: false,
      path: "/admin/queue/active?smart_folder_id=1"
    },
    {
      id: 10,
      name: "Saved queue",
      kind: "user_defined",
      subject_type: "admin_queue",
      visibility: "primary",
      position: 0,
      count: 3,
      active: false,
      filter: savedFilter(),
      path: "/admin/queue/active?smart_folder_id=10"
    },
    {
      id: 11,
      name: "Escalations",
      kind: "user_defined",
      subject_type: "admin_queue",
      visibility: "primary",
      position: 1,
      count: 1,
      active: false,
      path: "/admin/queue/active?smart_folder_id=11"
    }
  ]
}

function savedFilter() {
  return {
    and: [
      { value: "runs", op: "is", field: "queue_name" }
    ]
  }
}

function changedFilter() {
  return {
    and: [
      { field: "queue_name", op: "is", value: "merges" }
    ]
  }
}

function mockSmartFolderFetch() {
  return vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(
    new Response(
      JSON.stringify({
        subject_type: "admin_queue",
        subject_label: "Admin queue",
        dashboard_path: "/admin/queue",
        smart_folders: [],
        message: "Smart folder updated."
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    )
  ))
}

function dataTransferStub() {
  const values = new Map<string, string>()
  return {
    effectAllowed: "move",
    getData: (key: string) => values.get(key) || "",
    setData: (key: string, value: string) => values.set(key, value)
  }
}
