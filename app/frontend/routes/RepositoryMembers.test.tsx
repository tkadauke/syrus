import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryMembersRoute } from "./RepositoryMembers"
import * as useConfirmModule from "../hooks/useConfirm"

function membershipsPayload(overrides: Record<string, unknown> = {}) {
  return {
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    tabs: [],
    memberships: [
      {
        id: 10,
        role: "admin",
        agent_provider: null,
        created_at: "2026-01-01T00:00:00Z",
        user: { id: 1, email_address: "owner@example.com", name: "Ada Lovelace" }
      },
      {
        id: 11,
        role: "read",
        agent_provider: null,
        created_at: "2026-01-02T00:00:00Z",
        user: { id: 2, email_address: "reader@example.com", name: "Grace Hopper" }
      }
    ],
    team_grants: [],
    ...overrides
  }
}

function renderRoute(payload = membershipsPayload()) {
  const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/memberships"]}>
        <Routes>
          <Route element={<RepositoryMembersRoute />} path="/app-shell/repositories/:repositoryId/memberships" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

describe("RepositoryMembersRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("lists current members with their roles", async () => {
    renderRoute()

    expect(await screen.findByText("Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByText("owner@example.com")).toBeInTheDocument()
    expect(screen.getByText("Grace Hopper")).toBeInTheDocument()
    expect(screen.getByText("reader@example.com")).toBeInTheDocument()
  })

  it("adds a member by email at the chosen role", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/memberships" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(membershipsPayload({
          memberships: [
            ...membershipsPayload().memberships,
            {
              id: 12,
              role: "write",
              agent_provider: null,
              created_at: "2026-01-03T00:00:00Z",
              user: { id: 3, email_address: "writer@example.com", name: "Writer Person" }
            }
          ],
          message: "writer@example.com added as write."
        })))
      }
      return Promise.resolve(jsonResponse(membershipsPayload()))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories/1/memberships"]}>
          <Routes>
            <Route element={<RepositoryMembersRoute />} path="/app-shell/repositories/:repositoryId/memberships" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByText("Ada Lovelace")

    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "writer@example.com" } })
    fireEvent.change(screen.getAllByLabelText("Role")[0], { target: { value: "write" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Add" })[0])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/memberships",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Writer Person")).toBeInTheDocument()
  })

  it("changes an existing member's role", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/memberships/11" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(membershipsPayload({
          memberships: [
            membershipsPayload().memberships[0],
            { ...membershipsPayload().memberships[1], role: "write" }
          ],
          message: "Role updated to write."
        })))
      }
      return Promise.resolve(jsonResponse(membershipsPayload()))
    })

    renderRoute()
    await screen.findByText("Grace Hopper")

    const selects = screen.getAllByDisplayValue("Read")
    fireEvent.change(selects[0], { target: { value: "write" } })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/memberships/11",
        expect.objectContaining({ method: "PATCH" })
      )
    })
  })

  describe("team grants", () => {
    it("lists existing team grants", async () => {
      renderRoute(membershipsPayload({
        team_grants: [
          { id: 20, role: "write", created_at: "2026-01-04T00:00:00Z", team: { id: 5, name: "Platform" } }
        ]
      }))

      expect(await screen.findByText("Platform")).toBeInTheDocument()
    })

    it("grants a team access by name at the chosen role", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url === "/api/v1/app/repositories/1/team_grants" && init?.method === "POST") {
          return Promise.resolve(jsonResponse(membershipsPayload({
            team_grants: [
              { id: 20, role: "write", created_at: "2026-01-04T00:00:00Z", team: { id: 5, name: "Platform" } }
            ],
            message: "Platform added as write."
          })))
        }
        return Promise.resolve(jsonResponse(membershipsPayload()))
      })
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      render(
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/repositories/1/memberships"]}>
            <Routes>
              <Route element={<RepositoryMembersRoute />} path="/app-shell/repositories/:repositoryId/memberships" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("Ada Lovelace")

      fireEvent.change(screen.getByLabelText("Team name"), { target: { value: "Platform" } })
      const addButtons = screen.getAllByRole("button", { name: "Add" })
      fireEvent.click(addButtons[addButtons.length - 1])

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/repositories/1/team_grants",
          expect.objectContaining({ method: "POST" })
        )
      })
      expect(await screen.findByText("Platform")).toBeInTheDocument()
    })

    it("removes a team grant after confirmation", async () => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn().mockResolvedValue(true), dialog: <></> })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url === "/api/v1/app/repositories/1/team_grants/20" && init?.method === "DELETE") {
          return Promise.resolve(jsonResponse(membershipsPayload({ message: "Platform removed." })))
        }
        return Promise.resolve(jsonResponse(membershipsPayload({
          team_grants: [
            { id: 20, role: "write", created_at: "2026-01-04T00:00:00Z", team: { id: 5, name: "Platform" } }
          ]
        })))
      })
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      render(
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/repositories/1/memberships"]}>
            <Routes>
              <Route element={<RepositoryMembersRoute />} path="/app-shell/repositories/:repositoryId/memberships" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("Platform")
      const removeButtons = screen.getAllByRole("button", { name: "Remove" })
      fireEvent.click(removeButtons[removeButtons.length - 1])

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/repositories/1/team_grants/20",
          expect.objectContaining({ method: "DELETE" })
        )
      })
    })
  })

  describe("remove", () => {
    let mockConfirm: ReturnType<typeof vi.fn>

    beforeEach(() => {
      mockConfirm = vi.fn().mockResolvedValue(true)
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
    })

    it("asks for confirmation and calls the delete API", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url === "/api/v1/app/repositories/1/memberships/11" && init?.method === "DELETE") {
          return Promise.resolve(jsonResponse(membershipsPayload({
            memberships: [membershipsPayload().memberships[0]],
            message: "Member removed."
          })))
        }
        return Promise.resolve(jsonResponse(membershipsPayload()))
      })
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      render(
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/repositories/1/memberships"]}>
            <Routes>
              <Route element={<RepositoryMembersRoute />} path="/app-shell/repositories/:repositoryId/memberships" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("Grace Hopper")
      const removeButtons = screen.getAllByRole("button", { name: "Remove" })
      fireEvent.click(removeButtons[removeButtons.length - 1])

      await waitFor(() => {
        expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
      })
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/repositories/1/memberships/11",
          expect.objectContaining({ method: "DELETE" })
        )
      })
    })
  })
})
