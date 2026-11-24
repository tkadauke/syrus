import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { Link, MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { _clearRecentApiRequestsForTest } from "../api/client"
import { jsonResponse } from "../testSupport"
import { AdminTranscript } from "./AdminTranscript"

function payload(runId: number, page: number) {
  return {
    run_id: runId,
    job_id: 7,
    job_slug: `JOB-7`,
    step_kind: "implement",
    workflow_trigger_kind: "initial",
    finished: true,
    session_id: `session-run-${runId}-page-${page}`,
    summary: { model: "m", total_turns: 1, total_tool_calls: 0, total_cost_usd: 0, exit_reason: null, tool_call_counts: {}, mcp_tool_called: false },
    pagination: { page, per: 100, total_events: 1, total_pages: 1 },
    events: []
  }
}

function setup() {
  let release: (() => void) | undefined
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  vi.spyOn(window, "fetch").mockImplementation(async (input) => {
    const url = String(input)
    const match = url.match(/runs\/(\d+)\/transcript\?page=(\d+)/)
    if (!match) return jsonResponse({})
    const [, runId, page] = match
    // Only the second Run and the second page are held in flight.
    if (runId === "2" || page === "2") await gate
    return jsonResponse(payload(Number(runId), Number(page)))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/admin/runs/1/transcript"]}>
        <Routes>
          <Route path="/admin/runs/:runId/transcript" element={<AdminTranscript />} />
        </Routes>
        <Link to="/admin/runs/2/transcript">other run</Link>
        <Link to="/admin/runs/1/transcript?page=2">next page</Link>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return () => release?.()
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  _clearRecentApiRequestsForTest()
})

describe("AdminTranscript query transitions", () => {
  it("never shows the previous Run's transcript while another Run loads", async () => {
    const release = setup()
    await screen.findByText("session-run-1-page-1")

    fireEvent.click(screen.getByText("other run"))

    expect(screen.queryByText("session-run-1-page-1")).not.toBeInTheDocument()
    expect(screen.getByText("Loading transcript...", { exact: false })).toBeInTheDocument()
    release()
    await screen.findByText("session-run-2-page-1")
  })

  it("keeps the current page on screen while another page of the same Run loads", async () => {
    const release = setup()
    await screen.findByText("session-run-1-page-1")

    fireEvent.click(screen.getByText("next page"))

    expect(screen.getByText("session-run-1-page-1")).toBeInTheDocument()
    release()
    await screen.findByText("session-run-1-page-2")
  })
})
