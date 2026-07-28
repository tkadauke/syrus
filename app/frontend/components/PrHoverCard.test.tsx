import { act, fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { PrHoverCard } from "./PrHoverCard"

vi.mock("./PrPreviewCard", () => ({
  PrPreviewCard: ({ jobId, prNumber }: { jobId: number; prNumber: number }) => (
    <div data-testid="pr-card">PR #{prNumber} for job {jobId}</div>
  ),
  PrPreviewSkeleton: () => <div data-testid="pr-skeleton" />,
}))

function mockMatchMedia(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    })),
  })
}

function renderCard(jobId = 42, prNumber = 99, prUrl = "https://github.com/owner/repo/pull/99") {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <PrHoverCard jobId={jobId} prNumber={prNumber} prUrl={prUrl}>
          <a href={prUrl}>PR #{prNumber}</a>
        </PrHoverCard>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("PrHoverCard on a touch / non-pointer device", () => {
  beforeEach(() => mockMatchMedia(false))
  afterEach(() => vi.restoreAllMocks())

  it("renders children without opening a card on hover", () => {
    renderCard()
    expect(screen.getByRole("link", { name: "PR #99" })).toBeInTheDocument()
    expect(screen.queryByTestId("pr-card")).not.toBeInTheDocument()
  })
})

describe("PrHoverCard on a pointer:fine device", () => {
  beforeEach(() => {
    mockMatchMedia(true)
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("renders children wrapped in an inline span", () => {
    renderCard()
    const link = screen.getByRole("link", { name: "PR #99" })
    expect(link.parentElement?.tagName).toBe("SPAN")
  })

  it("does not show the card immediately on mouse enter", () => {
    renderCard()
    const span = screen.getByRole("link", { name: "PR #99" }).parentElement!
    fireEvent.mouseEnter(span)
    expect(screen.queryByTestId("pr-card")).not.toBeInTheDocument()
  })

  it("shows the preview card after 300ms delay", async () => {
    renderCard()
    const span = screen.getByRole("link", { name: "PR #99" }).parentElement!
    fireEvent.mouseEnter(span)

    await act(async () => { vi.advanceTimersByTime(300) })

    expect(screen.getByTestId("pr-card")).toBeInTheDocument()
    expect(screen.getByTestId("pr-card").textContent).toBe("PR #99 for job 42")
  })

  it("cancels open timer when mouse leaves before 300ms", async () => {
    renderCard()
    const span = screen.getByRole("link", { name: "PR #99" }).parentElement!
    fireEvent.mouseEnter(span)
    fireEvent.mouseLeave(span)

    await act(async () => { vi.advanceTimersByTime(400) })

    expect(screen.queryByTestId("pr-card")).not.toBeInTheDocument()
  })

  it("closes the card on mouse leave from the reference span", async () => {
    renderCard()
    const span = screen.getByRole("link", { name: "PR #99" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => { vi.advanceTimersByTime(300) })
    expect(screen.getByTestId("pr-card")).toBeInTheDocument()

    fireEvent.mouseLeave(span)
    await act(async () => { vi.advanceTimersByTime(200) })

    expect(screen.queryByTestId("pr-card")).not.toBeInTheDocument()
  })

  it("keeps the card open when mouse moves to the floating card", async () => {
    renderCard()
    const span = screen.getByRole("link", { name: "PR #99" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => { vi.advanceTimersByTime(300) })

    const card = screen.getByTestId("pr-card").parentElement!
    fireEvent.mouseLeave(span)
    fireEvent.mouseEnter(card)
    await act(async () => { vi.advanceTimersByTime(200) })

    expect(screen.getByTestId("pr-card")).toBeInTheDocument()
  })

  it("closes the card when mouse leaves the floating card", async () => {
    renderCard()
    const span = screen.getByRole("link", { name: "PR #99" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => { vi.advanceTimersByTime(300) })

    const card = screen.getByTestId("pr-card").parentElement!
    await act(async () => { fireEvent.mouseLeave(card) })

    expect(screen.queryByTestId("pr-card")).not.toBeInTheDocument()
  })
})
