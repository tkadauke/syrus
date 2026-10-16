import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AdminProcessesIndex } from "./AdminProcesses"

function processRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 9,
    kind: "agent",
    command: "claude --print",
    workdir: "/workspaces/9",
    hostname: "worker-a",
    pid: 4242,
    pgid: 4242,
    started_at: "2026-05-30T11:00:00Z",
    last_chunk_at: "2026-05-30T11:05:00Z",
    finished_at: null,
    duration_s: 300,
    exit_status: null,
    outcome: null,
    wall_timeout_s: 5400,
    silent_timeout_s: 1200,
    run_id: 12,
    workflow_id: 3,
    chat_session_id: null,
    workflow_slug: "WF-3",
    workflow_path: "/admin/workflows/3",
    stale: false,
    kill_requested_at: null,
    kill_requested_by_user_id: null,
    user: null,
    owner: null,
    ...overrides
  }
}

function processesPayload(overrides: Record<string, unknown> = {}) {
  return {
    active_smart_folder_id: null,
    smart_folders: [],
    filter: {},
    controls: { filter_schema: [] },
    processes: [processRow()],
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
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(processesPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/processes"]}>
        <AdminProcessesIndex />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminProcesses configurable columns", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    vi.useRealTimers()
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("renders the raw-table-converted processes grid with its default columns", async () => {
    renderRoute()

    expect(await screen.findByRole("columnheader", { name: "Kind" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Command" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Chat" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Workdir" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Host / PID" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Exit" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Actions" })).toBeInTheDocument()
    expect(screen.getByText("claude --print")).toBeInTheDocument()
    expect(screen.getByText("Showing 1-1 of 1 processes")).toBeInTheDocument()
  })

  it("hides an optional column and persists it under a processes-specific key", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Command" })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("checkbox", { name: "Command" }))

    await waitFor(() => {
      expect(screen.queryByRole("columnheader", { name: "Command" })).not.toBeInTheDocument()
    })
    // Kind stays -- it's the required identity column and never appears in the picker.
    expect(screen.getByRole("columnheader", { name: "Kind" })).toBeInTheDocument()

    // Actions is required (pinned to the end) and never appears in the persisted order.
    expect(JSON.parse(window.localStorage.getItem("syrus.admin.processes.visible_columns") ?? "[]")).toEqual([
      "chat_session_id",
      "workdir",
      "user",
      "owner",
      "host_pid",
      "started",
      "last_chunk",
      "duration",
      "timeouts",
      "exit_status",
      "outcome",
      "kill_requested"
    ])
  })

  it("confirms kills, shows a conflict, and refreshes the stale process row", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((_input, init) =>
      Promise.resolve(init?.method === "POST"
        ? jsonResponse({ error: { code: "already_finished", message: "Process already finished" } }, 409)
        : jsonResponse(processesPayload()))
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/admin/processes"]}>
          <AdminProcessesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Kill" }))
    expect(screen.getByText("Send SIGKILL to process #9?")).toBeInTheDocument()
    expect(fetchSpy.mock.calls.filter(([, init]) => init?.method === "POST")).toHaveLength(0)
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Kill" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("Process already finished")
    await waitFor(() => expect(fetchSpy.mock.calls.filter(([, init]) => init?.method !== "POST").length).toBeGreaterThan(1))
  })

  it("polls while a process is running", async () => {
    vi.useFakeTimers()
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(processesPayload()))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(<QueryClientProvider client={client}><MemoryRouter><AdminProcessesIndex /></MemoryRouter></QueryClientProvider>)
    await act(async () => { await Promise.resolve(); await Promise.resolve() })
    const initialCalls = fetchSpy.mock.calls.length

    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })

    expect(fetchSpy.mock.calls.length).toBeGreaterThan(initialCalls)
  })
})
