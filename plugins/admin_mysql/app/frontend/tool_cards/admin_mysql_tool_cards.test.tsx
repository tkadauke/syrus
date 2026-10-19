import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import killQueryToolCard from "./admin_mysql_kill_query"
import statusToolCard from "./admin_mysql_status"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_mysql_status",
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

const healthyPayload = {
  available: true,
  generated_at: "2026-09-10T12:00:00Z",
  adapter: "Mysql2",
  database: "syrus_production",
  connection_summary: {
    threads_connected: 7,
    threads_running: 1,
    max_used_connections: 42,
    max_connections: 151,
    sleeping_connections: 1,
    aborted_connects: 0,
    max_connection_errors: 0,
    wait_timeout: 600,
    interactive_timeout: 900
  },
  variables: {
    slow_query_log: "ON",
    log_output: "TABLE",
    long_query_time: 1,
    version: "8.4.0"
  },
  status: {
    Slow_queries: 0,
    Innodb_row_lock_current_waits: 0
  },
  process_list: [
    {
      id: 88,
      user: "sensitive_user",
      host: "db.internal",
      database: "syrus_production",
      command: "Query",
      time_seconds: 2,
      state: "executing",
      info: "SELECT COUNT(*) FROM jobs"
    },
    {
      id: 89,
      user: "sensitive_user",
      host: "db.internal",
      database: "syrus_production",
      command: "Sleep",
      time_seconds: 30,
      state: null,
      info: null
    }
  ],
  statement_digests: {
    available: true,
    rows: [
      {
        digest_text: "SELECT * FROM workflows WHERE state = ?",
        schema_name: "syrus_production",
        count: 12,
        total_seconds: 4.2,
        avg_seconds: 0.35,
        max_seconds: 1.2,
        rows_examined: 1200,
        rows_sent: 12,
        first_seen: "2026-09-10T10:00:00Z",
        last_seen: "2026-09-10T12:00:00Z"
      }
    ]
  },
  slow_log: {
    available: false,
    rows: [],
    error: {
      message: "slow-log rows are loaded on demand",
      hint: "Reading mysql.slow_log can be expensive on busy instances, so the live MySQL snapshot only loads row data when explicitly requested."
    }
  }
}

