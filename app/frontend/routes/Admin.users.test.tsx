import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { adminUsersPayloadFromSearch, adminUsersPayloadWithSavedFolder, currentAdminUserFilter } from "../test/app/adminPayloads"
import { mobileFiltersSummary } from "../test/app/dashboardPayloads"
import { renderAppAt } from "../test/app/render"
import { mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App admin users", () => {
  installAppTestLifecycle()

  it("renders the admin users route from the app admin users API", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            filters: { gh_rate: "low" },
            filter: { and: [{ field: "gh_rate", op: "is", value: "low" }] },
            controls: {
              filter_schema: [
                { field: "email", label: "Email", bucket: "string", operators: ["contains", "not_contains"], values: [] },
                {
                  field: "gh_rate",
                  label: "GH rate",
                  bucket: "enum",
                  operators: ["is"],
                  values: [
                    { value: "low", label: "Low (<10%)" },
                    { value: "exhausted", label: "Exhausted" }
                  ]
                }
              ]
            },
            count: 1,
            pagination: {
              page: 1,
              per_page: 100,
              total: 1,
              total_pages: 1,
              has_previous_page: false,
              has_next_page: false,
              previous_page: null,
              next_page: null,
              first_item: 1,
              last_item: 1
            },
            sort: { column: "email", direction: "asc" },
            active_smart_folder_id: 5,
            smart_folders: [
              {
                id: 5,
                name: "Rate limit low",
                kind: "builtin",
                subject_type: "admin_user",
                visibility: "when_present",
                count: 1,
                active: true,
                path: "/admin/users?smart_folder_id=5"
              },
              {
                id: 6,
                name: "Admins",
                kind: "builtin",
                subject_type: "admin_user",
                visibility: "on_demand",
                count: 1,
                active: false,
                path: "/admin/users?smart_folder_id=6"
              }
            ],
            users: [
              {
                id: 5,
                email_address: "operator@example.com",
                name: "Operator",
                first_name: null,
                last_name: null,
                profile_bio: null,
                profile_location: null,
                profile_company: null,
                profile_website: null,
                display_name: "Operator",
                github_handle: "octo",
                admin: true,
                scheduling_paused: false,
                agent_provider: "codex",
                codex_auth_mode: "api_key",
                has_github_token: true,
                has_claude_token: false,
                has_codex_token: true,
                has_codex_api_key: true,
                has_codex_auth_json: false,
                has_api_token: true,
                agent_max_turns: 200,
                github_api_blocked: false,
                github_api_blocked_at: null,
                github_api_blocked_reason: null,
                github_rate_limit: {
                  remaining: 5,
                  limit: 5000,
                  resource: "core",
                  reset_at: null,
                  observed_at: null,
                  percent: 0.001
                },
                created_at: "2026-05-30T12:00:00Z",
                updated_at: "2026-05-30T12:00:00Z"
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/users?gh_rate=low"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.getByRole("main", { name: "Admin users" })).toBeInTheDocument()
      expect(await screen.findByText("Operator")).toBeInTheDocument()
      const disclosure = mobileFiltersSummary("Rate limit low").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(mobileFiltersSummary("Rate limit low"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByText("operator@example.com")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /GH rate is Low/ })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Email text" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Operator" })).toHaveAttribute("href", "/app-shell/admin/users/5")
      expect(screen.getByRole("link", { name: "Rate limit low 1" })).toHaveAttribute("href", "/app-shell/admin/users?smart_folder_id=5")
      expect(screen.getByText("More")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/users?gh_rate=low",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreMedia()
    }
  })

  it("shows an update button for admin user saved folder filter drift", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () =>
      jsonResponse(
        adminUsersPayloadWithSavedFolder({
          and: [{ field: "admin", op: "is", value: true }]
        })
      )
    )

    try {
      renderAppAt("/app-shell/admin/users?smart_folder_id=12&q=dGVzdA")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Low rate users"))
      expect(screen.getByRole("button", { name: "Update Low rate users" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the save form for admin user filters with no active folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const payload = adminUsersPayloadWithSavedFolder(currentAdminUserFilter())
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () =>
      jsonResponse({
        ...payload,
        active_smart_folder_id: null,
        smart_folders: payload.smart_folders.map((folder) => ({ ...folder, active: false }))
      })
    )

    try {
      renderAppAt("/app-shell/admin/users")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("All users"))
      expect(screen.queryByRole("button", { name: "Update Low rate users" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("keeps an admin user saved folder active when applying filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname === "/api/v1/app/admin/users") {
        return Promise.resolve(jsonResponse(adminUsersPayloadFromSearch(url.searchParams)))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
    })

    try {
      renderAppAt("/app-shell/admin/users?smart_folder_id=12")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Low rate users"))
      expect(screen.queryByRole("button", { name: "Update Low rate users" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: /GH rate is Low/ }))
      fireEvent.change(screen.getByLabelText("Value"), { target: { value: "exhausted" } })

      await waitFor(() => {
        expect(
          fetchSpy.mock.calls.some(([path]) => {
            const url = new URL(String(path), "http://example.test")
            return url.pathname === "/api/v1/app/admin/users" && url.searchParams.get("smart_folder_id") === "12" && url.searchParams.has("q")
          })
        ).toBe(true)
      })
      expect(await screen.findByRole("button", { name: "Update Low rate users" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the update button for admin user saved folder matching filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async () => jsonResponse(adminUsersPayloadWithSavedFolder(currentAdminUserFilter())))

    try {
      renderAppAt("/app-shell/admin/users?smart_folder_id=12")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(mobileFiltersSummary("Low rate users"))
      expect(screen.queryByRole("button", { name: "Update Low rate users" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })
})
