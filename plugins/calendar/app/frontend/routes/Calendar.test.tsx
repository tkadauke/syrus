import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import CalendarRoute from "./Calendar"

describe("CalendarRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("switches views and applies shared FilterBar category filters", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        events: [
          {
            source_id: "calendar:chat_wakeups",
            id: "one",
            kind: "chat_wakeup",
            title: "Release reminder",
            starts_at: new Date().toISOString(),
            destination_path: "/chats/1",
            state: "pending",
            metadata: {}
          },
          {
            source_id: "calendar:solid_queue",
            id: "two",
            kind: "recurring_maintenance",
            title: "Cleanup",
            starts_at: new Date().toISOString(),
            destination_path: "/admin/queues",
            state: "planned",
            cadence: { label: "every 5 minutes", band: true },
            actual_started_at: "2026-11-02T10:00:00Z",
            actual_finished_at: "2026-11-02T10:00:12Z",
            metadata: { duration_seconds: 12 }
          }
        ],
        failures: [{ source: "calendar:broken", code: "provider_failed" }]
      })
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const filter = btoa(JSON.stringify({ and: [{ field: "category", op: "is", value: "chat_wakeup" }] }))
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[`/calendar?q=${filter}`]}>
          <CalendarRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Release reminder")).toBeInTheDocument()
    expect(screen.queryByText("Cleanup")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Agenda" }))
    expect(screen.getByRole("button", { name: "Agenda" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByText("Some event sources are temporarily unavailable.")).toBeInTheDocument()
  })

  it("shows cadence bands once and exposes accessible execution details", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        events: [
          {
            source_id: "calendar:solid_queue",
            id: "band",
            kind: "recurring_maintenance",
            title: "Queue cleanup",
            starts_at: "2026-11-02T00:00:00Z",
            ends_at: "2026-11-09T00:00:00Z",
            destination_path: "/admin/queues",
            state: "healthy",
            cadence: { label: "every 5 minutes", band: true },
            actual_started_at: "2026-11-02T10:00:00Z",
            actual_finished_at: "2026-11-02T10:00:12Z",
            metadata: { duration_seconds: 12 }
          }
        ],
        failures: []
      })
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/calendar"]}>
          <CalendarRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const details = await screen.findByRole("button", { name: "Queue cleanup" })
    expect(screen.getAllByText("Queue cleanup")).toHaveLength(1)
    const cadenceBands = screen.getByLabelText("High-frequency cadence bands")
    expect(cadenceBands.querySelector(".grid")?.className).toContain("sm:grid-cols-2")
    expect(details).toHaveAttribute("aria-expanded", "false")
    fireEvent.click(details)
    expect(details).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByText("Duration: 12.0 seconds")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open owning feature" })).toHaveAttribute("href", "/admin/queues")
    expect(screen.getByText(/Times shown in/)).toBeInTheDocument()
  })

  it("links a scheduled execution to both its Job and owning task", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        events: [
          {
            source_id: "scheduled_tasks:tasks",
            id: "task-1-slot",
            kind: "scheduled_task",
            title: "Repository sweep",
            starts_at: new Date().toISOString(),
            destination_path: "/jobs/7",
            state: "fired",
            metadata: { scheduled_task_path: "/scheduled_tasks/1", job_id: 7 }
          }
        ],
        failures: []
      })
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/calendar"]}>
          <CalendarRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Repository sweep" }))
    expect(screen.getByRole("link", { name: "Open owning feature" })).toHaveAttribute("href", "/jobs/7")
    expect(screen.getByRole("link", { name: "Open scheduled task" })).toHaveAttribute("href", "/scheduled_tasks/1")
  })

  it("renders coworker identity, operational policy, and drill-through destinations", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        events: [
          {
            source_id: "coworkers:scheduled_work",
            id: "coworker-task-1-slot",
            kind: "coworker_scheduled_task",
            title: "Morning briefing",
            starts_at: new Date().toISOString(),
            destination_path: "/jobs/7",
            state: "delayed",
            metadata: {
              coworker_name: "Maya",
              coworker_handle: "maya",
              coworker_path: "/coworkers/2",
              coworker_avatar_url: null,
              coworker_accent_hex: "#b6492e",
              main_chat_path: "/chats/12",
              scheduled_task_path: "/coworkers/2?tab=schedules",
              after_run: "wake",
              system_key: "journaling"
            }
          }
        ],
        failures: []
      })
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/calendar"]}>
          <CalendarRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Morning briefing" }))
    expect(screen.getByText("Maya @maya")).toBeInTheDocument()
    expect(screen.getByText("After run: wake")).toBeInTheDocument()
    expect(screen.getByText("System schedule: journaling")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open scheduled task" })).toHaveAttribute("href", "/coworkers/2?tab=schedules")
    expect(screen.getByRole("link", { name: "Open main chat" })).toHaveAttribute("href", "/chats/12")
    expect(screen.getByRole("link", { name: "Open coworker" })).toHaveAttribute("href", "/coworkers/2")
  })
})
