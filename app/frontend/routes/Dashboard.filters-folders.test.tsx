import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { bootstrapPayload } from "../test/app/bootstrap"
import {
  dashboardJobItem,
  dashboardPayload,
  dashboardPayloadPath,
  dashboardResponse,
  decodeFilterQueryParam,
  expectDashboardFetch
} from "../test/app/dashboardPayloads"
import { LocationProbe } from "../test/app/render"
import { mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App dashboard filters and smart folders", () => {
  installAppTestLifecycle()

  it("persists the selected dashboard view when the view toggle is clicked", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Dashboard preferences updated.", dashboard_preferences: {} }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(dashboardPayload({ subject: "job", view: path.includes("view=kanban") ? "kanban" : "list" })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("link", { name: "kanban" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/preferences",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ subject: "job", active_smart_folder_id: null, view: "kanban" })
        })
      )
    })
  })

  it("does not carry the current dashboard view when switching subjects in the v2 sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: { v2_ui: true, v2_sidebar_subject_selector: true }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path.startsWith("/api/v1/app/dashboard")) {
        const subject = path.includes("subject=epic") ? "epic" : "job"
        const view = subject === "epic" ? "kanban" : "list"
        return Promise.resolve(
          new Response(JSON.stringify(dashboardPayload({ subject, view })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
            <App />
            <LocationProbe />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const dashboardSections = await screen.findByRole("navigation", { name: "Dashboard sections" })
      fireEvent.click(within(dashboardSections).getByRole("link", { name: "Jobs" }))

      await waitFor(() => {
        expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/dashboard/jobs")
      })
      expect(screen.getByTestId("location")).not.toHaveTextContent("view=")
      expectDashboardFetch(fetchSpy, "/api/v1/app/dashboard?subject=job", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      script.remove()
    }
  })

  it("persists the selected dashboard smart folder including All jobs", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Dashboard preferences updated.", dashboard_preferences: {} }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              smart_folders: [
                {
                  id: 5,
                  name: "All jobs",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "always",
                  count: 0,
                  active: false,
                  path: "/dashboard/jobs?smart_folder_id=5"
                },
                {
                  id: 7,
                  name: "My work",
                  kind: "user_defined",
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 1,
                  active: false,
                  path: "/dashboard/jobs?smart_folder_id=7"
                }
              ]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByText("Folders and filters"))
      fireEvent.click(screen.getByRole("link", { name: "My work 1" }))
      fireEvent.click(screen.getByRole("link", { name: "All jobs 0" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/preferences",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({ subject: "job", smart_folder_id: 7 })
          })
        )
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/preferences",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({ subject: "job", smart_folder_id: 5 })
          })
        )
      })
    } finally {
      restoreMedia()
    }
  })

  it("renders dashboard smart folder visibility groups and badges", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: { v2_ui: true, v2_sidebar_subject_selector: true }
      })
    )
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      const url = new URL(path, "http://example.test")
      if (dashboardPayloadPath(url)) {
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              active_smart_folder_id: 3,
              smart_folders: [
                {
                  id: 5,
                  name: "All jobs",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "always",
                  count: 1982,
                  active: false,
                  path: "/dashboard/jobs?smart_folder_id=5"
                },
                {
                  id: 1,
                  name: "Inbox",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "always",
                  count: 3,
                  active: false,
                  path: "/dashboard/jobs?smart_folder_id=1"
                },
                {
                  id: 2,
                  name: "Stale",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "on_demand",
                  count: 1,
                  active: false,
                  path: "/dashboard/jobs?smart_folder_id=2"
                },
                {
                  id: 3,
                  name: "Merged this week",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "on_demand",
                  count: 0,
                  active: true,
                  path: "/dashboard/jobs?smart_folder_id=3"
                },
                {
                  id: 4,
                  name: "Saved review",
                  kind: "user_defined",
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 2,
                  active: false,
                  path: "/dashboard/jobs?smart_folder_id=4"
                }
              ],
              filter: { and: [{ field: "attention", op: "is", value: "merged_this_week" }] },
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=3"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const foldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      const primaryNav = screen.getByRole("navigation", { name: "Primary" })
      const dashboardLink = within(primaryNav).getByRole("link", { name: "Dashboard" })
      const dashboardSections = within(primaryNav).getByRole("navigation", { name: "Dashboard sections" })
      const dashboardSubnav = foldersPanel.closest("[aria-hidden]")
      expect(screen.queryByRole("navigation", { name: "Dashboard subjects" })).not.toBeInTheDocument()
      expect(dashboardSubnav).toHaveAttribute("aria-hidden", "false")
      expect(dashboardSections).toHaveClass(
        "inline-flex",
        "max-w-full",
        "flex-wrap",
        "overflow-hidden",
        "rounded",
        "border",
        "border-gray-300",
        "bg-white",
        "dark:border-gray-700",
        "dark:bg-gray-900"
      )
      expect(within(dashboardSections).getByRole("link", { name: "Epics" })).toHaveAttribute("href", "/app-shell/dashboard/epics")
      expect(within(dashboardSections).getByRole("link", { name: "Jobs" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(within(dashboardSections).getByRole("link", { name: "Jobs" })).toHaveClass("bg-brand/10", "text-brand", "ring-brand")
      expect(within(dashboardSections).getByRole("link", { name: "Workflows" })).toHaveAttribute("href", "/app-shell/dashboard/workflows")
      expect(primaryNav).toContainElement(foldersPanel)
      const dashboardNavItem = dashboardLink.closest("[draggable]")!.parentElement
      expect(dashboardNavItem).toContainElement(dashboardSections)
      expect(dashboardNavItem).toContainElement(foldersPanel)
      expect(within(foldersPanel).getByRole("link", { name: "All jobs 1982" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=5")
      expect(within(foldersPanel).getByRole("link", { name: "Inbox 3" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=1")
      const moreGroup = within(foldersPanel).getByText("More").closest("details")
      expect(moreGroup).not.toBeNull()
      expect(within(moreGroup!).queryByRole("link", { name: /All jobs/ })).not.toBeInTheDocument()
      expect(within(moreGroup!).getByRole("link", { name: "Stale 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=2")
      expect(within(moreGroup!).getByRole("link", { name: "Merged this week 0" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=3")
      expect(within(foldersPanel).getAllByRole("link", { name: /All jobs/ })).toHaveLength(1)
      expect(screen.getByRole("button", { name: /Preset.*Merged this week/ })).toBeInTheDocument()
      const savedReviewLink = within(foldersPanel).getByRole("link", { name: "Saved review 2" })
      expect(savedReviewLink).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=4")
      expect(within(foldersPanel).queryByRole("link", { name: "Manage" })).not.toBeInTheDocument()
      expect(within(foldersPanel).queryByLabelText("Folder name")).not.toBeInTheDocument()
      expect(within(foldersPanel).queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
      fireEvent.mouseEnter(savedReviewLink.parentElement!)
      fireEvent.click(within(foldersPanel).getByRole("button", { name: "Actions for Saved review" }))
      const folderMenu = screen.getByRole("menu")
      expect(folderMenu.parentElement).toBe(document.body)
      expect(foldersPanel).not.toContainElement(folderMenu)

      fireEvent.click(dashboardLink)
      expect(dashboardSubnav).toHaveAttribute("aria-hidden", "true")

      fireEvent.click(dashboardLink)
      expect(dashboardSubnav).toHaveAttribute("aria-hidden", "false")
    } finally {
      script.remove()
    }
  })

  it("shows dashboard filter save controls in the v2 sidebar folders once rows are current", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const appliedFilter = { and: [{ field: "state", op: "is", value: "open" }] }
    const savedFilter = { and: [{ field: "kind", op: "is", value: "issue" }] }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/smart_folders" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Smart folder saved.",
              redirect_to: "/dashboard/jobs?smart_folder_id=11",
              smart_folder: { id: 11, name: "Open work", position: 1, filter: appliedFilter }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      const url = new URL(path, "http://example.test")
      if (dashboardPayloadPath(url)) {
        const activeSmartFolder = url.searchParams.get("smart_folder_id") === "7" || url.searchParams.get("section") === "chrome"
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: activeSmartFolder ? 7 : null,
              filter: appliedFilter,
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  kind: "user_defined",
                  position: 2,
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 1,
                  active: activeSmartFolder,
                  filter: savedFilter,
                  path: "/dashboard/jobs?smart_folder_id=7"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7&q=stale"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByRole("heading", { name: "Smart folders" })).not.toBeInTheDocument()
      await waitFor(() => {
        expect(within(smartFoldersPanel).getByLabelText("Folder name")).toBeInTheDocument()
        expect(within(smartFoldersPanel).getByRole("button", { name: "Update My work" })).toBeInTheDocument()
        expect(within(smartFoldersPanel).getByRole("button", { name: "Save folder" })).toBeInTheDocument()
      })
      expect(fetchSpy.mock.calls.some(([input, init]) => String(input) === "/api/v1/app/smart_folders" && init?.method === "POST")).toBe(false)
    } finally {
      script.remove()
    }
  })

  it("shows update and save actions in the sidebar when the active saved dashboard folder filter differs", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        feature_flags: { v2_ui: true }
      })
    )
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      const url = new URL(path, "http://example.test")
      if (dashboardPayloadPath(url)) {
        const hasSmartFolder = url.searchParams.get("smart_folder_id") === "7"
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: hasSmartFolder ? 7 : null,
              filter: { and: [{ field: "kind", op: "is", value: "issue" }] },
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  kind: "user_defined",
                  position: 2,
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 1,
                  active: hasSmartFolder,
                  filter: { and: [{ field: "state", op: "is", value: "open" }] },
                  path: "/dashboard/jobs?view=list&smart_folder_id=7"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      await waitFor(() => {
        expect(within(smartFoldersPanel).getByRole("button", { name: "Update My work" })).toBeInTheDocument()
        expect(within(smartFoldersPanel).getByRole("button", { name: "Save folder" })).toBeInTheDocument()
      })
    } finally {
      script.remove()
    }
  })

  it("hides update and save actions when the active saved dashboard folder filter matches", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        feature_flags: { v2_ui: true }
      })
    )
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      const url = new URL(path, "http://example.test")
      if (dashboardPayloadPath(url)) {
        const hasSmartFolder = url.searchParams.get("smart_folder_id") === "7"
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: hasSmartFolder ? 7 : null,
              filter: { and: [{ field: "state", op: "is", value: "open" }] },
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  kind: "user_defined",
                  position: 2,
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 1,
                  active: hasSmartFolder,
                  filter: { and: [{ field: "state", op: "is", value: "open" }] },
                  path: "/dashboard/jobs?view=list&smart_folder_id=7"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByRole("button", { name: "Update My work" })).not.toBeInTheDocument()
      expect(within(smartFoldersPanel).queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("preserves the active smart folder while dashboard filters change", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        feature_flags: { v2_ui: true }
      })
    )
    document.body.appendChild(script)
    const storedFilter = { and: [{ field: "state", op: "is", value: "open" }] }
    const dashboardRequests: string[] = []
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/filters/usage" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Recorded." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      const url = new URL(path, "http://example.test")
      if (
        dashboardPayloadPath(url) &&
        (url.pathname.endsWith("/controls") || url.searchParams.get("smart_folder_id") === "7" || url.searchParams.get("section") === "chrome")
      ) {
        if (url.searchParams.get("section") !== "chrome") dashboardRequests.push(path)
        const q = url.searchParams.get("q")
        const filter = q ? decodeFilterQueryParam(q) : storedFilter
        const hasSmartFolder = url.searchParams.get("smart_folder_id") === "7"
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: hasSmartFolder ? 7 : null,
              filter,
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  kind: "user_defined",
                  position: 2,
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 1,
                  active: hasSmartFolder,
                  filter: storedFilter,
                  path: "/dashboard/jobs?view=list&smart_folder_id=7"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByRole("button", { name: "Update My work" })).not.toBeInTheDocument()

      fireEvent.click(await screen.findByRole("button", { name: "+ Add filter" }))
      fireEvent.click(screen.getByRole("button", { name: "Kind list" }))

      await waitFor(() => {
        expect(
          dashboardRequests.some((request) => {
            const url = new URL(request, "http://example.test")
            return url.searchParams.get("smart_folder_id") === "7" && url.searchParams.has("q")
          })
        ).toBe(true)
      })
      expect(within(smartFoldersPanel).getByRole("button", { name: "Update My work" })).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      fireEvent.click(screen.getByRole("button", { name: "Has parent yes/no" }))

      await waitFor(() => {
        const latestRequest = dashboardRequests.at(-1)
        expect(latestRequest).toBeTruthy()
        const url = new URL(latestRequest!, "http://example.test")
        const qTree = decodeFilterQueryParam(url.searchParams.get("q")!)
        expect(qTree.and.filter((chip) => chip.field === "state")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "kind")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "has_parent")).toHaveLength(1)
      })
    } finally {
      script.remove()
    }
  })

  it("clears built-in dashboard folder navigation when applying filters", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        feature_flags: { v2_ui: true }
      })
    )
    document.body.appendChild(script)
    const dashboardRequests: string[] = []
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/filters/usage" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Recorded." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      const url = new URL(path, "http://example.test")
      if (dashboardPayloadPath(url)) {
        if (url.searchParams.get("section") !== "chrome") dashboardRequests.push(path)
        const hasSmartFolder = url.searchParams.get("smart_folder_id") === "1"
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: hasSmartFolder ? 1 : null,
              filter: url.searchParams.get("q")
                ? decodeFilterQueryParam(url.searchParams.get("q")!)
                : {
                    and: [
                      { field: "attention", op: "is", value: "inbox" },
                      { field: "job_type", op: "is", value: "user" },
                      { field: "eligible_approver", op: "is", value: "me" }
                    ]
                  },
              smart_folders: [
                {
                  id: 1,
                  name: "Inbox",
                  kind: "builtin",
                  position: 0,
                  subject_type: "job",
                  visibility: "primary",
                  count: 1,
                  active: hasSmartFolder,
                  filter: {
                    and: [
                      { field: "attention", op: "is", value: "inbox" },
                      { field: "job_type", op: "is", value: "user" },
                      { field: "eligible_approver", op: "is", value: "me" }
                    ]
                  },
                  path: "/dashboard/jobs?view=list&smart_folder_id=1"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=1"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByLabelText("Folder name")).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Preset is Inbox" })).toBeInTheDocument()

      fireEvent.click(await screen.findByRole("button", { name: "+ Add filter" }))
      fireEvent.click(screen.getByRole("button", { name: "Kind list" }))

      await waitFor(() => {
        const latestRequest = dashboardRequests.at(-1)
        expect(latestRequest).toBeTruthy()
        const url = new URL(latestRequest!, "http://example.test")
        expect(url.searchParams.has("q")).toBe(true)
        expect(url.searchParams.has("smart_folder_id")).toBe(false)
        const qTree = decodeFilterQueryParam(url.searchParams.get("q")!)
        expect(qTree.and.filter((chip) => chip.field === "attention")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "job_type")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "eligible_approver")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "kind")).toHaveLength(1)
      })
      expect(within(smartFoldersPanel).getByLabelText("Folder name")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Preset is Inbox" })).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("updates the active saved dashboard folder with the applied filter", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        feature_flags: { v2_ui: true }
      })
    )
    document.body.appendChild(script)
    const storedFilter = { and: [{ field: "state", op: "is", value: "open" }] }
    const appliedFilter = { and: [{ field: "kind", op: "is", value: "issue" }] }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/smart_folders/7" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              subject_type: "job",
              subject_label: "Job",
              dashboard_path: "/dashboard/jobs",
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  position: 2,
                  filter: appliedFilter
                }
              ],
              message: "Smart folder updated."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      const url = new URL(path, "http://example.test")
      if (
        dashboardPayloadPath(url) &&
        (url.pathname.endsWith("/controls") || url.searchParams.get("smart_folder_id") === "7" || url.searchParams.get("section") === "chrome")
      ) {
        const hasSmartFolder = url.searchParams.get("smart_folder_id") === "7"
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: hasSmartFolder ? 7 : null,
              filter: appliedFilter,
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  kind: "user_defined",
                  position: 2,
                  subject_type: "job",
                  visibility: "user_defined",
                  count: 1,
                  active: hasSmartFolder,
                  filter: storedFilter,
                  path: "/dashboard/jobs?view=list&smart_folder_id=7"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7&q=stale"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      await waitFor(() => {
        expect(within(smartFoldersPanel).getByRole("button", { name: "Save folder" })).toBeInTheDocument()
        expect(within(smartFoldersPanel).getByRole("button", { name: "Update My work" })).toBeInTheDocument()
      })
      fireEvent.click(within(smartFoldersPanel).getByRole("button", { name: "Update My work" }))
      await waitFor(() => {
        expect(fetchSpy.mock.calls.some(([input, init]) => String(input) === "/api/v1/app/smart_folders/7" && init?.method === "PATCH")).toBe(true)
      })
    } finally {
      script.remove()
    }
  })
})
