import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { JobCompactCard, JobPreviewCard, JobPreviewSkeleton } from "./JobPreviewCard"

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

  it("compact: applies line-clamp-1 to title and hides body and see-more link", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 42, state: "open", issue_title: "Add dark mode", issue_body: "The app needs a dark mode." }
    }))
    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <JobPreviewCard compact id={42} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    await waitFor(() => expect(screen.getByText("Add dark mode")).toBeInTheDocument())
    const titleLink = screen.getByRole("link", { name: "Add dark mode" })
    expect(titleLink.className).toContain("line-clamp-1")
    expect(screen.queryByText("The app needs a dark mode.")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "See more" })).not.toBeInTheDocument()
  })

  it("compact: still shows slug and state badge", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job: { id: 42, state: "open", issue_title: "Add dark mode", issue_body: "" }
    }))
    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <JobPreviewCard compact id={42} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    await waitFor(() => expect(screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })).toBeInTheDocument())
    expect(screen.getByText("open")).toBeInTheDocument()
  })
})

describe("JobPreviewSkeleton", () => {
  it("renders a pulsing placeholder", () => {
    render(<JobPreviewSkeleton />)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })
})

describe("JobCompactCard", () => {
  it("extracts the job identifier and title from the backend label format", () => {
    // Backend emits "EPIC-N / source title"
    render(<JobCompactCard label="EPIC-2 / #123 Fix login bug" state="open" />)
    expect(screen.getByText("#123")).toBeInTheDocument()
    expect(screen.getByText("Fix login bug")).toBeInTheDocument()
  })

  it("handles epicless job labels with No Epic prefix", () => {
    render(<JobCompactCard epicId={null} label="No Epic / JOB-42 Dark mode" state="open" />)
    expect(screen.getByText("JOB-42")).toBeInTheDocument()
    expect(screen.getByText("Dark mode")).toBeInTheDocument()
  })

  it("handles labels with no slash separator", () => {
    render(<JobCompactCard label="JOB-42 Some title" state="open" />)
    expect(screen.getByText("JOB-42")).toBeInTheDocument()
    expect(screen.getByText("Some title")).toBeInTheDocument()
  })

  it("renders the state pill", () => {
    render(<JobCompactCard label="EPIC-1 / #1 T" state="merged" />)
    expect(screen.getByText("merged")).toBeInTheDocument()
  })

  it("applies focal ring styling when isFocal is true", () => {
    render(<JobCompactCard isFocal label="EPIC-1 / #1 T" state="open" />)
    expect(screen.getByTestId("job-compact-card").className).toContain("ring-2")
  })

  it("does not apply ring styling when isFocal is false", () => {
    render(<JobCompactCard label="EPIC-1 / #1 T" state="open" />)
    expect(screen.getByTestId("job-compact-card").className).not.toContain("ring-2")
  })

  it("applies gray left accent when epicId is null", () => {
    render(<JobCompactCard epicId={null} label="No Epic / JOB-1 T" state="open" />)
    expect(screen.getByTestId("job-compact-card").className).toContain("border-l-4")
  })

  it("does not apply left accent when epicId is set", () => {
    render(<JobCompactCard epicId={7} label="EPIC-7 / #1 T" state="open" />)
    expect(screen.getByTestId("job-compact-card").className).not.toContain("border-l-4")
  })

  it("calls onClick when the card is clicked", () => {
    const onClick = vi.fn()
    render(<JobCompactCard label="EPIC-1 / #1 T" onClick={onClick} state="open" />)
    fireEvent.click(screen.getByTestId("job-compact-card"))
    expect(onClick).toHaveBeenCalledOnce()
  })

  it("calls onClick when Enter is pressed on the card", () => {
    const onClick = vi.fn()
    render(<JobCompactCard label="EPIC-1 / #1 T" onClick={onClick} state="open" />)
    fireEvent.keyDown(screen.getByRole("link", { name: "EPIC-1 / #1 T" }), { key: "Enter" })
    expect(onClick).toHaveBeenCalledOnce()
  })

  it("omits title paragraph when the job source has no following text", () => {
    render(<JobCompactCard label="No Epic / JOB-99" state="open" />)
    expect(screen.getByText("JOB-99")).toBeInTheDocument()
    expect(screen.queryByRole("paragraph")).not.toBeInTheDocument()
  })
})
