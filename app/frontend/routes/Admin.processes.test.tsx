import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { adminProcessesPayloadFromSearch, adminProcessesPayloadWithSavedFolder, currentAdminProcessFilter } from "../test/app/adminPayloads"
import { mobileFiltersSummary } from "../test/app/dashboardPayloads"
import { renderAppAt } from "../test/app/render"
import { mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App admin processes", () => {
  installAppTestLifecycle()

  it("renders the admin processes route from the app admin processes API", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            filter: { and: [{ field: "state", op: "is", value: "running" }] },
            controls: {
              filter_schema: [
                {
                  field: "state",
                  label: "State",
                  bucket: "enum",
                  operators: ["is", "is_one_of"],
                  values: [
                    { value: "running", label: "Running" },
                    { value: "finished", label: "Finished" }
                  ]
                },
                { field: "kind", label: "Kind", bucket: "enum", operators: ["is"], values: [{ value: "agent", label: "Agent" }] },
                { field: "user_id", label: "User", bucket: "fk", operators: ["is", "is_not", "is_set", "is_unset"], typeahead: true },
                { field: "hostname", label: "Hostname", bucket: "enum", operators: ["is"], values: [{ value: "worker-a", label: "worker-a" }] }
              ]
            },
            active_smart_folder_id: 3,
            smart_folders: [
              {
                id: 3,
                name: "Running",
                kind: "builtin",
                subject_type: "spawned_process",
                visibility: "always",
                count: 1,
                active: true,
                path: "/admin/processes?smart_folder_id=3"
              }
            ],
            running_total: 1,
            total: 1,
            pagination: {
              page: 1,
              per_page: 100,
              total: 1,
              total_pages: 1,
              has_previous_page: false,
              has_next_page: false,
              previous_page: null,
              next_page: null,
              first_item: 1,
              last_item: 1
            },
            sort: { column: "started_at", direction: "desc" },
            processes: [
              {
                id: 8,
                kind: "agent",
                command: "claude --print",
                workdir: "/work",
                hostname: "worker-a",
                pid: 123,
                pgid: 123,
                started_at: "2026-05-30T12:00:00Z",
                last_chunk_at: "2026-05-30T12:01:00Z",
                finished_at: null,
                duration_s: 65,
                exit_status: null,
                outcome: null,
                wall_timeout_s: 1800,
                silent_timeout_s: 300,
                run_id: 4,
                workflow_id: 2,
                stale: false,
                kill_requested_at: null,
                kill_requested_by_user_id: null,
                user: { id: 1, label: "Operator", email_address: "operator@example.com", path: "/admin/users/1" },
                owner: { type: "workflow", label: "JOB-9 · Fix flaky spec", path: "/jobs/9?tab=workflows#workflow-2" }
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/processes?state=running"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.getByRole("main", { name: "Admin processes" })).toBeInTheDocument()
      expect(await screen.findByText("claude --print")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Operator (operator@example.com)" })).toHaveAttribute("href", "/app-shell/admin/users/1")
      expect(screen.getByRole("link", { name: "JOB-9 · Fix flaky spec" })).toHaveAttribute("href", "/app-shell/jobs/9?tab=workflows#workflow-2")
      const disclosure = mobileFiltersSummary("Running").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(mobileFiltersSummary("Running"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByText("worker-a")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /State is Running/ })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "User reference" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Hostname list" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Running 1" })).toHaveAttribute("href", "/app-shell/admin/processes?smart_folder_id=3")
      expect(screen.getByRole("link", { name: "Detail" })).toHaveAttribute("href", "/app-shell/admin/processes/8")
      expect(screen.getByRole("button", { name: "Kill" })).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/processes?state=running",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreMedia()
    }
  })

  it("shows an update button for admin process saved folder filter drift", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () =>
      jsonResponse(
        adminProcessesPayloadWithSavedFolder({
          and: [{ field: "state", op: "is", value: "finished" }]
        })
      )
    )

    try {
      renderAppAt("/app-shell/admin/processes?smart_folder_id=11&q=dGVzdA")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Live agents"))
      expect(screen.getByRole("button", { name: "Update Live agents" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the save form for admin process filters with no active folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const payload = adminProcessesPayloadWithSavedFolder(currentAdminProcessFilter())
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () =>
      jsonResponse({
        ...payload,
        active_smart_folder_id: null,
        smart_folders: payload.smart_folders.map((folder) => ({ ...folder, active: false }))
      })
    )

    try {
      renderAppAt("/app-shell/admin/processes")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Active + recent"))
      expect(screen.queryByRole("button", { name: "Update Live agents" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("keeps an admin process saved folder active when applying filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname === "/api/v1/app/admin/processes") {
        return Promise.resolve(jsonResponse(adminProcessesPayloadFromSearch(url.searchParams)))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
    })

    try {
      renderAppAt("/app-shell/admin/processes?smart_folder_id=11")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Live agents"))
      expect(screen.queryByRole("button", { name: "Update Live agents" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "State is Running" }))
      fireEvent.change(screen.getByLabelText("Value"), { target: { value: "finished" } })

      await waitFor(() => {
        expect(
          fetchSpy.mock.calls.some(([path]) => {
            const url = new URL(String(path), "http://example.test")
            return url.pathname === "/api/v1/app/admin/processes" && url.searchParams.get("smart_folder_id") === "11" && url.searchParams.has("q")
          })
        ).toBe(true)
      })
      expect(await screen.findByRole("button", { name: "Update Live agents" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the update button for admin process saved folder matching filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () => jsonResponse(adminProcessesPayloadWithSavedFolder(currentAdminProcessFilter())))

    try {
      renderAppAt("/app-shell/admin/processes?smart_folder_id=11")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Live agents"))
      expect(screen.queryByRole("button", { name: "Update Live agents" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("renders the admin process detail route with React transcript links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            id: 8,
            kind: "agent",
            command: "claude --print",
            workdir: "/work",
            hostname: "worker-a",
            pid: 123,
            pgid: 123,
            started_at: "2026-05-30T12:00:00Z",
            last_chunk_at: "2026-05-30T12:01:00Z",
            finished_at: null,
            duration_s: 65,
            exit_status: null,
            outcome: null,
            wall_timeout_s: 1800,
            silent_timeout_s: 300,
            run_id: 4,
            workflow_id: 2,
            workflow_slug: "WF-2",
            workflow_path: "/jobs/42?tab=workflows#workflow-2",
            stale: false,
            kill_requested_at: null,
            kill_requested_by_user_id: null,
            user: { id: 1, label: "Operator", email_address: "operator@example.com", path: "/admin/users/1" },
            owner: { type: "workflow", label: "JOB-42 · Fix flaky spec", path: "/jobs/42?tab=workflows#workflow-2" },
            host_metrics: null
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/processes/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const processDetail = screen.getByRole("main", { name: "Admin process detail" })
    expect(processDetail).toBeInTheDocument()
    expect(await within(processDetail).findByText("claude --print")).toBeInTheDocument()
    expect(within(processDetail).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
    expect(within(processDetail).getByRole("link", { name: "#4" })).toHaveAttribute("href", "/app-shell/admin/runs/4/transcript")
    expect(within(processDetail).getByRole("link", { name: "WF-2" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-2")
    expect(within(processDetail).getByRole("link", { name: "JOB-42 · Fix flaky spec" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-2")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/processes/8",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })
})
