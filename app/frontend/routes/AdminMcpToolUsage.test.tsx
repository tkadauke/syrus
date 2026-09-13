import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminMcpToolUsage } from "./AdminMcpToolUsage"

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/admin/mcp_tool_usage"]}>
        <Routes>
          <Route element={<AdminMcpToolUsage />} path="/admin/mcp_tool_usage" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function payload() {
  return {
    window: { start: "2026-08-14T00:00:00Z", end: "2026-08-21T00:00:00Z" },
    surface: "all",
    filters: { tool_name: null, server_name: null },
    totals: { calls: 10, errors: 2 },
    top_tools: [
      { tool_name: "read_live_state", server_name: "syrus-mcp-sidecar", calls: 6, errors: 1, error_rate: 0.1667 }
    ],
    error_rates: [
      { tool_name: "repo_info", server_name: "syrus-chat-sidecar", calls: 4, errors: 2, error_rate: 0.5 }
    ],
    surface_breakdown: [
      { surface: "workflow", calls: 6, errors: 1, error_rate: 0.1667 },
      { surface: "chat", calls: 4, errors: 2, error_rate: 0.5 }
    ],
    provider_breakdown: [
      { provider: "claude", calls: 10, errors: 2, error_rate: 0.2 }
    ],
    server_breakdown: [
      { server_name: "syrus-mcp-sidecar", calls: 6, errors: 1, error_rate: 0.1667 },
      { server_name: "syrus-chat-sidecar", calls: 4, errors: 2, error_rate: 0.5 }
    ],
    sidecar_mode_breakdown: [
      { sidecar_mode: "stdio", calls: 10, errors: 2, error_rate: 0.2 }
    ],
    unused_advertised_tools: ["submit_summary"],
    custom_card_gaps: {
      card_gap_priorities: [
        {
          tool_name: "repo_info",
          calls: 4,
          errors: 2,
          error_rate: 0.5,
          result_bytes: 2048,
          last_used_at: "2026-08-20T12:00:00Z",
          server_names: ["syrus-chat-sidecar"],
          priority_score: 14.13,
          priority_label: "investigate_errors",
          owner_type: "core",
          owner_name: "core",
          recommendation_target: "core",
          card_status: "missing"
        }
      ],
      high_volume_without_custom_card: [],
      high_error_with_weak_or_no_custom_card: [],
      unused_advertised_tools: []
    },
    recent_calls: [
      {
        id: 1,
        occurred_at: "2026-08-20T12:00:00Z",
        surface: "workflow",
        provider: "claude",
        tool_name: "read_live_state",
        server_name: "syrus-mcp-sidecar",
        status: "completed",
        error: false,
        error_class: null,
        error_message_summary: null,
        sidecar_mode: "stdio",
        job_id: 42,
        job_path: "/jobs/42",
        workflow_id: 7,
        workflow_path: "/jobs/42?tab=workflows#workflow-7",
        run_id: 99,
        run_path: "/admin/runs/99/transcript",
        chat_session_id: null,
        chat_path: null
      }
    ]
  }
}

describe("AdminMcpToolUsage", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders usage totals, breakdowns, unused tools, and linked recent calls", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute()

    expect(await screen.findByRole("heading", { name: "MCP tool usage" })).toBeInTheDocument()
    expect(String(fetchSpy.mock.calls[0][0])).toBe("/api/v1/app/admin/mcp_tool_usage")

    expect((await screen.findAllByText("read_live_state")).length).toBeGreaterThan(0)
    expect(screen.getAllByText("repo_info").length).toBeGreaterThan(0)
    expect(screen.getByText("Custom card gap priorities")).toBeInTheDocument()
    expect(screen.getByText("Investigate errors")).toBeInTheDocument()
    expect(screen.getByText("2 KB")).toBeInTheDocument()
    const priorityTable = screen.getByRole("columnheader", { name: "Last used" }).closest("table")
    expect(priorityTable).toHaveClass("min-w-[62rem]")
    expect(priorityTable?.parentElement).toHaveClass("overflow-x-auto")
    expect(screen.getByText("submit_summary")).toBeInTheDocument()

    const jobLink = screen.getByRole("link", { name: "JOB-42" })
    expect(jobLink).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "Run #99" })).toHaveAttribute("href", "/admin/runs/99/transcript")
  })

  it("re-fetches with a since parameter when the window preset changes", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute()
    await screen.findByRole("heading", { name: "MCP tool usage" })

    fireEvent.change(screen.getByLabelText("Window"), { target: { value: "30d" } })

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("window_preset=30d") && String(call[0]).includes("since="))).toBe(true)
    })
  })

  it("re-fetches with a surface filter when the surface changes", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute()
    await screen.findByRole("heading", { name: "MCP tool usage" })

    fireEvent.change(screen.getByLabelText("Surface"), { target: { value: "chat" } })

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("surface=chat"))).toBe(true)
    })
  })

  it("re-fetches with exact tool and server filters when entered", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute()
    await screen.findByRole("heading", { name: "MCP tool usage" })

    fireEvent.change(screen.getByLabelText("Tool"), { target: { value: "browser_navigate" } })
    fireEvent.keyDown(screen.getByLabelText("Tool"), { key: "Enter" })
    fireEvent.change(screen.getByLabelText("Server"), { target: { value: "syrus-mcp-sidecar" } })
    fireEvent.blur(screen.getByLabelText("Server"))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("tool_name=browser_navigate"))).toBe(true)
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("server_name=syrus-mcp-sidecar"))).toBe(true)
    })
  })
})
