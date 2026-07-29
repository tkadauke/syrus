import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { CronTemplateDetailRoute } from "./CronTemplates"
import * as useConfirmModule from "../hooks/useConfirm"

function templateDetail() {
  return {
    template: {
      id: 5,
      name: "Weekly update",
      description: "Runs every Monday.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      enabled: true,
      prompt: "Summarize changes.",
      applied_tasks_count: 0,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z"
    },
    pr_pileup_policies: ["skip", "pile", "replace"],
    repositories: [],
    applied_tasks: []
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(templateDetail()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/cron_templates/5"]}>
        <Routes>
          <Route element={<CronTemplateDetailRoute />} path="/app-shell/cron_templates/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("CronTemplateDetailRoute delete", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when deleting a template", async () => {
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
      if (url === "/api/v1/app/cron_templates/5" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse({ templates: [], pr_pileup_policies: [] }))
      }
      return Promise.resolve(jsonResponse(templateDetail()))
    })

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    fireEvent.click(deleteButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/cron_templates/5",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("does not call the delete API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(templateDetail()))

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    await act(async () => { fireEvent.click(deleteButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/cron_templates/5",
      expect.objectContaining({ method: "DELETE" })
    )
  })
})
