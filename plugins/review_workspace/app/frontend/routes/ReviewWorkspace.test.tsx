import "@testing-library/jest-dom/vitest"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { createPortal } from "react-dom"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import ReviewWorkspaceRoute from "./ReviewWorkspace"

class TestPointerEvent extends MouseEvent {
  pointerId: number
  pointerType: string
  constructor(type: string, init: PointerEventInit = {}) {
    super(type, init)
    this.pointerId = init.pointerId ?? 1
    this.pointerType = init.pointerType ?? "touch"
  }
}

vi.stubGlobal("PointerEvent", TestPointerEvent)

const jobApi = vi.hoisted(() => ({
  fetchJobDetail: vi.fn(async () => ({
    job: { id: 42, summary_state: "implemented" },
    actions: { can_approve: true },
    paths: { app_approve_path: "/canonical/jobs/42/approve" }
  })),
  fetchJobTab: vi.fn(async (_id: string, tab: string) =>
    tab === "review"
      ? {
          typed_artifacts: [{ type: "security_review", title: "Security review approved", renderer_type: "data_table" }],
          visual_evidence: { screenshots: [] as Array<{ id: number }> }
        }
      : {}
  ),
  postJobCommand: vi.fn(async () => ({})),
  submitJobFeedback: vi.fn(async () => undefined)
}))

vi.mock("@app/api/jobs", () => jobApi)
vi.mock("@app/lib/entityStore", () => ({ normalizeJobDetailPayload: (payload: unknown) => payload }))
vi.mock("@app/routes/jobDetail/ReviewWorkspace", () => ({
  ReviewWorkspace: ({
    conversationPortalTarget,
    payload,
    showConversation,
    visualEvidenceNavigation
  }: {
    conversationPortalTarget?: Element | null
    payload?: { visual_evidence?: { screenshots?: unknown[] } }
    showConversation?: boolean
    visualEvidenceNavigation?: { direction: number }
  }) => (
    <div>
      Canonical review evidence
      <span>Conversation {showConversation === false ? "hidden" : "shown"}</span>
      <span>{payload?.visual_evidence?.screenshots?.length ? `${payload.visual_evidence.screenshots.length} screenshots` : "No screenshots"}</span>
      {conversationPortalTarget ? createPortal(<div>Canonical contributed findings</div>, conversationPortalTarget) : null}
      {visualEvidenceNavigation ? <span>Evidence direction {visualEvidenceNavigation.direction}</span> : null}
    </div>
  )
}))

afterEach(() => {
  document.documentElement.classList.remove("dark")
  vi.useRealTimers()
  vi.restoreAllMocks()
})

