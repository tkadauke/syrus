import "@testing-library/jest-dom/vitest"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { createPortal } from "react-dom"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import ReviewWorkspaceRoute from "./ReviewWorkspace"

const jobApi = vi.hoisted(() => ({
  fetchJobDetail: vi.fn(async () => ({ job: { id: 42, summary_state: "implemented" }, actions: { can_approve: true }, paths: { app_approve_path: "/canonical/jobs/42/approve" } })),
  fetchJobTab: vi.fn(async (_id: string, tab: string) =>
    tab === "review"
      ? {
          typed_artifacts: [{ type: "security_review", title: "Security review approved", renderer_type: "data_table" }],
          visual_evidence: { screenshots: [] }
        }
      : {}
  ),
  postJobCommand: vi.fn(async () => ({})),
  submitJobFeedback: vi.fn(async () => undefined)
}))

vi.mock("@app/api/jobs", () => jobApi)
vi.mock("@app/lib/entityStore", () => ({ normalizeJobDetailPayload: (payload: unknown) => payload }))
vi.mock("@app/routes/jobDetail/ReviewWorkspace", () => ({
  ReviewWorkspace: ({ conversationPortalTarget, showConversation, visualEvidenceNavigation }: { conversationPortalTarget?: Element | null; showConversation?: boolean; visualEvidenceNavigation?: { direction: number } }) => (
    <div>
      Canonical review evidence
      <span>Conversation {showConversation === false ? "hidden" : "shown"}</span>
      {conversationPortalTarget ? createPortal(<div>Canonical contributed findings</div>, conversationPortalTarget) : null}
      {visualEvidenceNavigation ? <span>Evidence direction {visualEvidenceNavigation.direction}</span> : null}
    </div>
  )
}))

afterEach(() => vi.restoreAllMocks())

function renderRoute(path = "/review") {
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
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } })
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
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } }))
    renderRoute("/review/JOB-42")
    await screen.findByText("Canonical review evidence")
    fireEvent.keyDown(window, { key: "ArrowRight" })
    expect(await screen.findByText("Evidence direction 1")).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "ArrowLeft" })
    expect(await screen.findByText("Evidence direction -1")).toBeInTheDocument()
  })

  it("does not offer approval when the canonical payload denies it", async () => {
    jobApi.fetchJobDetail.mockResolvedValueOnce({ job: { id: 42, summary_state: "implemented" }, actions: { can_approve: false }, paths: { app_approve_path: "/canonical/jobs/42/approve" } })
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ count: 1, jobs: [job()] }), { status: 200, headers: { "Content-Type": "application/json" } }))
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
