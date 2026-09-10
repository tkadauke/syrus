import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import killQueryToolCard from "./admin_mysql_kill_query"
import statusToolCard from "./admin_mysql_status"

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
    max_connections: 151,
    sleeping_connections: 1,
    aborted_connects: 0,
    max_connection_errors: 0
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
        count: 12,
        total_seconds: 4.2,
        avg_seconds: 0.35,
        max_seconds: 1.2,
        rows_examined: 1200
      }
    ]
  },
  slow_log: {
    available: true,
    rows: []
  }
}

describe("Admin MySQL tool cards", () => {
  it("registers plugin-local card modules for Admin MySQL chat tools", () => {
    expect(pluginToolCardRendererFor("admin_mysql_status")).not.toBeNull()
    expect(pluginToolCardRendererFor("admin_mysql_kill_query")).not.toBeNull()
  })

  it("renders healthy status with connection health and query counts without sensitive connection details", () => {
    const cardContext = context({ parsedResult: healthyPayload })

    expect(statusToolCard.collapsedSummary?.(cardContext)).toBe("MySQL healthy · 1 active")
    render(<>{statusToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("healthy")).toBeInTheDocument()
    expect(screen.getByText("Active queries")).toBeInTheDocument()
    expect(screen.getByText("SELECT COUNT(*) FROM jobs")).toBeInTheDocument()
    expect(screen.getByText("Statement digests")).toBeInTheDocument()
    expect(screen.queryByText("sensitive_user")).not.toBeInTheDocument()
    expect(screen.queryByText("db.internal")).not.toBeInTheDocument()
    expect(screen.queryByText("syrus_production")).not.toBeInTheDocument()
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
          hint: "Grant SELECT on performance_schema.events_statements_summary_by_digest."
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

    const unavailable = context({ parsedResult: { available: false, process_list: [], status: {}, statement_digests: { available: true, rows: [] }, slow_log: { available: true, rows: [] } } })
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
    expect(screen.getAllByText(/Show full payload/).length).toBeGreaterThan(0)
    expect(screen.queryByText("sensitive_user[db.internal]")).not.toBeInTheDocument()
    expect(screen.queryByText("syrus_production")).not.toBeInTheDocument()
  })

  it("renders admin_mysql_kill_query success and failure outcomes", () => {
    const killed = context({
      toolName: "admin_mysql_kill_query",
      parsedResult: { killed: true, thread_id: 90, generated_at: "2026-09-10T12:00:00Z" }
    })
    const failed = context({
      toolName: "admin_mysql_kill_query",
      resultError: true,
      parsedResult: { killed: false, thread_id: 91, error: { message: "Unknown thread id: 91" } }
    })

    expect(killQueryToolCard.collapsedSummary?.(killed)).toBe("Killed query #90")
    render(<>{killQueryToolCard.renderExpanded(killed)}</>)
    expect(screen.getByText("killed")).toBeInTheDocument()
    expect(screen.getByText("thread #90")).toBeInTheDocument()

    expect(killQueryToolCard.collapsedSummary?.(failed)).toBe("Kill query failed #91")
    render(<>{killQueryToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Unknown thread id: 91")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed JSON payloads", () => {
    expect(statusToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(statusToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(killQueryToolCard.renderExpanded(context({ toolName: "admin_mysql_kill_query", parsedResult: { thread_id: 1 } }))).toBeNull()
  })
})
