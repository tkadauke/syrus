import { act, fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { SlugHoverCard } from "./SlugHoverCard"

// Stub preview cards so tests don't need live API calls
vi.mock("./JobPreviewCard", () => ({
  JobPreviewCard: ({ id }: { id: number }) => <div data-testid="job-card">JOB-{id}</div>,
  JobPreviewSkeleton: () => <div data-testid="job-skeleton" />,
}))
vi.mock("./EpicPreviewCard", () => ({
  EpicPreviewCard: ({ id }: { id: number }) => <div data-testid="epic-card">EPIC-{id}</div>,
  EpicPreviewSkeleton: () => <div data-testid="epic-skeleton" />,
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

function renderCard(kind: "job" | "epic", id: number) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <SlugHoverCard id={id} kind={kind}>
          <a href={`/${kind}s/${id}`}>{kind.toUpperCase()}-{id}</a>
        </SlugHoverCard>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("SlugHoverCard on a touch / non-pointer device", () => {
  beforeEach(() => mockMatchMedia(false))
  afterEach(() => vi.restoreAllMocks())

  it("renders children without any wrapper span", () => {
    renderCard("job", 1)
    // The anchor is present but no card should appear on hover
    expect(screen.getByRole("link", { name: "JOB-1" })).toBeInTheDocument()
    // No floating card
    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })
})

describe("SlugHoverCard on a pointer:fine device", () => {
  beforeEach(() => {
    mockMatchMedia(true)
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("renders children wrapped in an inline span", () => {
    renderCard("job", 1)
    const link = screen.getByRole("link", { name: "JOB-1" })
    expect(link.parentElement?.tagName).toBe("SPAN")
  })

  it("does not show the card immediately on mouse enter", () => {
    renderCard("job", 42)
    const span = screen.getByRole("link", { name: "JOB-42" }).parentElement!
    fireEvent.mouseEnter(span)
    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("shows the job card after 300ms delay", async () => {
    renderCard("job", 42)
    const span = screen.getByRole("link", { name: "JOB-42" }).parentElement!
    fireEvent.mouseEnter(span)

    await act(async () => { vi.advanceTimersByTime(300) })

    expect(screen.getByTestId("job-card")).toBeInTheDocument()
    expect(screen.getByTestId("job-card").textContent).toBe("JOB-42")
  })

  it("shows the epic card for kind=epic", async () => {
    renderCard("epic", 7)
    const span = screen.getByRole("link", { name: "EPIC-7" }).parentElement!
    fireEvent.mouseEnter(span)

    await act(async () => { vi.advanceTimersByTime(300) })

    expect(screen.getByTestId("epic-card")).toBeInTheDocument()
    expect(screen.getByTestId("epic-card").textContent).toBe("EPIC-7")
  })

  it("cancels open timer when mouse leaves before 300ms", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    fireEvent.mouseLeave(span)

    await act(async () => { vi.advanceTimersByTime(400) })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("closes the card on mouse leave from the reference span", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => { vi.advanceTimersByTime(300) })
    expect(screen.getByTestId("job-card")).toBeInTheDocument()

    fireEvent.mouseLeave(span)
    // Advance past the 100ms close grace period
    await act(async () => { vi.advanceTimersByTime(200) })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("keeps the card open when mouse moves to the floating card", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => { vi.advanceTimersByTime(300) })

    const card = screen.getByTestId("job-card").parentElement!
    // Mouse leaves reference but enters floating — grace period cancelled
    fireEvent.mouseLeave(span)
    fireEvent.mouseEnter(card)
    await act(async () => { vi.advanceTimersByTime(200) })

    expect(screen.getByTestId("job-card")).toBeInTheDocument()
  })

  it("closes the card when mouse leaves the floating card", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => { vi.advanceTimersByTime(300) })

    // handleFloatingLeave calls setIsOpen(false) directly — no timer needed
    const card = screen.getByTestId("job-card").parentElement!
    await act(async () => { fireEvent.mouseLeave(card) })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })
})
