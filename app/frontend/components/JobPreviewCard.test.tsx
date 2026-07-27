import { jsonResponse } from "../testSupport"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { JobPreviewCard, JobPreviewSkeleton } from "./JobPreviewCard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function renderCard(id: number) {
  render(
    <QueryClientProvider client={client()}>
      <MemoryRouter>
        <JobPreviewCard id={id} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("JobPreviewCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows skeleton while data is loading", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    renderCard(42)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })

  it("renders slug label, state badge, and title after load", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 42, state: "open", issue_title: "Add dark mode", issue_body: "The app needs a dark mode." }
    }))
    renderCard(42)
    await waitFor(() => expect(screen.getByText("Add dark mode")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
  })

  it("renders the issue body", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 1, state: "open", issue_title: "T", issue_body: "Some description here." }
    }))
    renderCard(1)
    await waitFor(() => expect(screen.getByText("Some description here.")).toBeInTheDocument())
  })

  it("truncates issue body at 500 chars and appends ellipsis", async () => {
    const longBody = "a".repeat(600)
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 1, state: "open", issue_title: "T", issue_body: longBody }
    }))
    renderCard(1)
    await waitFor(() => expect(screen.getByText(/…$/)).toBeInTheDocument())
    const el = screen.getByText(/…$/)
    expect(el.textContent).toHaveLength(501) // 500 chars + "…"
  })

  it("does not truncate body that is exactly 500 chars", async () => {
    const body = "b".repeat(500)
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 1, state: "open", issue_title: "T", issue_body: body }
    }))
    renderCard(1)
    await waitFor(() => expect(screen.getByText(body)).toBeInTheDocument())
    expect(screen.queryByText(/…$/)).not.toBeInTheDocument()
  })

  it("renders a See More link pointing to the job detail page", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 42, state: "implemented", issue_title: "T", issue_body: "" }
    }))
    renderCard(42)
    await waitFor(() => expect(screen.getByRole("link", { name: "See more" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "See more" })).toHaveAttribute("href", "/jobs/42")
  })

  it("shows generating title text when issue_title is null and title_pending is true", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 5, state: "running", issue_title: null, title_pending: true, issue_body: null }
    }))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("Generating title…")).toBeInTheDocument())
  })

  it("renders the title as a link to the job detail page", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 42, state: "open", issue_title: "Add dark mode", issue_body: "" }
    }))
    renderCard(42)
    await waitFor(() => expect(screen.getByRole("link", { name: "Add dark mode" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "Add dark mode" })).toHaveAttribute("href", "/jobs/42")
  })

  it("renders markdown headings without raw ## syntax", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 1, state: "open", issue_title: "T", issue_body: "## Problem\nNeeds fixing." }
    }))
    renderCard(1)
    await waitFor(() => expect(screen.getByText("Problem")).toBeInTheDocument())
    expect(screen.queryByText(/## Problem/)).not.toBeInTheDocument()
  })

  it("does not render img elements from the body", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 1, state: "open", issue_title: "T", issue_body: '<img src="https://example.com/logo.png" alt="logo">' }
    }))
    renderCard(1)
    await waitFor(() => expect(screen.getByRole("link", { name: "See more" })).toBeInTheDocument())
    expect(document.querySelector("img")).not.toBeInTheDocument()
  })
})

describe("JobPreviewSkeleton", () => {
  it("renders a pulsing placeholder", () => {
    render(<JobPreviewSkeleton />)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })
})
