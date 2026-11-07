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
})
