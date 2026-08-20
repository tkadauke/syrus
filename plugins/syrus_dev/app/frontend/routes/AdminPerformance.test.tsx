import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import { AdminPerformance } from "./AdminPerformance"

describe("AdminPerformance", () => {
  it("truncates long metadata in the slow phases table and exposes full value via title", async () => {
    const longMetadata = { extension_point: "agent_provider", provider: "AgentProviders::Claude", op: "invoke_one_shot", extra: "x".repeat(80) }
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...performancePayload(),
      summaries: {
        ...performancePayload().summaries,
        slow_phases: [
          {
            phase: "plugin.agent_provider.invoke_one_shot",
            count: 1,
            total_duration_ms: 4240,
            average_duration_ms: 4240,
            max_duration_ms: 4240,
            last_seen_at: "2026-08-01T14:32:46Z",
            recent_metadata: longMetadata
          }
        ]
      }
    }))

    renderRoute(<AdminPerformance />)
    await waitFor(() => expect(screen.queryByText("Loading performance logs...")).not.toBeInTheDocument())

    const fullJson = JSON.stringify(longMetadata)
    const metadataDiv = await screen.findByTitle(fullJson)
    expect(metadataDiv).toHaveClass("truncate")
  })

  it("renders performance summaries and recent events", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(performancePayload()))

    renderRoute(<AdminPerformance />)

    expect(await screen.findByRole("heading", { name: "Performance" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/performance?limit=500&revision_scope=current", expect.objectContaining({
      credentials: "same-origin"
    }))

    await waitFor(() => expect(screen.queryByText("Loading performance logs...")).not.toBeInTheDocument())
    const summary = await screen.findByRole("region", { name: "Performance summary" })
    expect(within(summary).getByText("yes")).toBeInTheDocument()
    expect(within(summary).getByText("3")).toBeInTheDocument()
    expect(within(summary).getByText("abcdef123456")).toBeInTheDocument()
    expect(within(summary).getByText("rails.cache")).toBeInTheDocument()
    expect(within(summary).getByText("1.00s")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Overview" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Browser" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Requests" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Jobs" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "SQL" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Phases" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Events" })).toBeInTheDocument()

    expect(screen.getByText("Revision comparison vs oldsha123456")).toBeInTheDocument()
    expect(screen.getByText("/api/v1/app/chats/126")).toBeInTheDocument()
    expect(screen.getByText("regressed")).toBeInTheDocument()
    expect(screen.getByText("+580ms (+96.7%)")).toBeInTheDocument()
    expect(screen.getByText("Browser traces")).toBeInTheDocument()
    expect(screen.getByText("Browser max")).toBeInTheDocument()
    expect(screen.getByText("Backend API avg / max")).toBeInTheDocument()
    expect(screen.getByText("Frontend overhead avg / max")).toBeInTheDocument()
    expect(screen.getByText("GET /api/v1/app/chats/126")).toBeInTheDocument()
    expect(screen.getByText("PollRepositoryJob")).toBeInTheDocument()
    expect(screen.getByText("polling")).toBeInTheDocument()
    expect(screen.getByText("job-123")).toBeInTheDocument()
    expect(screen.getAllByText("chat_payload.recent_chats").length).toBeGreaterThan(0)
    expect(screen.getAllByText("dashboard.route").length).toBeGreaterThan(0)
    expect(screen.getByText("frontend-request-1")).toBeInTheDocument()
    expect(screen.getByText("300ms / 300ms")).toBeInTheDocument()
    expect(screen.getByText("SELECT `jobs`.* FROM `jobs` WHERE `jobs`.`state` = ?")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Events" }))
    expect(screen.getByText("slow_request")).toBeInTheDocument()
    expect(screen.getByText("246 SQL · 629ms")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "All SHAs" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenLastCalledWith("/api/v1/app/admin/performance?limit=500&revision_scope=all", expect.objectContaining({
      credentials: "same-origin"
    })))
  })

  it("puts browser traces above backend-only slow request details", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(performancePayload()))

    renderRoute(<AdminPerformance />)

    const browserTraces = await screen.findByText("Browser traces")
    const slowRequestCells = await screen.findAllByText("GET /api/v1/app/chats/126")
    const slowRequestTable = slowRequestCells[0].closest("section")
    expect(slowRequestTable).not.toBeNull()
    expect(browserTraces.compareDocumentPosition(slowRequestTable!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("opens SQL explain results in a visual modal and supports safe analyze", async () => {
    const fetchSpy = vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse(performancePayload()))
      .mockResolvedValueOnce(jsonResponse(explainPayload({ analyzeSafe: true })))
      .mockResolvedValueOnce(jsonResponse(explainPayload({ mode: "analyze", analyzeSafe: true, rows: [{ "EXPLAIN": "-> Table scan on jobs (actual time=0.1..1.2 rows=25 loops=1)" }] })))

    renderRoute(<AdminPerformance />)
    await screen.findByRole("heading", { name: "Performance" })

    fireEvent.click(await screen.findByRole("button", { name: "Explain" }))
    expect(await screen.findByRole("dialog", { name: "SQL explain result" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Run EXPLAIN ANALYZE" })).toBeDisabled()

    fireEvent.click(screen.getByRole("button", { name: "Run EXPLAIN" }))
    await screen.findByText("Table jobs")
    expect(screen.getByText("access: ALL")).toBeInTheDocument()
    expect(screen.getByText("high")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Run EXPLAIN ANALYZE" })).not.toBeDisabled()

    fireEvent.click(screen.getByRole("button", { name: "Run EXPLAIN ANALYZE" }))
    await screen.findByText(/EXPLAIN ANALYZE executed this read-only query/)

    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/performance/explain", expect.objectContaining({
      method: "POST",
      body: expect.stringContaining("\"analyze\":true")
    }))

    fireEvent.click(screen.getByRole("button", { name: "Run EXPLAIN" }))
    expect(await screen.findByText("Table jobs")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledTimes(3)
  })

  it("shows request-level SQL fingerprints from a slow request summary", async () => {
    const fetchSpy = vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse(performancePayload()))
      .mockResolvedValueOnce(jsonResponse(explainPayload({ analyzeSafe: true })))

    renderRoute(<AdminPerformance />)
    await screen.findByRole("heading", { name: "Performance" })

    fireEvent.click(await screen.findByRole("button", { name: "Details" }))
    const dialog = await screen.findByRole("dialog", { name: "Slow request SQL details" })
    expect(within(dialog).getByText("request-123")).toBeInTheDocument()
    expect(within(dialog).getAllByText((_content, element) => element?.textContent?.includes("246 SQL · 629ms") ?? false).length).toBeGreaterThan(0)
    expect(within(dialog).getByText("Slow phases")).toBeInTheDocument()
    expect(within(dialog).getByText("chat_payload.messages_json")).toBeInTheDocument()
    expect(within(dialog).getByText("Message Load")).toBeInTheDocument()
    expect(within(dialog).getByText("Job Exists")).toBeInTheDocument()
    expect(within(dialog).getByText("SELECT 1 AS one FROM `jobs` WHERE `jobs`.`id` = ? LIMIT ?")).toBeInTheDocument()
    expect(within(dialog).getByText("620ms")).toBeInTheDocument()

    fireEvent.click(within(dialog).getAllByRole("button", { name: "Explain" }).at(-1)!)
    expect(await screen.findByRole("dialog", { name: "SQL explain result" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Run EXPLAIN" }))
    await screen.findByText("Table jobs")

    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/performance/explain", expect.objectContaining({
      method: "POST",
      body: expect.stringContaining("SELECT 1 AS one")
    }))
  })
})

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/admin/performance"]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function performancePayload() {
  return {
    enabled: true,
    current_revision: "abcdef1234567890",
    revision_scope: "current",
    thresholds: {
      slow_request_ms: 1000,
      slow_job_ms: 5000,
      slow_sql_ms: 500,
      slow_phase_ms: 250,
      request_sql_count_threshold: 50,
      request_sql_duration_ms: 500,
      top_sql_fingerprint_limit: 10,
      max_sql_fingerprints_per_request: 5
    },
    storage: {
      kind: "rails.cache",
      cache_key: "syrus:performance:events",
      max_events: 200,
      expires_in_seconds: 86400
    },
    baseline: {
      revision: "oldsha1234567890",
      comparisons: {
        slow_requests: [
          {
            key: "GET /api/v1/app/chats/126 Api::V1::App::ChatsController show",
            label: "/api/v1/app/chats/126",
            current_average_duration_ms: 1180,
            baseline_average_duration_ms: 600,
            delta_average_duration_ms: 580,
            delta_percent: 96.7,
            current_count: 2,
            baseline_count: 3,
            status: "regressed"
          }
        ],
        slow_jobs: [],
        slow_phases: [],
        browser_traces: [],
        sql_fingerprints: []
      }
    },
    summaries: {
      slow_requests: [
        {
          method: "GET",
          path: "/api/v1/app/chats/126",
          controller: "Api::V1::App::ChatsController",
          action: "show",
          count: 2,
          total_duration_ms: 2360,
          average_duration_ms: 1180,
          max_duration_ms: 1210,
          average_sql_count: 246,
          average_sql_duration_ms: 629,
          last_seen_at: "2026-08-01T14:32:45Z"
        }
      ],
      slow_jobs: [
        {
          job_class: "PollRepositoryJob",
          queue_name: "polling",
          count: 1,
          total_duration_ms: 12_000,
          average_duration_ms: 12_000,
          max_duration_ms: 12_000,
          average_sql_count: 60,
          average_sql_duration_ms: 8_000,
          slow_sql_count: 2,
          last_seen_at: "2026-08-01T14:32:44Z",
          recent_active_job_id: "job-123",
          recent_trigger_reasons: [ "duration", "sql_duration" ]
        }
      ],
      slow_phases: [
        {
          phase: "chat_payload.recent_chats",
          count: 1,
          total_duration_ms: 620,
          average_duration_ms: 620,
          max_duration_ms: 620,
          last_seen_at: "2026-08-01T14:32:46Z",
          recent_metadata: { chat_id: 126 }
        }
      ],
      browser_traces: [
        {
          name: "dashboard.route",
          path: "/dashboard/jobs?smart_folder_id=7",
          count: 1,
          total_duration_ms: 1500,
          average_duration_ms: 1500,
          max_duration_ms: 1500,
          average_api_duration_ms: 1200,
          max_api_duration_ms: 1200,
          recent_api_request_ids: [ "frontend-request-1" ],
          last_seen_at: "2026-08-01T14:32:47Z",
          recent_metadata: { subject: "job", rows_count: "0" }
        }
      ],
      sql_fingerprints: [
        {
          fingerprint: "select_jobs_by_state",
          sample_sql: "SELECT `jobs`.* FROM `jobs` WHERE `jobs`.`state` = ?",
          name: "Job Load",
          count: 50,
          total_duration_ms: 400,
          average_duration_ms: 8,
          max_duration_ms: 30
        }
      ]
    },
    events: [
      {
        event: "syrus.performance.slow_job",
        occurred_at: "2026-08-01T14:32:44Z",
        app_revision: "abcdef1234567890",
        duration_ms: 12_000,
        job_class: "PollRepositoryJob",
        active_job_id: "job-123",
        queue_name: "polling",
        sql_count: 60,
        sql_duration_ms: 8_000,
        trigger_reasons: [ "duration", "sql_duration" ]
      },
      {
        event: "syrus.performance.slow_request",
        occurred_at: "2026-08-01T14:32:45Z",
        app_revision: "abcdef1234567890",
        request_id: "request-123",
        duration_ms: 1180,
        method: "GET",
        path: "/api/v1/app/chats/126",
        controller: "Api::V1::App::ChatsController",
        action: "show",
        sql_count: 246,
        sql_duration_ms: 629,
        top_sql_fingerprints: [
          {
            fingerprint: "SELECT ? AS one FROM `jobs` WHERE `jobs`.`id` = ? LIMIT ?",
            sample_sql: "SELECT 1 AS one FROM `jobs` WHERE `jobs`.`id` = ? LIMIT ?",
            name: "Job Exists",
            count: 20,
            total_duration_ms: 620,
            max_duration_ms: 80
          }
        ]
      },
      {
        event: "syrus.performance.slow_phase",
        occurred_at: "2026-08-01T14:32:47Z",
        app_revision: "abcdef1234567890",
        request_id: "request-123",
        duration_ms: 520,
        phase: "chat_payload.messages_json",
        metadata: { chat_id: 126, message_count: 40 },
        sql_count: 8,
        sql_duration_ms: 300,
        top_sql_fingerprints: [
          {
            fingerprint: "SELECT `chat_messages`.* FROM `chat_messages` WHERE `chat_messages`.`chat_session_id` = ?",
            sample_sql: "SELECT `chat_messages`.* FROM `chat_messages` WHERE `chat_messages`.`chat_session_id` = ?",
            name: "Message Load",
            count: 8,
            total_duration_ms: 300,
            max_duration_ms: 90
          }
        ]
      }
    ]
  }
}

