import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AdminUsersIndex } from "./AdminUsers"

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    email_address: "ada@example.com",
    name: "Ada Lovelace",
    first_name: "Ada",
    last_name: "Lovelace",
    profile_bio: null,
    profile_location: null,
    profile_company: null,
    profile_website: null,
    display_name: "Ada Lovelace",
    github_handle: "ada",
    admin: false,
    role: "developer",
    scheduling_paused: false,
    agent_provider: "claude",
    chat_provider: null,
    codex_auth_mode: "api_key",
    has_github_token: true,
    has_claude_token: true,
    has_codex_token: false,
    has_codex_api_key: false,
    has_codex_auth_json: false,
    has_api_token: false,
    agent_max_turns: 200,
    github_api_blocked: false,
    github_api_blocked_at: null,
    github_api_blocked_reason: null,
    github_rate_limit: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides
  }
}

function usersPayload(overrides: Record<string, unknown> = {}) {
  return {
    active_smart_folder_id: null,
    smart_folders: [],
    filter: {},
    controls: { filter_schema: [] },
    filters: {},
    count: 1,
    users: [userRow()],
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(usersPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/users"]}>
        <AdminUsersIndex />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminUsers configurable columns", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("shows every default column for the raw-table-converted users grid", async () => {
    renderRoute()

    expect(await screen.findByRole("columnheader", { name: "User" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "GitHub" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Admin" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Role" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Agent" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Scheduling" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Tokens" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "GH API" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "GH rate" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Ada Lovelace" })).toBeInTheDocument()
  })

  it("hides an optional column through the column picker and persists it under a users-specific key", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "User" })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("checkbox", { name: "GH rate" }))

    await waitFor(() => {
      expect(screen.queryByRole("columnheader", { name: "GH rate" })).not.toBeInTheDocument()
    })
    // User stays -- it's the required identity column and never appears in the picker.
    expect(screen.getByRole("columnheader", { name: "User" })).toBeInTheDocument()

    expect(JSON.parse(window.localStorage.getItem("syrus.admin.users.visible_columns") ?? "[]")).toEqual([
      "github",
      "admin",
      "role",
      "agent",
      "scheduling",
      "tokens",
      "gh_api"
    ])
  })
})
