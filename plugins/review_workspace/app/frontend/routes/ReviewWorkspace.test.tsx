import "@testing-library/jest-dom/vitest"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { createPortal } from "react-dom"
import { useState } from "react"
import { createMemoryRouter, Link, MemoryRouter, Route, RouterProvider, Routes, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import ReviewWorkspaceRoute from "./ReviewWorkspace"
import { resetReviewSessionStoreForTests } from "../lib/reviewSession"

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
  fetchJobDetail: vi.fn(async (id = "42") => ({
    job: { id: Number(id), summary_state: "implemented" },
    actions: { can_approve: true },
    paths: { app_approve_path: "/canonical/jobs/42/approve", job_path: "/jobs/JOB-42" }
  })),
  fetchJobTab: vi.fn(async (_id: string, tab: string): Promise<Record<string, unknown>> =>
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

const hapticsMock = vi.hoisted(() => ({ selection: vi.fn(), impact: vi.fn() }))
vi.mock("@app/lib/iosHaptics", () => ({ haptics: hapticsMock }))
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
    payload?: { job?: { id: number }; visual_evidence?: { screenshots?: unknown[] } }
    showConversation?: boolean
    visualEvidenceNavigation?: { direction: number }
  }) => {
    const [intrinsicWidth, setIntrinsicWidth] = useState(640)
    return (
      <div className="w-full min-w-0 max-w-full" data-testid="canonical-review-workspace">
        Canonical review evidence for Job {payload?.job?.id}
        <span>Conversation {showConversation === false ? "hidden" : "shown"}</span>
        <span>{payload?.visual_evidence?.screenshots?.length ? `${payload.visual_evidence.screenshots.length} screenshots` : "No screenshots"}</span>
        <p className="break-words">{"A long Job summary ".repeat(20)}</p>
        <button onClick={() => setIntrinsicWidth((width) => (width === 640 ? 960 : 640))} type="button">
          Switch review version
        </button>
        <button type="button">Show all captured</button>
        <div className="w-full min-w-0 max-w-full overflow-x-scroll" data-intrinsic-width={intrinsicWidth} data-testid="diff-file-scroll">
          <div style={{ width: `${intrinsicWidth}px` }}>{"long/unbroken/path/".repeat(30)}</div>
        </div>
        {conversationPortalTarget ? createPortal(<div>Canonical contributed findings</div>, conversationPortalTarget) : null}
        {visualEvidenceNavigation ? <span>Evidence direction {visualEvidenceNavigation.direction}</span> : null}
      </div>
    )
  }
}))

afterEach(() => {
  window.localStorage.clear()
  window.sessionStorage.clear()
  resetReviewSessionStoreForTests()
  document.documentElement.classList.remove("dark")
  vi.useRealTimers()
  vi.restoreAllMocks()
})

