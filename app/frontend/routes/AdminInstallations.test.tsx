import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AdminInstallations } from "./AdminInstallations"

function installationRepository(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    slug: "acme/widgets",
    owner: "acme",
    name: "widgets",
    owner_user: { id: 2, email_address: "ada@example.com", admin: false },
    app_credential_active: true,
    app_credential_inactive_reason: null,
    recommended_next_action: null,
    credential_mode: "app",
    account_login: "acme",
    installation_removed_at: null,
    github_owner_id: 100,
    github_repository_id: 200,
    ...overrides
  }
}

function installationsPayload(overrides: Record<string, unknown> = {}) {
  return {
    github_app_registered: true,
    github_app_slug: "syrus-app",
    latest_sync: { last_attempted_at: null, last_successful_at: null, duration_ms: null, records_seen: null, error_class: null, error_message: null },
    pat_owner_groups: [],
    repositories: [installationRepository()],
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(installationsPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/installations"]}>
        <AdminInstallations />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminInstallations repositories configurable columns", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("renders the raw-table-converted repositories grid with its default columns", async () => {
    renderRoute()

    expect(await screen.findByRole("columnheader", { name: "Repository" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Syrus owner" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "App" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "PAT" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Account" })).toBeInTheDocument()
    expect(screen.getByText("acme/widgets")).toBeInTheDocument()
  })

  it("hides an optional column and persists it under an installations-specific key", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Syrus owner" })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("checkbox", { name: "Syrus owner" }))

    await waitFor(() => {
      expect(screen.queryByRole("columnheader", { name: "Syrus owner" })).not.toBeInTheDocument()
    })
    // Repository stays -- it's the required identity column and never appears in the picker.
    expect(screen.getByRole("columnheader", { name: "Repository" })).toBeInTheDocument()

    expect(JSON.parse(window.localStorage.getItem("syrus.admin.installations.repositories.visible_columns") ?? "[]")).toEqual([
      "app_credential",
      "pat_credential",
      "account"
    ])
  })

  it("shows the empty state when there are no repositories", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(installationsPayload({ repositories: [] })))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/admin/installations"]}>
          <AdminInstallations />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No repositories configured.")).toBeInTheDocument()
  })
})
