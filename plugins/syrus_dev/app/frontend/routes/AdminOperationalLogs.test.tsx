import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import type { OperationalLogsPayload } from "../api/adminOperationalLogs"
import { AdminOperationalLogs } from "./AdminOperationalLogs"

describe("AdminOperationalLogs", () => {
  it("renders filters, log rows, and paginates", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(logsPayload()))

    renderRoute(<AdminOperationalLogs />)

    expect(await screen.findByRole("heading", { name: "Operational Logs" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/operational_logs?since=1h&revision_scope=current&per_page=50", expect.objectContaining({
      credentials: "same-origin"
    }))

    const table = await screen.findByRole("table")
    expect(within(table).getByText("error")).toBeInTheDocument()
    expect(within(table).getByText("worker · worker-a · pid 123")).toBeInTheDocument()
    expect(within(table).queryByText("abcdef1234567890".slice(0, 12))).not.toBeInTheDocument()
    expect(within(table).getByText("JOB-2631 · WF-16100 · RUN-74392 · REQ req-1")).toBeInTheDocument()
    const message = within(table).getByText("failed token=[REDACTED] migration")
    expect(message).toHaveClass("break-words")
    expect(within(table).getByText("path=/jobs api_key=api_key=[REDACTED]")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Next" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenLastCalledWith("/api/v1/app/admin/operational_logs?since=1h&revision_scope=current&per_page=50&page=2", expect.objectContaining({
      credentials: "same-origin"
    })))
  })

  it("submits bounded search filters", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(logsPayload({ logs: [] })))

    renderRoute(<AdminOperationalLogs />)

    await screen.findByRole("heading", { name: "Operational Logs" })
    fireEvent.change(screen.getByLabelText("Search"), { target: { value: "migration" } })
    fireEvent.change(screen.getByLabelText("Since"), { target: { value: "2h" } })
    fireEvent.change(screen.getByLabelText("Until"), { target: { value: "2026-08-05T10:00:00Z" } })
    fireEvent.change(screen.getByLabelText("Level"), { target: { value: "error" } })
    fireEvent.change(screen.getByLabelText("Role"), { target: { value: "worker" } })
    fireEvent.change(screen.getByLabelText("Hostname"), { target: { value: "worker-a" } })
    fireEvent.change(screen.getByLabelText("Revision"), { target: { value: "all" } })
    fireEvent.change(screen.getByLabelText("Per page"), { target: { value: "100" } })
    fireEvent.click(screen.getByRole("button", { name: "Search" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenLastCalledWith("/api/v1/app/admin/operational_logs?query=migration&since=2h&until=2026-08-05T10%3A00%3A00Z&level=error&role=worker&hostname=worker-a&revision_scope=all&per_page=100", expect.objectContaining({
      credentials: "same-origin"
    })))
  })

  it("renders disabled and empty states", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(logsPayload({
      enabled: false,
      logs: [],
      error: { code: "operational_log_indexing_disabled", message: "Operational log indexing is disabled for this instance." }
    })))

    renderRoute(<AdminOperationalLogs />)

    expect(await screen.findByText("Operational log indexing is disabled for this instance.")).toBeInTheDocument()
  })

  it("renders empty state when enabled with no rows", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(logsPayload({ logs: [] })))

    renderRoute(<AdminOperationalLogs />)

    expect(await screen.findByText("No operational logs match these filters.")).toBeInTheDocument()
  })

  it("renders loading and error states", async () => {
    vi.spyOn(window, "fetch").mockRejectedValue(new Error("network down"))

    renderRoute(<AdminOperationalLogs />)

    expect(screen.getByText("Loading operational logs...")).toBeInTheDocument()
    expect(await screen.findByText("Unable to load operational logs.")).toBeInTheDocument()
  })

  it("dedupes job_class from context and only shows per-row revision when scope is all", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(logsPayload({
      revision_scope: "all",
      logs: [
        {
          id: 11,
          occurred_at: "2026-08-05T10:05:00Z",
          level: "info",
          role: "worker",
          hostname: "worker-b",
          app_revision: "0123456789ab",
          pid: 456,
          source: "run_job",
          job_id: null,
          workflow_id: null,
          run_id: null,
          request_id: null,
          message: "RunJob",
          context: { job_class: "RunJob", queue: "runs" }
        }
      ]
    })))

    renderRoute(<AdminOperationalLogs />)

    const table = await screen.findByRole("table")
    expect(within(table).getByText("0123456789ab")).toBeInTheDocument()
    expect(within(table).getByText("queue=runs")).toBeInTheDocument()
    expect(within(table).queryByText(/job_class=/)).not.toBeInTheDocument()
  })
})

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/admin/operational_logs"]}>
        <Routes>
          <Route path="/app-shell/admin/operational_logs" element={children} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function logsPayload(overrides: Partial<OperationalLogsPayload> = {}) {
  return { ...logsPayloadBase(), ...overrides }
}

function logsPayloadBase(): OperationalLogsPayload {
  return {
    enabled: true,
    retention_seconds: 21600,
    current_revision: "abcdef1234567890",
    revision_scope: "current",
    filters: {
      query: null,
      since: "2026-08-05T09:00:00Z",
      until: null,
      level: null,
      role: null,
      hostname: null
    },
    pagination: {
      page: 1,
      per_page: 50,
      has_next_page: true,
      has_previous_page: false,
      next_page: 2,
      previous_page: null
    },
    logs: [
      {
        id: 10,
        occurred_at: "2026-08-05T10:00:00Z",
        level: "error",
        role: "worker",
        hostname: "worker-a",
        app_revision: "abcdef1234567890",
        pid: 123,
        source: "active_job",
        job_id: 2631,
        workflow_id: 16100,
        run_id: 74392,
        request_id: "req-1",
        message: "failed token=[REDACTED] migration",
        context: { path: "/jobs", api_key: "api_key=[REDACTED]" }
      }
    ]
  }
}
