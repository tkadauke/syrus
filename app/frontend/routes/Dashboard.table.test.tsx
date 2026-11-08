import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import * as useConfirmModule from "../hooks/useConfirm"
import { bootstrapPayload, setupStatus, setupStatusPayload } from "../test/app/bootstrap"
import {
  dashboardEpicItem,
  dashboardJobItem,
  dashboardPathMatches,
  dashboardPathStartsWith,
  dashboardPayload,
  dashboardWorkflowItem,
  decodeFilterQ,
  expectDashboardFetch,
  mockDashboardFetch,
  mockDashboardFetchWithChatPreview
} from "../test/app/dashboardPayloads"
import { expectRunningPill } from "../test/app/jobPayloads"
import { renderAppAt } from "../test/app/render"
import { mockClipboardWrite, mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App dashboard tables", () => {
  installAppTestLifecycle()

  it("renders the app-shell dashboard route from the app dashboard API", async () => {
    let sortColumn = "title"
    let sortDirection = "desc"
    let latestFilterTree: unknown = null
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        const body = JSON.parse(String(init.body)) as { sort_column: string; sort_direction: string }
        sortColumn = body.sort_column
        sortDirection = body.sort_direction

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

      if (path === "/api/v1/app/dashboard/jobs/bulk" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Retry enqueued for 1 job.",
              action: "retry",
              affected_job_ids: [42],
              skipped_job_ids: []
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (path === "/api/v1/app/smart_folders" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Smart folder saved.",
              redirect_to: "/dashboard/jobs?smart_folder_id=11",
              smart_folder: { id: 11, name: "Open work", position: 1, filter: { and: [{ field: "state", op: "is", value: "open" }] } }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (
        dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job") ||
        dashboardPathStartsWith(path, "/api/v1/app/dashboard?view=list&q=") ||
        dashboardPathMatches(path, "/api/v1/app/dashboard?smart_folder_id=11&subject=job")
      ) {
        const q = new URL(path, "https://syrus.test").searchParams.get("q")
        if (q) latestFilterTree = decodeFilterQ(q)

        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                filter: latestFilterTree || { and: [] },
                page: 2,
                per_page: 10,
                total: 25,
                total_pages: 3,
                preferences: {
                  sort: { column: sortColumn, direction: sortDirection },
                  visible_columns: ["checkbox", "issue", "state", "repository", "owner", "latest", "workflows_count", "started"],
                  kanban_lanes: ["queued", "running", "succeeded"]
                },
                items: [
                  dashboardJobItem({
                    retry_state: {
                      classification: "git_failure",
                      classification_label: "Git failure",
                      retryable: false,
                      next_auto_retry_at: null,
                      retry_attempt_count: 1,
                      retry_budget_remaining: 0,
                      retry_budget: 3,
                      auto_retry_exhausted: true,
                      provider_circuit_open: false,
                      retry_delayed_until: null,
                      retry_delay_reason: null,
                      state_label: "Auto-Retry Exhausted"
                    },
                    bulk_actions: {
                      retry: true,
                      claim: true,
                      close: true
                    }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Repair aqueduct")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Dashboard" })).toHaveClass("max-w-[96rem]")
    expect(screen.queryByText("25 jobs in this view")).not.toBeInTheDocument()
    const dashboardHeader = screen.getByRole("heading", { name: "Dashboard" }).closest("header")
    expect(dashboardHeader).not.toHaveClass("border-b")
    expect(dashboardHeader).toHaveClass("flex", "flex-wrap", "items-center", "gap-3")
    expect(screen.getByRole("navigation", { name: "Dashboard view" }).closest("header")).toBe(dashboardHeader)
    expect(screen.getByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/42")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("target", "_blank")
    expect(screen.getByRole("link", { name: "PR #34" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/34")
    expect(screen.getByRole("link", { name: "PR #34" })).toHaveAttribute("target", "_blank")
    expect(document.querySelectorAll("[data-status-pill='true']")).toHaveLength(3)
    const retryLabel = screen.getByText("Auto-Retry Exhausted")
    expect(retryLabel.closest("[data-status-pill='true']")).toHaveClass("rounded-[var(--radius-pill)]", "ring-1")
    expect(screen.getAllByRole("link", { name: "acme/widgets" }).some((link) => link.getAttribute("href") === "/app-shell/repositories/3")).toBe(true)
    expect(screen.getAllByText("acme/widgets").length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "Operator" })).toHaveAttribute("href", "/app-shell/profiles/1")
    expect(screen.getByRole("link", { name: "kanban" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=kanban")
    expect(screen.getByRole("link", { name: "New Epic" })).toHaveAttribute("href", "/app-shell/epics/new")
    expect(screen.getByRole("link", { name: "New Epic" })).toHaveClass("bg-brand", "text-on-brand")
    expect(screen.getByRole("link", { name: "New Job" })).toHaveAttribute("href", "/app-shell/jobs/new")
    expect(screen.getByRole("link", { name: "New Job" })).toHaveClass("bg-success", "text-white")
    expect(screen.queryByText("0 selected")).not.toBeInTheDocument()
    expect(screen.queryByText(/Sorted by/)).not.toBeInTheDocument()
    expect(within(screen.getByRole("button", { name: "Sort by Issue ascending" })).getByText("↓")).toBeInTheDocument()
    const stateCell = screen.getByRole("cell", { name: "open" })
    expect(stateCell).toBeInTheDocument()
    expect(stateCell).not.toHaveTextContent(/rebase|running/i)
    const latestWorkflowCell = screen.getByRole("cell", { name: "Latest workflow: rebase running" })
    expect(latestWorkflowCell).toBeInTheDocument()
    const latestWorkflowTrigger = within(latestWorkflowCell).getByLabelText("Latest workflow trigger: rebase")
    expect(latestWorkflowTrigger).toHaveClass("rounded-full", "ring-1", "bg-gray-100")
    expect(latestWorkflowCell).toHaveTextContent(/rebase.*running/i)
    const latestWorkflowStatus = within(latestWorkflowCell).getByText("running").closest("[data-status-pill='true']")
    expect(latestWorkflowStatus).toBeInTheDocument()
    expect(latestWorkflowTrigger.parentElement).toHaveClass("flex-col", "items-start")
    expect(latestWorkflowStatus?.parentElement).toBe(latestWorkflowTrigger.parentElement)
    expect(screen.getByText("Showing 11-20 of 25")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&page=1")
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&page=3")
    expectDashboardFetch(
      fetchSpy,
      "/api/v1/app/dashboard?view=list&subject=job",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        signal: expect.any(AbortSignal)
      })
    )

    fireEvent.click(screen.getByLabelText("Select Repair aqueduct"))
    fireEvent.click(screen.getByRole("button", { name: "Claim work" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/jobs/bulk",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ job_ids: [42], bulk_action: "claim" })
        })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByPlaceholderText("Search filters...")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByPlaceholderText("Search filters...")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "state" } })
    fireEvent.click(screen.getByRole("button", { name: "State list" }))
    expect(await screen.findByRole("dialog", { name: "State filter settings" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Apply filter" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Done" })).not.toBeInTheDocument()

    await waitFor(() => {
      expect(latestFilterTree).toEqual({ and: [{ field: "state", op: "is", value: "open" }] })
    })
    fireEvent.change(screen.getByLabelText("Value"), { target: { value: "closed" } })
    await waitFor(() => {
      expect(latestFilterTree).toEqual({ and: [{ field: "state", op: "is", value: "closed" }] })
    })
    expect(screen.getByRole("button", { name: "Wrap in NOT" })).toHaveTextContent("¬")
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringMatching(/^\/api\/v1\/app\/dashboard\?view=list&q=/),
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
    expect(await screen.findByRole("link", { name: "Clear filters" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list")

    fireEvent.click(await screen.findByRole("button", { name: "+ OR alternative" }))
    expect(screen.queryByRole("dialog", { name: "State filter settings" })).not.toBeInTheDocument()
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "State list" }))

    await waitFor(() => {
      expect(latestFilterTree).toEqual({
        and: [
          {
            or: [
              { field: "state", op: "is", value: "closed" },
              { field: "state", op: "is", value: "open" }
            ]
          }
        ]
      })
    })
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "parent" } })
    fireEvent.click(screen.getByRole("button", { name: "Has parent yes/no" }))
    await waitFor(() => {
      expect(latestFilterTree).toEqual({
        and: [
          {
            or: [
              { field: "state", op: "is", value: "closed" },
              { field: "state", op: "is", value: "open" }
            ]
          },
          { field: "has_parent", op: "is_true", value: null }
        ]
      })
    })
    fireEvent.click(await screen.findByRole("button", { name: "Has parent is true" }))
    expect(await screen.findByRole("dialog", { name: "Has parent filter settings" })).toBeInTheDocument()
    expect(screen.queryByText("No value needed")).not.toBeInTheDocument()

    expect(screen.queryByLabelText("Sort column")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Direction")).not.toBeInTheDocument()
    await waitFor(() => {
      expect(screen.queryByText("Dashboard preferences updated.")).not.toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Sort by Issue ascending" }))

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
            active_smart_folder_id: null,
            sort_column: "title",
            sort_direction: "asc"
          })
        })
      )
    })
    expect(within(await screen.findByRole("button", { name: "Sort by Issue descending" })).getByText("↑")).toBeInTheDocument()

    const columnsButton = screen.getByRole("button", { name: "Columns" })
    expect(columnsButton).toHaveClass("h-[var(--control-height-md)]", "w-[var(--control-height-md)]")
    expect(columnsButton).not.toHaveTextContent("Columns")
    fireEvent.click(columnsButton)
    expect(screen.getByRole("group", { name: "Visible columns" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("group", { name: "Visible columns" })).not.toBeInTheDocument()
    fireEvent.click(columnsButton)
    expect(screen.getByRole("group", { name: "Visible columns" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("group", { name: "Visible columns" })).not.toBeInTheDocument()
    fireEvent.click(columnsButton)
    expect(screen.getByRole("group", { name: "Visible columns" })).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText("Workflows count"))

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
            visible_columns: ["state", "repository", "owner", "latest", "started"]
          })
        })
      )
    })

    fireEvent.click(screen.getByLabelText("Select Repair aqueduct"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/jobs/bulk",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            job_ids: [42],
            bulk_action: "retry"
          })
        })
      )
    })
    expect(await screen.findByText("Retry enqueued for 1 job.")).toBeInTheDocument()
  }, 30000)

  it("reports the total affected count after closing selected jobs one at a time", async () => {
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn().mockResolvedValue(true), dialog: <></> })
    const bulkBodies: Array<{ job_ids: number[]; bulk_action: string }> = []
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          jsonResponse(
            dashboardPayload({
              subject: "job",
              view: "list",
              total: 2,
              items: [
                dashboardJobItem({ id: 42, title: "First aqueduct", bulk_actions: { close: true } }),
                dashboardJobItem({ id: 43, title: "Second aqueduct", bulk_actions: { close: true } })
              ]
            })
          )
        )
      }
      if (path === "/api/v1/app/dashboard/jobs/bulk" && init?.method === "POST") {
        const body = JSON.parse(String(init.body)) as { job_ids: number[]; bulk_action: string }
        bulkBodies.push(body)
        return Promise.resolve(
          jsonResponse({
            message: "1 job closed.",
            action: "close",
            affected_job_ids: body.job_ids,
            skipped_job_ids: []
          })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    renderAppAt("/app-shell/dashboard/jobs?view=list")

    fireEvent.click(await screen.findByLabelText("Select First aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Second aqueduct"))
    fireEvent.click(screen.getByRole("button", { name: "Close" }))

    expect(await screen.findByText("2 jobs closed.")).toBeInTheDocument()
    expect(bulkBodies).toEqual([
      { job_ids: [42], bulk_action: "close" },
      { job_ids: [43], bulk_action: "close" }
    ])
  })

  it("reenables bulk job actions after the action succeeds", async () => {
    let resolveBulkAction: ((response: Response) => void) | undefined
    const bulkActionResponse = new Promise<Response>((resolve) => {
      resolveBulkAction = resolve
    })
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                total: 1,
                items: [
                  dashboardJobItem({
                    bulk_actions: {
                      retry: true,
                      close: true
                    }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/dashboard/jobs/bulk") return bulkActionResponse

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByLabelText("Select Repair aqueduct"))
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))

    await waitFor(() => {
      expect(screen.getByText("0 of 1 retried")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Cancel" })).toBeEnabled()
      expect(screen.queryByRole("button", { name: "Retry" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Close" })).not.toBeInTheDocument()
    })

    resolveBulkAction?.(
      new Response(JSON.stringify({ message: "Retry enqueued for 1 job." }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    expect(await screen.findByText("Retry enqueued for 1 job.")).toBeInTheDocument()
    expect(screen.getByText("1 selected")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Retry" })).toBeEnabled()
      expect(screen.getByRole("button", { name: "Close" })).toBeEnabled()
    })
  })

  it("shows only bulk job actions that apply to every selected dashboard row", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                total: 4,
                preferences: {
                  ...dashboardPayload().preferences,
                  visible_columns: ["checkbox", "issue", "state"]
                },
                items: [
                  dashboardJobItem({
                    id: 42,
                    title: "Backlogged aqueduct",
                    state: "backlog",
                    issue_number: 42,
                    can_release_from_backlog: true,
                    bulk_actions: {
                      release_from_backlog: true,
                      close: true
                    }
                  }),
                  dashboardJobItem({
                    id: 43,
                    title: "Queued aqueduct",
                    state: "queued",
                    issue_number: 43,
                    can_release_from_backlog: false,
                    bulk_actions: {
                      move_to_backlog: true,
                      close: true
                    }
                  }),
                  dashboardJobItem({
                    id: 44,
                    title: "Paused aqueduct",
                    state: "running",
                    issue_number: 44,
                    manual_paused: true,
                    bulk_actions: {
                      unpause: true,
                      close: true
                    }
                  }),
                  dashboardJobItem({
                    id: 45,
                    title: "Reviewable aqueduct",
                    state: "implemented",
                    issue_number: 45,
                    can_approve: true,
                    bulk_actions: {
                      approve: true,
                      close: true
                    }
                  }),
                  dashboardJobItem({
                    id: 46,
                    title: "Uncertain aqueduct",
                    state: "triaging",
                    triaging_reason: "classifier_uncertain",
                    issue_number: 46,
                    bulk_actions: {
                      accept_triage: true,
                      close: true
                    }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    renderAppAt("/app-shell/dashboard/jobs?view=list")

    expect(await screen.findByText("Backlogged aqueduct")).toBeInTheDocument()
    const bulkToolbar = () => screen.getByText(/\d selected/).closest("div")!.parentElement!

    fireEvent.click(screen.getByLabelText("Select Backlogged aqueduct"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).getByRole("button", { name: "Start" })).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    expect(await screen.findByText("2 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Start" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Backlogged aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Paused aqueduct"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).getByRole("button", { name: "Unpause" })).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    expect(await screen.findByText("2 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Unpause" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Paused aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Reviewable aqueduct"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).getByRole("button", { name: "Approve" })).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    expect(await screen.findByText("2 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Reviewable aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    fireEvent.click(screen.getByLabelText("Select Uncertain aqueduct"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).getByRole("button", { name: "Accept" })).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Queued aqueduct"))
    expect(await screen.findByText("2 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Accept" })).not.toBeInTheDocument()
  }, 30000)

  it("fails closed when row payloads omit bulk_actions", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                total: 2,
                preferences: {
                  ...dashboardPayload().preferences,
                  visible_columns: ["checkbox", "issue", "state"]
                },
                items: [
                  dashboardJobItem({
                    id: 46,
                    title: "Implemented fixture",
                    state: "implemented",
                    issue_number: 46,
                    claimed_by_user: null
                  }),
                  dashboardJobItem({
                    id: 47,
                    title: "Failed fixture",
                    state: "failed",
                    issue_number: 47,
                    claimed_by_user: null,
                    retry_state: {
                      classification: "git_failure",
                      classification_label: "Git failure",
                      retryable: true,
                      next_auto_retry_at: null,
                      retry_attempt_count: 1,
                      retry_budget_remaining: 2,
                      retry_budget: 3,
                      auto_retry_exhausted: false,
                      provider_circuit_open: false,
                      retry_delayed_until: null,
                      retry_delay_reason: null,
                      state_label: "Retryable failure"
                    }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    renderAppAt("/app-shell/dashboard/jobs?view=list")

    expect(await screen.findByText("Implemented fixture")).toBeInTheDocument()
    const bulkToolbar = () => screen.getByText(/\d selected/).closest("div")!.parentElement!

    fireEvent.click(screen.getByLabelText("Select Implemented fixture"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Start" })).not.toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Backlog" })).not.toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Unpause" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Select Failed fixture"))
    expect(await screen.findByText("2 selected")).toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Start" })).not.toBeInTheDocument()
    expect(within(bulkToolbar()).queryByRole("button", { name: "Backlog" })).not.toBeInTheDocument()
  }, 30000)

  it("renders dashboard timestamp columns as relative times with absolute tooltips", async () => {
    const restoreMedia = mockMediaQuery(true)
    const dateNowSpy = vi.spyOn(Date, "now").mockReturnValue(new Date("2026-05-30T12:01:00Z").getTime())
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                preferences: {
                  ...dashboardPayload().preferences,
                  visible_columns: ["checkbox", "issue", "started", "created_at", "updated_at"]
                },
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const startedAt = "2026-05-30T10:01:00Z"
      const absoluteStartedAt = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(startedAt))
      await screen.findByText("Repair aqueduct")
      const relativeStartedAt = document.querySelector(`time[datetime="${startedAt}"]`)

      expect(relativeStartedAt).toHaveTextContent("2 hours ago")
      expect(relativeStartedAt).toHaveAttribute("dateTime", startedAt)
      expect(relativeStartedAt).toHaveAttribute("title", absoluteStartedAt)
      expect(screen.queryByText(absoluteStartedAt)).not.toBeInTheDocument()
    } finally {
      dateNowSpy.mockRestore()
      restoreMedia()
    }
  })

  it("shows dashboard subjects in the sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: { v2_ui: true }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          new Response(JSON.stringify(dashboardPayload({ subject: "job", view: "list" })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("navigation", { name: "Dashboard sections" })).toBeInTheDocument()
      expect(screen.queryByRole("navigation", { name: "Dashboard subjects" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("uses the indigo trigger badge for chat feedback workflows", async () => {
    const restoreMedia = mockMediaQuery(true)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        preferences: {
          sort: { column: "created_at", direction: "desc" },
          visible_columns: ["issue", "state", "latest"],
          kanban_lanes: ["queued", "running", "succeeded"]
        },
        items: [
          dashboardJobItem({
            active_workflow_trigger_kind: "chat_feedback",
            latest_workflow_trigger_kind: "chat_feedback"
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

      const latestWorkflowCell = await screen.findByRole("cell", { name: "Latest workflow: chat_feedback running" })
      const latestWorkflowTrigger = within(latestWorkflowCell).getByLabelText("Latest workflow trigger: chat feedback")
      expect(latestWorkflowTrigger).toHaveClass("bg-indigo-100", "text-indigo-700", "ring-indigo-200")
    } finally {
      restoreMedia()
    }
  })

  it("renders postponed auto-merge attempts from dashboard job state", async () => {
    const restoreMedia = mockMediaQuery(true)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        preferences: {
          sort: { column: "created_at", direction: "desc" },
          visible_columns: ["issue", "state", "latest"],
          kanban_lanes: ["queued", "running", "succeeded"]
        },
        items: [
          dashboardJobItem({
            latest_workflow_trigger_kind: "auto_merge",
            latest_workflow_state: "postponed"
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

      const latestCell = await screen.findByRole("cell", { name: "Latest workflow: auto_merge postponed" })
      expect(within(latestCell).getByText("auto merge")).toBeInTheDocument()
      expect(within(latestCell).getByText("postponed")).toBeInTheDocument()
      expect(within(latestCell).queryByText("cancelled")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("leaves the latest workflow cell empty for dashboard jobs with no workflows", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&subject=job")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                preferences: {
                  sort: { column: "created_at", direction: "desc" },
                  visible_columns: ["checkbox", "issue", "state", "latest"],
                  kanban_lanes: ["queued", "running", "succeeded"]
                },
                items: [
                  dashboardJobItem({
                    id: 523,
                    title: "Blocked child",
                    state: "blocked_by_epic",
                    summary_state: "blocked_by_epic",
                    active_workflow_trigger_kind: null,
                    latest_workflow_id: null,
                    latest_workflow_trigger_kind: null,
                    latest_workflow_state: "queued",
                    workflows_count: 0
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Blocked child")).toBeInTheDocument()
    const row = screen.getByRole("row", { name: /Blocked child/i })
    const cells = within(row).getAllByRole("cell")
    expect(cells[3]).toBeEmptyDOMElement()
    expect(within(row).queryByText("Queued")).not.toBeInTheDocument()

    fetchSpy.mockRestore()
  })

  it("disambiguates GitHub issue numbers from Syrus Job ids on the dashboard", async () => {
    const clipboardWrite = mockClipboardWrite()
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        items: [
          dashboardJobItem({
            id: 594,
            kind: "direct",
            title: "Navigate to Epic",
            issue_number: null,
            issue_url: null,
            pr_number: null,
            pr_url: null,
            epic: {
              id: 7,
              number: 7,
              display_number: "EPIC-7",
              path: "/epics/7"
            }
          }),
          dashboardJobItem({
            id: 595,
            kind: "issue",
            title: "GitHub issue",
            issue_number: 123,
            issue_url: "https://github.com/acme/widgets/issues/123",
            pr_number: null,
            pr_url: null
          })
        ]
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Navigate to Epic")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/app-shell/epics/7")
    expect(screen.getByText("Navigate to Epic").closest("td")).toHaveTextContent("EPIC-7/JOB-594")
    const copySlugButton = screen.getByRole("button", { name: "Copy JOB-594 to clipboard" })
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-594"))
    expect(screen.getByRole("button", { name: "Copy JOB-595 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("GitHub issue").closest("td")).toHaveTextContent("JOB-595")
    expect(screen.getByRole("link", { name: "#123" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/123")
    expect(screen.queryByText("#594")).not.toBeInTheDocument()
  })

  it("renders dashboard job metadata with middot separators and copyable direct job slugs", async () => {
    const clipboardWrite = mockClipboardWrite()
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        items: [
          dashboardJobItem({
            id: 602,
            kind: "direct",
            title: "Direct chat repair",
            issue_number: null,
            issue_url: null,
            pr_number: 44,
            pr_url: "https://github.com/acme/widgets/pull/44",
            tags: [],
            source_chat: {
              chat_id: 9,
              chat_title: "Review",
              proposal_id: 6,
              proposal_kind: "job",
              message_id: 3,
              path: "/chats/9",
              display_name: "Chat",
              profile_path: "/profiles/2"
            }
          }),
          dashboardJobItem({
            id: 603,
            kind: "direct",
            title: "Direct standalone",
            issue_number: null,
            issue_url: null,
            pr_number: null,
            pr_url: null,
            tags: [],
            source_chat: null
          }),
          dashboardJobItem({
            id: 604,
            kind: "direct",
            title: "Paused direct",
            issue_number: null,
            issue_url: null,
            pr_number: null,
            pr_url: null,
            manual_paused: true,
            manual_paused_at: "2026-05-30T11:00:00Z",
            bulk_actions: { unpause: true },
            tags: [],
            source_chat: null
          })
        ]
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const chatJobCell = (await screen.findByRole("link", { name: "Direct chat repair" })).closest("td")
    expect(chatJobCell).toHaveTextContent("JOB-602·PR #44·CHAT-9")
    expect(within(chatJobCell!).getByRole("link", { name: "PR #44" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/44")

    const copyChatSlugButton = within(chatJobCell!).getByRole("button", { name: "Copy CHAT-9 to clipboard" })
    const chatSlugLink = copyChatSlugButton.closest("a")
    expect(chatSlugLink).toHaveAttribute("href", "/app-shell/chats/9")
    // Regression test for a real-browser-only bug: jsdom doesn't implement
    // anchor-click navigation, so a plain fireEvent.click can't tell "the
    // native default action was prevented" apart from "propagation to the
    // Link's own onClick (which calls preventDefault) was merely stopped".
    // Dispatching a real, cancelable MouseEvent and asserting
    // defaultPrevented catches the case where only stopPropagation runs.
    const chatSlugClickEvent = new MouseEvent("click", { bubbles: true, cancelable: true })
    copyChatSlugButton.dispatchEvent(chatSlugClickEvent)
    expect(chatSlugClickEvent.defaultPrevented).toBe(true)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("CHAT-9"))

    const copySlugButton = within(chatJobCell!).getByRole("button", { name: "Copy JOB-602 to clipboard" })
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-602"))

    const standaloneCell = screen.getByRole("link", { name: "Direct standalone" }).closest("td")
    expect(standaloneCell).toHaveTextContent("JOB-603")
    expect(within(standaloneCell!).queryByText("·")).not.toBeInTheDocument()

    const pausedCell = screen.getByRole("link", { name: "Paused direct" }).closest("td")
    const pausedMetadataRows = pausedCell!.querySelectorAll('div[class*="gap-x-1.5"]')
    expect(pausedMetadataRows).toHaveLength(2)
    expect(pausedMetadataRows[0]).toHaveTextContent("JOB-604")
    expect(pausedMetadataRows[0]).not.toHaveTextContent("Manually paused")
    expect(pausedMetadataRows[1]).toHaveTextContent("Manually paused·Unpause")
    expect(within(pausedCell!).getByRole("button", { name: "Unpause" })).toBeEnabled()
  })

  it("shows a chat preview card on hover for the dashboard source chat slug", async () => {
    const restoreMedia = mockMediaQuery(true)
    try {
      mockDashboardFetchWithChatPreview(
        dashboardPayload({
          subject: "job",
          view: "list",
          items: [
            dashboardJobItem({
              id: 610,
              kind: "direct",
              title: "Chat-originated repair",
              issue_number: null,
              issue_url: null,
              pr_number: null,
              pr_url: null,
              tags: [],
              source_chat: {
                chat_id: 11,
                chat_title: "Roadmap sync",
                proposal_id: 8,
                proposal_kind: "job",
                message_id: 4,
                path: "/chats/11#message-4",
                label: "Job proposal in Roadmap sync"
              }
            })
          ]
        }),
        {
          id: 11,
          chat_slug: "CHAT-11",
          title: "Roadmap sync",
          title_pending: false,
          participants: [{ id: 1, name: "Ada Lovelace", avatar_url: null, role: "owner" }],
          pending_proposal_count: 0,
          pending_actions_count: 0
        }
      )

      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const copyChatSlugButton = await screen.findByRole("button", { name: "Copy CHAT-11 to clipboard" })
      expect(copyChatSlugButton.closest("a")).toHaveAttribute("href", "/app-shell/chats/11#message-4")

      fireEvent.mouseEnter(copyChatSlugButton.parentElement!.parentElement!)
      expect(await screen.findByText("Roadmap sync")).toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("surfaces readiness failures on the dashboard", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        setup_status: {
          ...setupStatus(),
          readiness: {
            status: "error",
            checks: [
              {
                key: "worker_queue",
                label: "Worker/queue",
                status: "error",
                message: "No Solid Queue worker processes are registered.",
                remediation: "Start the worker process with bin/jobs and confirm it can connect to the queue database.",
                optional: false
              },
              {
                key: "github",
                label: "GitHub",
                status: "ok",
                message: "GitHub accepted the configured personal access token.",
                remediation: null,
                optional: false
              }
            ]
          }
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = mockDashboardFetch(dashboardPayload({ subject: "job", view: "list", items: [dashboardJobItem()] }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("region", { name: "System readiness" })).toBeInTheDocument()
    expect(screen.getByText("No Solid Queue worker processes are registered.")).toBeInTheDocument()
    expect(screen.getByText("Start the worker process with bin/jobs and confirm it can connect to the queue database.")).toBeInTheDocument()
    expect(screen.queryByText("GitHub accepted the configured personal access token.")).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open Operator Console" })).toHaveAttribute("href", "/app-shell/admin/console")
    expectDashboardFetch(
      fetchSpy,
      "/api/v1/app/dashboard?view=list&subject=job",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("renders useful owner badges on the jobs dashboard", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (dashboardPathMatches(path, "/api/v1/app/dashboard?view=list&ownership_scope=team&subject=job")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                ownership: { scope: "team", owner_id: 1, team_user_count: 2, badges_visible: true },
                preferences: {
                  sort: { column: "created_at", direction: "desc" },
                  visible_columns: ["checkbox", "issue", "state", "repository", "latest", "workflows_count", "started"],
                  kanban_lanes: ["queued", "running", "succeeded"],
                  ownership_scope: "team",
                  owner_user_id: 1,
                  owner_id: 1
                },
                items: [
                  dashboardJobItem({ title: "Mine", owner_badge: null }),
                  dashboardJobItem({
                    id: 43,
                    title: "Theirs",
                    owner_user: { id: 2, name: "Teammate", email_address: "teammate@example.com" },
                    owner_badge: { label: "Teammate", kind: "other_user" }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&ownership_scope=team"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Teammate")).toBeInTheDocument()
    expect(screen.queryByText("Operator")).not.toBeInTheDocument()
    // Owner filter for jobs moved to the FilterBar; no standalone ownership chip rendered
    expect(screen.queryByRole("button", { name: /Owner is/i })).toBeNull()
  })

  it("keeps dashboard folders and filters collapsed on mobile", async () => {
    const restoreMedia = mockMediaQuery(false)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        active_smart_folder_id: 7,
        items: [dashboardJobItem()]
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

      expect(await screen.findByText("Repair aqueduct")).toBeInTheDocument()
      const controls = screen.getByRole("group", { name: "Dashboard controls" })
      expect(controls).toHaveClass("justify-between")
      expect(within(controls).getByRole("navigation", { name: "Dashboard subjects" })).toBeInTheDocument()
      expect(within(controls).getByRole("navigation", { name: "Dashboard subjects" }).parentElement).toHaveClass("flex-1", "overflow-x-auto")
      expect(within(controls).getByRole("navigation", { name: "Dashboard view" })).toBeInTheDocument()
      expect(within(controls).queryByRole("button", { name: "Columns" })).not.toBeInTheDocument()

      const disclosureLabel = screen.getByText("My work", { selector: "summary > span" })
      const disclosure = disclosureLabel.closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      expect(screen.queryByText("Folders and filters")).not.toBeInTheDocument()
      fireEvent.click(disclosureLabel)
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "My work 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=7")
    } finally {
      restoreMedia()
    }
  })

  it("renders mobile Job dashboard rows as consolidated cards", async () => {
    const restoreMedia = mockMediaQuery(false)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        items: [
          dashboardJobItem({
            summary_state: "implemented",
            total_cost_usd: 0.1234
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

      const row = await screen.findByRole("article", { name: "Repair aqueduct" })
      expect(within(row).getByLabelText("Select Repair aqueduct")).toBeInTheDocument()
      expect(within(row).getByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/42")
      expect(within(row).getByText("implemented")).toBeInTheDocument()
      expect(within(row).getByText("$0.1234")).toBeInTheDocument()
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
      expect(within(row).getByRole("link", { name: "PR #34" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/34")
      expect(within(row).queryByText("Not approved")).not.toBeInTheDocument()
      expect(within(row).queryByText(/workflow/)).not.toBeInTheDocument()
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("omits mobile Job dashboard cost before any billed run", async () => {
    const restoreMedia = mockMediaQuery(false)
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        items: [dashboardJobItem({ total_cost_usd: null })]
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

      const row = await screen.findByRole("article", { name: "Repair aqueduct" })
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).queryByText("$0.00")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders mobile Epic dashboard rows as consolidated cards", async () => {
    const restoreMedia = mockMediaQuery(false)
    mockDashboardFetch(
      dashboardPayload({
        subject: "epic",
        view: "list",
        preferences: {
          sort: { column: "updated_at", direction: "desc" },
          visible_columns: ["epic", "state", "repository", "updated"],
          kanban_lanes: ["backlog", "ready", "in_progress", "done"]
        },
        controls: {
          ...dashboardPayload().controls,
          sort_columns: ["title", "state", "repository", "updated_at"]
        },
        items: [
          dashboardEpicItem({
            description: "Epic: Extend filter framework to Epics Make Syrus's chip-bar filter framework work for Epics."
          })
        ]
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const row = await screen.findByRole("article", { name: "EPIC-7 Raise the forum" })
      expect(row).toHaveClass("grid-cols-[auto_minmax(0,1fr)]")
      expect(within(row).getByRole("checkbox", { name: "Select Raise the forum" })).toBeInTheDocument()
      expect(within(row).getByRole("link", { name: "EPIC-7 Raise the forum" })).toHaveAttribute("href", "/app-shell/epics/7")
      expect(within(row).getByText("ready")).toBeInTheDocument()
      expect(within(row).getByText("EPIC-7")).toBeInTheDocument()
      expect(within(row).getByText("Raise the forum")).toBeInTheDocument()
      expect(within(row).getByText(/chip-bar filter framework/)).toBeInTheDocument()
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).queryByText("View")).not.toBeInTheDocument()
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders mobile Workflow dashboard rows as consolidated cards", async () => {
    const restoreMedia = mockMediaQuery(false)
    mockDashboardFetch(
      dashboardPayload({
        subject: "workflow",
        view: "list",
        preferences: {
          sort: { column: "started_at", direction: "desc" },
          visible_columns: ["workflow", "job", "trigger", "state", "started", "finished", "agent"],
          kanban_lanes: ["queued", "running", "done"]
        },
        controls: {
          ...dashboardPayload().controls,
          columns: {
            required: [
              { key: "workflow", title: "Workflow" },
              { key: "job", title: "Job" }
            ],
            optional: [
              { key: "trigger", title: "Trigger" },
              { key: "state", title: "State" },
              { key: "started", title: "Started" },
              { key: "finished", title: "Finished" },
              { key: "agent", title: "Agent" }
            ]
          },
          sort_columns: ["title", "state", "started_at", "finished_at"]
        },
        items: [dashboardWorkflowItem()]
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/workflows?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const rowLink = await screen.findByRole("link", { name: "WF-9 Repair aqueduct" })
      const row = rowLink.parentElement!
      expect(rowLink).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-9")
      expect(row).toHaveClass("grid-cols-[7.25rem_minmax(0,1fr)]")
      expect(within(row).getByText("running")).toBeInTheDocument()
      expectRunningPill(within(row).getByText("running"))
      expect(within(row).getByText("WF-9")).toBeInTheDocument()
      expect(within(row).getByRole("button", { name: "Copy WF-9 to clipboard" })).toBeInTheDocument()
      expect(within(row).getByText("Repair aqueduct")).toBeInTheDocument()
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).getByText("manual")).toBeInTheDocument()
      expect(within(row).getByText("codex")).toBeInTheDocument()
      expect(within(row).getByText(/Started/)).toBeInTheDocument()
      expect(within(row).getByText(/Finished/)).toBeInTheDocument()
      expect(within(row).queryByText("View")).not.toBeInTheDocument()
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders desktop Workflow dashboard slugs as links", async () => {
    const restoreMedia = mockMediaQuery(true)
    mockDashboardFetch(
      dashboardPayload({
        subject: "workflow",
        view: "list",
        preferences: {
          sort: { column: "started_at", direction: "desc" },
          visible_columns: ["workflow", "job", "state", "started"],
          kanban_lanes: ["queued", "running", "done"]
        },
        controls: {
          ...dashboardPayload().controls,
          columns: {
            required: [
              { key: "workflow", title: "Workflow" },
              { key: "job", title: "Job" }
            ],
            optional: [
              { key: "trigger", title: "Trigger" },
              { key: "state", title: "State" },
              { key: "started", title: "Started" },
              { key: "finished", title: "Finished" },
              { key: "agent", title: "Agent" }
            ]
          },
          sort_columns: ["title", "state", "started_at", "finished_at"]
        },
        items: [dashboardWorkflowItem()]
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/workflows?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("link", { name: "WF-9" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-9")
    } finally {
      restoreMedia()
    }
  })

  it("points an empty first-run dashboard at the direct job action", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({ setupStatus: null }))
    document.body.appendChild(script)

    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        total: 0,
        counts: { jobs: 0, epics: 0, workflows: 0 },
        items: [],
        setup: setupStatusPayload()
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "No Jobs yet" })).toBeInTheDocument()
    expect(screen.getByText("Finish credentials first so Syrus can talk to GitHub and the selected agent.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open setup" })).toHaveAttribute("href", "/app-shell/setup")
  })

  it("does not mention finishing setup on a completed empty dashboard", async () => {
    mockDashboardFetch(
      dashboardPayload({
        subject: "job",
        view: "list",
        total: 0,
        counts: { jobs: 0, epics: 0, workflows: 0 },
        items: []
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No jobs exist yet. Create work from a direct prompt or a labelled GitHub issue.")).toBeInTheDocument()
    expect(screen.queryByText(/Finish setup/)).not.toBeInTheDocument()
  })
})
