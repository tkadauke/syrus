import { test, expect, type Page, type Route } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

const DATABASE_NAME = "app_production"
const TABLE_NAME = "users"

// The preview sandbox has no reachable external MySQL server, so a real
// connection would only ever exercise the (already-covered) connection-error
// path. Route interception stands in for that server, letting this spec
// exercise the real "list connections -> browse databases -> browse tables"
// path end to end while staying deterministic.
async function mockSchemaBrowsing(page: Page) {
  await page.route((url) => url.pathname.includes("/api/v1/app/admin/mysql_connections"), async (route) => {
    const segments = new URL(route.request().url()).pathname.split("/").filter(Boolean)
    const rest = segments.slice(segments.indexOf("mysql_connections") + 2)

    if (rest[0] === "query" && route.request().method() === "POST") {
      await fulfillQuery(route)
      return
    }

    if (rest[0] !== "schema") {
      await route.continue()
      return
    }

    if (rest.length === 1) {
      await route.fulfill({
        json: {
          available: true,
          generated_at: "2026-01-01T00:00:00Z",
          databases: [
            { name: DATABASE_NAME, system_schema: false, default_character_set: "utf8mb4", default_collation: "utf8mb4_general_ci" },
            { name: "information_schema", system_schema: true, default_character_set: "utf8", default_collation: "utf8_general_ci" }
          ]
        }
      })
      return
    }

    if (rest.length === 3 && rest[2] === "tables") {
      await route.fulfill({
        json: {
          available: true,
          generated_at: "2026-01-01T00:00:00Z",
          database: DATABASE_NAME,
          system_schema: false,
          truncated: false,
          tables: [
            { name: TABLE_NAME, type: "BASE TABLE", engine: "InnoDB", approximate_row_count: 2, data_length_bytes: 16384, index_length_bytes: 16384, created_at: null, updated_at: null, comment: null }
          ]
        }
      })
      return
    }

    if (rest.length === 5 && rest[2] === "tables" && rest[4] === "content") {
      await route.fulfill({
        json: {
          available: true,
          statement: `SELECT * FROM \`${DATABASE_NAME}\`.\`${TABLE_NAME}\` LIMIT 51`,
          read_only: true,
          columns: ["id", "email"],
          rows: [{ id: 1, email: "demo@syrus.local" }],
          row_count: 1,
          truncated: false,
          duration_ms: 3,
          generated_at: "2026-01-01T00:00:00Z",
          filter_schema: [],
          filter: null,
          page: 1,
          per_page: 50,
          has_more: false
        }
      })
      return
    }

    if (rest.length === 4 && rest[2] === "tables" && rest[3] === TABLE_NAME) {
      await route.fulfill({
        json: {
          database: DATABASE_NAME,
          table: TABLE_NAME,
          system_schema: false,
          generated_at: "2026-01-01T00:00:00Z",
          info: {
            available: true,
            type: "BASE TABLE",
            engine: "InnoDB",
            approximate_row_count: 2,
            data_length_bytes: 16384,
            index_length_bytes: 16384,
            auto_increment: 3,
            created_at: null,
            updated_at: null,
            collation: "utf8mb4_general_ci",
            comment: null
          },
          columns: {
            available: true,
            truncated: false,
            rows: [
              { name: "id", column_type: "bigint", data_type: "bigint", nullable: false, key: "PRI", default: null, extra: "auto_increment", character_max_length: null, numeric_precision: 19, numeric_scale: 0, comment: null },
              { name: "email", column_type: "varchar(255)", data_type: "varchar", nullable: false, key: "UNI", default: null, extra: null, character_max_length: 255, numeric_precision: null, numeric_scale: null, comment: null }
            ]
          },
          indexes: { available: true, truncated: false, rows: [{ name: "PRIMARY", unique: true, type: "BTREE", columns: [ "id" ] }] },
          foreign_keys: { available: true, truncated: false, rows: [] }
        }
      })
      return
    }

    await route.continue()
  })
}

