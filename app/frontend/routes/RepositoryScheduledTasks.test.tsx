import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryScheduledTasksRoute } from "./RepositoryScheduledTasks"
import * as useConfirmModule from "../hooks/useConfirm"

function tasksPayload(overrides: Record<string, unknown> = {}) {
  return {
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    tabs: [],
    tasks: [
      {
        id: 10,
        name: "Daily check",
        prompt: "Check for issues.",
        schedule_label: "0 9 * * 1",
        next_fire_at: null,
        state: "scheduled",
        active: true
      }
    ],
    message: null,
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(tasksPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/scheduled_tasks"]}>
        <Routes>
          <Route element={<RepositoryScheduledTasksRoute />} path="/app-shell/repositories/:repositoryId/scheduled_tasks" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryScheduledTasksRoute delete", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when deleting a task", async () => {
    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    fireEvent.click(deleteButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the delete API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/scheduled_tasks/10" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(tasksPayload({ tasks: [] })))
      }
      return Promise.resolve(jsonResponse(tasksPayload()))
    })

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    fireEvent.click(deleteButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/scheduled_tasks/10",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("does not call the delete API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(tasksPayload()))

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    await act(async () => { fireEvent.click(deleteButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/repositories/1/scheduled_tasks/10",
      expect.objectContaining({ method: "DELETE" })
    )
  })
})