function explainPayload({ analyzeSafe, mode = "explain", rows }: { analyzeSafe: boolean; mode?: "explain" | "analyze"; rows?: Array<Record<string, unknown>> }) {
  return {
    adapter: "mysql2",
    mode,
    normalized_sql: "SELECT `jobs`.* FROM `jobs` WHERE `jobs`.`state` = NULL",
    placeholder_substituted: true,
    timeout_ms: mode === "analyze" ? 1000 : null,
    analyze_safe: analyzeSafe,
    analyze_safety_reason: analyzeSafe ? "Read-only single-statement query; EXPLAIN ANALYZE will run with a short statement timeout." : "Only SELECT/CTE statements can be analyzed.",
    rows: rows ?? [
      {
        EXPLAIN: JSON.stringify({
          query_block: {
            table: {
              table_name: "jobs",
              access_type: "ALL",
              rows_examined_per_scan: 1000,
              filtered: 10,
              cost_info: { query_cost: "42.00" }
            }
          }
        })
      }
    ],
    json_plan: rows ? null : {
      query_block: {
        table: {
          table_name: "jobs",
          access_type: "ALL",
          rows_examined_per_scan: 1000,
          filtered: 10,
          cost_info: { query_cost: "42.00" }
        }
      }
    },
    warnings: []
  }
}