// The Query tab posts raw SQL through the same guardrailed QueryExecutor as
// the Content tab's grid. A SELECT gets rows back; anything else gets the
// server's real 403 write_not_allowed rejection -- this is the exact
// enforcement the second half of this spec asserts, so the mock mirrors
// QueryExecutor#execute's read_only_statement? branch rather than always
// succeeding.
async function fulfillQuery(route: Route) {
  const body = route.request().postDataJSON() as { mysql_query?: { sql?: string } }
  const sql = body.mysql_query?.sql ?? ""

  if (/^\s*select/i.test(sql)) {
    await route.fulfill({
      json: {
        available: true,
        statement: sql,
        read_only: true,
        columns: ["id", "email"],
        rows: [{ id: 1, email: "demo@syrus.local" }],
        row_count: 1,
        truncated: false,
        duration_ms: 3,
        generated_at: "2026-01-01T00:00:00Z"
      }
    })
    return
  }

  await route.fulfill({
    status: 403,
    json: {
      error: {
        code: "write_not_allowed",
        message: "This connection is read-only. Enable write access on the connection to run non-SELECT statements."
      }
    }
  })
}

test("DB Browser lists connections, databases, and tables read-only with no write-action UI", async ({ page }) => {
  await signInAsDemo(page)
  await mockSchemaBrowsing(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", { hasText: "MySQL DB Browser" })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
  }

  await page.goto("/db_browser")
  await expect(page.getByRole("heading", { name: "DB Browser" })).toBeVisible()
  await expect(page.getByText("No connections yet. Add one to get started.")).toBeVisible()

  await page.getByLabel("Label", { exact: true }).fill("Reporting replica")
  await page.getByLabel("Host", { exact: true }).fill("127.0.0.1")
  await page.getByLabel("Port", { exact: true }).fill("3306")
  await page.getByLabel("Username", { exact: true }).fill("reporting")
  await page.getByLabel("Password", { exact: true }).fill("not-a-real-password")
  await page.getByRole("button", { name: "Add connection", exact: true }).click()

  const connectionRow = page.getByRole("row", { name: /Reporting replica/ })
  await expect(connectionRow).toBeVisible()
  await expect(connectionRow.getByText("Read-only")).toBeVisible()

  await connectionRow.getByRole("button", { name: "Connect" }).click()
  await expect(page.getByRole("heading", { name: "Browsing Reporting replica" })).toBeVisible()

  const schemaTree = page.getByRole("navigation", { name: "Databases and tables" })
  await expect(schemaTree.getByText(DATABASE_NAME)).toBeVisible()
  await expect(schemaTree.getByText("information_schema")).toBeVisible()
  await expect(schemaTree.getByText("System")).toBeVisible()

  await schemaTree.getByRole("button", { name: DATABASE_NAME, exact: true }).click()
  await schemaTree.getByRole("button", { name: TABLE_NAME }).click()

  // Content tab is the default view for a selected table: real row data,
  // sortable columns, pagination -- no way to edit or delete a row.
  await expect(page.getByRole("cell", { name: "demo@syrus.local" })).toBeVisible()
  await expect(page.getByRole("button", { name: /insert row|delete row|update row|save changes/i })).toHaveCount(0)

  await page.getByRole("tab", { name: "Structure" }).click()
  await expect(page.getByRole("cell", { name: "email", exact: true })).toBeVisible()
  await expect(page.getByRole("cell", { name: "UNI", exact: true })).toBeVisible()
  await expect(page.getByRole("button", { name: /insert row|delete row|update row|save changes/i })).toHaveCount(0)

  await page.getByRole("tab", { name: "Query", exact: true }).click()
  await expect(page.getByText("This connection is read-only by default; non-SELECT statements are rejected unless write access is enabled.")).toBeVisible()
  await expect(page.getByRole("button", { name: /insert row|delete row|update row|save changes/i })).toHaveCount(0)

  // A read-only SELECT runs and renders its rows in the same results grid.
  await page.getByLabel("SQL statement").fill(`SELECT * FROM ${TABLE_NAME} LIMIT 1`)
  await page.getByRole("button", { name: "Run query" }).click()
  await expect(page.getByRole("cell", { name: "demo@syrus.local" })).toBeVisible()

  // A write statement against a read-only connection is rejected -- here,
  // server-side by QueryExecutor#execute (mocked as the real 403 it returns)
  // -- and the UI surfaces the rejection instead of pretending it ran.
  await page.getByLabel("SQL statement").fill(`DELETE FROM ${TABLE_NAME} WHERE id = 1`)
  await page.getByRole("button", { name: "Run query" }).click()
  await expect(page.getByRole("alert")).toHaveText("This connection is read-only. Enable write access on the connection to run non-SELECT statements.")
  await expect(page.getByRole("button", { name: /insert row|delete row|update row|save changes/i })).toHaveCount(0)
})
