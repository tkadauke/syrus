import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { AdminTeamDetailRoute, AdminTeamsIndex } from "./AdminTeams"
import * as useConfirmModule from "../hooks/useConfirm"

function teamsPayload(overrides: Record<string, unknown> = {}) {
  return {
    teams: [
      { id: 1, name: "Platform", member_count: 2, repository_count: 1, owned_by_current_user: true, team_path: "/admin/teams/1" }
    ],
    ...overrides
  }
}

function teamDetailPayload(overrides: Record<string, unknown> = {}) {
  return {
    team: { id: 1, name: "Platform", member_count: 2, repository_count: 1, owned_by_current_user: true, team_path: "/admin/teams/1" },
    can_manage: true,
    memberships: [
      { id: 10, role: "owner", created_at: "2026-01-01T00:00:00Z", user: { id: 1, email_address: "owner@example.com", name: "Ada Lovelace" } },
      { id: 11, role: "member", created_at: "2026-01-02T00:00:00Z", user: { id: 2, email_address: "member@example.com", name: "Grace Hopper" } }
    ],
    repository_grants: [
      { id: 20, role: "write", created_at: "2026-01-03T00:00:00Z", repository: { id: 5, slug: "acme/widgets" } }
    ],
    ...overrides
  }
}

function renderIndex(payload = teamsPayload()) {
  const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/teams"]}>
        <Routes>
          <Route element={<AdminTeamsIndex />} path="/app-shell/admin/teams" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

function renderDetail(payload = teamDetailPayload()) {
  const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/teams/1"]}>
        <Routes>
          <Route element={<AdminTeamDetailRoute />} path="/app-shell/admin/teams/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

describe("AdminTeamsIndex", () => {
  afterEach(() => vi.restoreAllMocks())

  it("lists teams with member and repository counts", async () => {
    renderIndex()

    expect(await screen.findByText("Platform")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
  })

  it("shows an empty state with no teams", async () => {
    renderIndex(teamsPayload({ teams: [] }))

    expect(await screen.findByText("No teams yet.")).toBeInTheDocument()
  })

  it("creates a team from the form", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/teams" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(teamsPayload({
          teams: [
            ...teamsPayload().teams,
            { id: 2, name: "Growth", member_count: 1, repository_count: 0, owned_by_current_user: true, team_path: "/admin/teams/2" }
          ],
          message: "Growth created."
        })))
      }
      return Promise.resolve(jsonResponse(teamsPayload()))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/admin/teams"]}>
          <Routes>
            <Route element={<AdminTeamsIndex />} path="/app-shell/admin/teams" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByText("Platform")

    fireEvent.change(screen.getByPlaceholderText("e.g. Platform"), { target: { value: "Growth" } })
    fireEvent.click(screen.getByRole("button", { name: "Create" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/teams",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Growth")).toBeInTheDocument()
  })
})

describe("AdminTeamDetailRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows members and read-only repository grants", async () => {
    renderDetail()

    expect(await screen.findByText("Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByText("Grace Hopper")).toBeInTheDocument()
    expect(screen.getByText("acme/widgets")).toBeInTheDocument()
  })

  it("adds a member by email when the current user can manage the team", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/teams/1/memberships" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(teamDetailPayload({
          memberships: [
            ...teamDetailPayload().memberships,
            { id: 12, role: "member", created_at: "2026-01-04T00:00:00Z", user: { id: 3, email_address: "new@example.com", name: "New Person" } }
          ],
          message: "new@example.com added as member."
        })))
      }
      return Promise.resolve(jsonResponse(teamDetailPayload()))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/admin/teams/1"]}>
          <Routes>
            <Route element={<AdminTeamDetailRoute />} path="/app-shell/admin/teams/:id" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByText("Ada Lovelace")

    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "new@example.com" } })
    fireEvent.click(screen.getByRole("button", { name: "Add" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/teams/1/memberships",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("New Person")).toBeInTheDocument()
  })

  it("renders the member role select as a compact, non-full-width control", async () => {
    renderDetail()

    await screen.findByText("Ada Lovelace")
    const selects = screen.getAllByDisplayValue("Owner")
    // Regression guard: appending "w-auto" after inputClass()'s "w-full" lost
    // the CSS specificity tie (Tailwind emits w-full after w-auto), so the
    // select silently stayed full width and squeezed the member row's name/
    // email column down to one character per line.
    expect(selects[0].className).toMatch(/\bw-auto\b/)
    expect(selects[0].className).not.toMatch(/\bw-full\b/)
  })

  it("hides management controls when the current user cannot manage the team", async () => {
    renderDetail(teamDetailPayload({ can_manage: false }))

    await screen.findByText("Ada Lovelace")

    expect(screen.getByText("Only a team owner or an admin can manage this team.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Remove" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Email")).not.toBeInTheDocument()
  })

  describe("delete", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn().mockResolvedValue(true), dialog: <></> })
    })

    it("asks for confirmation and calls the delete API", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url === "/api/v1/app/teams/1" && init?.method === "DELETE") {
          return Promise.resolve(jsonResponse(teamsPayload({ teams: [], message: "Platform deleted." })))
        }
        return Promise.resolve(jsonResponse(teamDetailPayload()))
      })
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      render(
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/admin/teams/1"]}>
            <Routes>
              <Route element={<AdminTeamDetailRoute />} path="/app-shell/admin/teams/:id" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("Ada Lovelace")
      fireEvent.click(screen.getByRole("button", { name: "Delete team" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/teams/1",
          expect.objectContaining({ method: "DELETE" })
        )
      })
    })
  })
})
