import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EpicDetailJob } from "../api/epics"
import { EpicCompactCard, EpicPreviewCard, EpicPreviewSkeleton } from "./EpicPreviewCard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function job(state: string, title = "A job"): EpicDetailJob {
  return { id: Math.random(), slug: "JOB-1", label: "JOB-1", title, path: "/jobs/1", state, landed: false, pr_number: null, pr_url: null, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" }
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
      { id: 10, slug: "JOB-10", label: "JOB-10", title: "First job", path: "/jobs/10", state: "open", landed: false, pr_number: null, pr_url: null, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" },
      { id: 20, slug: "JOB-20", label: "JOB-20", title: "Second job", path: "/jobs/20", state: "merged", landed: true, pr_number: null, pr_url: null, owner_user_id: null, owner_user: null, repository_slug: "owner/repo" },
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

  it("compact: applies line-clamp-1 to title and hides progress bar, description, child jobs, and see-more link", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <EpicPreviewCard compact id={7} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    await waitFor(() => expect(screen.getByText("Onboarding flow")).toBeInTheDocument())
    const titleLink = screen.getByRole("link", { name: "Onboarding flow" })
    expect(titleLink.className).toContain("line-clamp-1")
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument()
    expect(screen.queryByText("Make onboarding easy.")).not.toBeInTheDocument()
    expect(screen.queryByRole("listitem")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "See more" })).not.toBeInTheDocument()
  })

  it("compact: still shows display number and state badge", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <EpicPreviewCard compact id={7} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    await waitFor(() => expect(screen.getByRole("button", { name: "Copy EPIC-7 to clipboard" })).toBeInTheDocument())
    expect(screen.getByText("in progress")).toBeInTheDocument()
  })

  it("renders aggregate deployment stage row for done epics with deployment_stages", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ state: "done" }),
      deployment_stages: [
        { name: "staging", label: "On Staging", reached_count: 5, total: 5, reached_at: "2026-01-01T10:00:00Z" },
        { name: "production", label: "In Production", reached_count: 3, total: 5, reached_at: "2026-01-02T10:00:00Z" }
      ]
    }))
    renderCard(7)
    await waitFor(() => expect(screen.getByTestId("epic-deployment-stage-pipeline")).toBeInTheDocument())
    expect(screen.getByText("On Staging")).toBeInTheDocument()
    expect(screen.getByText("In Production")).toBeInTheDocument()
  })

  it("shows fully-reached badge as checkmark when reached_count equals total", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ state: "done" }),
      deployment_stages: [
        { name: "staging", label: "On Staging", reached_count: 5, total: 5, reached_at: "2026-01-01T10:00:00Z" }
      ]
    }))
    renderCard(7)
    await waitFor(() => expect(screen.getByTestId("epic-deployment-stage-pipeline")).toBeInTheDocument())
    expect(screen.getByText("✓")).toBeInTheDocument()
  })

  it("shows partial count badge when reached_count is less than total", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ state: "done" }),
      deployment_stages: [
        { name: "production", label: "In Production", reached_count: 3, total: 5, reached_at: null }
      ]
    }))
    renderCard(7)
    await waitFor(() => expect(screen.getByTestId("epic-deployment-stage-pipeline")).toBeInTheDocument())
    expect(screen.getByText("3/5")).toBeInTheDocument()
  })

  it("does not render deployment stage row when deployment_stages is absent", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(epicPayload()))
    renderCard(7)
    await waitFor(() => expect(screen.getByText("Onboarding flow")).toBeInTheDocument())
    expect(screen.queryByTestId("epic-deployment-stage-pipeline")).not.toBeInTheDocument()
  })

  it("renders aggregate deployment stage row after the title, not before the slug/badge row", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ state: "done", title: "My epic" }),
      deployment_stages: [
        { name: "staging", label: "On Staging", reached_count: 5, total: 5, reached_at: "2026-01-01T10:00:00Z" }
      ]
    }))
    renderCard(7)
    await waitFor(() => expect(screen.getByTestId("epic-deployment-stage-pipeline")).toBeInTheDocument())
    const cardRoot = screen.getByTestId("epic-deployment-stage-pipeline").closest(".shadow-lg")!
    const children = Array.from(cardRoot.children)
    const slugRow = children.findIndex((el) => el.querySelector("[aria-label='Copy EPIC-7 to clipboard']"))
    const titleLink = children.findIndex((el) => el.matches("a") && el.textContent === "My epic")
    const pipeline = children.findIndex((el) => el.querySelector("[data-testid='epic-deployment-stage-pipeline']"))
    expect(slugRow).toBeLessThan(titleLink)
    expect(titleLink).toBeLessThan(pipeline)
  })

  it("compact: does not render deployment stage row even when deployment_stages are present", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...epicPayload({ state: "done" }),
      deployment_stages: [
        { name: "staging", label: "On Staging", reached_count: 5, total: 5, reached_at: "2026-01-01T10:00:00Z" }
      ]
    }))
    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <EpicPreviewCard compact id={7} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    await waitFor(() => expect(screen.getByText("Onboarding flow")).toBeInTheDocument())
    expect(screen.queryByTestId("epic-deployment-stage-pipeline")).not.toBeInTheDocument()
  })
})

describe("EpicPreviewSkeleton", () => {
  it("renders a pulsing placeholder", () => {
    render(<EpicPreviewSkeleton />)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })
})

describe("EpicCompactCard", () => {
  it("renders the slug (first word) and title from the label", () => {
    render(<EpicCompactCard label="EPIC-7 Big feature" state="open" />)
    expect(screen.getByText("EPIC-7")).toBeInTheDocument()
    expect(screen.getByText("Big feature")).toBeInTheDocument()
  })

  it("renders the state pill", () => {
    render(<EpicCompactCard label="EPIC-1 Title" state="merged" />)
    expect(screen.getByText("merged")).toBeInTheDocument()
  })

  it("applies focal ring styling when isFocal is true", () => {
    render(<EpicCompactCard isFocal label="EPIC-1 Title" state="open" />)
    expect(screen.getByTestId("epic-compact-card").className).toContain("ring-2")
  })

  it("does not apply ring styling when isFocal is false", () => {
    render(<EpicCompactCard label="EPIC-1 Title" state="open" />)
    expect(screen.getByTestId("epic-compact-card").className).not.toContain("ring-2")
  })

  it("calls onClick when the card is clicked", () => {
    const onClick = vi.fn()
    render(<EpicCompactCard label="EPIC-1 Title" onClick={onClick} state="open" />)
    fireEvent.click(screen.getByTestId("epic-compact-card"))
    expect(onClick).toHaveBeenCalledOnce()
  })

  it("calls onClick when Enter is pressed on the card", () => {
    const onClick = vi.fn()
    render(<EpicCompactCard label="EPIC-1 Title" onClick={onClick} state="open" />)
    fireEvent.keyDown(screen.getByRole("link", { name: "EPIC-1 Title" }), { key: "Enter" })
    expect(onClick).toHaveBeenCalledOnce()
  })

  it("omits the title paragraph when the label has no space", () => {
    render(<EpicCompactCard label="EPIC-1" state="open" />)
    expect(screen.getByText("EPIC-1")).toBeInTheDocument()
    expect(screen.queryByRole("paragraph")).not.toBeInTheDocument()
  })

  it("renders a multi-word title correctly", () => {
    render(<EpicCompactCard label="EPIC-42 Add dark mode to dashboard" state="in_progress" />)
    expect(screen.getByText("EPIC-42")).toBeInTheDocument()
    expect(screen.getByText("Add dark mode to dashboard")).toBeInTheDocument()
  })
})