function renderRoute(path = "/review", width = 390) {
  Object.defineProperty(window, "innerWidth", { configurable: true, value: width })
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

function railLink(name: RegExp) {
  return within(screen.getByRole("complementary", { name: "Ready now" })).getByRole("link", { name })
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function renderSessionRouter(entryPath: string, reviewPath: string, width = 390) {
  Object.defineProperty(window, "innerWidth", { configurable: true, value: width })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const prefix = entryPath.startsWith("/app-shell") ? "/app-shell" : ""
  const router = createMemoryRouter(
    [
      {
        path: "*",
        element: (
          <>
            <LocationProbe />
            <Link to={reviewPath}>Enter review</Link>
          </>
        )
      },
      { path: `${prefix}/review`, element: <ReviewWorkspaceRoute /> },
      { path: `${prefix}/review/:job_id`, element: <ReviewWorkspaceRoute /> }
    ],
    { initialEntries: [entryPath] }
  )
  render(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  )
  return router
}

function reviewJobs(count = 4) {
  return Array.from({ length: count }, (_, index) => ({ ...job(), id: 42 + index, slug: `JOB-${42 + index}`, title: `Review ${index + 1}` }))
}

describe("ReviewWorkspaceRoute", () => {
  it("keeps button and gesture movement inside one dashboard review history entry", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 4, jobs: reviewJobs() }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderSessionRouter("/dashboard/jobs", "/review")
    fireEvent.click(screen.getByRole("link", { name: "Enter review" }))

    await screen.findByRole("heading", { name: "Review 1" })
    fireEvent.click(screen.getByRole("button", { name: "Next Job" }))
    await screen.findByRole("heading", { name: "Review 2" })
    let card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 31, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 150, clientY: 150, pointerId: 31, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 150, clientY: 150, pointerId: 31, pointerType: "touch" })
    await screen.findByRole("heading", { name: "Review 3" })
    card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 32, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 150, clientY: 150, pointerId: 32, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 150, clientY: 150, pointerId: 32, pointerType: "touch" })
    await screen.findByRole("heading", { name: "Review 4" })

    fireEvent.click(screen.getByRole("button", { name: "Exit review workspace" }))
    expect(await screen.findByTestId("location")).toHaveTextContent("/dashboard/jobs")
  })

  it("returns to another in-app entry route with X after a canonical redirect", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 4, jobs: reviewJobs() }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const router = renderSessionRouter("/settings/profile", "/review/42")
    fireEvent.click(screen.getByRole("link", { name: "Enter review" }))
    await waitFor(() => expect(router.state.location.pathname).toBe("/review/JOB-42"))
    await screen.findByRole("heading", { name: "Review 1" })
    fireEvent.click(screen.getByRole("button", { name: "Next Job" }))
    await waitFor(() => expect(router.state.location.pathname).toBe("/review/JOB-43"))

    fireEvent.click(screen.getByRole("button", { name: "Exit review workspace" }))
    expect(await screen.findByTestId("location")).toHaveTextContent("/settings/profile")
  })

  it("makes browser Back leave the session after internal Job movement", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 4, jobs: reviewJobs() }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const router = renderSessionRouter("/repositories/7", "/review/JOB-42")
    fireEvent.click(screen.getByRole("link", { name: "Enter review" }))
    await screen.findByRole("heading", { name: "Review 1" })
    fireEvent.click(screen.getByRole("button", { name: "Next Job" }))
    await screen.findByRole("heading", { name: "Review 2" })

    await router.navigate(-1)
    expect(await screen.findByTestId("location")).toHaveTextContent("/repositories/7")
  })

  it("uses the prefixed dashboard fallback for a direct deep link", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 390 })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const router = createMemoryRouter(
      [
        { path: "/app-shell/review/:job_id", element: <ReviewWorkspaceRoute /> },
        { path: "/app-shell/dashboard/jobs", element: <LocationProbe /> }
      ],
      { initialEntries: ["/app-shell/review/JOB-42"] }
    )
    render(
      <QueryClientProvider client={client}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    )
    fireEvent.click(await screen.findByRole("button", { name: "Exit review workspace" }))
    expect(await screen.findByTestId("location")).toHaveTextContent("/app-shell/dashboard/jobs")
  })

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
    await waitFor(() => expect(railLink(/JOB-42/)).toHaveAttribute("href", "/review/JOB-42"))
  })

  it("renders the caught-up state for an empty stack", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 0, jobs: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute()
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })

  it("uses the compact mobile hierarchy and progresses after approval", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    expect(await screen.findByTestId("mobile-review-summary")).toBeInTheDocument()
    expect(screen.queryByText("Canonical review evidence")).not.toBeInTheDocument()
    expect(screen.getByTestId("mobile-gesture-coach")).toBeInTheDocument()
    expect(screen.queryByText(/J \/ K move/)).not.toBeInTheDocument()
    expect(screen.queryByText("Security review approved")).not.toBeInTheDocument()
    const actions = screen.getByRole("complementary", { name: "Decision context" })
    const buttons = within(actions).getAllByRole("button")
    expect(buttons.map((button) => button.getAttribute("aria-label") ?? button.textContent)).toEqual(["Approve", "Give feedback", "Defer for this session"])
    expect(buttons[0]).toHaveClass("max-lg:order-2", "max-lg:col-span-2", "max-lg:min-h-11")
    expect(buttons[1]).toHaveClass("max-lg:order-3", "max-lg:min-h-11")
    expect(buttons[2]).toHaveClass("max-lg:order-1", "max-lg:min-h-11")
    expect(within(buttons[1]).queryByText("Give feedback")).toHaveClass("max-lg:hidden")
    expect(within(buttons[2]).queryByText("Defer for this session")).toHaveClass("max-lg:hidden")
    fireEvent.click(screen.getByRole("button", { name: "Approve" }))
    fireEvent.click(screen.getByRole("button", { name: "Approve for landing" }))
    await waitFor(() => expect(jobApi.postJobCommand).toHaveBeenCalledWith("/canonical/jobs/42/approve", { expected_revision: 3 }))
  })

  it("preserves the desktop decision action order", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42", 1280)

    await screen.findByText("Canonical review evidence for Job 42")
    const actions = screen.getByRole("complementary", { name: "Decision context" })
    expect(
      within(actions)
        .getAllByRole("button")
        .map((button) => button.getAttribute("aria-label") ?? button.textContent)
    ).toEqual(["Approve for landing (A)", "Give feedback", "Defer for this session"])
    expect(within(actions).getByRole("button", { name: "Approve for landing (A)" })).toBeInTheDocument()
    expect(within(actions).getByRole("button", { name: "Give feedback" })).toHaveTextContent("Give feedback (F)")
  })

  it("owns mobile scrolling inside the fixed dynamic-viewport workspace", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    await screen.findByTestId("mobile-review-summary")
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
    await screen.findByTestId("mobile-review-summary")
    expect(screen.getByRole("main", { name: "Review" })).toHaveClass("bg-page", "text-text")
    expect(screen.getByRole("button", { name: "Job details" })).toHaveClass("min-h-11", "min-w-11", "bg-surface")
    expect(screen.getByRole("complementary", { name: "Decision context" })).toHaveClass("max-lg:bg-transparent")
  })

  it("focuses the discoverable exit and supports keyboard Job navigation", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    await waitFor(() => expect(screen.getByRole("button", { name: "Exit review workspace" })).toHaveFocus())
    fireEvent.keyDown(window, { key: "j" })
    await waitFor(() => expect(railLink(/JOB-43/)).toHaveAttribute("aria-current", "page"))
  })

  it("navigates mobile visual evidence with both arrow keys", async () => {
    jobApi.fetchJobTab
      .mockImplementationOnce(async () => ({}))
      .mockImplementationOnce(async () => ({ visual_evidence: { captured_count: 2, submitted_count: 2, screenshots: [screenshot(1), screenshot(2)] } }))
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const carousel = configureCarousel(320)
    expect(screen.getByText("1 of 2")).toHaveClass("sr-only")
    fireEvent.keyDown(window, { key: "ArrowRight" })
    expect(carousel.scrollTo).toHaveBeenLastCalledWith({ behavior: "smooth", left: 320 })
    await waitFor(() => expect(screen.getByText("2 of 2")).toBeInTheDocument())
    fireEvent.keyDown(window, { key: "ArrowLeft" })
    await waitFor(() => expect(screen.getByText("1 of 2")).toBeInTheDocument())
  })

  it("does not offer approval when the canonical payload denies it", async () => {
    jobApi.fetchJobDetail.mockResolvedValueOnce({
      job: { id: 42, summary_state: "implemented" },
      actions: { can_approve: false },
      paths: { app_approve_path: "/canonical/jobs/42/approve", job_path: "/jobs/JOB-42" }
    })
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    expect(await screen.findByRole("button", { name: "Approve" })).toBeDisabled()
    fireEvent.keyDown(window, { key: "a" })
    expect(screen.queryByText("Approve JOB-42 for landing?")).not.toBeInTheDocument()
  })

  it("submits feedback through the canonical chat-feedback endpoint and progresses the stack", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    await screen.findByTestId("mobile-review-summary")
    fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))
    fireEvent.change(await screen.findByLabelText("What should change?"), { target: { value: "Please tighten this." } })
    fireEvent.click(screen.getByRole("button", { name: "Send feedback" }))
    await waitFor(() => expect(jobApi.submitJobFeedback).toHaveBeenCalledWith(42, "Please tighten this.", 3))
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
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    const decisionTouchRegion = screen.getByTestId("mobile-decision-touch-region")
    expect(decisionTouchRegion).toHaveClass("touch-none")
    expect(decisionTouchRegion).not.toHaveClass("touch-pan-x", "touch-pan-y")
    fireEvent.pointerDown(decisionTouchRegion, { clientX: 80, clientY: 200, pointerId: 1, pointerType: "touch" })
    fireEvent.pointerMove(decisionTouchRegion, { clientX: 170, clientY: 205, pointerId: 1, pointerType: "touch" })
    expect(screen.getByTestId("mobile-gesture-action")).toHaveTextContent("Approve")
    expect(card.style.transform).toBe("translate3d(90px, 0px, 0) rotate(3deg)")
    expect(card.style.transformOrigin).toBe("50% 75%")
    const reveal = screen.getByTestId("mobile-gesture-reveal")
    expect(reveal).toHaveClass("absolute", "inset-y-0", "w-[min(8.5rem,calc(100vw_-_1rem))]", "left-[max(.5rem,env(safe-area-inset-left))]", "z-20")
    expect(reveal).not.toHaveAttribute("style")
    expect(reveal).toHaveAttribute("aria-label", "Release to review approval")
    expect(screen.getByTestId("mobile-gesture-action")).toHaveClass("w-full", "whitespace-nowrap", "shrink-0", "text-xs")
    expect(reveal).not.toHaveClass("fixed", "top-20")
    expect(card).toHaveClass("relative", "z-10")
    fireEvent.pointerUp(decisionTouchRegion, { clientX: 170, clientY: 205, pointerId: 1, pointerType: "touch" })
    expect(card.style.transform).toBe("")
    expect(await screen.findByText("Approve JOB-42 for landing?")).toBeInTheDocument()
    expect(jobApi.postJobCommand).not.toHaveBeenCalled()
  })

  it("keeps ambiguous touch motion pending, then locks and arms one horizontal action", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    const scroller = screen.getByTestId("review-workspace-scroll-container")
    scroller.scrollTop = 40

    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 501, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 104, clientY: 208, pointerId: 501, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 125, clientY: 223, pointerId: 501, pointerType: "touch" })
    expect(screen.queryByTestId("mobile-gesture-reveal")).not.toBeInTheDocument()
    expect(scroller.scrollTop).toBe(40)

    fireEvent.pointerMove(card, { clientX: 135, clientY: 220, pointerId: 501, pointerType: "touch" })
    expect(screen.getByTestId("mobile-gesture-reveal")).toHaveAttribute("data-gesture-direction", "right")
    fireEvent.pointerMove(card, { clientX: 140, clientY: 320, pointerId: 501, pointerType: "touch" })
    expect(card.style.transform).toContain("translate3d(40px, 0px, 0)")
    expect(screen.getByTestId("mobile-gesture-action")).toHaveTextContent("Approve")
    expect(scroller.scrollTop).toBe(40)

    fireEvent.pointerMove(card, { clientX: 190, clientY: 320, pointerId: 501, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 120, clientY: 100, pointerId: 501, pointerType: "touch" })
    expect(screen.getByTestId("mobile-gesture-reveal")).toHaveAttribute("data-gesture-direction", "right")
    fireEvent.pointerUp(card, { clientX: 120, clientY: 100, pointerId: 501, pointerType: "touch" })

    expect(await screen.findByRole("dialog", { name: "Approve JOB-42 for landing?" })).toBeInTheDocument()
    expect(screen.getAllByRole("dialog", { name: "Approve JOB-42 for landing?" })).toHaveLength(1)
  })

  it("clicks at distance increments while dragging and impacts only on a left or right commit", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    hapticsMock.selection.mockClear()
    hapticsMock.impact.mockClear()

    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 601, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 108, clientY: 200, pointerId: 601, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 120, clientY: 200, pointerId: 601, pointerType: "touch" })
    expect(hapticsMock.selection).not.toHaveBeenCalled()
    fireEvent.pointerMove(card, { clientX: 130, clientY: 200, pointerId: 601, pointerType: "touch" })
    expect(hapticsMock.selection).toHaveBeenCalledTimes(1)
    fireEvent.pointerMove(card, { clientX: 130, clientY: 200, pointerId: 601, pointerType: "touch" })
    expect(hapticsMock.selection).toHaveBeenCalledTimes(1)
    expect(hapticsMock.impact).not.toHaveBeenCalled()

    fireEvent.pointerMove(card, { clientX: 180, clientY: 200, pointerId: 601, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 180, clientY: 200, pointerId: 601, pointerType: "touch" })
    expect(hapticsMock.impact).toHaveBeenCalledTimes(1)
    expect(hapticsMock.impact).toHaveBeenCalledWith("medium")
  })

  it("does not give haptics for a released, uncommitted drag", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    hapticsMock.impact.mockClear()
    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 602, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 130, clientY: 200, pointerId: 602, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 130, clientY: 200, pointerId: 602, pointerType: "touch" })
    expect(hapticsMock.impact).not.toHaveBeenCalled()
  })

  it("keeps interactive summary targets action-free while allowing locked vertical reading scroll", async () => {
    jobApi.fetchJobTab
      .mockImplementationOnce(async () => ({ summary: { text: "Read the [review guide](https://example.com/review)." } }))
      .mockImplementationOnce(async () => ({ visual_evidence: { screenshots: [] } }))
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    const link = await screen.findByRole("link", { name: "review guide" })
    const scroller = screen.getByTestId("review-workspace-scroll-container")
    Object.defineProperty(scroller, "clientHeight", { configurable: true, value: 300 })
    Object.defineProperty(scroller, "scrollHeight", { configurable: true, value: 1000 })
    scroller.scrollTop = 200

    fireEvent.pointerDown(link, { clientX: 120, clientY: 240, pointerId: 505, pointerType: "touch" })
    fireEvent.pointerMove(link, { clientX: 126, clientY: 232, pointerId: 505, pointerType: "touch" })
    expect(scroller.scrollTop).toBe(200)
    fireEvent.pointerMove(link, { clientX: 128, clientY: 160, pointerId: 505, pointerType: "touch" })
    expect(scroller.scrollTop).toBe(280)
    expect(screen.queryByTestId("mobile-gesture-reveal")).not.toBeInTheDocument()
    fireEvent.pointerUp(link, { clientX: 128, clientY: 160, pointerId: 505, pointerType: "touch" })
    expect(screen.queryByRole("dialog", { name: /Approve/ })).not.toBeInTheDocument()

    fireEvent.pointerDown(link, { clientX: 100, clientY: 200, pointerId: 506, pointerType: "touch" })
    fireEvent.pointerMove(link, { clientX: 190, clientY: 205, pointerId: 506, pointerType: "touch" })
    fireEvent.pointerUp(link, { clientX: 190, clientY: 205, pointerId: 506, pointerType: "touch" })
    expect(screen.queryByTestId("mobile-gesture-reveal")).not.toBeInTheDocument()
    expect(screen.queryByRole("dialog", { name: /Approve/ })).not.toBeInTheDocument()
  })

  it("cancels unarmed, cancelled, and lost-capture gestures without replaying intent", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")

    fireEvent.pointerDown(card, { clientX: 150, clientY: 200, pointerId: 502, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 100, clientY: 190, pointerId: 502, pointerType: "touch" })
    expect(screen.getByTestId("mobile-gesture-reveal")).toHaveAttribute("data-gesture-direction", "left")
    fireEvent.pointerUp(card, { clientX: 100, clientY: 190, pointerId: 502, pointerType: "touch" })
    expect(screen.queryByRole("heading", { name: "All caught up" })).not.toBeInTheDocument()

    fireEvent.pointerDown(card, { clientX: 150, clientY: 200, pointerId: 503, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 55, clientY: 210, pointerId: 503, pointerType: "touch" })
    fireEvent.pointerCancel(card, { pointerId: 503, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 55, clientY: 210, pointerId: 503, pointerType: "touch" })

    fireEvent.pointerDown(card, { clientX: 150, clientY: 200, pointerId: 504, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 245, clientY: 190, pointerId: 504, pointerType: "touch" })
    fireEvent.lostPointerCapture(card, { pointerId: 504, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 245, clientY: 190, pointerId: 504, pointerType: "touch" })

    expect(card.style.transform).toBe("")
    expect(screen.queryByTestId("mobile-gesture-reveal")).not.toBeInTheDocument()
    expect(screen.queryByRole("dialog", { name: /Approve/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "All caught up" })).not.toBeInTheDocument()
  })

  it.each([320, 430])("keeps horizontal action cues stable across drag progress at a %ipx viewport", async (viewport) => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42", viewport)
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    const documentScrollLeft = document.documentElement.scrollLeft

    for (const distance of [16, 48, 72, 120]) {
      for (const direction of [-1, 1]) {
        const pointerId = distance + direction + 200
        fireEvent.pointerDown(card, { clientX: 160, clientY: 220, pointerId, pointerType: "touch" })
        fireEvent.pointerMove(card, { clientX: 160 + distance * direction, clientY: 221, pointerId, pointerType: "touch" })
        const reveal = screen.getByTestId("mobile-gesture-reveal")
        const action = screen.getByTestId("mobile-gesture-action")
        expect(reveal).toHaveClass("z-20", "w-[min(8.5rem,calc(100vw_-_1rem))]")
        expect(reveal.style.width).toBe("")
        expect(reveal).toHaveAttribute("data-gesture-direction", direction > 0 ? "right" : "left")
        expect(action).toHaveTextContent(direction > 0 ? "Approve" : "Defer")
        expect(action).toHaveClass("whitespace-nowrap")
        expect(action).not.toHaveClass("break-words", "truncate", "overflow-hidden")
        expect(Number(action.style.opacity)).toBeGreaterThan(0)
        expect(document.documentElement.scrollLeft).toBe(documentScrollLeft)
        fireEvent.pointerCancel(card, { pointerId, pointerType: "touch" })
        expect(card.style.transform).toBe("")
        expect(screen.queryByTestId("mobile-gesture-reveal")).not.toBeInTheDocument()
      }
    }

    fireEvent.pointerDown(card, { clientX: 160, clientY: 220, pointerId: 399, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 205, clientY: 220, pointerId: 399, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 205, clientY: 220, pointerId: 399, pointerType: "touch" })
    expect(card.style.transform).toBe("")
    expect(screen.queryByRole("dialog", { name: /Approve/ })).not.toBeInTheDocument()
  })

  it("keeps the longest localized horizontal action inside the fixed narrow-phone cue", async () => {
    await i18n.changeLanguage("de")
    try {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(
        new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
      )
      renderRoute("/review/JOB-42", 320)
      await screen.findByTestId("mobile-review-summary")
      const card = screen.getByTestId("mobile-review-card")

      fireEvent.pointerDown(card, { clientX: 160, clientY: 220, pointerId: 410, pointerType: "touch" })
      fireEvent.pointerMove(card, { clientX: 40, clientY: 220, pointerId: 410, pointerType: "touch" })

      const reveal = screen.getByTestId("mobile-gesture-reveal")
      const action = screen.getByTestId("mobile-gesture-action")
      expect(reveal).toHaveClass("z-20", "w-[min(8.5rem,calc(100vw_-_1rem))]")
      expect(reveal.style.width).toBe("")
      expect(action).toHaveTextContent("Zurückstellen")
      expect(action).toHaveClass("w-full", "whitespace-nowrap", "gap-1", "px-1.5", "text-xs")
      expect(action).not.toHaveClass("overflow-hidden", "truncate", "text-ellipsis")
      expect(action.querySelector("svg")).toHaveClass("h-3.5", "w-3.5", "shrink-0")
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("bounds rotation by drag direction and keeps vertical and reduced-motion gestures rotation-free", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")

    fireEvent.pointerDown(card, { clientX: 180, clientY: 200, pointerId: 21, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 30, clientY: 202, pointerId: 21, pointerType: "touch" })
    expect(card.style.transform).toContain("translate3d(-120px, 0px, 0)")
    expect(card.style.transform).toContain("rotate(-4deg)")
    expect(screen.getByTestId("mobile-gesture-reveal")).toHaveClass("right-[max(.5rem,env(safe-area-inset-right))]", "w-[min(8.5rem,calc(100vw_-_1rem))]")
    expect(screen.getByTestId("mobile-gesture-reveal").style.width).toBe("")
    fireEvent.pointerCancel(card, { pointerId: 21, pointerType: "touch" })
    expect(card.style.transform).toBe("")

    fireEvent.pointerDown(card, { clientX: 180, clientY: 240, pointerId: 22, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 182, clientY: 180, pointerId: 22, pointerType: "touch" })
    expect(card.style.transform).toBe("translate3d(0px, -60px, 0)")
    expect(card.style.transform).not.toContain("rotate")
    expect(screen.getByTestId("mobile-gesture-reveal")).toHaveAttribute("data-gesture-direction", "up")
    expect(screen.getByTestId("mobile-gesture-action")).toHaveClass("w-[min(12rem,70vw)]", "whitespace-nowrap")
    expect(screen.getByTestId("mobile-gesture-action")).toHaveTextContent("Next")
    fireEvent.pointerCancel(card, { pointerId: 22, pointerType: "touch" })

    fireEvent.pointerDown(card, { clientX: 180, clientY: 180, pointerId: 24, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 178, clientY: 240, pointerId: 24, pointerType: "touch" })
    expect(screen.getByTestId("mobile-gesture-reveal")).toHaveAttribute("data-gesture-direction", "down")
    expect(screen.getByTestId("mobile-gesture-action")).toHaveTextContent("Previous")
    fireEvent.pointerCancel(card, { pointerId: 24, pointerType: "touch" })

    const originalMatchMedia = window.matchMedia
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }))
    )
    fireEvent.pointerDown(card, { clientX: 80, clientY: 200, pointerId: 23, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 170, clientY: 200, pointerId: 23, pointerType: "touch" })
    expect(card.style.transform).toBe("")
    expect(screen.getByTestId("mobile-gesture-action")).toHaveTextContent("Approve")
    expect(screen.getByTestId("mobile-gesture-action")).not.toHaveAttribute("style")
    fireEvent.pointerUp(card, { clientX: 170, clientY: 200, pointerId: 23, pointerType: "touch" })
    expect(await screen.findByRole("dialog", { name: "Approve JOB-42 for landing?" })).toBeInTheDocument()
    vi.stubGlobal("matchMedia", originalMatchMedia)
  })

  it("opens mobile approval in a separate safe-area sheet without reflowing the action grid", async () => {
    const openerTitle = "A deliberately long Job title that wraps across a narrow iPhone viewport without colliding with gesture intent"
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [{ ...job(), title: openerTitle }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )
    renderRoute("/review/JOB-42", 375)
    await screen.findByRole("heading", { name: openerTitle })
    const approveButton = screen.getByRole("button", { name: "Approve" })
    const actionBar = approveButton.parentElement
    expect(actionBar).toHaveClass("max-lg:grid-cols-4")
    approveButton.focus()
    fireEvent.click(approveButton)

    const dialog = screen.getByRole("dialog", { name: "Approve JOB-42 for landing?" })
    expect(dialog).not.toBe(actionBar)
    expect(dialog).toHaveClass("rounded-t-2xl", "bg-surface", "pb-[max(1.25rem,env(safe-area-inset-bottom))]")
    expect(screen.getByTestId("mobile-approval-backdrop")).toHaveClass("fixed", "inset-0", "z-[70]")
    expect(actionBar).toHaveClass("max-lg:grid-cols-4")
    expect(within(actionBar!).getAllByRole("button")).toHaveLength(3)
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus()
    expect(document.body.style.overflow).toBe("hidden")

    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("dialog", { name: "Approve JOB-42 for landing?" })).not.toBeInTheDocument()
    expect(document.body.style.overflow).toBe("")
    expect(approveButton).toHaveFocus()
  })

  it("does not carry or replay approval gesture intent across Job navigation", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 80, clientY: 200, pointerId: 11, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 170, clientY: 200, pointerId: 11, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 170, clientY: 200, pointerId: 11, pointerType: "touch" })
    fireEvent.click(await screen.findByRole("button", { name: "Cancel" }))
    fireEvent.keyDown(window, { key: "j" })
    await waitFor(() => expect(railLink(/JOB-43/)).toHaveAttribute("aria-current", "page"))
    await waitFor(() => expect(jobApi.fetchJobDetail).toHaveBeenCalledWith("43"))
    expect(screen.queryByText("Approve JOB-43 for landing?")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Job details" }))
    expect(await screen.findByText("Canonical review evidence for Job 43")).toBeInTheDocument()
    expect(screen.queryByText("Canonical review evidence for Job 42")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Close Job details" }))
    fireEvent.keyDown(window, { key: "k" })
    await waitFor(() => expect(railLink(/JOB-42/)).toHaveAttribute("aria-current", "page"))
    expect(screen.queryByText("Approve JOB-42 for landing?")).not.toBeInTheDocument()
  })

  it("arbitrates touch scrolling and boundary navigation without relying on pointer cancellation", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const scroller = screen.getByTestId("review-workspace-scroll-container")
    Object.defineProperty(scroller, "clientHeight", { configurable: true, value: 300 })
    Object.defineProperty(scroller, "scrollHeight", { configurable: true, value: 1000 })
    scroller.scrollTop = 200
    let card = screen.getByTestId("mobile-review-card")
    expect(card).not.toHaveClass("touch-pan-x", "touch-pan-y", "touch-none")
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 12, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 158, clientY: 244, pointerId: 12, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 172, clientY: 228, pointerId: 12, pointerType: "touch" })
    expect(scroller.scrollTop).toBe(200)
    fireEvent.pointerMove(card, { clientX: 170, clientY: 150, pointerId: 12, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 150, clientY: 150, pointerId: 12, pointerType: "touch" })
    expect(scroller.scrollTop).toBe(300)
    expect(railLink(/JOB-42/)).toHaveAttribute("aria-current", "page")

    scroller.scrollTop = 700
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 13, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 150, clientY: 150, pointerId: 13, pointerType: "touch" })
    fireEvent.pointerCancel(card, { clientX: 150, clientY: 150, pointerId: 13, pointerType: "touch" })
    expect(railLink(/JOB-42/)).toHaveAttribute("aria-current", "page")

    card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 150, clientY: 250, pointerId: 14, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 150, clientY: 150, pointerId: 14, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 150, clientY: 150, pointerId: 14, pointerType: "touch" })
    await waitFor(() => expect(railLink(/JOB-43/)).toHaveAttribute("aria-current", "page"))
  })

  it("supports mouse vertical navigation in both directions and cancels short gestures", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    let card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { button: 0, clientX: 150, clientY: 300, pointerId: 2, pointerType: "mouse" })
    fireEvent.pointerUp(card, { button: 0, clientX: 153, clientY: 260, pointerId: 2, pointerType: "mouse" })
    expect(screen.getAllByText("1 of 2 ready now")).toHaveLength(2)
    fireEvent.pointerDown(card, { button: 0, clientX: 150, clientY: 300, pointerId: 3, pointerType: "mouse" })
    fireEvent.pointerMove(card, { button: 0, clientX: 150, clientY: 210, pointerId: 3, pointerType: "mouse" })
    fireEvent.pointerUp(card, { button: 0, clientX: 150, clientY: 210, pointerId: 3, pointerType: "mouse" })
    await waitFor(() => expect(screen.getAllByText("2 of 2 ready now")).toHaveLength(2))
    card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { button: 0, clientX: 150, clientY: 200, pointerId: 4, pointerType: "mouse" })
    fireEvent.pointerMove(card, { button: 0, clientX: 150, clientY: 290, pointerId: 4, pointerType: "mouse" })
    fireEvent.pointerUp(card, { button: 0, clientX: 150, clientY: 290, pointerId: 4, pointerType: "mouse" })
    await waitFor(() => expect(screen.getAllByText("1 of 2 ready now")).toHaveLength(2))
  })

  it("opens details on long press and cancels the press after movement", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    vi.useFakeTimers()
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 5, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 120, clientY: 200, pointerId: 5, pointerType: "touch" })
    act(() => vi.advanceTimersByTime(600))
    expect(screen.queryByRole("dialog", { name: "Job details" })).not.toBeInTheDocument()
    fireEvent.pointerDown(card, { clientX: 100, clientY: 200, pointerId: 6, pointerType: "touch" })
    act(() => vi.advanceTimersByTime(600))
    expect(screen.getByRole("dialog", { name: "Job details" })).toBeInTheDocument()
    expect(screen.getByText("Canonical review evidence for Job 42")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("contains content-dependent horizontal overflow inside the mobile details diff scroller", async () => {
    const longTitle = `Review ${"an unusually long unbroken Job title".repeat(8)}`
    const longPath = `${"nested-directory/".repeat(18)}repository`
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [{ ...job(), title: longTitle, repository: { id: 1, slug: longPath } }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )
    renderRoute("/review/JOB-42", 375)
    await screen.findByRole("heading", { name: longTitle })

    const documentScrollLeft = document.documentElement.scrollLeft
    fireEvent.click(screen.getByRole("button", { name: "Job details" }))

    const dialog = await screen.findByRole("dialog", { name: "Job details" })
    const backdrop = screen.getByTestId("mobile-details-backdrop")
    const content = screen.getByTestId("mobile-details-content")
    const diffScroller = screen.getByTestId("diff-file-scroll")
    expect(backdrop).toHaveClass("w-full", "max-w-full", "overflow-x-hidden")
    expect(dialog).toHaveClass("w-full", "min-w-0", "max-w-full", "overflow-x-hidden", "overflow-y-auto")
    expect(content).toHaveClass("w-full", "min-w-0", "max-w-full")
    expect(screen.getByTestId("canonical-review-workspace")).toHaveClass("w-full", "min-w-0", "max-w-full")
    expect(diffScroller).toHaveClass("w-full", "min-w-0", "max-w-full", "overflow-x-scroll")

    Object.defineProperties(dialog, {
      clientWidth: { configurable: true, value: 335 },
      scrollWidth: { configurable: true, value: 335 }
    })
    Object.defineProperties(diffScroller, {
      clientWidth: { configurable: true, value: 303 },
      scrollWidth: { configurable: true, get: () => Number(diffScroller.dataset.intrinsicWidth) }
    })
    expect(dialog.scrollWidth).toBe(dialog.clientWidth)
    expect(diffScroller.scrollWidth).toBeGreaterThan(diffScroller.clientWidth)
    expect(document.documentElement.scrollLeft).toBe(documentScrollLeft)
    expect(dialog.scrollLeft).toBe(0)

    fireEvent.click(screen.getByRole("button", { name: "Switch review version" }))
    expect(diffScroller).toHaveAttribute("data-intrinsic-width", "960")
    expect(dialog.scrollWidth).toBe(dialog.clientWidth)
    expect(diffScroller.scrollWidth).toBeGreaterThan(diffScroller.clientWidth)
    expect(document.documentElement.scrollLeft).toBe(documentScrollLeft)
    expect(dialog.scrollLeft).toBe(0)

    fireEvent.click(screen.getByRole("button", { name: "Show all captured" }))
    fireEvent.click(screen.getByRole("button", { name: "Close Job details" }))
    expect(screen.queryByRole("dialog", { name: "Job details" })).not.toBeInTheDocument()
    expect(document.documentElement.scrollLeft).toBe(documentScrollLeft)
  })

  it("defers with a leftward swipe and ignores browser-edge approval swipes", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const card = screen.getByTestId("mobile-review-card")
    fireEvent.pointerDown(card, { clientX: 5, clientY: 200, pointerId: 7, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 100, clientY: 200, pointerId: 7, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 100, clientY: 200, pointerId: 7, pointerType: "touch" })
    expect(screen.queryByText("Approve JOB-42 for landing?")).not.toBeInTheDocument()
    fireEvent.pointerDown(card, { clientX: 150, clientY: 200, pointerId: 8, pointerType: "touch" })
    fireEvent.pointerMove(card, { clientX: 60, clientY: 200, pointerId: 8, pointerType: "touch" })
    fireEvent.pointerUp(card, { clientX: 60, clientY: 200, pointerId: 8, pointerType: "touch" })
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })

  it("presents multiple screenshots and the explicit no-screenshot state", async () => {
    jobApi.fetchJobTab
      .mockImplementationOnce(async () => ({}))
      .mockImplementationOnce(async () => ({
        typed_artifacts: [],
        visual_evidence: { captured_count: 2, submitted_count: 2, screenshots: [screenshot(1), screenshot(2)] }
      }))
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify({ count: 1, jobs: [job()] }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
    )
    const first = renderRoute("/review/JOB-42")
    expect(await screen.findByRole("region", { name: "Submitted visual evidence" })).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: /Show visual evidence/ })).toHaveLength(2)
    expect(screen.queryByRole("button", { name: "Previous visual evidence" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Next visual evidence" })).not.toBeInTheDocument()
    expect(screen.getByText("1 of 2")).toHaveClass("sr-only")
    first.unmount()
    renderRoute("/review/JOB-42")
    expect(await screen.findByText("No visual evidence submitted.")).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Visual evidence" })).not.toBeInTheDocument()
    expect(screen.getByTestId("mobile-no-evidence")).not.toHaveClass("min-h-40")
  })

  it("resets the evidence position when navigating between cached Jobs", async () => {
    const second = { ...job(), id: 43, slug: "JOB-43", title: "Review next" }
    jobApi.fetchJobTab.mockImplementation(async (id: string, tab: string) => {
      if (tab !== "review") return {}
      const screenshots = id === "42" ? [screenshot(1), screenshot(2), screenshot(3)] : [screenshot(4)]
      return { visual_evidence: { captured_count: screenshots.length, submitted_count: screenshots.length, screenshots } }
    })
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 2, jobs: [job(), second] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")

    expect(await screen.findByText("1 of 3")).toHaveClass("sr-only")
    fireEvent.click(screen.getByRole("button", { name: "Next Job" }))
    expect(await screen.findByRole("heading", { name: "Review next" })).toBeInTheDocument()
    expect(await screen.findByText("1 of 1")).toHaveClass("sr-only")
    expect(screen.queryByRole("group", { name: "Choose visual evidence" })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Previous Job" }))
    expect(await screen.findByRole("heading", { name: "Review me" })).toBeInTheDocument()
    const carousel = configureCarousel(300)
    fireEvent.click(screen.getByRole("button", { name: "Show visual evidence 3 of 3" }))
    await waitFor(() => expect(screen.getByText("3 of 3")).toBeInTheDocument())

    fireEvent.click(screen.getByRole("button", { name: "Next Job" }))

    expect(await screen.findByRole("heading", { name: "Review next" })).toBeInTheDocument()
    expect(screen.getByText("1 of 1")).toBeInTheDocument()
    expect(screen.getByRole("img", { name: "Screenshot 4" })).toBeInTheDocument()
    expect(screen.queryByText("No visual evidence submitted.")).not.toBeInTheDocument()
  })

  it("synchronizes dots and captions from settled swipes in both directions", async () => {
    jobApi.fetchJobTab
      .mockImplementationOnce(async () => ({}))
      .mockImplementationOnce(async () => ({
        visual_evidence: { captured_count: 4, submitted_count: 4, screenshots: [screenshot(1), screenshot(2), screenshot(3), screenshot(4)] }
      }))
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const carousel = configureCarousel(300)

    carousel.element.scrollLeft = 600
    fireEvent.scroll(carousel.element)
    await waitFor(() => expect(screen.getByText("Screenshot 3", { selector: "span" })).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Show visual evidence 3 of 4" })).toHaveAttribute("aria-pressed", "true")

    carousel.element.scrollLeft = 300
    fireEvent.scroll(carousel.element)
    await waitFor(() => expect(screen.getByText("Screenshot 2", { selector: "span" })).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Show visual evidence 2 of 4" })).toHaveAttribute("aria-pressed", "true")
  })

  it("keeps carousel gestures isolated, preserves resize position, and honors reduced motion", async () => {
    jobApi.fetchJobTab
      .mockImplementationOnce(async () => ({}))
      .mockImplementationOnce(async () => ({ visual_evidence: { captured_count: 2, submitted_count: 2, screenshots: [screenshot(1), screenshot(2)] } }))
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    const carousel = configureCarousel(280)
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }))
    )

    fireEvent.click(screen.getByRole("button", { name: "Show visual evidence 2 of 2" }))
    expect(carousel.scrollTo).toHaveBeenLastCalledWith({ behavior: "auto", left: 280 })
    await waitFor(() => expect(screen.getByText("2 of 2")).toBeInTheDocument())
    fireEvent.resize(window)
    expect(carousel.scrollTo).toHaveBeenLastCalledWith({ behavior: "auto", left: 280 })

    const caption = screen.getByTestId("mobile-evidence-caption")
    expect(caption.closest("[data-review-gesture-exempt]")).not.toBeNull()
    fireEvent.pointerDown(caption, { clientX: 80, clientY: 220, pointerId: 49, pointerType: "touch" })
    fireEvent.pointerMove(caption, { clientX: 180, clientY: 222, pointerId: 49, pointerType: "touch" })
    fireEvent.pointerUp(caption, { clientX: 180, clientY: 222, pointerId: 49, pointerType: "touch" })
    expect(screen.queryByRole("dialog", { name: /Approve/ })).not.toBeInTheDocument()
    expect(screen.getByTestId("mobile-review-card").style.transform).toBe("")

    fireEvent.pointerDown(carousel.element, { clientX: 220, clientY: 180, pointerId: 50, pointerType: "touch" })
    fireEvent.pointerMove(carousel.element, { clientX: 80, clientY: 182, pointerId: 50, pointerType: "touch" })
    expect(screen.queryByTestId("mobile-gesture-reveal")).not.toBeInTheDocument()
    fireEvent.pointerUp(carousel.element, { clientX: 80, clientY: 182, pointerId: 50, pointerType: "touch" })
    expect(screen.queryByRole("dialog", { name: /Approve/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "All caught up" })).not.toBeInTheDocument()
    const gestureSurface = screen.getByTestId("mobile-review-card")
    expect(gestureSurface.style.transform).toBe("")
    expect(gestureSurface).not.toHaveClass("touch-pan-x", "touch-pan-y", "touch-none")
    const touchActionAncestors = Array.from(carousel.element.parentElement ? [carousel.element.parentElement] : []).flatMap((ancestor) => {
      const elements: HTMLElement[] = []
      for (let element: HTMLElement | null = ancestor; element; element = element.parentElement) elements.push(element)
      return elements
    })
    expect(touchActionAncestors.some((element) => element.classList.contains("touch-none"))).toBe(false)
    expect(touchActionAncestors.some((element) => element.classList.contains("touch-pan-y") && !element.classList.contains("touch-pan-x"))).toBe(false)
    expect(carousel.element).toHaveClass("overscroll-x-contain", "touch-pan-x", "touch-pan-y")
  })

  it("refreshes eligibility and clears a stale Job after an approval error", async () => {
    let workspaceRequests = 0
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      if (String(input).includes("/summary"))
        return new Response(JSON.stringify({ change_scope: null }), { status: 200, headers: { "Content-Type": "application/json" } })
      workspaceRequests += 1
      const jobs = workspaceRequests === 1 ? [job()] : []
      return new Response(JSON.stringify({ count: jobs.length, jobs }), { status: 200, headers: { "Content-Type": "application/json" } })
    })
    jobApi.postJobCommand.mockRejectedValueOnce(new Error("Job is no longer eligible"))
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")
    fireEvent.click(screen.getByRole("button", { name: "Approve" }))
    fireEvent.click(screen.getByRole("button", { name: "Approve for landing" }))
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
    expect(workspaceRequests).toBeGreaterThan(1)
  })

  it("reconciles the active stack when realtime Job eligibility changes", async () => {
    let workspaceRequests = 0
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      if (String(input).includes("/summary"))
        return new Response(JSON.stringify({ change_scope: null }), { status: 200, headers: { "Content-Type": "application/json" } })
      workspaceRequests += 1
      const jobs = workspaceRequests === 1 ? [job()] : []
      return new Response(JSON.stringify({ count: jobs.length, jobs }), { status: 200, headers: { "Content-Type": "application/json" } })
    })
    renderRoute("/review/JOB-42")
    await screen.findByTestId("mobile-review-summary")

    window.dispatchEvent(new CustomEvent("syrus:app-event", { detail: { resource: "job", id: 42, type: "updated" } }))

    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
    expect(workspaceRequests).toBe(2)
  })

  describe("session-scoped deferrals", () => {
    let eligible: number[] = []
    function mockEligibility(ids: number[]) {
      eligible = ids
      vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
        if (String(input).includes("/summary"))
          return new Response(JSON.stringify({ change_scope: null }), { status: 200, headers: { "Content-Type": "application/json" } })
        const jobs = reviewJobs(6).filter((entry) => eligible.includes(entry.id))
        return new Response(JSON.stringify({ count: jobs.length, jobs }), { status: 200, headers: { "Content-Type": "application/json" } })
      })
    }
    function swipeLeft() {
      const card = screen.getByTestId("mobile-review-card")
      fireEvent.pointerDown(card, { clientX: 150, clientY: 200, pointerId: 9, pointerType: "touch" })
      fireEvent.pointerMove(card, { clientX: 60, clientY: 200, pointerId: 9, pointerType: "touch" })
      fireEvent.pointerUp(card, { clientX: 60, clientY: 200, pointerId: 9, pointerType: "touch" })
    }
    function sessionRouter(initial: string = "/review/JOB-42") {
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      Object.defineProperty(window, "innerWidth", { configurable: true, value: 390 })
      const router = createMemoryRouter(
        [
          { path: "/dashboard/*", element: <Link to="/review/JOB-42">Enter review</Link> },
          { path: "/review", element: <ReviewWorkspaceRoute /> },
          { path: "/review/:job_id", element: <ReviewWorkspaceRoute /> }
        ],
        { initialEntries: ["/dashboard", initial], initialIndex: 1 }
      )
      const view = render(
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      )
      return { router, client, view }
    }
    async function deferAAndB() {
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      swipeLeft()
      await screen.findByText("JOB-44 · acme/widgets")
    }

    it("keeps button- and gesture-deferred Jobs excluded after feedback on another Job and a refresh", async () => {
      mockEligibility([42, 43, 44, 45])
      const { client } = sessionRouter()
      await deferAAndB()
      fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))
      fireEvent.change(await screen.findByLabelText("What should change?"), { target: { value: "Tighten." } })
      eligible = [42, 43, 45]
      const seen: string[] = []
      const observer = new MutationObserver(() => seen.push(document.body.textContent ?? ""))
      observer.observe(document.body, { childList: true, subtree: true, characterData: true })
      fireEvent.click(screen.getByRole("button", { name: "Send feedback" }))
      await waitFor(() => expect(jobApi.submitJobFeedback).toHaveBeenCalledWith(44, "Tighten.", 3))
      await screen.findByText("JOB-45 · acme/widgets")
      await waitFor(() => expect(client.isFetching()).toBe(0))
      observer.disconnect()
      expect(seen.some((text) => /JOB-4[23] · acme/.test(text))).toBe(false)
      expect(screen.queryByText("JOB-42 · acme/widgets")).not.toBeInTheDocument()
      expect(screen.queryByText("JOB-43 · acme/widgets")).not.toBeInTheDocument()
    })

    it("carries the acted-on Job id when the active route changes before the request settles", async () => {
      mockEligibility([42, 43, 44, 45])
      let release!: () => void
      jobApi.submitJobFeedback.mockImplementationOnce(() => new Promise<undefined>((resolve) => (release = () => resolve(undefined))))
      sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))
      fireEvent.change(await screen.findByLabelText("What should change?"), { target: { value: "Later." } })
      fireEvent.click(screen.getByRole("button", { name: "Send feedback" }))
      await waitFor(() => expect(jobApi.submitJobFeedback).toHaveBeenCalledWith(42, "Later.", 3))
      fireEvent.keyDown(window, { key: "j" })
      await screen.findByText("JOB-43 · acme/widgets")
      eligible = [43, 44, 45]
      await act(async () => release())
      await screen.findByText("JOB-43 · acme/widgets")
      expect(screen.getAllByText("1 of 3 ready now").length).toBeGreaterThan(0)
    })

    it("restores deferrals after a remount and keeps them through a canonical replacement", async () => {
      mockEligibility([42, 43, 44])
      const { view } = sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      const stored = window.sessionStorage.getItem("syrus.review_workspace.sessions")
      expect(stored).toContain("42")
      view.unmount()
      // Same-tab reload: history state and sessionStorage survive; a new router restores them.
      expect(window.sessionStorage.getItem("syrus.review_workspace.sessions")).toBe(stored)
      const sessionId = Object.keys(JSON.parse(stored!).sessions)[0]
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      const router = createMemoryRouter([{ path: "/review/:job_id", element: <ReviewWorkspaceRoute /> }], {
        initialEntries: [{ pathname: "/review/JOB-42", state: { reviewWorkspaceSessionId: sessionId, reviewWorkspaceCanReturn: false } }]
      })
      render(
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      )
      await screen.findByText("JOB-43 · acme/widgets")
      expect(router.state.location.pathname).toBe("/review/JOB-43")
      expect(screen.queryByText("JOB-42 · acme/widgets")).not.toBeInTheDocument()
    })

    it("excludes an approved Job and keeps earlier deferrals", async () => {
      mockEligibility([42, 43, 44])
      sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Approve" }))
      eligible = [42, 43, 44]
      fireEvent.click(screen.getByRole("button", { name: "Approve for landing" }))
      await waitFor(() => expect(jobApi.postJobCommand).toHaveBeenCalled())
      await screen.findByText("JOB-44 · acme/widgets")
      expect(screen.queryByText("JOB-42 · acme/widgets")).not.toBeInTheDocument()
      expect(screen.queryByText("JOB-43 · acme/widgets")).not.toBeInTheDocument()
    })

    it("does not exclude the Job or alter deferrals when feedback fails", async () => {
      mockEligibility([42, 43])
      jobApi.submitJobFeedback.mockRejectedValueOnce(new Error("nope"))
      sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))
      fireEvent.change(await screen.findByLabelText("What should change?"), { target: { value: "x" } })
      fireEvent.click(screen.getByRole("button", { name: "Send feedback" }))
      expect(await screen.findByRole("alert")).toBeInTheDocument()
      expect(screen.getByText("JOB-43 · acme/widgets")).toBeInTheDocument()
      expect(screen.queryByText("JOB-42 · acme/widgets")).not.toBeInTheDocument()
    })

    it("clears deferrals on explicit exit so a fresh entry shows eligible Jobs again", async () => {
      mockEligibility([42, 43])
      const { router } = sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Exit review workspace" }))
      await waitFor(() => expect(router.state.location.pathname).toBe("/dashboard/jobs"))
      expect(window.sessionStorage.getItem("syrus.review_workspace.sessions") ?? "").not.toContain("42")
      fireEvent.click(screen.getByRole("link", { name: "Enter review" }))
      expect(await screen.findByText("JOB-42 · acme/widgets")).toBeInTheDocument()
    })

    it("prunes deferred ids that are no longer eligible", async () => {
      mockEligibility([42, 43, 44])
      const { client } = sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      eligible = [43, 44]
      await act(async () => {
        await client.invalidateQueries({ queryKey: ["review_workspace"], exact: true })
      })
      await waitFor(() => expect(window.sessionStorage.getItem("syrus.review_workspace.sessions") ?? "").not.toContain("[42]"))
    })

    it("falls back to in-memory state when sessionStorage is unavailable", async () => {
      mockEligibility([42, 43])
      vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
        throw new Error("denied")
      })
      vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw new Error("denied")
      })
      sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      expect(await screen.findByText("JOB-43 · acme/widgets")).toBeInTheDocument()
      expect(screen.queryByText("JOB-42 · acme/widgets")).not.toBeInTheDocument()
    })

    it("isolates separate sessions", async () => {
      mockEligibility([42, 43])
      const first = sessionRouter()
      await screen.findByText("JOB-42 · acme/widgets")
      fireEvent.click(screen.getByRole("button", { name: "Defer for this session" }))
      await screen.findByText("JOB-43 · acme/widgets")
      first.view.unmount()
      sessionRouter()
      expect(await screen.findByText("JOB-42 · acme/widgets")).toBeInTheDocument()
    })
  })

  describe("decision brief and context", () => {
    function mockDetail(header: Record<string, unknown>, review: Record<string, unknown> = {}, summary: Record<string, unknown> = {}) {
      jobApi.fetchJobDetail.mockImplementationOnce(
        async () =>
          ({
            job: { id: 42, summary_state: "implemented", pr_number: 7, pr_url: "https://github.com/acme/widgets/pull/7", pr_checks: null },
            actions: { can_approve: true },
            paths: { app_approve_path: "/canonical/jobs/42/approve", job_path: "/jobs/JOB-42" },
            workflows: [],
            epic: null,
            ...header
          }) as never
      )
      jobApi.fetchJobTab.mockImplementation(async (_id: string, tab: string) =>
        tab === "review" ? { typed_artifacts: [], visual_evidence: { screenshots: [] }, ...review } : summary
      )
    }
    function mockList(scope: unknown = null, head: string | null = "h1") {
      vi.spyOn(globalThis, "fetch").mockImplementation(
        async (input) =>
          new Response(JSON.stringify(String(input).includes("/summary") ? { change_scope: scope, current_head_sha: head } : { count: 1, jobs: [job()] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
      )
    }
    const rowText = (id: string) => document.querySelector(`[data-brief-row="${id}"]`)?.textContent

    it("renders a full brief with only present signals and canonical links", async () => {
      mockDetail(
        {
          job: { id: 42, summary_state: "implemented", pr_number: 7, pr_url: "https://github.com/acme/widgets/pull/7", pr_checks: { state: "passing" } },
          epic: { id: 9, display_number: "EPIC-9", title: "Big work", epic_path: "/epics/EPIC-9" },
          workflows: [
            {
              id: 1,
              artifacts: {
                adversarial_review_iterations: [{ iteration: 1, verdict: "approved", reviewed_head_sha: "h1", non_blocking_findings: [{}] }],
                security_review_iterations: [{ iteration: 1, verdict: "approved", reviewed_head_sha: "h1" }]
              }
            }
          ]
        },
        { visual_evidence: { screenshots: [screenshot(1)] } },
        { test_plan: { steps: ["a", "b"] } }
      )
      mockList({ files_changed: 3, additions: 10, deletions: 2 })
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      await waitFor(() => expect(rowText("scope")).toContain("3 files"))
      expect(rowText("scope")).toContain("+10")
      expect(rowText("readiness")).toContain("Ready to approve")
      expect(rowText("checks")).toContain("Passing")
      expect(rowText("adversarial")).toContain("1 non-blocking")
      expect(rowText("security")).toContain("Ran, no findings")
      expect(rowText("tests")).toContain("2 steps")
      expect(rowText("visual")).toContain("1 screenshots")
      expect(rowText("epic")).toContain("EPIC-9")
      const links = within(screen.getByRole("navigation", { name: "Job context" }))
      expect(links.getByRole("link", { name: "Open JOB-42" })).toHaveAttribute("href", "/jobs/JOB-42")
      expect(links.getByRole("link", { name: "Open EPIC-9" })).toHaveAttribute("href", "/epics/EPIC-9")
      const pr = links.getByRole("link", { name: /PR #7/ })
      expect(pr).toHaveAttribute("href", "https://github.com/acme/widgets/pull/7")
      expect(pr).toHaveAttribute("target", "_blank")
      expect(links.getByRole("button", { name: "Full diff and details" })).toBeInTheDocument()
      expect(screen.queryByText("Why it needs you:")).not.toBeInTheDocument()
    })

    it("omits unavailable signals and never claims findings or backend-only work", async () => {
      mockDetail({ job: { id: 42, summary_state: "implemented", pr_checks: null }, workflows: [{ id: 1, artifacts: {} }] })
      mockList(null)
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(rowText("scope")).toBeUndefined()
      expect(rowText("checks")).toBeUndefined()
      expect(rowText("tests")).toBeUndefined()
      expect(rowText("epic")).toBeUndefined()
      expect(rowText("reviews")).toContain("None recorded")
      expect(screen.queryByText(/no findings/i)).not.toBeInTheDocument()
      expect(screen.queryByText(/backend/i)).not.toBeInTheDocument()
      const links = within(screen.getByRole("navigation", { name: "Job context" }))
      expect(links.queryByRole("link", { name: /EPIC/ })).not.toBeInTheDocument()
      expect(links.queryByRole("link", { name: /PR #/ })).not.toBeInTheDocument()
      expect(screen.getByTestId("mobile-no-evidence")).toHaveTextContent("No visual evidence submitted.")
    })

    it("shows failing checks separately from the actual approval decision", async () => {
      mockDetail({
        job: {
          id: 42,
          summary_state: "implemented",
          pr_checks: { state: "failing", attribution: { verdict: "own", own_names: ["rspec"], failing_names: ["rspec"] } }
        },
        actions: { can_approve: true },
        workflows: [{ id: 2, artifacts: { security_review_iterations: [{ iteration: 2, verdict: "needs_work", reviewed_head_sha: "h1" }] } }]
      })
      mockList()
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(rowText("readiness")).toContain("Ready to approve")
      expect(rowText("checks")).toContain("Failing: rspec")
      expect(rowText("security")).toContain("Blocking findings")
      expect(rowText("adversarial")).toBeUndefined()
    })

    it("does not present review evidence from a superseded commit as current", async () => {
      mockDetail({
        workflows: [
          { id: 1, artifacts: { adversarial_review_iterations: [{ iteration: 1, verdict: "approved", reviewed_head_sha: "old" }] } },
          { id: 2, artifacts: {} }
        ]
      })
      mockList(null, "h2")
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(rowText("adversarial")).toBeUndefined()
      expect(rowText("reviews_unconfirmed")).toContain("Not confirmed for the current commit")
      expect(screen.queryByText(/no findings/i)).not.toBeInTheDocument()
    })

    it("treats unstamped review evidence as unconfirmed when the current head is unknown", async () => {
      mockDetail({ workflows: [{ id: 1, artifacts: { security_review_iterations: [{ iteration: 1, verdict: "approved" }] } }] })
      mockList(null, null)
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(rowText("security")).toBeUndefined()
      expect(rowText("reviews_unconfirmed")).toBeTruthy()
    })

    it("keeps unknown and pending checks and skipped reviews honest", async () => {
      mockDetail({
        job: { id: 42, summary_state: "implemented", pr_checks: { state: "unknown" } },
        workflows: [{ id: 2, artifacts: { adversarial_review_iterations: [{ iteration: 1, verdict: "skipped", reviewed_head_sha: "h1" }] } }]
      })
      mockList()
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(rowText("checks")).toContain("Unknown")
      expect(rowText("adversarial")).toContain("Skipped")
    })

    it("isolates every context link from swipe gestures", async () => {
      mockDetail({ epic: { id: 9, display_number: "EPIC-9", title: "Big", epic_path: "/epics/EPIC-9" } })
      mockList()
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      const nav = screen.getByRole("navigation", { name: "Job context" })
      const targets = [...nav.querySelectorAll("a, button")]
      expect(targets).toHaveLength(4)
      for (const target of targets) {
        expect(target).toHaveAttribute("data-review-gesture-exempt")
        fireEvent.pointerDown(target, { clientX: 80, clientY: 200, pointerId: 21, pointerType: "touch" })
        fireEvent.pointerMove(target, { clientX: 200, clientY: 200, pointerId: 21, pointerType: "touch" })
        fireEvent.pointerUp(target, { clientX: 200, clientY: 200, pointerId: 21, pointerType: "touch" })
      }
      expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument()
      expect(window.localStorage.getItem("syrus.reviewWorkspace.gestureHelpAcknowledged")).toBeNull()
    })

    it("keeps long titles and many signals in wrapping, non-overflowing rows", async () => {
      mockDetail({
        job: {
          id: 42,
          summary_state: "implemented",
          pr_checks: { state: "failing", attribution: { verdict: "own", own_names: ["a-very-long-check-name-".repeat(5)] } }
        },
        epic: { id: 9, display_number: "EPIC-9", title: "An extremely long epic title ".repeat(6), epic_path: "/epics/EPIC-9" },
        test_plan: { steps: ["a"] }
      })
      mockList({ files_changed: 1, additions: 1, deletions: 1 })
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      for (const row of document.querySelectorAll("[data-brief-row] dd")) expect(row).toHaveClass("break-words", "min-w-0")
      expect(screen.getByTestId("mobile-context-links")).toHaveClass("flex-wrap")
    })
  })

  describe("gesture help", () => {
    const KEY = "syrus.reviewWorkspace.gestureHelpAcknowledged"
    function mockJobs() {
      vi.spyOn(globalThis, "fetch").mockImplementation(
        async (input) =>
          new Response(JSON.stringify(String(input).includes("/summary") ? { change_scope: null } : { count: 1, jobs: [job()] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
      )
    }

    it("shows one first-use coach and no permanent duplicate instruction copy", async () => {
      mockJobs()
      renderRoute("/review/JOB-42")
      expect(await screen.findByTestId("mobile-gesture-coach")).toBeInTheDocument()
      expect(screen.queryByText("Swipe up or down to move · right to approve · left to defer · hold for details")).not.toBeInTheDocument()
      expect(screen.getAllByText(/hold for details|press and hold for details/)).toHaveLength(2) // coach + sr-only instructions
      expect(screen.getByLabelText("Current Job gesture area")).toHaveAttribute("aria-describedby", "review-gesture-instructions")
      expect(document.getElementById("review-gesture-instructions")).toHaveClass("sr-only")
    })

    it("persists a versioned dismissal and stays hidden on the next visit", async () => {
      mockJobs()
      const first = renderRoute("/review/JOB-42")
      fireEvent.click(await screen.findByRole("button", { name: "Got it" }))
      expect(screen.queryByTestId("mobile-gesture-coach")).not.toBeInTheDocument()
      expect(window.localStorage.getItem(KEY)).toBe("1")
      first.unmount()
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(screen.queryByTestId("mobile-gesture-coach")).not.toBeInTheDocument()
    })

    it("reintroduces the coach when the stored acknowledgement is from an older version", async () => {
      window.localStorage.setItem(KEY, "0")
      mockJobs()
      renderRoute("/review/JOB-42")
      expect(await screen.findByTestId("mobile-gesture-coach")).toBeInTheDocument()
    })

    it("acknowledges the first successful gesture", async () => {
      mockJobs()
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-gesture-coach")
      const card = screen.getByTestId("mobile-review-card")
      fireEvent.pointerDown(card, { clientX: 80, clientY: 200, pointerId: 31, pointerType: "touch" })
      fireEvent.pointerMove(card, { clientX: 170, clientY: 200, pointerId: 31, pointerType: "touch" })
      fireEvent.pointerUp(card, { clientX: 170, clientY: 200, pointerId: 31, pointerType: "touch" })
      await waitFor(() => expect(screen.queryByTestId("mobile-gesture-coach")).not.toBeInTheDocument())
      expect(window.localStorage.getItem(KEY)).toBe("1")
    })

    it("reopens gesture help from the details sheet without clearing the acknowledgement", async () => {
      window.localStorage.setItem(KEY, "1")
      mockJobs()
      renderRoute("/review/JOB-42")
      await screen.findByTestId("mobile-decision-brief")
      expect(screen.queryByTestId("mobile-gesture-coach")).not.toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Job details" }))
      fireEvent.click(await screen.findByRole("button", { name: "Gesture help" }))
      expect(await screen.findByTestId("mobile-gesture-coach")).toBeInTheDocument()
      expect(screen.queryByTestId("mobile-details-sheet")).not.toBeInTheDocument()
      expect(window.localStorage.getItem(KEY)).toBe("1")
    })
  })
})

function job() {
  return {
    id: 42,
    revision: 3,
    slug: "JOB-42",
    title: "Review me",
    priority: "high",
    ready_at: "2026-11-19T00:00:00Z",
    dependency_blocked: false,
    repository: { id: 1, slug: "acme/widgets" },
    pr_number: 7
  }
}

function screenshot(id: number) {
  return {
    id: String(id),
    workflow_id: 1,
    run_id: 1,
    sequence: id,
    status: "submitted",
    captured_at: "2026-11-19T00:00:00Z",
    page: { title: `Screenshot ${id}` },
    viewport: { width: 390, height: 844 },
    submission_failed: false,
    image_url: `/screenshots/${id}.png`
  }
}

function configureCarousel(width: number) {
  const element = screen.getByTestId("mobile-evidence-carousel")
  Object.defineProperty(element, "clientWidth", { configurable: true, value: width })
  const scrollTo = vi.fn(({ left }: ScrollToOptions) => {
    element.scrollLeft = Number(left ?? 0)
    fireEvent.scroll(element)
  })
  Object.defineProperty(element, "scrollTo", { configurable: true, value: scrollTo })
  return { element, scrollTo }
}
