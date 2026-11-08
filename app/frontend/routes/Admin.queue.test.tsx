import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { adminQueuePayloadFromSearch, adminQueuePayloadWithSavedFolder, currentAdminQueueFilter } from "../test/app/adminPayloads"
import { mobileFiltersSummary } from "../test/app/dashboardPayloads"
import { renderAppAt } from "../test/app/render"
import { mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App admin queue", () => {
  installAppTestLifecycle()

  it("renders the admin queue route from the app admin queue API", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            filter: { and: [{ field: "queue_name", op: "is", value: "runs" }] },
            controls: {
              filter_schema: [
                {
                  field: "queue_name",
                  label: "Queue",
                  bucket: "enum",
                  operators: ["is", "is_one_of"],
                  values: [
                    { value: "runs", label: "Runs" },
                    { value: "chat", label: "Chat" },
                    { value: "default", label: "Default" }
                  ]
                },
                { field: "job_class", label: "Job class", bucket: "string", operators: ["contains", "is"], values: [] }
              ]
            },
            active_smart_folder_id: 1,
            smart_folders: [
              {
                id: 1,
                name: "Runs",
                kind: "builtin",
                subject_type: "admin_queue",
                visibility: "always",
                count: 1,
                active: true,
                path: "/admin/queue/active?smart_folder_id=1"
              },
              {
                id: 2,
                name: "Chat",
                kind: "builtin",
                subject_type: "admin_queue",
                visibility: "always",
                count: 0,
                active: false,
                path: "/admin/queue/active?smart_folder_id=2"
              }
            ],
            jobs: [
              {
                id: 12,
                class_name: "RunJob",
                queue_name: "runs",
                arguments: [42],
                created_at: "2026-05-30T12:00:00Z",
                claimed_at: "2026-05-30T12:01:00Z"
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/queue/active"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.getByRole("main", { name: "Admin queue" })).toBeInTheDocument()
      expect(screen.getByRole("heading", { name: "Queue" }).closest("header")).toHaveClass("items-end", "justify-between")
      expect(screen.getByRole("button", { name: "Run stale-run reaper" })).toHaveClass("shrink-0")
      expect(await screen.findByText("RunJob")).toBeInTheDocument()
      const disclosure = mobileFiltersSummary("Runs").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(mobileFiltersSummary("Runs"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByText("runs")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /Queue is Runs/ })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Job class text" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Runs 1" })).toHaveAttribute("href", "/app-shell/admin/queue/active?smart_folder_id=1")
      expect(screen.getByRole("link", { name: "All queue" })).toHaveAttribute("href", "/app-shell/admin/queue/active")
      expect(screen.getByRole("link", { name: "Failed" })).toHaveAttribute("href", "/app-shell/admin/queue/failed")
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/queue/active",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreMedia()
    }
  })

  it("keeps the admin queue filter editor open while filter changes refetch", async () => {
    const restoreMedia = mockMediaQuery(false)
    let resolveRefetch: (response: Response) => void = () => {}
    const queuePayload = (value: string) => ({
      filter: { and: [{ field: "job_class", op: "contains", value }] },
      controls: {
        filter_schema: [
          { field: "queue_name", label: "Queue", bucket: "enum", operators: ["is"], values: [{ value: "runs", label: "Runs" }] },
          { field: "job_class", label: "Job class", bucket: "string", operators: ["contains", "is"], values: [] }
        ]
      },
      active_smart_folder_id: null,
      smart_folders: [],
      jobs: [
        {
          id: 12,
          class_name: "RunJob",
          queue_name: "runs",
          arguments: [42],
          created_at: "2026-05-30T12:00:00Z",
          claimed_at: "2026-05-30T12:01:00Z"
        }
      ]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname !== "/api/v1/app/admin/queue/active") {
        return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
      }

      if (!url.searchParams.has("q")) {
        return Promise.resolve(new Response(JSON.stringify(queuePayload("Run")), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return new Promise<Response>((resolve) => {
        resolveRefetch = resolve
      })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/queue/active"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("RunJob")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("All queue"))
      fireEvent.click(screen.getByRole("button", { name: "Job class contains Run" }))

      const valueInput = screen.getByLabelText("Value")
      fireEvent.change(valueInput, { target: { value: "RunJ" } })
      fireEvent.keyDown(valueInput, { key: "Enter" })

      await waitFor(() => {
        const queueCalls = fetchSpy.mock.calls.filter((call) => String(call[0]).startsWith("/api/v1/app/admin/queue"))
        expect(queueCalls).toHaveLength(2)
      })
      expect(screen.getByRole("dialog", { name: "Job class filter settings" })).toBeInTheDocument()
      expect(screen.getByLabelText("Value")).toHaveValue("RunJ")

      resolveRefetch(new Response(JSON.stringify(queuePayload("RunJ")), { status: 200, headers: { "Content-Type": "application/json" } }))
      await waitFor(() => {
        expect(screen.getByRole("button", { name: "Job class contains RunJ" })).toBeInTheDocument()
      })
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("shows an update button for admin queue saved folder filter drift", async () => {
    const restoreMedia = mockMediaQuery(false)
    let queuePayload = adminQueuePayloadWithSavedFolder({
      and: [{ field: "queue_name", op: "is", value: "chat" }]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = new URL(String(input), "http://example.test")
      const method = init?.method || "GET"
      if (url.pathname === "/api/v1/app/admin/queue/active") {
        return Promise.resolve(jsonResponse(queuePayload))
      }
      if (url.pathname === "/api/v1/app/smart_folders/10" && method === "PATCH") {
        queuePayload = adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())
        return Promise.resolve(jsonResponse({ ...queuePayload, message: "Smart folder updated." }))
      }
      if (url.pathname === "/api/v1/app/smart_folders" && method === "POST") {
        queuePayload = adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())
        return Promise.resolve(
          jsonResponse({
            ...queuePayload,
            message: "Smart folder saved.",
            redirect_to: "/admin/queue/active?smart_folder_id=10"
          })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${method} ${url.pathname}`))
    })

    try {
      const updateView = renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10&q=dGVzdA")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Run repairs"))
      expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Update Run repairs" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/smart_folders/10", expect.objectContaining({ method: "PATCH" }))
      })
      const patchCall = fetchSpy.mock.calls.find(
        ([path, init]) => path === "/api/v1/app/smart_folders/10" && (init as RequestInit | undefined)?.method === "PATCH"
      )
      expect(JSON.parse(String((patchCall?.[1] as RequestInit).body))).toMatchObject({
        filter: JSON.stringify(currentAdminQueueFilter()),
        smart_folder: {
          name: "Run repairs",
          position: 2
        }
      })
      await waitFor(() => {
        expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
      })
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()

      updateView.unmount()
      fetchSpy.mockClear()
      queuePayload = adminQueuePayloadWithSavedFolder({
        and: [{ field: "queue_name", op: "is", value: "chat" }]
      })

      renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10&q=dGVzdA")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Run repairs"))
      fireEvent.change(screen.getByLabelText("Folder name"), { target: { value: "Chat repairs" } })
      fireEvent.click(screen.getByRole("button", { name: "Save as new folder" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/smart_folders", expect.objectContaining({ method: "POST" }))
      })
      const postCall = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/smart_folders" && (init as RequestInit | undefined)?.method === "POST")
      expect(JSON.parse(String((postCall?.[1] as RequestInit).body))).toMatchObject({
        filter: JSON.stringify(currentAdminQueueFilter()),
        subject_type: "admin_queue",
        smart_folder: { name: "Chat repairs" }
      })
      await waitFor(() => {
        expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
      })
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("saves an applied admin queue filter from the smart folder nav", async () => {
    const restoreMedia = mockMediaQuery(false)
    const appliedFilter = { and: [{ field: "queue_name", op: "is", value: "runs" }] }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/smart_folders" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Smart folder saved.",
              redirect_to: "/admin/queue?smart_folder_id=21",
              smart_folder: { id: 21, name: "Runs queue", position: 1, filter: appliedFilter }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      const url = new URL(path, "http://example.test")
      if (url.pathname === "/api/v1/app/admin/queue/active") {
        const activeFolderId = url.searchParams.get("smart_folder_id")
        return Promise.resolve(
          new Response(
            JSON.stringify({
              filter: appliedFilter,
              controls: {
                filter_schema: [
                  {
                    field: "queue_name",
                    label: "Queue",
                    bucket: "enum",
                    operators: ["is", "is_one_of"],
                    values: [
                      { value: "runs", label: "Runs" },
                      { value: "chat", label: "Chat" }
                    ]
                  }
                ]
              },
              active_smart_folder_id: activeFolderId ? Number(activeFolderId) : null,
              smart_folders: [
                {
                  id: 1,
                  name: "Runs",
                  kind: "builtin",
                  subject_type: "admin_queue",
                  visibility: "always",
                  count: 1,
                  active: activeFolderId === "1",
                  filter: { and: [{ field: "queue_name", op: "is", value: "chat" }] },
                  path: "/admin/queue/active?smart_folder_id=1"
                }
              ],
              jobs: [
                {
                  id: 12,
                  class_name: "RunJob",
                  queue_name: "runs",
                  arguments: [42],
                  created_at: "2026-05-30T12:00:00Z",
                  claimed_at: "2026-05-30T12:01:00Z"
                }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/queue/active?smart_folder_id=1&q=changed"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("RunJob")
      const disclosure = mobileFiltersSummary("Runs").closest("details")
      fireEvent.click(mobileFiltersSummary("Runs"))
      expect(disclosure).toHaveAttribute("open")
      const folderNameInput = screen.getByLabelText("Folder name")
      fireEvent.change(folderNameInput, { target: { value: "Runs queue" } })
      fireEvent.click(screen.getByRole("button", { name: "Save as new folder" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/smart_folders",
          expect.objectContaining({
            method: "POST",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({
              filter: JSON.stringify(appliedFilter),
              subject_type: "admin_queue",
              smart_folder: { name: "Runs queue" }
            })
          })
        )
      })
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the save form for admin queue filters with no active folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const payload = adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () =>
      jsonResponse({
        ...payload,
        active_smart_folder_id: null,
        smart_folders: payload.smart_folders.map((folder) => ({ ...folder, active: false }))
      })
    )

    try {
      renderAppAt("/app-shell/admin/queue/active")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("All queue"))
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("keeps an admin queue saved folder active when applying filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname === "/api/v1/app/admin/queue/active") {
        return Promise.resolve(jsonResponse(adminQueuePayloadFromSearch(url.searchParams)))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
    })

    try {
      renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Run repairs"))
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Queue is Runs" }))
      fireEvent.change(screen.getByLabelText("Value"), { target: { value: "chat" } })

      await waitFor(() => {
        expect(
          fetchSpy.mock.calls.some(([path]) => {
            const url = new URL(String(path), "http://example.test")
            return url.pathname === "/api/v1/app/admin/queue/active" && url.searchParams.get("smart_folder_id") === "10" && url.searchParams.has("q")
          })
        ).toBe(true)
      })
      expect(await screen.findByRole("button", { name: "Update Run repairs" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the update button for admin queue saved folder matching filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () => jsonResponse(adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())))

    try {
      renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Run repairs"))
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("renders admin queue workers when SolidQueue reports queue metadata as a string", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            workers: [
              {
                hostname: "worker-a",
                pid: 101,
                queues: "runs",
                threads: 2,
                last_heartbeat_at: "2026-05-30T12:00:00Z",
                stale: false
              }
            ],
            all_processes: [
              {
                kind: "Worker",
                hostname: "worker-a",
                pid: 101,
                last_heartbeat_at: "2026-05-30T12:00:00Z"
              }
            ],
            worker_health: {
              generated_at: "2026-05-30T12:02:00Z",
              range: {
                since: "2026-05-30T06:02:00Z",
                until: "2026-05-30T12:02:00Z"
              },
              current_sample_window_seconds: 900,
              current: [
                {
                  id: 4,
                  hostname: "worker-a",
                  role: "worker",
                  version: "abc123",
                  started_at: "2026-05-30T11:00:00Z",
                  last_heartbeat_at: "2026-05-30T12:00:00Z",
                  seconds_since_heartbeat: 120,
                  stale: false,
                  health: { level: "ok", reasons: [] },
                  sample: {
                    id: 7,
                    hostname: "worker-a",
                    role: "worker",
                    version: "abc123",
                    observed_at: "2026-05-30T12:01:00Z",
                    cpu_used_percent: 25,
                    load_1m: 1.2,
                    load_5m: 1.1,
                    load_15m: 1,
                    memory_used_percent: 45,
                    memory_available_bytes: 4294967296,
                    memory_total_bytes: 8589934592,
                    data_root_used_percent: 55,
                    data_root_available_bytes: 10737418240,
                    data_root_total_bytes: 21474836480,
                    cpu_pressure_some: 3,
                    cpu_pressure_full: null,
                    io_pressure_some: 4,
                    io_pressure_full: null,
                    raw_metrics: {}
                  },
                  trend: {
                    sample_count: 1,
                    first_observed_at: "2026-05-30T12:01:00Z",
                    last_observed_at: "2026-05-30T12:01:00Z",
                    warning_count: 0,
                    critical_count: 0
                  }
                }
              ],
              hosts: [
                {
                  hostname: "worker-a",
                  current: null,
                  windows: {
                    "15m": {
                      sample_count: 1,
                      first_observed_at: "2026-05-30T12:01:00Z",
                      last_observed_at: "2026-05-30T12:01:00Z",
                      warning_count: 0,
                      critical_count: 0,
                      cpu_used_percent: { avg: 25, max: 25 },
                      memory_used_percent: { avg: 45, max: 45 },
                      data_root_used_percent: { avg: 55, max: 55 },
                      load_1m: { avg: 1.2, max: 1.2 }
                    },
                    "1h": {
                      sample_count: 1,
                      first_observed_at: "2026-05-30T12:01:00Z",
                      last_observed_at: "2026-05-30T12:01:00Z",
                      warning_count: 0,
                      critical_count: 0,
                      cpu_used_percent: { avg: 25, max: 25 },
                      memory_used_percent: { avg: 45, max: 45 },
                      data_root_used_percent: { avg: 55, max: 55 },
                      load_1m: { avg: 1.2, max: 1.2 }
                    },
                    "6h": {
                      sample_count: 1,
                      first_observed_at: "2026-05-30T12:01:00Z",
                      last_observed_at: "2026-05-30T12:01:00Z",
                      warning_count: 0,
                      critical_count: 0,
                      cpu_used_percent: { avg: 25, max: 25 },
                      memory_used_percent: { avg: 45, max: 45 },
                      data_root_used_percent: { avg: 55, max: 55 },
                      load_1m: { avg: 1.2, max: 1.2 }
                    }
                  },
                  recent_samples: [
                    {
                      id: 7,
                      hostname: "worker-a",
                      role: "worker",
                      version: "abc123",
                      observed_at: "2026-05-30T12:01:00Z",
                      cpu_used_percent: 25,
                      load_1m: 1.2,
                      load_5m: 1.1,
                      load_15m: 1,
                      memory_used_percent: 45,
                      memory_available_bytes: 4294967296,
                      memory_total_bytes: 8589934592,
                      data_root_used_percent: 55,
                      data_root_available_bytes: 10737418240,
                      data_root_total_bytes: 21474836480,
                      cpu_pressure_some: 3,
                      cpu_pressure_full: null,
                      io_pressure_some: 4,
                      io_pressure_full: null,
                      raw_metrics: {}
                    }
                  ]
                }
              ]
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/queue/workers"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin queue" })).toBeInTheDocument()
    expect(await screen.findByText("Worker health")).toBeInTheDocument()
    expect(screen.getAllByText("worker-a")).toHaveLength(3)
    expect(screen.getByText("runs")).toBeInTheDocument()
    expect(screen.getAllByText("healthy").length).toBeGreaterThan(0)
    expect(screen.getAllByText("CPU pressure").length).toBeGreaterThan(0)
    expect(screen.getAllByText("IO pressure").length).toBeGreaterThan(0)
    expect(screen.getByText("Memory available")).toBeInTheDocument()
    expect(screen.getByText("Data root available")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-cpu_used_percent")).toBeInTheDocument()
    expect(screen.getByText("Exact values")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/queue/workers",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })
})