describe("Admin MySQL tool cards", () => {
  it("registers plugin-local card modules for Admin MySQL chat tools", () => {
    expect(pluginToolCardRendererFor("admin_mysql_status")).not.toBeNull()
    expect(pluginToolCardRendererFor("admin_mysql_kill_query")).not.toBeNull()
  })

  it("renders every connection, variable, process, and digest field", () => {
    const cardContext = context({ input: { limit: 25 }, parsedResult: healthyPayload })

    expect(statusToolCard.collapsedSummary?.(cardContext)).toBe("MySQL healthy · 1 active")
    render(<>{statusToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("healthy")).toBeInTheDocument()
    expect(screen.getByText("Active queries")).toBeInTheDocument()
    expect(screen.getByText("SELECT COUNT(*) FROM jobs")).toBeInTheDocument()
    expect(screen.getByText("Statement digests")).toBeInTheDocument()
    expect(screen.getByText("slow-log rows are loaded on demand")).toBeInTheDocument()
    expect(screen.getByText("Adapter")).toBeInTheDocument()
    expect(screen.getByText("Mysql2")).toBeInTheDocument()
    expect(screen.getByText("Aborted connects")).toBeInTheDocument()
    expect(screen.getByText("Max connection errors")).toBeInTheDocument()
    expect(screen.getByText("Max used connections")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
    expect(screen.getByText("Wait timeout")).toBeInTheDocument()
    expect(screen.getByText("10m 0s")).toBeInTheDocument()
    expect(screen.getByText("Interactive timeout")).toBeInTheDocument()
    expect(screen.getByText("15m 0s")).toBeInTheDocument()
    expect(screen.getByText("limit: 25")).toBeInTheDocument()
    expect(screen.getAllByText("sensitive_user")).toHaveLength(2)
    expect(screen.getAllByText("db.internal")).toHaveLength(2)
    expect(screen.getAllByText("syrus_production").length).toBeGreaterThan(1)
    expect(screen.getByText("0.35s avg")).toBeInTheDocument()
    expect(screen.getByText("12 rows sent")).toBeInTheDocument()
    expect(screen.getByText("first: 2026-09-10T10:00:00Z")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy 88 to clipboard" })).toBeInTheDocument()
  })

  it("renders degraded status when process rows are locked or waiting", () => {
    const parsedResult = {
      ...healthyPayload,
      process_list: [
        {
          id: 90,
          command: "Query",
          time_seconds: 61,
          state: "Waiting for table metadata lock",
          info: "ALTER TABLE jobs ADD INDEX index_jobs_on_state (state)"
        }
      ],
      slow_log: { available: true, rows: [] }
    }
    const cardContext = context({ parsedResult })

    expect(statusToolCard.collapsedSummary?.(cardContext)).toBe("MySQL degraded · 1 active · 1 waiting")
    render(<>{statusToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("degraded")).toBeInTheDocument()
    expect(screen.getByText("waiting")).toBeInTheDocument()
    expect(screen.getByText("Waiting for table metadata lock")).toBeInTheDocument()
  })

  it("renders unavailable partial sections with actionable hints", () => {
    const parsedResult = {
      ...healthyPayload,
      statement_digests: {
        available: false,
        rows: [],
        error: {
          class: "Mysql2::Error",
          message: "The Syrus MySQL user cannot read Performance Schema statement digests.",
          hint: "Grant SELECT on performance_schema.events_statements_summary_by_digest.",
          setup_sql: ["GRANT SELECT ON performance_schema.events_statements_summary_by_digest TO CURRENT_USER;"]
        }
      },
      slow_log: {
        available: false,
        rows: [],
        error: {
          message: "slow-log rows are loaded on demand",
          hint: "Reading mysql.slow_log can be expensive."
        }
      }
    }
    const cardContext = context({ parsedResult })

    expect(statusToolCard.collapsedSummary?.(cardContext)).toBe("MySQL degraded · 1 active")
    render(<>{statusToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("The Syrus MySQL user cannot read Performance Schema statement digests.")).toBeInTheDocument()
    expect(screen.getByText("Mysql2::Error")).toBeInTheDocument()
    expect(screen.getByText("GRANT SELECT ON performance_schema.events_statements_summary_by_digest TO CURRENT_USER;")).toBeInTheDocument()
    expect(screen.getByText("slow-log rows are loaded on demand")).toBeInTheDocument()
  })

  it("renders tool-level error state when status returns plain text instead of JSON", () => {
    const cardContext = context({
      resultBody: "Error: Admin MySQL is only available when Syrus is using the mysql2 adapter",
      resultError: true,
      parsedResult: null
    })

    expect(statusToolCard.collapsedSummary?.(cardContext)).toBe("MySQL status failed")
    render(<>{statusToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("MySQL status failed")).toBeInTheDocument()
    expect(screen.getByText("Error: Admin MySQL is only available when Syrus is using the mysql2 adapter")).toBeInTheDocument()
  })

  it("renders payload-level unavailable and error states", () => {
    render(<>{statusToolCard.renderExpanded(context({ parsedResult: { available: false, error: { message: "lost connection" } } }))}</>)
    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("lost connection")).toBeInTheDocument()

    const unavailable = context({
      parsedResult: {
        available: false,
        process_list: [],
        status: {},
        statement_digests: { available: true, rows: [] },
        slow_log: { available: true, rows: [] }
      }
    })
    expect(statusToolCard.collapsedSummary?.(unavailable)).toBe("MySQL unavailable · 0 active")
  })

  it("renders slow-query rows and truncates large query/log previews", () => {
    const longSql = Array.from({ length: 12 }, (_, index) => `SELECT ${index} AS value FROM very_large_table WHERE payload LIKE '%${index}%'`).join("\n")
    const parsedResult = {
      ...healthyPayload,
      status: { Slow_queries: 6, Innodb_row_lock_current_waits: 0 },
      statement_digests: {
        available: true,
        rows: [
          {
            digest_text: longSql,
            count: 3,
            total_seconds: 35.123,
            max_seconds: 20.5,
            rows_examined: 90000
          }
        ]
      },
      slow_log: {
        available: true,
        rows: [
          {
            start_time: "2026-09-10T11:59:00Z",
            user_host: "sensitive_user[db.internal]",
            query_time: "00:00:12.000000",
            lock_time: "00:00:02.000000",
            rows_sent: 2,
            rows_examined: 45000,
            database: "syrus_production",
            sql_text: longSql
          }
        ]
      }
    }
    const cardContext = context({ parsedResult })

    expect(statusToolCard.collapsedSummary?.(cardContext)).toBe("MySQL healthy · 1 active · 1 slow")
    render(<>{statusToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("00:00:12.000000 query")).toBeInTheDocument()
    expect(screen.getByText("2 rows sent")).toBeInTheDocument()
    expect(screen.getByText("database: syrus_production")).toBeInTheDocument()
    expect(screen.getByText("user: sensitive_user[db.internal]")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Show more" }).length).toBeGreaterThan(0)
  })

  it("expands capped process, digest, and slow-log lists inline", () => {
    const processRows = Array.from({ length: 9 }, (_, index) => ({
      id: 100 + index,
      command: "Query",
      time_seconds: index,
      state: "executing",
      info: `SELECT ${index}`
    }))
    const digestRows = Array.from({ length: 4 }, (_, index) => ({ digest_text: `DIGEST ${index}`, count: 1 }))
    const slowRows = Array.from({ length: 4 }, (_, index) => ({ start_time: `time-${index}`, sql_text: `SLOW ${index}` }))

    render(
      <>
        {statusToolCard.renderExpanded(
          context({
            parsedResult: {
              ...healthyPayload,
              process_list: processRows,
              statement_digests: { available: true, rows: digestRows },
              slow_log: { available: true, rows: slowRows }
            }
          })
        )}
      </>
    )

    expect(screen.queryByText("SELECT 8")).not.toBeInTheDocument()
    expect(screen.queryByText("DIGEST 3")).not.toBeInTheDocument()
    expect(screen.queryByText("SLOW 3")).not.toBeInTheDocument()
    screen.getAllByRole("button", { name: /Show all/ }).forEach((button) => fireEvent.click(button))
    expect(screen.getByText("SELECT 8")).toBeInTheDocument()
    expect(screen.getByText("DIGEST 3")).toBeInTheDocument()
    expect(screen.getByText("SLOW 3")).toBeInTheDocument()
  })

  it("redacts secrets in SQL and tool-level errors", () => {
    const secret = "super-secret-database-password"
    const parsedResult = {
      ...healthyPayload,
      process_list: [{ id: 99, command: "Query", info: `SELECT * FROM users WHERE password='${secret}'` }]
    }
    const { unmount } = render(<>{statusToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.queryByText(new RegExp(secret))).not.toBeInTheDocument()
    expect(screen.getByText(/password='\[redacted\]'/)).toBeInTheDocument()
    unmount()

    render(<>{statusToolCard.renderExpanded(context({ resultBody: `password=${secret}`, resultError: true, parsedResult: null }))}</>)
    expect(screen.queryByText(new RegExp(secret))).not.toBeInTheDocument()
    expect(screen.getByText("password=[redacted]")).toBeInTheDocument()
  })

  it("selects the same card and payload for prefixed, structured, and content-text MCP results", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_mysql_status")).toBe("admin_mysql_status")
    expect(pluginToolCardRendererFor(normalizedToolName("mcp__syrus-chat-sidecar__admin_mysql_status"))).toBe(statusToolCard)

    const structured = normalizedToolCardParsedResult({ structured_content: healthyPayload, content: [] })
    const text = normalizedToolCardParsedResult({ structured_content: null, content: [{ type: "text", text: JSON.stringify(healthyPayload) }] })
    expect(structured).toEqual(healthyPayload)
    expect(text).toEqual(healthyPayload)
    expect(statusToolCard.collapsedSummary?.(context({ parsedResult: structured }))).toBe("MySQL healthy · 1 active")
    expect(statusToolCard.collapsedSummary?.(context({ parsedResult: text }))).toBe("MySQL healthy · 1 active")
  })

  it("renders admin_mysql_kill_query as a pending operator confirmation", () => {
    const pending = context({
      toolName: "admin_mysql_kill_query",
      parsedResult: {
        pending_confirmation_id: 90,
        pending_action_id: 90,
        state: "pending",
        message: "Kill the query on MySQL thread 90?"
      }
    })

    expect(killQueryToolCard.collapsedSummary?.(pending)).toBe("Kill the query on MySQL thread 90?")
    render(<>{killQueryToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Kill the query on MySQL thread 90?")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed JSON payloads", () => {
    expect(statusToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(statusToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(killQueryToolCard.renderExpanded(context({ toolName: "admin_mysql_kill_query", parsedResult: { thread_id: 1 } }))).toBeNull()
  })
})
