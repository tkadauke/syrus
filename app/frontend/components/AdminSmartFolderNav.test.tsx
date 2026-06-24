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
})

function renderNav({ folders = smartFolders(), onMutationSuccess = vi.fn() }: { folders?: AdminSmartFolder[]; onMutationSuccess?: () => void } = {}) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        <AdminSmartFolderNav
          activeSmartFolderId={null}
          allLabel="All queue"
          allPath="/admin/queue/active"
          ariaLabel="Admin queue smart folders"
          folders={folders}
          heading="Queues"
          onMutationSuccess={onMutationSuccess}
          prefix=""
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
