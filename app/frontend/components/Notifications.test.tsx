import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { NotificationsBell, NotificationsRoute } from "./Notifications"

describe("Notifications", () => {
  afterEach(() => {
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
  created_at: string
}> = {}) {
  return {
    id: overrides.id ?? 1,
    kind: overrides.kind ?? "job_failed",
    body: overrides.body ?? "Notification",
    read_at: overrides.read_at ?? null,
    pr_url: overrides.pr_url ?? null,
    job_id: overrides.job_id ?? null,
    created_at: overrides.created_at ?? "2026-06-25T12:00:00Z"
  }
}

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" }
  })
}
