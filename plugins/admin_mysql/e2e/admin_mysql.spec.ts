import { test, expect, type Page, type Route } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

const ADMIN_PAGES_PATH = "/api/v1/app/admin/plugin_pages"
const MYSQL_PATH = "/api/v1/app/admin/mysql"
const KILL_PATH = "/api/v1/app/admin/mysql/kill_query"

function mysqlPayload(includeSlowLog: boolean) {
  return {
    available: true,
    generated_at: "2026-09-01T12:00:00Z",
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
      { id: 101, user: "app", host: "10.0.0.1:5000", database: "syrus_production", command: "Sleep", time_seconds: 12, state: null, info: null },
      { id: 202, user: "app", host: "10.0.0.2:5000", database: "syrus_production", command: "Query", time_seconds: 3, state: "executing", info: "SELECT * FROM jobs" }
    ],
    statement_digests: {
      available: true,
      rows: [
        {
          schema_name: "syrus_production",
          digest_text: "SELECT `jobs` . * FROM `jobs` WHERE `jobs` . `state` = ?",
          count: 5439,
          total_seconds: 248.3,
          avg_seconds: 0.046,
          max_seconds: 21.5,
          rows_sent: 1,
          rows_examined: 1,
          first_seen: null,
          last_seen: null
        }
      ]
    },
    slow_log: {
      available: true,
      config: { slow_query_log: "ON", log_output: "TABLE", long_query_time: "1.000000" },
      rows: includeSlowLog
        ? [
            {
              start_time: "2026-09-01T11:59:00Z",
              user_host: "app[app] @ 10.0.0.1",
              query_time: "1.200000",
              lock_time: "0.000000",
              rows_sent: 1,
              rows_examined: 1000,
              database: "syrus_production",
              sql_text: "SELECT * FROM jobs"
            }
          ]
        : []
    }
  }
}

async function mockAdminMysql(page: Page) {
  await page.route((url) => url.pathname === ADMIN_PAGES_PATH, async (route) => {
    await route.fulfill({
      json: {
        pages: [
          {
            id: "admin_mysql.mysql",
            label: "MySQL",
            label_key: "admin_mysql:nav_mysql",
            path: "/admin/mysql",
            paths: [ "/admin/mysql" ],
            component: "admin_mysql/AdminMysql",
            group_id: "observability",
            order: 70
          }
        ]
      }
    })
  })

  await page.route((url) => url.pathname === MYSQL_PATH, async (route) => {
    const includeSlowLog = new URL(route.request().url()).searchParams.get("include_slow_log") === "true"
    await route.fulfill({ json: mysqlPayload(includeSlowLog) })
  })

  await page.route((url) => url.pathname === KILL_PATH, fulfillKillQuery)
}

async function fulfillKillQuery(route: Route) {
  const body = route.request().postDataJSON() as { thread_id?: number }

  await route.fulfill({
    json: {
      killed: true,
      thread_id: body.thread_id,
      generated_at: "2026-09-01T12:00:01Z"
    }
  })
}

test("Admin MySQL plugin renders live diagnostics and guarded query termination", async ({ page }) => {
  await signInAsDemo(page)
  await mockAdminMysql(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", {
    has: page.getByRole("heading", { name: "Admin MySQL", exact: true })
  })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
  }

  // The preview database is SQLite, so AdminMysql::AdminPages intentionally
  // hides this page from the real admin registry. The mocked registry above
  // exposes the same route/component pair so this spec can still exercise the
  // plugin-owned dashboard with deterministic MySQL-shaped data.
  await page.goto("/admin/mysql")
  await expect(page.getByRole("heading", { name: "MySQL", exact: true })).toBeVisible()
  await expect(page.getByText("Threads running")).toBeVisible()
  await expect(page.getByText("2", { exact: true }).first()).toBeVisible()
  await expect(page.getByText("syrus_production")).toBeVisible()
  await expect(page.getByRole("heading", { name: "Statement digests" })).toBeVisible()
  await expect(page.getByText("SELECT `jobs` . * FROM `jobs` WHERE `jobs` . `state` = ?")).toBeVisible()

  const hideIdle = page.getByLabel(/Hide idle threads/)
  await expect(hideIdle).toBeChecked()
  await expect(page.getByRole("cell", { name: "Sleep", exact: true })).toHaveCount(0)
  await expect(page.getByRole("cell", { name: "Query", exact: true })).toBeVisible()

  await hideIdle.uncheck()
  await expect(page.getByRole("cell", { name: "Sleep", exact: true })).toBeVisible()

  await page.getByRole("button", { name: "Load slow log rows" }).click()
  const slowLogPanel = page.locator("section", { has: page.getByRole("heading", { name: "Slow log" }) })
  await expect(slowLogPanel.getByRole("cell", { name: "SELECT * FROM jobs" })).toBeVisible()

  page.on("dialog", (dialog) => dialog.accept())
  await page.getByRole("button", { name: "Kill query" }).click()
  await expect(page.getByText("Killed query for thread 202.")).toBeVisible()
})
