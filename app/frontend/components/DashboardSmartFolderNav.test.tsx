import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { DashboardPayload, DashboardSmartFolder } from "../api/dashboard"
import * as smartFoldersApi from "../api/smartFolders"
import { DashboardSmartFolderNav } from "./DashboardSmartFolderNav"

vi.mock("../api/smartFolders", () => ({
  deleteSmartFolder: vi.fn(),
  updateSmartFolder: vi.fn()
}))

function renderNav(folders: DashboardSmartFolder[]) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })

  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <DashboardSmartFolderNav payload={payload(folders)} prefix="" search="" />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function payload(folders: DashboardSmartFolder[]): DashboardPayload {
  return {
    subject: "job",
    view: "list",
    filter: null,
    landing_queue: { visible: false, paused: false, toggle_path: "/api/v1/app/landing_queue/pause" },
    smart_folders: folders,
    active_smart_folder_id: null,
    paths: {
      dashboard_path: "/dashboard",
      dashboard_jobs_path: "/dashboard/jobs",
      dashboard_epics_path: "/dashboard/epics",
      dashboard_workflows_path: "/dashboard/workflows",
      new_epic_path: "/epics/new",
      new_job_path: "/jobs/new",
      app_dashboard_path: "/api/v1/app/dashboard"
    }
  } as DashboardPayload
}

function folder(values: Partial<DashboardSmartFolder>): DashboardSmartFolder {
  return {
    id: 101,
    name: "Saved work",
    kind: "user_defined",
    subject_type: "job",
    visibility: "always",
    position: 4,
    count: 3,
    active: false,
    path: "/dashboard/jobs?smart_folder_id=101",
    ...values
  }
}

describe("DashboardSmartFolderNav", () => {
  beforeEach(() => {
    vi.mocked(smartFoldersApi.updateSmartFolder).mockResolvedValue({} as never)
    vi.mocked(smartFoldersApi.deleteSmartFolder).mockResolvedValue({} as never)
  })

  it("renames a user-defined folder on Enter", async () => {
    renderNav([folder({})])

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

    fireEvent.click(screen.getByRole("button", { name: "Actions for Saved work" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }))

    expect(smartFoldersApi.deleteSmartFolder).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("menuitem", { name: "Confirm delete?" }))

    await waitFor(() => {
      expect(smartFoldersApi.deleteSmartFolder).toHaveBeenCalledWith(101)
    })
  })

  it("does not render menu controls for builtin folders", () => {
    renderNav([folder({ id: 7, name: "Inbox", kind: "builtin", position: 0, path: "/dashboard/jobs?smart_folder_id=7" })])

    expect(screen.getByRole("link", { name: "Inbox 3" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Actions for Inbox" })).not.toBeInTheDocument()
  })
})
