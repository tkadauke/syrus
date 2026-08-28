import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import { AdminMysql } from "./AdminMysql"

describe("AdminMysql", () => {
  it("keeps the statement digests and slow log panels shrinkable so their tables scroll instead of overflowing the page", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(mysqlPayload()))

    renderRoute(<AdminMysql />)

    await waitFor(() => expect(screen.queryByText("Loading MySQL state...")).not.toBeInTheDocument())

    const digestsHeading = await screen.findByRole("heading", { name: "Statement digests" })
    const slowLogHeading = await screen.findByRole("heading", { name: "Slow log" })

    // These headings live inside the two grid panels placed side by side at
    // the `xl` breakpoint (`grid xl:grid-cols-2`). Grid items default to
    // `min-width: auto`, so a wide table forces the whole grid track (and
    // the page) wider instead of letting the panel's own `overflow-auto`
    // table wrapper scroll internally. `min-w-0` on the panel is what makes
    // the internal scroll actually take effect.
    expect(digestsHeading.closest("section")).toHaveClass("min-w-0")
    expect(slowLogHeading.closest("section")).toHaveClass("min-w-0")
  })
})

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/admin/mysql"]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function mysqlPayload() {
  return {
    available: true,
    generated_at: "2026-08-27T12:00:00Z",
    adapter: "mysql2",
    database: "syrus_production",
    connection_summary: {
      threads_connected: 10,
      threads_running: 2,
      max_used_connections: 20,
      max_connections: 200,
      sleeping_connections: 8,
      aborted_connects: 0,
      max_connection_errors: 0,
      wait_timeout: 28800,
      interactive_timeout: 28800
    },
    variables: {
      version: "8.0.36",
      max_connections: 200,
      innodb_buffer_pool_size: "1073741824",
      innodb_redo_log_capacity: "104857600",
      innodb_flush_log_at_trx_commit: 1,
      sync_binlog: 1,
      slow_query_log: "ON",
      log_output: "TABLE",
      long_query_time: "1.000000",
      performance_schema: "ON"
    },
    status: {
      Slow_queries: 3,
      Created_tmp_tables: 100,
      Created_tmp_disk_tables: 1,
      Handler_commit: 1000,
      Handler_rollback: 2,
      Innodb_row_lock_current_waits: 0,
      Innodb_row_lock_waits: 5,
      Innodb_row_lock_time: 42,
      Innodb_data_fsyncs: 200,
      Innodb_os_log_fsyncs: 300,
      Innodb_log_waits: 0
    },
    process_list: [
      { id: 1, user: "app", host: "10.0.0.1:5000", database: "syrus_production", command: "Sleep", time_seconds: 12, state: null, info: null }
    ],
    statement_digests: {
      available: true,
      rows: [
        { schema_name: "syrus_production", digest_text: "SELECT `jobs` . * FROM `jobs` WHERE `jobs` . `state` = ?", count: 54392498, total_seconds: 24831.6, avg_seconds: 0.001, max_seconds: 215.0, rows_sent: 1, rows_examined: 1, first_seen: null, last_seen: null }
      ]
    },
    slow_log: {
      available: true,
      config: { slow_query_log: "ON", log_output: "TABLE", long_query_time: "1.000000" },
      rows: [
        { start_time: "2026-08-27T11:59:00Z", user_host: "app[app] @ 10.0.0.1", query_time: "1.200000", lock_time: "0.000000", rows_sent: 1, rows_examined: 1000, database: "syrus_production", sql_text: "SELECT * FROM jobs" }
      ]
    }
  }
}
