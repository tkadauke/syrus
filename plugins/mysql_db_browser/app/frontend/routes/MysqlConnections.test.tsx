import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { MysqlConnections } from "./MysqlConnections"

function querySql(body: Record<string, unknown> | undefined): string | undefined {
  const mysqlQuery = body?.mysql_query as { sql?: string } | undefined
  return mysqlQuery?.sql
}

function stagingConnection(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    label: "Staging",
    host: "db.staging.internal",
    port: 3306,
    username: "app",
    default_database: "staging",
    agentic_access_enabled: false,
    allow_writes: false,
    has_password: true,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides
  }
}

function setupFetchMock(initial = [stagingConnection()]) {
  let connections = initial
  let nextId = Math.max(0, ...initial.map((connection) => connection.id)) + 1
  const calls: { body?: Record<string, unknown>; method: string; url: string }[] = []

  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const method = (init?.method || "GET").toUpperCase()
    const body = init?.body ? JSON.parse(String(init.body)) : undefined
    calls.push({ body, method, url })

    if (url === "/api/v1/app/admin/mysql_connections" && method === "GET") {
      return Promise.resolve(jsonResponse({ mysql_connections: connections }))
    }
    if (url === "/api/v1/app/admin/mysql_connections" && method === "POST") {
      const created = { ...stagingConnection(), has_password: Boolean(body?.mysql_connection?.password), ...body?.mysql_connection, id: nextId }
      nextId += 1
      connections = [...connections, created]
      return Promise.resolve(jsonResponse({ mysql_connection: created }, 201))
    }
    if (url === "/api/v1/app/admin/mysql_connections/test" && method === "POST") {
      return Promise.resolve(jsonResponse({ success: false, error: "Access denied" }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+\/test$/.test(url) && method === "POST") {
      return Promise.resolve(jsonResponse({ success: true }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+$/.test(url) && method === "PATCH") {
      const id = Number(url.split("/").pop())
      connections = connections.map((connection) => (connection.id === id ? { ...connection, ...body?.mysql_connection } : connection))
      return Promise.resolve(jsonResponse({ mysql_connection: connections.find((connection) => connection.id === id) }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+$/.test(url) && method === "DELETE") {
      const id = Number(url.split("/").pop())
      connections = connections.filter((connection) => connection.id !== id)
      return Promise.resolve(new Response(null, { status: 204 }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+\/schema$/.test(url) && method === "GET") {
      return Promise.resolve(jsonResponse({
        available: true,
        generated_at: "2026-01-01T00:00:00Z",
        databases: [
          { name: "app_staging", system_schema: false, default_character_set: "utf8mb4", default_collation: "utf8mb4_0900_ai_ci" },
          { name: "information_schema", system_schema: true, default_character_set: "utf8", default_collation: "utf8_general_ci" }
        ]
      }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+\/schema\/app_staging\/tables$/.test(url) && method === "GET") {
      return Promise.resolve(jsonResponse({
        available: true,
        generated_at: "2026-01-01T00:00:00Z",
        database: "app_staging",
        system_schema: false,
        truncated: false,
        tables: [
          { name: "users", type: "BASE TABLE", engine: "InnoDB", approximate_row_count: 12, data_length_bytes: 1024, index_length_bytes: 512, created_at: null, updated_at: null, comment: null }
        ]
      }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+\/schema\/app_staging\/tables\/users$/.test(url) && method === "GET") {
      return Promise.resolve(jsonResponse({
        database: "app_staging",
        table: "users",
        system_schema: false,
        generated_at: "2026-01-01T00:00:00Z",
        info: { available: true, type: "BASE TABLE", engine: "InnoDB", approximate_row_count: 12, data_length_bytes: 1024, index_length_bytes: 512, auto_increment: 13, created_at: null, updated_at: null, collation: "utf8mb4_0900_ai_ci", comment: null },
        columns: {
          available: true,
          truncated: false,
          rows: [
            { name: "id", column_type: "bigint", data_type: "bigint", nullable: false, key: "PRI", default: null, extra: "auto_increment", character_max_length: null, numeric_precision: 20, numeric_scale: 0, comment: null },
            { name: "email", column_type: "varchar(255)", data_type: "varchar", nullable: true, key: null, default: null, extra: null, character_max_length: 255, numeric_precision: null, numeric_scale: null, comment: null }
          ]
        },
        indexes: {
          available: true,
          truncated: false,
          rows: [ { name: "PRIMARY", unique: true, type: "BTREE", columns: [ "id" ] } ]
        }
      }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+\/schema\/app_staging\/tables\/users\/content/.test(url) && method === "GET") {
      const params = new URLSearchParams(url.split("?")[1] || "")
      return Promise.resolve(jsonResponse({
        available: true,
        statement: "SELECT * FROM `app_staging`.`users` LIMIT 51 OFFSET 0",
        read_only: true,
        columns: [ "id", "email" ],
        rows: [ { id: 1, email: "grace@example.com" }, { id: 2, email: "ada@example.com" } ],
        row_count: 2,
        truncated: false,
        duration_ms: 3,
        generated_at: "2026-01-01T00:00:00Z",
        filter_schema: [
          { field: "id", label: "Id", bucket: "number", operators: [ "equals", "not_equals", "greater_than", "less_than", "between", "is_set", "is_unset" ] },
          { field: "email", label: "Email", bucket: "string", operators: [ "contains", "does_not_contain", "starts_with", "does_not_start_with", "ends_with", "does_not_end_with", "equals", "not_equals", "is_set", "is_unset" ] }
        ],
        filter: params.get("q") ? { and: [] } : null,
        page: Number(params.get("page")) || 1,
        per_page: 50,
        has_more: false
      }))
    }
    if (/\/api\/v1\/app\/admin\/mysql_connections\/\d+\/query$/.test(url) && method === "POST") {
      return Promise.resolve(jsonResponse({
        available: true,
        statement: body?.mysql_query?.sql,
        read_only: true,
        columns: [ "id" ],
        rows: [ { id: 1 } ],
        row_count: 1,
        truncated: false,
        duration_ms: 2,
        generated_at: "2026-01-01T00:00:00Z"
      }))
    }

    throw new Error(`Unhandled fetch: ${method} ${url}`)
  }) as typeof window.fetch)

  return { calls, fetchSpy }
}

function renderConnections() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/db_browser"]}>
          <MysqlConnections />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("MysqlConnections", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("lists connections without ever rendering a password", async () => {
    setupFetchMock()
    renderConnections()

    expect(await screen.findByText("Staging")).toBeInTheDocument()
    expect(screen.getByText("db.staging.internal:3306")).toBeInTheDocument()
    expect(screen.getByText("Set")).toBeInTheDocument()
    expect(document.body.textContent).not.toContain("hunter2")
  })

  it("shows the empty state when there are no connections", async () => {
    setupFetchMock([])
    renderConnections()

    expect(await screen.findByText("No connections yet. Add one to get started.")).toBeInTheDocument()
  })

  it("creates a connection from the add form", async () => {
    setupFetchMock([])
    renderConnections()

    await screen.findByText("No connections yet. Add one to get started.")

    fireEvent.change(screen.getByLabelText("Label"), { target: { value: "Prod" } })
    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "db.prod.internal" } })
    fireEvent.change(screen.getByLabelText("Username"), { target: { value: "app" } })
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "hunter2" } })
    fireEvent.click(screen.getByRole("button", { name: "Add connection" }))

    expect(await screen.findByText("Prod")).toBeInTheDocument()
    expect(await screen.findByText('Connection "Prod" added.')).toBeInTheDocument()
    expect(document.body.textContent).not.toContain("hunter2")
  })

  it("edits a connection without pre-filling the stored password", async () => {
    setupFetchMock()
    renderConnections()

    fireEvent.click(await screen.findByRole("button", { name: "Edit" }))

    const editRow = (await screen.findByText("Edit connection")).closest("tr") as HTMLElement
    const passwordInput = within(editRow).getByLabelText("Password", { exact: false }) as HTMLInputElement
    expect(passwordInput.value).toBe("")

    fireEvent.change(within(editRow).getByLabelText("Label"), { target: { value: "Staging (renamed)" } })
    fireEvent.click(within(editRow).getByRole("button", { name: "Save" }))

    expect(await screen.findByText("Staging (renamed)")).toBeInTheDocument()
    expect(await screen.findByText('Connection "Staging (renamed)" updated.')).toBeInTheDocument()
  })

  it("deletes a connection after confirmation", async () => {
    setupFetchMock()
    vi.spyOn(window, "confirm").mockReturnValue(true)
    renderConnections()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    await waitFor(() => expect(screen.queryByText("Staging")).not.toBeInTheDocument())
    expect(await screen.findByText("No connections yet. Add one to get started.")).toBeInTheDocument()
  })

  it("does not delete when the confirmation is dismissed", async () => {
    const { calls } = setupFetchMock()
    vi.spyOn(window, "confirm").mockReturnValue(false)
    renderConnections()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    await waitFor(() => expect(screen.getByText("Staging")).toBeInTheDocument())
    expect(calls.some((call) => call.method === "DELETE")).toBe(false)
  })

  it("tests an existing connection and reports success", async () => {
    setupFetchMock()
    renderConnections()

    const row = (await screen.findByText("Staging")).closest("tr") as HTMLElement
    fireEvent.click(within(row).getByRole("button", { name: "Test connection" }))

    expect(await within(row).findByText("Connection succeeded.")).toBeInTheDocument()
  })

  describe("schema browsing", () => {
    it("lists databases (including system schemas) and shows the table's Content grid by default", async () => {
      setupFetchMock()
      renderConnections()

      fireEvent.click(await screen.findByRole("button", { name: "Browse Schema" }))

      expect(await screen.findByText("Browsing Staging")).toBeInTheDocument()
      expect(await screen.findByText("app_staging")).toBeInTheDocument()
      expect(screen.getByText("information_schema")).toBeInTheDocument()
      expect(screen.getByText("System")).toBeInTheDocument()

      fireEvent.click(screen.getByText("app_staging"))
      fireEvent.click(await screen.findByText("users"))

      expect(await screen.findByText("grace@example.com")).toBeInTheDocument()
      expect(screen.getByText("ada@example.com")).toBeInTheDocument()
    })

    it("switches to the Structure sub-tab to see columns and indexes", async () => {
      setupFetchMock()
      renderConnections()

      fireEvent.click(await screen.findByRole("button", { name: "Browse Schema" }))
      fireEvent.click(await screen.findByText("app_staging"))
      fireEvent.click(await screen.findByText("users"))
      await screen.findByText("grace@example.com")

      fireEvent.click(screen.getByRole("tab", { name: "Structure" }))

      expect(await screen.findByText("app_staging.users")).toBeInTheDocument()
      expect(screen.getByText("id")).toBeInTheDocument()
      expect(screen.getByText("email")).toBeInTheDocument()
      expect(screen.getByText("PRIMARY", { exact: false })).toBeInTheDocument()
    })

    it("returns to the connection list", async () => {
      setupFetchMock()
      renderConnections()

      fireEvent.click(await screen.findByRole("button", { name: "Browse Schema" }))
      expect(await screen.findByText("Browsing Staging")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Back to connections" }))

      expect(await screen.findByText("db.staging.internal:3306")).toBeInTheDocument()
    })
  })

  describe("Query tab", () => {
    it("runs a raw SQL statement and shows the results grid", async () => {
      const { calls } = setupFetchMock()
      renderConnections()

      fireEvent.click(await screen.findByRole("button", { name: "Browse Schema" }))
      fireEvent.click(await screen.findByRole("tab", { name: "Query" }))

      fireEvent.change(screen.getByLabelText("SQL statement"), { target: { value: "SELECT * FROM users" } })
      fireEvent.click(screen.getByRole("button", { name: "Run query" }))

      expect(await screen.findByText("1 rows in 2ms")).toBeInTheDocument()
      const queryCall = calls.find((call) => call.method === "POST" && call.url.endsWith("/query"))
      expect(queryCall?.body).toEqual({ mysql_query: { sql: "SELECT * FROM users" } })
    })
  })

  describe("Live tab", () => {
    it("runs the Process List canned query and lets an operator switch to Global Status", async () => {
      const { calls } = setupFetchMock()
      renderConnections()

      fireEvent.click(await screen.findByRole("button", { name: "Browse Schema" }))
      fireEvent.click(await screen.findByRole("tab", { name: "Live" }))

      await waitFor(() => expect(calls.some((call) => call.method === "POST" && call.url.endsWith("/query"))).toBe(true))
      expect(await screen.findByText("1 rows in 2ms")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("tab", { name: "Global Status" }))

      const statusCall = await waitFor(() => {
        const found = calls.find((call) => querySql(call.body)?.includes("performance_schema.global_status"))
        expect(found).toBeTruthy()
        return found
      })
      expect(querySql(statusCall?.body)).toContain("performance_schema.global_status")
    })
  })
})
