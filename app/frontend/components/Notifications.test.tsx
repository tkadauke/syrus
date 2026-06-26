import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { NotificationsBell, NotificationsRoute } from "./Notifications"

describe("Notifications", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("renders the bell without a badge when there are no unread notifications", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(notificationsPayload({ unread_count: 0 })))

    renderWithClient(
      <MemoryRouter>
        <NotificationsBell prefix="" />
      </MemoryRouter>
    )

    expect(await screen.findByRole("button", { name: "Notifications" })).toBeInTheDocument()
    expect(screen.queryByText("9+")).not.toBeInTheDocument()
    expect(screen.queryByText("1")).not.toBeInTheDocument()
  })

  it("renders capped unread badge text", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(notificationsPayload({ unread_count: 12 })))

    renderWithClient(
      <MemoryRouter>
        <NotificationsBell prefix="" />
      </MemoryRouter>
    )

    expect(await screen.findByRole("button", { name: "Notifications, 12 unread" })).toBeInTheDocument()
    expect(screen.getByText("9+")).toBeInTheDocument()
  })

  it("toggles the desktop notifications panel", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(notificationsPayload({
      notifications: [
        notificationRecord({ id: 1, kind: "job_failed", body: "Job failed", job_id: 7 }),
        notificationRecord({ id: 2, kind: "pr_merged", body: "PR merged", read_at: "2026-06-25T12:00:00Z" })
      ],
      unread_count: 1
    })))

    renderWithClient(
      <MemoryRouter>
        <NotificationsBell prefix="/app-shell" />
      </MemoryRouter>
    )

    const bell = await screen.findByRole("button", { name: "Notifications, 1 unread" })
    expect(screen.queryByText("Job failed")).not.toBeInTheDocument()

    fireEvent.click(bell)
    const panel = screen.getByRole("heading", { name: "Notifications" }).closest("div")
    expect(screen.getByText("Job failed")).toBeInTheDocument()
    expect(screen.getByText("PR merged")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Mark all read" })).toBeInTheDocument()

    fireEvent.click(bell)
    await waitFor(() => {
      expect(screen.queryByText("Job failed")).not.toBeInTheDocument()
    })
    expect(panel).not.toBeInTheDocument()
  })

  it("renders the mobile notifications route", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(notificationsPayload({
      notifications: [
        notificationRecord({ id: 3, kind: "job_implemented", body: "Implementation ready", job_id: 9 })
      ],
      unread_count: 1
    })))

    renderWithClient(
      <MemoryRouter initialEntries={["/app-shell/notifications"]}>
        <Routes>
          <Route element={<NotificationsRoute />} path="/app-shell/notifications" />
        </Routes>
      </MemoryRouter>
    )

    const main = await screen.findByRole("main", { name: "Notifications" })
    expect(within(main).getByRole("button", { name: "Back" })).toBeInTheDocument()
    expect(within(main).getByRole("heading", { name: "Notifications" })).toBeInTheDocument()
    expect(await within(main).findByText("Implementation ready")).toBeInTheDocument()
  })

  it("splits notification row navigation between the job body and PR link", async () => {
    const notification = notificationRecord({
      id: 1263,
      kind: "job_implemented",
      body: "Syrus opened PR #1263 for JOB-1228: Add dark mode toggle",
      job_id: 1228,
      job_title: "Add dark mode toggle",
      pr_url: "https://github.com/acme/widgets/pull/1263"
    })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url.includes("/api/v1/app/notifications/1263/mark_read") && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse({
          notification: { ...notification, read_at: "2026-06-25T12:01:00Z" },
          unread_count: 0
        }))
      }

      return Promise.resolve(jsonResponse(notificationsPayload({
        notifications: [ notification ],
        unread_count: 1
      })))
    })
    const open = vi.spyOn(window, "open").mockReturnValue(null)

    renderWithClient(
      <MemoryRouter initialEntries={["/app-shell/notifications"]}>
        <Routes>
          <Route element={<NotificationsRoute />} path="/app-shell/notifications" />
          <Route element={<div>Job detail</div>} path="/app-shell/jobs/1228" />
        </Routes>
      </MemoryRouter>
    )

    const main = await screen.findByRole("main", { name: "Notifications" })
    fireEvent.click(await within(main).findByRole("link", { name: "PR #1263" }))

    expect(open).toHaveBeenCalledWith("https://github.com/acme/widgets/pull/1263", "_blank", "noopener")
    expect(screen.queryByText("Job detail")).not.toBeInTheDocument()

    fireEvent.click(within(main).getByText("Syrus opened PR #1263 for JOB-1228: Add dark mode toggle"))

    expect(await screen.findByText("Job detail")).toBeInTheDocument()
  })
})

function renderWithClient(children: React.ReactNode) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={queryClient}>
      {children}
    </QueryClientProvider>
  )
}

function notificationsPayload(overrides: Partial<{
  notifications: ReturnType<typeof notificationRecord>[]
  unread_count: number
}> = {}) {
  const notifications = overrides.notifications ?? []

  return {
    notifications,
    unread_count: overrides.unread_count ?? 0,
    pagination: {
      page: 1,
      per_page: 20,
      total: notifications.length,
      total_pages: notifications.length > 0 ? 1 : 0
    }
  }
}

function notificationRecord(overrides: Partial<{
  id: number
  kind: string
  body: string
  read_at: string | null
  pr_url: string | null
  job_id: number | null
  job_title: string | null
  created_at: string
}> = {}) {
  return {
    id: overrides.id ?? 1,
    kind: overrides.kind ?? "job_failed",
    body: overrides.body ?? "Notification",
    read_at: overrides.read_at ?? null,
    pr_url: overrides.pr_url ?? null,
    job_id: overrides.job_id ?? null,
    job_title: overrides.job_title ?? null,
    created_at: overrides.created_at ?? "2026-06-25T12:00:00Z"
  }
}

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" }
  })
}
