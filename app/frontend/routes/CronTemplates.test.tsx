import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { CronTemplateDetailRoute, CronTemplateFormRoute } from "./CronTemplates"
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

function renderNewForm() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/cron_templates/new"]}>
        <Routes>
          <Route element={<CronTemplateFormRoute mode="new" />} path="/app-shell/cron_templates/new" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("CronTemplateFormRoute cadence preview", () => {
  afterEach(() => vi.restoreAllMocks())

  it("previews the pre-filled placeholder cadence successfully on load", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/cron_templates/preview_schedule" && init?.method === "POST") {
        const body = JSON.parse(String(init.body))
        expect(body.schedule_input).toBe("Every Monday at 9:00 AM")
        return Promise.resolve(jsonResponse({
          valid: true,
          schedule_input: "Every Monday at 9:00 AM",
          schedule_format: "rrule",
          schedule_expression: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
          schedule_timezone: "UTC",
          schedule_explanation: "Every Monday at 9:00 AM UTC",
          next_fire_at: null,
          cron_expression: null,
          errors: [],
          source: "natural",
          structured_intent: null
        }))
      }
      return Promise.resolve(jsonResponse({ templates: [], pr_pileup_policies: ["skip", "pile", "replace"] }))
    })

    renderNewForm()

    expect(await screen.findByDisplayValue("Every Monday at 9:00 AM")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.getByText("Every Monday at 9:00 AM UTC")).toBeInTheDocument()
    })
  })

  it("labels an LLM-assisted preview as a deterministic explanation with an AI-assist badge", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/cron_templates/preview_schedule" && init?.method === "POST") {
        const body = JSON.parse(String(init.body))
        if (body.schedule_input === "moday at 9am in tjhe mornin") {
          return Promise.resolve(jsonResponse({
            valid: true,
            schedule_input: "moday at 9am in tjhe mornin",
            schedule_format: "rrule",
            schedule_expression: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
            schedule_timezone: "UTC",
            schedule_explanation: "Every Monday at 9:00 AM UTC",
            next_fire_at: null,
            cron_expression: null,
            errors: [],
            source: "structured_intent",
            structured_intent: { frequency: "WEEKLY", day: "monday", hour: 9, minute: 0 }
          }))
        }
        return Promise.resolve(jsonResponse({
          valid: true, schedule_input: body.schedule_input, schedule_format: "rrule",
          schedule_expression: "", schedule_timezone: "UTC", schedule_explanation: "Every Monday at 9:00 AM UTC",
          next_fire_at: null, cron_expression: null, errors: [], source: "natural", structured_intent: null
        }))
      }
      return Promise.resolve(jsonResponse({ templates: [], pr_pileup_policies: ["skip", "pile", "replace"] }))
    })

    renderNewForm()

    const input = await screen.findByPlaceholderText("Every Monday at 9:00 AM")
    fireEvent.change(input, { target: { value: "moday at 9am in tjhe mornin" } })

    await waitFor(() => {
      expect(screen.getByText("(via AI assist)")).toBeInTheDocument()
    })
  })
})
