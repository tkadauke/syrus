import { jsonResponse } from "../testSupport"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EpicDetailJob } from "../api/epics"
import { EpicPreviewCard, EpicPreviewSkeleton } from "./EpicPreviewCard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function job(state: string, title = "A job"): EpicDetailJob {
  return { id: Math.random(), slug: "JOB-1", label: "JOB-1", title, path: "/jobs/1", state, pr_number: null, pr_url: null, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" }
}

function epicPayload(overrides: Record<string, unknown> = {}) {
  return {
    epic: {
      id: 7,
      number: 7,
      display_number: "EPIC-7",
      title: "Onboarding flow",
      description: "Make onboarding easy.",
      state: "in_progress",
      jobs_count: 3,
      ...overrides
    },
    jobs: [job("merged"), job("open"), job("implemented")],
    summary: { done_jobs_count: 1, total_jobs_count: 3, dependency_edge_count: 0, blocked: false, blocked_reason: null }
  }
}

function renderCard(id: number) {
  render(
    <QueryClientProvider client={client()}>
      <MemoryRouter>
        <EpicPreviewCard id={id} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("EpicPreviewCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows skeleton while data is loading", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    renderCard(7)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })

  it("renders display number, state badge, and title after load", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    renderCard(7)
    await waitFor(() => expect(screen.getByText("Onboarding flow")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy EPIC-7 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("in progress")).toBeInTheDocument()
  })

  it("renders the epic description", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    renderCard(7)
    await waitFor(() => expect(screen.getByText("Make onboarding easy.")).toBeInTheDocument())
  })

  it("truncates description at 500 chars and appends ellipsis", async () => {
    const longDesc = "x".repeat(600)
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload({ description: longDesc, jobs_count: 0 })))
    renderCard(7)
    await waitFor(() => expect(screen.getByText(/…$/)).toBeInTheDocument())
    expect(screen.getByText(/…$/).textContent).toHaveLength(501)
  })

  it("renders a progress bar when jobs_count > 0", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    renderCard(7)
    await waitFor(() => expect(screen.getByRole("progressbar")).toBeInTheDocument())
  })

  it("omits the progress bar when jobs_count is 0", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload({ jobs_count: 0 })))
    renderCard(7)
    await waitFor(() => expect(screen.getByText("Onboarding flow")).toBeInTheDocument())
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument()
  })

  it("shows up to 5 child jobs with state badges and titles", async () => {
    // Priority order: failed(0) < open(3) < implemented(4) < approved(5) < merged(6) < closed(7)
    // closed job is 6th and should be cut off
    const manyJobs = [
      job("failed", "Failed job"),
      job("open", "Open job"),
      job("implemented", "Implemented job"),
      job("approved", "Approved job"),
      job("merged", "Merged job"),
      job("closed", "Closed job — should be hidden"),
    ]
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ jobs_count: 6 }),
      jobs: manyJobs
    }))
    renderCard(7)
    await waitFor(() => expect(screen.getByText("Failed job")).toBeInTheDocument())
    expect(screen.getByText("Merged job")).toBeInTheDocument()
    expect(screen.queryByText("Closed job — should be hidden")).not.toBeInTheDocument()
    expect(screen.getAllByRole("listitem")).toHaveLength(5)
  })

  it("sorts child jobs with failed first and merged last", async () => {
    const manyJobs = [
      job("merged", "Merged job"),
      job("open", "Open job"),
      job("failed", "Failed job"),
    ]
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ jobs_count: 3 }),
      jobs: manyJobs
    }))
    renderCard(7)
    await waitFor(() => expect(screen.getAllByRole("listitem")).toHaveLength(3))
    const items = screen.getAllByRole("listitem").map((li) => li.textContent ?? "")
    expect(items[0]).toContain("Failed job")
    expect(items[items.length - 1]).toContain("Merged job")
  })

  it("renders the epic title as a link to the epic detail page", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    renderCard(7)
    await waitFor(() => expect(screen.getByRole("link", { name: "Onboarding flow" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "Onboarding flow" })).toHaveAttribute("href", "/epics/7")
  })

  it("renders each child job row as a link to the job detail page", async () => {
    const fixedJobs: EpicDetailJob[] = [
      { id: 10, slug: "JOB-10", label: "JOB-10", title: "First job", path: "/jobs/10", state: "open", pr_number: null, pr_url: null, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" },
      { id: 20, slug: "JOB-20", label: "JOB-20", title: "Second job", path: "/jobs/20", state: "merged", pr_number: null, pr_url: null, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" },
    ]
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ ...epicPayload({ jobs_count: 2 }), jobs: fixedJobs }))
    renderCard(7)
    await waitFor(() => expect(screen.getByText("First job")).toBeInTheDocument())
    expect(screen.getByRole("link", { name: /First job/ })).toHaveAttribute("href", "/jobs/10")
    expect(screen.getByRole("link", { name: /Second job/ })).toHaveAttribute("href", "/jobs/20")
  })

  it("renders a See More link pointing to the epic detail page", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    renderCard(7)
    await waitFor(() => expect(screen.getByRole("link", { name: "See more" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "See more" })).toHaveAttribute("href", "/epics/7")
  })
})

describe("EpicPreviewSkeleton", () => {
  it("renders a pulsing placeholder", () => {
    render(<EpicPreviewSkeleton />)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })
})
