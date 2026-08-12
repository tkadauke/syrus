import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { ScheduledTaskDetailRoute, ScheduledTaskFormRoute } from "./ScheduledTasks"
import * as useConfirmModule from "../hooks/useConfirm"

function taskDetail(overrides: { recent_jobs?: unknown[] } = {}) {
  return {
    task: {
      id: 7,
      name: "Weekly check",
      kind: "cron",
      state: "active",
      repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
      schedule_label: "0 9 * * 1",
      last_fired_at: null,
      archived_at: null,
      consecutive_failure_count: 0,
      scheduled_task_path: "/scheduled_tasks/7",
      prompt: "Check for updates.",
      cron_expression: "0 9 * * 1",
      hourly_cron_expression: null,
      fire_at: null,
      next_fire_at: null,
      pr_pileup_policy: "skip",
      auto_approve_mode: "never",
      auto_approve_preview: "Never",
      last_successful_fire_at: null,
      archived: false,
      fireable: true,
      pausable: true,
      resumable: false,
      editable: true
    },
    recent_jobs: overrides.recent_jobs ?? [],
    options: {
      kinds: ["cron", "one_shot"],
      pr_pileup_policies: ["skip", "pile", "replace"],
      auto_approve_modes: [{ value: "never", label: "Never", preview: "No direct rule." }]
    }
  }
}

function renderRoute(payload: ReturnType<typeof taskDetail> = taskDetail()) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/scheduled_tasks/7"]}>
        <Routes>
          <Route element={<ScheduledTaskDetailRoute />} path="/app-shell/scheduled_tasks/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ScheduledTaskDetailRoute archive", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when archiving a task", async () => {
    renderRoute()

    const archiveButton = await screen.findByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the delete API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/scheduled_tasks/7" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse({ active_tasks: [], fired_one_shots: [], archived_tasks: [], options: taskDetail().options }))
      }
      return Promise.resolve(jsonResponse(taskDetail()))
    })

    renderRoute()

    const archiveButton = await screen.findByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/scheduled_tasks/7",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("does not call the delete API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(taskDetail()))

    renderRoute()

    const archiveButton = await screen.findByRole("button", { name: "Archive" })
    await act(async () => { fireEvent.click(archiveButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/scheduled_tasks/7",
      expect.objectContaining({ method: "DELETE" })
    )
  })
})

describe("ScheduledTaskDetailRoute recent jobs", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  afterEach(() => vi.restoreAllMocks())

  it("renders the job as a copyable slug instead of a bare #id link", async () => {
    renderRoute(taskDetail({
      recent_jobs: [
        { id: 2922, state: "running", closure_reason: null, pr_number: null, external_pr_number: null, created_at: "2026-08-12T00:00:00Z", job_path: "/jobs/2922" }
      ]
    }))

    expect(await screen.findByText("JOB-2922")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy JOB-2922 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByText("#2922")).not.toBeInTheDocument()
  })

  it("copies the job slug to the clipboard when clicked", async () => {
    renderRoute(taskDetail({
      recent_jobs: [
        { id: 2922, state: "running", closure_reason: null, pr_number: null, external_pr_number: null, created_at: "2026-08-12T00:00:00Z", job_path: "/jobs/2922" }
      ]
    }))

    const copyButton = await screen.findByRole("button", { name: "Copy JOB-2922 to clipboard" })
    fireEvent.click(copyButton)

    await waitFor(() => {
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith("JOB-2922")
    })
  })
})

function newFormPayload() {
  return {
    task: {
      id: null,
      name: "",
      prompt: "",
      kind: "cron",
      cron_expression: "",
      schedule_input: "",
      schedule_format: "rrule",
      schedule_expression: "",
      schedule_timezone: "UTC",
      fire_at: "",
      pr_pileup_policy: "skip",
      auto_approve_mode: "never",
      cron_template_id: null
    },
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    from_template: null,
    options: {
      kinds: ["cron", "one_shot"],
      pr_pileup_policies: ["skip", "pile", "replace"],
      auto_approve_modes: [{ value: "never", label: "Never", preview: "No direct rule." }]
    }
  }
}

function renderNewForm() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/scheduled_tasks/new"]}>
        <Routes>
          <Route element={<ScheduledTaskFormRoute mode="new" />} path="/app-shell/repositories/:repositoryId/scheduled_tasks/new" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ScheduledTaskFormRoute cadence preview", () => {
  afterEach(() => vi.restoreAllMocks())

  it("previews the pre-filled placeholder cadence successfully on load", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/scheduled_tasks/preview_schedule" && init?.method === "POST") {
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
      return Promise.resolve(jsonResponse(newFormPayload()))
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
      if (url === "/api/v1/app/scheduled_tasks/preview_schedule" && init?.method === "POST") {
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
      return Promise.resolve(jsonResponse(newFormPayload()))
    })

    renderNewForm()

    const input = await screen.findByPlaceholderText("Every Monday at 9:00 AM")
    fireEvent.change(input, { target: { value: "moday at 9am in tjhe mornin" } })

    await waitFor(() => {
      expect(screen.getByText("(via AI assist)")).toBeInTheDocument()
    })
  })
})
