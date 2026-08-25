import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { MysqlConnections } from "./MysqlConnections"

function stagingConnection(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    label: "Staging",
    host: "db.staging.internal",
    port: 3306,
    username: "app",
    default_database: "staging",
    agentic_access_enabled: false,
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
})
