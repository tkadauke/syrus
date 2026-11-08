import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { bootstrapPayload } from "../test/app/bootstrap"
import { dashboardJobItem, dashboardPayload, dashboardResponse, mockDashboardFetch } from "../test/app/dashboardPayloads"
import { mockClipboardWrite, mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App dashboard landing queue", () => {
  installAppTestLifecycle()

  it("toggles landing queue pause from the React dashboard", async () => {
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
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/dashboard/landing_pause" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Landing paused.",
              landing_paused: true
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: 7,
              smart_folders: [
                {
                  id: 7,
                  name: "Landing queue",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "when_present",
                  count: 0,
                  active: true,
                  path: "/dashboard/jobs?smart_folder_id=7"
                }
              ],
              landing_queue: {
                visible: true,
                paused: false,
                toggle_path: "/api/v1/app/dashboard/landing_pause"
              },
              controls: {
                ...dashboardPayload().controls,
                columns: {
                  required: [
                    { key: "checkbox", title: "Checkbox" },
                    { key: "landing_queue_position", title: "Queue" },
                    { key: "issue", title: "Issue" }
                  ],
                  optional: dashboardPayload().controls.columns.optional
                }
              },
              items: [dashboardJobItem({ landing_queue_position: 3 })]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByRole("button", { name: "Pause landing" }))
      const confirmDialog = await screen.findByRole("dialog", { name: "Pause the landing queue? Approved jobs will stop landing until you resume it." })
      fireEvent.click(within(confirmDialog).getByRole("button", { name: "Pause landing" }))
      expect(screen.getByRole("columnheader", { name: "Queue" })).toBeInTheDocument()
      expect(screen.getByRole("cell", { name: "#3" })).toBeInTheDocument()

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/landing_pause",
          expect.objectContaining({
            method: "POST",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({ confirmed: true })
          })
        )
      })
      expect(await screen.findByText("Landing paused.")).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("renders expandable landing queue blocker rows in dependency order", async () => {
    const restoreMedia = mockMediaQuery(true)
    const clipboardWrite = mockClipboardWrite()
    const payload = dashboardPayload({
      subject: "job",
      view: "list",
      active_smart_folder_id: 7,
      smart_folders: [
        {
          id: 7,
          name: "Landing queue",
          kind: "builtin",
          subject_type: "job",
          visibility: "when_present",
          count: 1,
          active: true,
          attention_preset: "landing_queue",
          path: "/dashboard/jobs?smart_folder_id=7"
        }
      ],
      preferences: {
        ...dashboardPayload().preferences,
        sort: { column: "landing_queue_position", direction: "asc" }
      },
      controls: {
        ...dashboardPayload().controls,
        columns: {
          required: [
            { key: "checkbox", title: "Checkbox" },
            { key: "landing_queue_position", title: "Queue" },
            { key: "issue", title: "Issue" },
            { key: "state", title: "State" }
          ],
          optional: dashboardPayload().controls.columns.optional
        }
      },
      landing_queue: {
        visible: true,
        paused: false,
        toggle_path: "/api/v1/app/dashboard/landing_pause",
        entries: [
          {
            key: "epic:10",
            position: 1,
            job_ids: [1],
            blocker_jobs: [
              {
                id: 2,
                title: "Prepare data layer",
                job_path: "/jobs/2",
                state: "open",
                pr_number: 22,
                pr_path: "https://github.com/acme/widgets/pull/22",
                epic_id: 20,
                epic_title: "Data Layer",
                repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                latest_workflow_state: "running",
                latest_workflow_trigger_kind: "initial",
                latest_workflow_id: 101,
                started_at: "2026-06-01T09:00:00Z",
                created_at: "2026-06-01T08:00:00Z"
              },
              {
                id: 3,
                title: "Document rollout",
                job_path: "/jobs/3",
                state: "open",
                pr_number: null,
                pr_path: null,
                epic_id: null,
                epic_title: null,
                repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                latest_workflow_state: null,
                latest_workflow_trigger_kind: null,
                latest_workflow_id: null,
                started_at: null,
                created_at: "2026-06-01T07:00:00Z"
              }
            ],
            dependency_edges: [
              { from_job_id: 2, to_job_id: 1 },
              { from_job_id: 1, to_job_id: 3 }
            ]
          }
        ]
      },
      items: [
        dashboardJobItem({
          id: 1,
          title: "Land API surface",
          landing_queue_position: 1,
          landing_queue_entry_key: "epic:10",
          epic: { id: 10, number: 10, display_number: "EPIC-10", path: "/epics/10" },
          approved_at: "2026-06-01T10:00:00Z"
        })
      ]
    })
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      if (url.includes("/api/v1/app/jobs/2")) {
        return Promise.resolve(
          jsonResponse({
            job: {
              id: 2,
              state: "open",
              issue_body: "Blocker hover preview body.",
              issue_title: "Prepare data layer",
              title_pending: false,
              start_blocked_reason: null,
              start_blocked_details: null
            }
          })
        )
      }

      return Promise.resolve(dashboardResponse(payload, input))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const expander = await screen.findByRole("button", { name: /2 blockers/ })
      expect(expander).toHaveAttribute("aria-expanded", "false")
      expect(screen.queryByText("Prepare data layer")).not.toBeInTheDocument()
      expect(screen.getByText("Land API surface")).toBeInTheDocument()

      fireEvent.click(expander)

      expect(expander).toHaveAttribute("aria-expanded", "true")
      expect(screen.getByText("Epic: Data Layer")).toBeInTheDocument()
      expect(screen.getByText("standalone")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Prepare data layer" })).toHaveAttribute("href", "/app-shell/jobs/2")
      expect(screen.getByRole("link", { name: "Prepare data layer" }).closest("tr")).toHaveClass("bg-gray-50/70")
      expect(screen.getByText("Prepare data layer").closest("tr")?.textContent).not.toContain("#1")
      const blockerSlugButton = screen.getByRole("button", { name: "Copy JOB-2 to clipboard" })
      expect(blockerSlugButton).toHaveTextContent("JOB-2")
      expect(blockerSlugButton.parentElement?.tagName).toBe("SPAN")
      fireEvent.click(blockerSlugButton)
      await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-2"))
      fireEvent.mouseEnter(blockerSlugButton.parentElement!)
      expect(await screen.findByText("Blocker hover preview body.")).toBeInTheDocument()

      const rowText = Array.from(document.querySelectorAll("tbody tr")).map((row) => row.textContent || "")
      expect(rowText.findIndex((text) => text.includes("Prepare data layer"))).toBeLessThan(rowText.findIndex((text) => text.includes("Land API surface")))
      expect(rowText.findIndex((text) => text.includes("Document rollout"))).toBeGreaterThan(rowText.findIndex((text) => text.includes("Land API surface")))
    } finally {
      restoreMedia()
    }
  })

  it("renders expandable mobile landing queue blockers in dependency order", async () => {
    const restoreMedia = mockMediaQuery(false)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        active_smart_folder_id: 7,
        smart_folders: [
          {
            id: 7,
            name: "Landing queue",
            kind: "builtin",
            subject_type: "job",
            visibility: "when_present",
            count: 1,
            active: true,
            attention_preset: "landing_queue",
            path: "/dashboard/jobs?smart_folder_id=7"
          }
        ],
        preferences: {
          ...dashboardPayload().preferences,
          sort: { column: "landing_queue_position", direction: "asc" }
        },
        landing_queue: {
          visible: true,
          paused: false,
          toggle_path: "/api/v1/app/dashboard/landing_pause",
          entries: [
            {
              key: "epic:10",
              position: 1,
              job_ids: [1],
              blocker_jobs: [
                {
                  id: 2,
                  title: "Prepare data layer",
                  job_path: "/jobs/2",
                  state: "open",
                  pr_number: 22,
                  pr_path: "https://github.com/acme/widgets/pull/22",
                  epic_id: 20,
                  epic_title: "Data Layer",
                  repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                  latest_workflow_state: "running",
                  latest_workflow_trigger_kind: "initial",
                  latest_workflow_id: 101,
                  started_at: "2026-06-01T09:00:00Z",
                  created_at: "2026-06-01T08:00:00Z"
                },
                {
                  id: 3,
                  title: "Document rollout",
                  job_path: "/jobs/3",
                  state: "open",
                  pr_number: null,
                  pr_path: null,
                  epic_id: null,
                  epic_title: null,
                  repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                  latest_workflow_state: null,
                  latest_workflow_trigger_kind: null,
                  latest_workflow_id: null,
                  started_at: null,
                  created_at: "2026-06-01T07:00:00Z"
                }
              ],
              dependency_edges: [
                { from_job_id: 2, to_job_id: 1 },
                { from_job_id: 1, to_job_id: 3 }
              ]
            }
          ]
        },
        items: [
          dashboardJobItem({
            id: 1,
            title: "Land API surface",
            landing_queue_position: 1,
            landing_queue_entry_key: "epic:10",
            epic: { id: 10, number: 10, display_number: "EPIC-10", path: "/epics/10" },
            approved_at: "2026-06-01T10:00:00Z"
          })
        ]
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const expander = await screen.findByRole("button", { name: /2 blockers/ })
      expect(expander).toHaveAttribute("aria-expanded", "false")
      expect(screen.queryByText("Prepare data layer")).not.toBeInTheDocument()
      expect(screen.getByRole("article", { name: "Land API surface" })).toBeInTheDocument()

      fireEvent.click(expander)

      expect(expander).toHaveAttribute("aria-expanded", "true")
      expect(screen.getByText("Epic: Data Layer")).toBeInTheDocument()
      expect(screen.getByText("standalone")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Prepare data layer" })).toHaveAttribute("href", "/app-shell/jobs/2")
      expect(screen.getByRole("link", { name: "PR #22" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/22")

      const rowText = Array.from(document.querySelectorAll("article")).map((row) => row.textContent || "")
      expect(rowText.findIndex((text) => text.includes("Prepare data layer"))).toBeLessThan(rowText.findIndex((text) => text.includes("Land API surface")))
      expect(rowText.findIndex((text) => text.includes("Document rollout"))).toBeGreaterThan(rowText.findIndex((text) => text.includes("Land API surface")))
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("hides landing queue blocker expanders when not sorted by queue position", async () => {
    const restoreMedia = mockMediaQuery(true)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        preferences: {
          ...dashboardPayload().preferences,
          sort: { column: "title", direction: "asc" }
        },
        landing_queue: {
          visible: true,
          paused: false,
          toggle_path: "/api/v1/app/dashboard/landing_pause",
          entries: [
            {
              key: "job:1",
              position: 1,
              job_ids: [1],
              blocker_jobs: [
                {
                  id: 2,
                  title: "Hidden blocker",
                  job_path: "/jobs/2",
                  state: "open",
                  pr_number: null,
                  pr_path: null,
                  repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                  latest_workflow_state: null,
                  latest_workflow_trigger_kind: null,
                  latest_workflow_id: null,
                  started_at: null,
                  created_at: "2026-06-01T07:00:00Z"
                }
              ],
              dependency_edges: [{ from_job_id: 2, to_job_id: 1 }]
            }
          ]
        },
        items: [
          dashboardJobItem({
            id: 1,
            title: "Visible approved job",
            landing_queue_position: 1,
            landing_queue_entry_key: "job:1",
            approved_at: "2026-06-01T10:00:00Z"
          })
        ]
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Visible approved job")).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: /blocker/ })).not.toBeInTheDocument()
      expect(screen.queryByText("Hidden blocker")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("resets queue sorting outside the landing queue folder", async () => {
    const restoreMedia = mockMediaQuery(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences") {
        expect(init?.method).toBe("PATCH")
        return new Response(JSON.stringify({ message: "Dashboard preferences updated.", dashboard_preferences: {} }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      }

      return new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            active_smart_folder_id: 3,
            preferences: {
              ...dashboardPayload().preferences,
              sort: { column: "landing_queue_position", direction: "asc" }
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "landing_queue_position", "created_at", "started_at"]
            },
            smart_folders: [
              {
                id: 3,
                name: "In progress",
                kind: "builtin",
                subject_type: "job",
                visibility: "when_present",
                count: 2,
                active: true,
                path: "/dashboard/jobs?smart_folder_id=3"
              }
            ],
            landing_queue: {
              visible: false,
              paused: false,
              toggle_path: "/api/v1/app/dashboard/landing_pause"
            },
            items: [
              dashboardJobItem({ id: 1, title: "First job", epic: { id: 10, number: 10, display_number: "#10", path: "/epics/10" } }),
              dashboardJobItem({ id: 2, title: "Second job", epic: { id: 11, number: 11, display_number: "#11", path: "/epics/11" } })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=3"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("First job")).toBeInTheDocument()
      expect(screen.getByText("Second job").closest("tr")).not.toHaveClass("border-t-4")

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/preferences",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({
              subject: "job",
              active_smart_folder_id: 3,
              sort_column: "created_at",
              sort_direction: "desc"
            })
          })
        )
      })
    } finally {
      restoreMedia()
    }
  })
})
