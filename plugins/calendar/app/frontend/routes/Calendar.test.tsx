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
            metadata: {}
          }
        ],
        failures: []
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
  })
})
