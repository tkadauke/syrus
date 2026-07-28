import { jsonResponse } from "../testSupport"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PrPreviewCard, PrPreviewSkeleton } from "./PrPreviewCard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function jobPayload(overrides: Record<string, unknown> = {}) {
  return {
    job: {
      id: 42,
      state: "implemented",
      issue_title: "Add dark mode",
      issue_body: "",
      pr_mergeable: true,
      pr_mergeable_checked_at: null,
      ...overrides
    }
  }
}

function renderCard(prUrl = "https://github.com/owner/repo/pull/99") {
  render(
    <QueryClientProvider client={client()}>
      <MemoryRouter>
        <PrPreviewCard jobId={42} prNumber={99} prUrl={prUrl} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("PrPreviewCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows skeleton while data is loading", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    renderCard()
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })

  it("renders PR number slug, state pill, job title, and mergeability chip when data loads", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(jobPayload()))
    renderCard()
    await waitFor(() => expect(screen.getByText("Add dark mode")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy PR #99 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("implemented")).toBeInTheDocument()
    expect(screen.getByText("mergeable")).toBeInTheDocument()
  })

  it("renders an external link to the PR URL", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(jobPayload()))
    renderCard()
    await waitFor(() => expect(screen.getByRole("link", { name: "Open PR #99 on GitHub" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "Open PR #99 on GitHub" })).toHaveAttribute("href", "https://github.com/owner/repo/pull/99")
  })

  it("renders the job title as a link to the job detail page", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(jobPayload()))
    renderCard()
    await waitFor(() => expect(screen.getByRole("link", { name: "Add dark mode" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "Add dark mode" })).toHaveAttribute("href", "/jobs/42")
  })

  it("renders unmergeable pill when pr_mergeable is false", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(jobPayload({ pr_mergeable: false })))
    renderCard()
    await waitFor(() => expect(screen.getByText("unmergeable")).toBeInTheDocument())
  })

  it("does not render when prUrl is empty", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    renderCard("")
    expect(document.querySelector(".animate-pulse")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Copy PR #/ })).not.toBeInTheDocument()
  })
})

describe("PrPreviewSkeleton", () => {
  it("renders a pulsing placeholder", () => {
    render(<PrPreviewSkeleton />)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })
})
