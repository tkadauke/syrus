import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { ChatJobStatusPanel } from "./ChatJobStatusPanel"
import type { ChatJobStatusItem } from "../api/chats"

function renderPanel(chatId: number | string = 8) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
        <LocationProbe />
        <Routes>
          <Route
            element={<ChatJobStatusPanel chatId={chatId} />}
            path="/app-shell/chats/:id"
          />
          <Route element={<div data-testid="job-detail" />} path="/jobs/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}{location.search}</div>
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function jobItem(overrides: Partial<ChatJobStatusItem & { kind: "job" }> = {}): ChatJobStatusItem {
  return {
    kind: "job",
    job_id: 42,
    slug: "JOB-42",
    title: "Inspect the aqueduct",
    state: "open",
    workflow_step: null,
    pr_number: null,
    pr_url: null,
    blocker: null,
    ...overrides
  }
}

function epicItem(overrides: Partial<ChatJobStatusItem & { kind: "epic" }> = {}): ChatJobStatusItem {
  return {
    kind: "epic",
    epic_id: 5,
    slug: "EPIC-5",
    title: "Aqueduct renovation",
    state: "in_progress",
    progress: { done: 1, total: 3 },
    children: [
      {
        kind: "job",
        job_id: 10,
        slug: "JOB-10",
        title: "Survey route",
        state: "open",
        workflow_step: null,
        pr_number: null,
        pr_url: null,
        blocker: null
      }
    ],
    ...overrides
  }
}

describe("ChatJobStatusPanel empty state", () => {
  beforeEach(() => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([]))
  })

  it("shows the empty state when no confirmed proposals exist", async () => {
    renderPanel()

    expect(await screen.findByText("No confirmed proposals yet.")).toBeInTheDocument()
  })
})

describe("ChatJobStatusPanel job cards", () => {
  it("renders a standalone job card with title and slug", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([jobItem()]))

    renderPanel()

    expect(await screen.findByText("Inspect the aqueduct")).toBeInTheDocument()
    expect(screen.getByText("JOB-42")).toBeInTheDocument()
  })

  it("shows the workflow step when present", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([
      jobItem({ workflow_step: "implement" })
    ]))

    renderPanel()

    expect(await screen.findByText("Step: implement")).toBeInTheDocument()
  })

  it("shows a PR link when pr_number and pr_url are set", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([
      jobItem({ pr_number: 7, pr_url: "https://github.com/acme/widgets/pull/7" })
    ]))

    renderPanel()

    const link = await screen.findByRole("link", { name: "PR #7" })
    expect(link).toHaveAttribute("href", "https://github.com/acme/widgets/pull/7")
  })

  it("navigates to the job detail page when the card is clicked", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([jobItem()]))

    renderPanel()

    const card = await screen.findByRole("button", { name: /Inspect the aqueduct/i })
    fireEvent.click(card)

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/jobs/42")
    })
  })
})

describe("ChatJobStatusPanel blocker banner", () => {
  it("shows a red blocker banner when the job has a blocker", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([
      jobItem({
        blocker: { reason: "awaiting_review", description: "Waiting for PR review and approval" }
      })
    ]))

    renderPanel()

    expect(await screen.findByText("Awaiting review")).toBeInTheDocument()
  })

  it("shows a landing failed banner for landing_failed blockers", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([
      jobItem({
        state: "landing",
        blocker: { reason: "landing_failed", description: "Auto-merge failed" }
      })
    ]))

    renderPanel()

    expect(await screen.findByText("Landing failed")).toBeInTheDocument()
  })

  it("shows a dependency failed banner for dependency_failed blockers", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([
      jobItem({
        state: "queued",
        blocker: { reason: "dependency_failed", description: "A dependency failed" }
      })
    ]))

    renderPanel()

    expect(await screen.findByText("Dependency failed")).toBeInTheDocument()
  })
})

describe("ChatJobStatusPanel epic tree", () => {
  it("renders an epic section with title and progress pill", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([epicItem()]))

    renderPanel()

    expect(await screen.findByText("Aqueduct renovation")).toBeInTheDocument()
    expect(screen.getByText("EPIC-5")).toBeInTheDocument()
    expect(screen.getByText("1/3")).toBeInTheDocument()
  })

  it("renders child job cards under the epic when expanded", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([epicItem()]))

    renderPanel()

    expect(await screen.findByText("Survey route")).toBeInTheDocument()
    expect(screen.getByText("JOB-10")).toBeInTheDocument()
  })

  it("collapses and expands the epic section on header click", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse([epicItem()]))

    renderPanel()

    expect(await screen.findByText("Survey route")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Collapse Aqueduct renovation/ }))

    expect(screen.queryByText("Survey route")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Expand Aqueduct renovation/ }))

    expect(await screen.findByText("Survey route")).toBeInTheDocument()
  })
})

describe("ChatJobStatusPanel live updates", () => {
  it("invalidates the job_status query when a matching syrus:job-status-changed event fires", async () => {
    let callCount = 0
    vi.spyOn(window, "fetch").mockImplementation(() => {
      callCount++
      return Promise.resolve(jsonResponse([jobItem({ title: callCount === 1 ? "First load" : "After update" })]))
    })

    renderPanel(8)

    expect(await screen.findByText("First load")).toBeInTheDocument()

    window.dispatchEvent(new CustomEvent("syrus:job-status-changed", {
      detail: { job_id: 42, chat_session_id: 8 }
    }))

    expect(await screen.findByText("After update")).toBeInTheDocument()
  })

  it("does not invalidate when the chat_session_id does not match", async () => {
    let callCount = 0
    vi.spyOn(window, "fetch").mockImplementation(() => {
      callCount++
      return Promise.resolve(jsonResponse([jobItem({ title: "Stable title" })]))
    })

    renderPanel(8)

    expect(await screen.findByText("Stable title")).toBeInTheDocument()
    const fetchCountBefore = callCount

    window.dispatchEvent(new CustomEvent("syrus:job-status-changed", {
      detail: { job_id: 42, chat_session_id: 99 }
    }))

    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(callCount).toBe(fetchCountBefore)
  })
})
