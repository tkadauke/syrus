import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import {
  dashboardEpicItem,
  dashboardJobItem,
  dashboardPayload,
  dashboardResponse,
  expectDashboardFetch,
  mockDashboardFetch
} from "../test/app/dashboardPayloads"
import { expectRunningPill } from "../test/app/jobPayloads"
import { mockClipboardWrite } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App dashboard Kanban", () => {
  installAppTestLifecycle()

  it("renders app-shell dashboard kanban lanes from the app dashboard API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Dashboard preferences updated.",
              dashboard_preferences: {}
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
              view: "kanban",
              total: 1,
              lanes: [
                { key: "queued", title: "Queued", count: 0, items: [] },
                { key: "running", title: "Running", count: 1, items: [dashboardJobItem()] },
                { key: "succeeded", title: "Succeeded", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Running" })).toBeInTheDocument()
    expect(screen.getByText("Repair aqueduct")).toBeInTheDocument()
    expect(screen.getByText("Repair aqueduct").closest(".select-none")).toBeInTheDocument()
    expectRunningPill(screen.getByText("running"))
    expect(screen.getByLabelText("Active workflow trigger: rebase")).toHaveTextContent("rebase")
    expect(screen.getByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/42")
    expect(screen.getByRole("link", { name: "PR #34" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/34")
    expect(screen.queryByText(/Showing/)).not.toBeInTheDocument()
    expectDashboardFetch(
      fetchSpy,
      "/api/v1/app/dashboard?view=kanban&subject=job",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )

    const lanesButton = screen.getByRole("button", { name: "Kanban lanes" })
    expect(lanesButton).toHaveClass("h-[var(--control-height-md)]", "w-[var(--control-height-md)]")
    expect(lanesButton).not.toHaveTextContent("Kanban lanes")
    expect(screen.queryByRole("group", { name: "Kanban lanes" })).not.toBeInTheDocument()
    fireEvent.click(lanesButton)
    expect(screen.getByRole("group", { name: "Kanban lanes" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("group", { name: "Kanban lanes" })).not.toBeInTheDocument()
    fireEvent.click(lanesButton)
    expect(screen.getByRole("group", { name: "Kanban lanes" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("group", { name: "Kanban lanes" })).not.toBeInTheDocument()
    fireEvent.click(lanesButton)
    expect(screen.getByRole("group", { name: "Kanban lanes" })).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText("Succeeded"))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/preferences",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            subject: "job",
            kanban_lanes: ["queued", "running"]
          })
        })
      )
    })
  })

  it("limits Kanban lanes to 20 cards and loads more on demand", async () => {
    const runningJobs = Array.from({ length: 25 }, (_, index) =>
      dashboardJobItem({
        id: index + 1,
        title: `Repair aqueduct ${index + 1}`,
        paths: { job_path: `/jobs/${index + 1}`, source_path: `/jobs/${index + 1}/source` }
      })
    )

    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "kanban",
        total: 25,
        lanes: [
          { key: "queued", title: "Queued", count: 0, items: [] },
          { key: "running", title: "Running", count: 25, items: runningJobs },
          { key: "succeeded", title: "Succeeded", count: 0, items: [] }
        ],
        kanban_limit: 100
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Repair aqueduct 20" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Repair aqueduct 21" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load more Running" }))

    expect(screen.getByRole("link", { name: "Repair aqueduct 21" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repair aqueduct 25" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Load more Running" })).not.toBeInTheDocument()
  })

  it("loads another server-backed Kanban lane page without replacing other lanes", async () => {
    const firstPageJobs = Array.from({ length: 20 }, (_, index) =>
      dashboardJobItem({
        id: index + 1,
        title: `Repair aqueduct ${index + 1}`,
        paths: { job_path: `/jobs/${index + 1}`, source_path: `/jobs/${index + 1}/source` }
      })
    )
    const nextPageJob = dashboardJobItem({
      id: 21,
      title: "Repair aqueduct 21",
      paths: { job_path: "/jobs/21", source_path: "/jobs/21/source" }
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      const isLaneFetch = url.searchParams.get("kanban_lane") === "running"
      const payload = dashboardPayload({
        subject: "job",
        view: "kanban",
        total: 22,
        lanes: isLaneFetch
          ? [
              { key: "queued", title: "Queued", count: 1, items: [dashboardJobItem({ id: 99, title: "Server stale queued" })] },
              { key: "running", title: "Running", count: 21, total_count: 21, loaded_count: 21, has_more: false, next_offset: 21, items: [nextPageJob] },
              { key: "succeeded", title: "Succeeded", count: 0, items: [] }
            ]
          : [
              { key: "queued", title: "Queued", count: 1, items: [dashboardJobItem({ id: 98, title: "Keep queued card" })] },
              { key: "running", title: "Running", count: 21, total_count: 21, loaded_count: 20, has_more: true, next_offset: 20, items: firstPageJobs },
              { key: "succeeded", title: "Succeeded", count: 0, items: [] }
            ],
        kanban_limit: 100
      })

      return Promise.resolve(dashboardResponse(payload, input))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=kanban&smart_folder_id=7&scope=mine"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Repair aqueduct 20" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Keep queued card" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load more Running" }))

    expect(await screen.findByRole("link", { name: "Repair aqueduct 21" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Keep queued card" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Server stale queued" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/dashboard?view=kanban&smart_folder_id=7&scope=mine&subject=job&kanban_lane=running&kanban_offset=20&section=rows",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("shows a needs attention badge on stuck Epic kanban cards", async () => {
    mockDashboardFetch(
      dashboardPayload({
        subject: "epic",
        view: "kanban",
        preferences: {
          sort: { column: "updated_at", direction: "desc" },
          visible_columns: ["epic", "state", "repository", "updated"],
          kanban_lanes: ["in_progress"]
        },
        controls: {
          ...dashboardPayload().controls,
          sort_columns: ["title", "state", "repository", "updated_at"],
          kanban_lanes: [{ key: "in_progress", title: "In progress" }]
        },
        lanes: [
          {
            key: "in_progress",
            title: "In progress",
            count: 1,
            items: [dashboardEpicItem({ state: "in_progress", stuck: true, landed_jobs_count: 0 })]
          }
        ],
        kanban_limit: 100
      })
    )
    const clipboardWrite = mockClipboardWrite()

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const copySlugButton = within(card).getByRole("button", { name: "Copy EPIC-7 to clipboard" })
    expect(copySlugButton).toHaveTextContent("EPIC-7")
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("EPIC-7"))
    const badge = within(card).getByText("Needs attention")
    expect(badge).toHaveAttribute("title", "All jobs closed - mark this epic done or file a follow-up.")
  })

  it("hides the needs attention badge on non-stuck Epic kanban cards", async () => {
    mockDashboardFetch(
      dashboardPayload({
        subject: "epic",
        view: "kanban",
        preferences: {
          sort: { column: "updated_at", direction: "desc" },
          visible_columns: ["epic", "state", "repository", "updated"],
          kanban_lanes: ["in_progress"]
        },
        controls: {
          ...dashboardPayload().controls,
          sort_columns: ["title", "state", "repository", "updated_at"],
          kanban_lanes: [{ key: "in_progress", title: "In progress" }]
        },
        lanes: [
          {
            key: "in_progress",
            title: "In progress",
            count: 1,
            items: [dashboardEpicItem({ state: "in_progress", stuck: false, landed_jobs_count: 0 })]
          }
        ],
        kanban_limit: 100
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    expect(within(card).queryByText("Needs attention")).not.toBeInTheDocument()
  })

  it("renders backlog job kanban cards with source, age, dependencies, and actions", async () => {
    const backloggedJob = dashboardJobItem({
      id: 88,
      kind: "direct",
      title: "Backlog dashboard lane",
      state: "backlog",
      summary_state: "backlog",
      priority: "high",
      issue_number: null,
      issue_url: null,
      pr_number: null,
      pr_url: null,
      active_workflow_trigger_kind: null,
      latest_workflow_id: null,
      latest_workflow_trigger_kind: null,
      latest_workflow_state: "backlog",
      workflows_count: 0,
      dependencies: [
        {
          id: 4,
          slug: "JOB-41",
          state: "queued",
          pending: false,
          succeeded: false
        }
      ],
      unsatisfied_dependency_count: 1,
      bulk_actions: { release_from_backlog: true },
      paths: {
        job_path: "/jobs/88"
      }
    })
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "kanban",
        total: 1,
        preferences: {
          ...dashboardPayload().preferences,
          kanban_lanes: ["backlog"]
        },
        controls: {
          ...dashboardPayload().controls,
          kanban_lanes: [{ key: "backlog", title: "Backlog" }]
        },
        lanes: [{ key: "backlog", title: "Backlog", count: 1, items: [backloggedJob] }],
        kanban_limit: 25
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const title = await screen.findByRole("link", { name: "Backlog dashboard lane" })
    const card = title.closest("article")
    expect(card).not.toBeNull()
    expect(within(card!).getByText("acme/widgets")).toBeInTheDocument()
    expect(within(card!).getByText("High")).toBeInTheDocument()
    expect(within(card!).getByText("Direct")).toBeInTheDocument()
    expect(within(card!).getByText("1/1 dependencies blocked")).toBeInTheDocument()
    expect(card!.querySelector("time")).toHaveAttribute("datetime", "2026-05-30T10:00:00Z")
    expect(within(card!).getByRole("button", { name: "Start" })).toBeInTheDocument()
  })

  it("moves Epic kanban cards with drag and drop", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated." }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 1,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["backlog", "ready", "in_progress"]
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "backlog", title: "Backlog" },
                  { key: "ready", title: "Ready" },
                  { key: "in_progress", title: "In progress" }
                ]
              },
              lanes: [
                { key: "backlog", title: "Backlog", count: 0, items: [] },
                { key: "ready", title: "Ready", count: 1, items: [dashboardEpicItem()] },
                { key: "in_progress", title: "In progress", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const targetLane = screen.getByLabelText("In progress lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(card, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/state",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ target_state: "in_progress" })
        })
      )
    })
    expect(await screen.findByRole("status")).toHaveTextContent("Epic updated.")
  })

  it("moves all-closed Epic kanban cards to Done with drag and drop", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated." }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 1,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["in_progress", "done"]
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "in_progress", title: "In progress" },
                  { key: "done", title: "Done" }
                ]
              },
              lanes: [
                { key: "in_progress", title: "In progress", count: 1, items: [dashboardEpicItem({ state: "in_progress", all_jobs_closed: true })] },
                { key: "done", title: "Done", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const targetLane = screen.getByLabelText("Done lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(card, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/state",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ target_state: "done" })
        })
      )
    })
    expect(await screen.findByRole("status")).toHaveTextContent("Epic updated.")
  })

  it("optimistically moves Epic kanban cards and keeps drag enabled while updates are pending", async () => {
    let resolvePatch: (response: Response) => void = () => {}
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return new Promise((resolve) => {
          resolvePatch = resolve
        })
      }

      if (path === "/api/v1/app/epics/8/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated." }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 2,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["ready", "in_progress"]
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "ready", title: "Ready" },
                  { key: "in_progress", title: "In progress" }
                ]
              },
              lanes: [
                {
                  key: "ready",
                  title: "Ready",
                  count: 2,
                  items: [
                    dashboardEpicItem(),
                    dashboardEpicItem({
                      id: 8,
                      number: 8,
                      display_number: "EPIC-8",
                      title: "Raise the basilica",
                      paths: {
                        epic_path: "/epics/8",
                        edit_epic_path: "/epics/8/edit",
                        app_state_path: "/api/v1/app/epics/8/state"
                      }
                    })
                  ]
                },
                { key: "in_progress", title: "In progress", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const firstCard = await screen.findByLabelText("EPIC-7 Raise the forum")
    const targetLane = screen.getByLabelText("In progress lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(firstCard, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    expect(within(targetLane).getByRole("link", { name: "Raise the forum" })).toBeInTheDocument()

    const secondCard = screen.getByLabelText("EPIC-8 Raise the basilica")
    fireEvent.dragStart(secondCard, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/8/state",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ target_state: "in_progress" })
        })
      )
    })
    expect(within(targetLane).getByRole("link", { name: "Raise the basilica" })).toBeInTheDocument()

    resolvePatch(
      new Response(JSON.stringify({ message: "Epic updated." }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )
  })

  it("rolls optimistic Epic kanban moves back when the update fails", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ error: { message: "The senate objected." } }), {
            status: 422,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 1,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["ready", "in_progress"]
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "ready", title: "Ready" },
                  { key: "in_progress", title: "In progress" }
                ]
              },
              lanes: [
                { key: "ready", title: "Ready", count: 1, items: [dashboardEpicItem()] },
                { key: "in_progress", title: "In progress", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const readyLane = screen.getByLabelText("Ready lane")
    const targetLane = screen.getByLabelText("In progress lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(card, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    expect(within(targetLane).getByRole("link", { name: "Raise the forum" })).toBeInTheDocument()
    expect(await screen.findByRole("alert")).toHaveTextContent("The senate objected.")

    await waitFor(() => {
      expect(within(readyLane).getByRole("link", { name: "Raise the forum" })).toBeInTheDocument()
    })
    expect(within(targetLane).queryByRole("link", { name: "Raise the forum" })).not.toBeInTheDocument()
  })

  it("renders Epic kanban cards without overflow-hidden on the draggable article", async () => {
    const payload = dashboardPayload({
      subject: "epic",
      view: "kanban",
      total: 1,
      preferences: {
        sort: { column: "updated_at", direction: "desc" },
        visible_columns: ["epic", "state", "repository", "updated"],
        kanban_lanes: ["ready"]
      },
      controls: {
        ...dashboardPayload().controls,
        sort_columns: ["title", "state", "repository", "updated_at"],
        kanban_lanes: [{ key: "ready", title: "Ready" }]
      },
      lanes: [{ key: "ready", title: "Ready", count: 1, items: [dashboardEpicItem()] }],
      kanban_limit: 100
    })
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    // overflow-hidden on a draggable element prevents the browser's drag ghost image from
    // following the cursor, making the card appear stuck during drag (regression: bc93acd1)
    expect(card.className).not.toContain("overflow-hidden")
  })
})