function renderRoute(path = "/review") {
  Object.defineProperty(window, "innerWidth", { configurable: true, value: 390 })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/review" element={<ReviewWorkspaceRoute />} />
          <Route path="/review/:job_id" element={<ReviewWorkspaceRoute />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ReviewWorkspaceRoute", () => {
  it("falls back from a stale deep link to the first eligible Job", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          count: 1,
          jobs: [
            {
              id: 42,
              slug: "JOB-42",
              title: "Review me",
              priority: "high",
              ready_at: "2026-11-19T00:00:00Z",
              dependency_blocked: false,
              repository: { id: 1, slug: "acme/widgets" },
              pr_number: 7
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    renderRoute("/review/JOB-999")

    expect(await screen.findByRole("heading", { name: "Review me" })).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("href", "/review/JOB-42"))
  })

  it("renders the caught-up state for an empty stack", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 0, jobs: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute()
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })

  it("uses canonical evidence and progresses after approval", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    expect(await screen.findByText("Canonical review evidence")).toBeInTheDocument()
    expect(screen.getByText("Conversation hidden")).toBeInTheDocument()
    const findings = screen.getByRole("region", { name: "Risk and review findings" })
    expect(within(findings).getByText("Canonical contributed findings")).toBeInTheDocument()
    expect(screen.queryByText("Security review approved")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Approve for landing (A)" }))
    fireEvent.click(screen.getByRole("button", { name: "Approve for landing" }))
    await waitFor(() => expect(jobApi.postJobCommand).toHaveBeenCalledWith("/canonical/jobs/42/approve"))
  })

  it("owns mobile scrolling inside the fixed dynamic-viewport workspace", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    await screen.findByText("Canonical review evidence")
    const workspace = screen.getByRole("main", { name: "Review" })
    const scroller = screen.getByTestId("review-workspace-scroll-container")
    expect(workspace).toHaveClass("h-dvh", "overflow-hidden")
    expect(scroller).toHaveClass("h-[calc(100dvh-4rem)]", "overflow-y-scroll", "overscroll-contain", "lg:overflow-hidden")
    expect(scroller).toContainElement(screen.getByRole("complementary", { name: "Decision context" }))
  })

  it("keeps narrow dark-appearance controls inside themed mobile surfaces", async () => {
    document.documentElement.classList.add("dark")
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    expect(screen.getByRole("main", { name: "Review" })).toHaveClass("bg-page", "text-text")
    expect(screen.getByRole("button", { name: "Job details" })).toHaveClass("min-h-11", "min-w-11", "bg-surface")
    expect(screen.getByRole("complementary", { name: "Decision context" })).toHaveClass("bg-surface")
  })

  it("focuses the discoverable exit and supports keyboard Job navigation", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    await waitFor(() => expect(screen.getByRole("button", { name: "Exit review workspace" })).toHaveFocus())
    fireEvent.keyDown(window, { key: "j" })
    await waitFor(() => expect(screen.getByRole("link", { name: /JOB-43/ })).toHaveAttribute("aria-current", "page"))
  })

  it("navigates canonical visual evidence with both arrow keys", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    fireEvent.keyDown(window, { key: "ArrowRight" })
    expect(await screen.findByText("Evidence direction 1")).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "ArrowLeft" })
    expect(await screen.findByText("Evidence direction -1")).toBeInTheDocument()
  })

  it("does not offer approval when the canonical payload denies it", async () => {
    jobApi.fetchJobDetail.mockResolvedValueOnce({
      job: { id: 42, summary_state: "implemented" },
      actions: { can_approve: false },
      paths: { app_approve_path: "/canonical/jobs/42/approve" }
    })
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    expect(await screen.findByRole("button", { name: "Approve for landing (A)" })).toBeDisabled()
    fireEvent.keyDown(window, { key: "a" })
    expect(screen.queryByText("Approve JOB-42 for landing?")).not.toBeInTheDocument()
  })

  it("submits feedback through the canonical chat-feedback endpoint and progresses the stack", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    await screen.findByText("Canonical review evidence")
    fireEvent.click(screen.getByRole("button", { name: "Give feedback (F)" }))
    fireEvent.change(await screen.findByLabelText("What should change?"), { target: { value: "Please tighten this." } })
    fireEvent.click(screen.getByRole("button", { name: "Send feedback" }))
    await waitFor(() => expect(jobApi.submitJobFeedback).toHaveBeenCalledWith(42, "Please tighten this."))
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })

  it("defers an item only for the current workspace session", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    fireEvent.click(await screen.findByRole("button", { name: "Defer for this session" }))
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })

  it("turns a rightward touch swipe into approval intent without approving", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 80, clientY: 200, pointerId: 1, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 170, clientY: 205, pointerId: 1, pointerType: "touch" })
    expect(screen.getByText("Release to review approval")).toBeInTheDocument()
    fireEvent.pointerUp(card, { clientX: 170, clientY: 205, pointerId: 1, pointerType: "touch" })
    expect(await screen.findByText("Approve JOB-42 for landing?")).toBeInTheDocument()
    expect(jobApi.postJobCommand).not.toHaveBeenCalled()
  })

  it("does not carry or replay approval gesture intent across Job navigation", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 80, clientY: 200, pointerId: 11, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 170, clientY: 200, pointerId: 11, pointerType: "touch" })
    fireEvent.click(await screen.findByRole("button", { name: "Cancel" }))
    fireEvent.keyDown(window, { key: "j" })
    await waitFor(() => expect(screen.getByRole("link", { name: /JOB-43/ })).toHaveAttribute("aria-current", "page"))
    await waitFor(() => expect(jobApi.fetchJobDetail).toHaveBeenCalledWith("43"))
    expect(screen.queryByText("Approve JOB-43 for landing?")).not.toBeInTheDocument()
    fireEvent.keyDown(window, { key: "k" })
    await waitFor(() => expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("aria-current", "page"))
    expect(screen.queryByText("Approve JOB-42 for landing?")).not.toBeInTheDocument()
  })

  it("arbitrates touch scrolling and boundary navigation without relying on pointer cancellation", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    const scroller = screen.getByTestId("review-workspace-scroll-container")
    Object.defineProperty(scroller, "clientHeight", { configurable: true, value: 300 })
    Object.defineProperty(scroller, "scrollHeight", { configurable: true, value: 1000 })
    scroller.scrollTop = 200
    let card = screen.getByTestId("mobile-review-card")
    expect(card).toHaveClass("touch-none")
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 12, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 150, clientY: 150, pointerId: 12, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 150, clientY: 150, pointerId: 12, pointerType: "touch" })
    expect(scroller.scrollTop).toBe(300)
    expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("aria-current", "page")

    scroller.scrollTop = 700
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 13, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 150, clientY: 150, pointerId: 13, pointerType: "touch" })
    fireEvent.pointerCancel(card, { clientX: 150, clientY: 150, pointerId: 13, pointerType: "touch" })
    expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("aria-current", "page")

    card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 14, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 150, clientY: 150, pointerId: 14, pointerType: "touch" })
    await waitFor(() => expect(screen.getByRole("link", { name: /JOB-43/ })).toHaveAttribute("aria-current", "page"))
  })

  it("supports mouse vertical navigation in both directions and cancels short gestures", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    let card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { button: 0, clientX: 150, clientY: 300, pointerId: 2, pointerType: "mouse" })
    fireEvent.pointerUp(card, { button: 0, clientX: 153, clientY: 260, pointerId: 2, pointerType: "mouse" })
    expect(screen.getAllByText("1 of 2 ready now")).toHaveLength(2)
    fireEvent.pointerDown(card, { button: 0, clientX: 150, clientY: 300, pointerId: 3, pointerType: "mouse" })
    fireEvent.pointerUp(card, { button: 0, clientX: 150, clientY: 210, pointerId: 3, pointerType: "mouse" })
    await waitFor(() => expect(screen.getAllByText("2 of 2 ready now")).toHaveLength(2))
    card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { button: 0, clientX: 150, clientY: 200, pointerId: 4, pointerType: "mouse" })
    fireEvent.pointerUp(card, { button: 0, clientX: 150, clientY: 290, pointerId: 4, pointerType: "mouse" })
    await waitFor(() => expect(screen.getAllByText("1 of 2 ready now")).toHaveLength(2))
  })

  it("opens details on long press and cancels the press after movement", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    vi.useFakeTimers()
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 5, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 120, clientY: 200, pointerId: 5, pointerType: "touch" })
    act(() => vi.advanceTimersByTime(600))
    expect(screen.queryByRole("dialog", { name: "Job details" })).not.toBeInTheDocument()
    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 6, pointerType: "touch" })
    act(() => vi.advanceTimersByTime(600))
    expect(screen.getByRole("dialog", { name: "Job details" })).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("defers with a leftward swipe and ignores browser-edge approval swipes", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 5, clientY: 200, pointerId: 7, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 100, clientY: 200, pointerId: 7, pointerType: "touch" })
    expect(screen.queryByText("Approve JOB-42 for landing?")).not.toBeInTheDocument()
    fireEvent.pointerDown(card, { clientX: 150, clientY: 200, pointerId: 8, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 60, clientY: 200, pointerId: 8, pointerType: "touch" })
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })

  it("passes multiple screenshots and the explicit no-screenshot state through canonical evidence", async () => {
    jobApi.fetchJobTab
      .mockImplementationOnce(async () => ({}))
      .mockImplementationOnce(async () => ({ typed_artifacts: [], visual_evidence: { screenshots: [{ id: 1 }, { id: 2 }] } }))
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify({ count: 1, jobs: [job()] }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
    )
    const first = renderRoute("/review/JOB-42")
    expect(await screen.findByText("2 screenshots")).toBeInTheDocument()
    first.unmount()
    renderRoute("/review/JOB-42")
    expect(await screen.findByText("No screenshots")).toBeInTheDocument()
  })

  it("refreshes eligibility and clears a stale Job after an approval error", async () => {
    let workspaceRequests = 0
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      workspaceRequests += 1
      const jobs = workspaceRequests === 1 ? [job()] : []
      return new Response(JSON.stringify({ count: jobs.length, jobs }), { status: 200, headers: { "Content-Type": "application/json" } })
    })
    jobApi.postJobCommand.mockRejectedValueOnce(new Error("Job is no longer eligible"))
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    fireEvent.click(screen.getByRole("button", { name: "Approve for landing (A)" }))
    fireEvent.click(screen.getByRole("button", { name: "Approve for landing" }))
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
    expect(workspaceRequests).toBeGreaterThan(1)
  })
})

function job() {
  return {
    id: 42,
    slug: "JOB-42",
    title: "Review me",
    priority: "high",
    ready_at: "2026-11-19T00:00:00Z",
    dependency_blocked: false,
    repository: { id: 1, slug: "acme/widgets" },
    pr_number: 7
  }
}
