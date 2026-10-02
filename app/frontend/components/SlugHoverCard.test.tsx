import { act, fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { Link, MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { SlugReferenceRegistryEntry } from "../lib/slugReferenceRegistry"
import { CopyableSlug } from "./CopyableSlug"
import { SlugReferenceCard } from "./SlugHoverCard"

// Stub preview cards so tests don't need live API calls
vi.mock("./JobPreviewCard", () => ({
  JobPreviewCard: ({ id }: { id: number }) => <div data-testid="job-card">JOB-{id}</div>,
  JobPreviewSkeleton: () => <div data-testid="job-skeleton" />
}))
vi.mock("./EpicPreviewCard", () => ({
  EpicPreviewCard: ({ id }: { id: number }) => <div data-testid="epic-card">EPIC-{id}</div>,
  EpicPreviewSkeleton: () => <div data-testid="epic-skeleton" />
}))
vi.mock("../pluginSlugPreviewCards", () => ({
  pluginSlugPreviewCardComponentForPrefix: (prefix: string | null | undefined) =>
    prefix === "DOC" ? ({ id }: { id: number }) => <div data-testid="doc-card">DOC-{id}</div> : null
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
      dispatchEvent: vi.fn()
    }))
  })
}

function renderCard(kind: "job" | "epic" | "plugin", id: number, prefix?: string, overrides: Partial<SlugReferenceRegistryEntry> = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const label = kind === "plugin" ? prefix : kind.toUpperCase()
  const slug = `${label}-${id}`
  const entry = registryEntry({
    prefix: prefix ?? kind.toUpperCase(),
    type: kind === "plugin" ? "design_doc" : kind,
    pluginPreviewComponent: kind === "plugin" && prefix === "DOC" ? ({ id }: { id: number }) => <div data-testid="doc-card">DOC-{id}</div> : null,
    ...overrides
  })
  const child = entry.linkable && entry.hrefTemplate ? (
    <Link to={`/${(prefix ?? kind).toLowerCase()}s/${id}`}>{slug}</Link>
  ) : (
    <CopyableSlug slug={slug} />
  )

  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <SlugReferenceCard entry={entry} id={id} slug={slug}>
          {child}
        </SlugReferenceCard>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function registryEntry(overrides: Partial<SlugReferenceRegistryEntry> & Pick<SlugReferenceRegistryEntry, "prefix" | "type">): SlugReferenceRegistryEntry {
  return {
    displayLabel: overrides.prefix,
    copyable: true,
    linkable: true,
    previewAvailable: true,
    linkifiesGeneratedText: true,
    hrefTemplate: "/refs/:id",
    mobileInteractionHints: { tap: "open", long_press: "copy" },
    pluginPreviewComponent: null,
    ...overrides
  }
}

describe("SlugReferenceCard on a touch / non-pointer device", () => {
  beforeEach(() => {
    mockMatchMedia(false)
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })
  afterEach(() => vi.restoreAllMocks())

  it("renders children without opening from hover", () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!

    fireEvent.mouseEnter(span)

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("opens an action sheet on tap/click and dismisses it on outside pointer down", async () => {
    renderCard("job", 42)
    const link = screen.getByRole("link", { name: "JOB-42" })

    let clickResult = true
    await act(async () => {
      clickResult = fireEvent.click(link)
    })

    expect(clickResult).toBe(false)
    expect(screen.getByRole("dialog", { name: "Actions for JOB-42" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open JOB-42" })).toHaveAttribute("href", "/refs/42")
    expect(screen.getByRole("button", { name: "Copy JOB-42" })).toBeInTheDocument()
    expect(screen.getByTestId("job-card")).toBeInTheDocument()

    await act(async () => {
      fireEvent.pointerDown(document.body)
    })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("opens the same action surface from Enter and dismisses it with Escape", async () => {
    renderCard("job", 42)
    const link = screen.getByRole("link", { name: "JOB-42" })

    await act(async () => {
      fireEvent.keyDown(link, { key: "Enter" })
    })

    expect(screen.getByRole("dialog", { name: "Actions for JOB-42" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open JOB-42" })).toBeInTheDocument()
    expect(screen.getByTestId("job-card")).toBeInTheDocument()

    await act(async () => {
      fireEvent.keyDown(document, { key: "Escape" })
    })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("opens copy-only registered refs with an unavailable-preview state", async () => {
    renderCard("plugin", 5, "INSIGHT", { displayLabel: "Insight", hrefTemplate: null, linkable: false, previewAvailable: false })
    const button = screen.getByRole("button", { name: "Copy INSIGHT-5 to clipboard" })

    await act(async () => {
      fireEvent.click(button)
    })

    expect(screen.getByRole("dialog", { name: "Actions for INSIGHT-5" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Open INSIGHT-5" })).not.toBeInTheDocument()
    const copyAction = screen.getByRole("button", { name: "Copy INSIGHT-5" })
    expect(copyAction).toBeInTheDocument()
    expect(screen.getByText("No preview is available for this reference.")).toBeInTheDocument()

    fireEvent.click(copyAction)
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("INSIGHT-5")
  })

  it("opens copy-only registered refs from Space without copying inline", async () => {
    renderCard("plugin", 5, "INSIGHT", { displayLabel: "Insight", hrefTemplate: null, linkable: false, previewAvailable: false })
    const button = screen.getByRole("button", { name: "Copy INSIGHT-5 to clipboard" })

    await act(async () => {
      fireEvent.keyDown(button, { key: " " })
    })

    expect(screen.getByRole("dialog", { name: "Actions for INSIGHT-5" })).toBeInTheDocument()
    expect(navigator.clipboard.writeText).not.toHaveBeenCalled()
  })
})

describe("SlugReferenceCard on a pointer:fine device", () => {
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

    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    expect(screen.getByTestId("job-card")).toBeInTheDocument()
    expect(screen.getByTestId("job-card").textContent).toBe("JOB-42")
  })

  it("constrains the floating card width to the viewport", async () => {
    renderCard("job", 42)
    const span = screen.getByRole("link", { name: "JOB-42" }).parentElement!
    fireEvent.mouseEnter(span)

    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    expect(screen.getByTestId("job-card").parentElement).toHaveClass("[&>*]:max-w-[calc(100vw-1rem)]")
  })

  it("shows the epic card for kind=epic", async () => {
    renderCard("epic", 7)
    const span = screen.getByRole("link", { name: "EPIC-7" }).parentElement!
    fireEvent.mouseEnter(span)

    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    expect(screen.getByTestId("epic-card")).toBeInTheDocument()
    expect(screen.getByTestId("epic-card").textContent).toBe("EPIC-7")
  })

  it("shows the plugin-provided doc card for kind=plugin, prefix=DOC", async () => {
    renderCard("plugin", 20, "DOC")
    const span = screen.getByRole("link", { name: "DOC-20" }).parentElement!
    fireEvent.mouseEnter(span)

    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    expect(screen.getByTestId("doc-card")).toBeInTheDocument()
    expect(screen.getByTestId("doc-card").textContent).toBe("DOC-20")
  })

  it("cancels open timer when mouse leaves before 300ms", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    fireEvent.mouseLeave(span)

    await act(async () => {
      vi.advanceTimersByTime(400)
    })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("closes the card on mouse leave from the reference span", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => {
      vi.advanceTimersByTime(300)
    })
    expect(screen.getByTestId("job-card")).toBeInTheDocument()

    fireEvent.mouseLeave(span)
    // Advance past the 100ms close grace period
    await act(async () => {
      vi.advanceTimersByTime(200)
    })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("keeps the card open when mouse moves to the floating card", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    const card = screen.getByTestId("job-card").parentElement!
    // Mouse leaves reference but enters floating — grace period cancelled
    fireEvent.mouseLeave(span)
    fireEvent.mouseEnter(card)
    await act(async () => {
      vi.advanceTimersByTime(200)
    })

    expect(screen.getByTestId("job-card")).toBeInTheDocument()
  })

  it("closes the card when mouse leaves the floating card", async () => {
    renderCard("job", 1)
    const span = screen.getByRole("link", { name: "JOB-1" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    // handleFloatingLeave calls setIsOpen(false) directly — no timer needed
    const card = screen.getByTestId("job-card").parentElement!
    await act(async () => {
      fireEvent.mouseLeave(card)
    })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
  })

  it("does not warn or render a stale portal when unmounted before the open timer fires", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { unmount } = renderCard("job", 42)
    const span = screen.getByRole("link", { name: "JOB-42" }).parentElement!
    fireEvent.mouseEnter(span)

    unmount()

    await act(async () => {
      vi.advanceTimersByTime(300)
    })

    expect(screen.queryByTestId("job-card")).not.toBeInTheDocument()
    expect(errorSpy).not.toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it("does not warn or render a stale portal when unmounted before the close timer fires", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { unmount } = renderCard("job", 42)
    const span = screen.getByRole("link", { name: "JOB-42" }).parentElement!
    fireEvent.mouseEnter(span)
    await act(async () => {
      vi.advanceTimersByTime(300)
    })
    expect(screen.getByTestId("job-card")).toBeInTheDocument()

    fireEvent.mouseLeave(span)
    unmount()

    await act(async () => {
      vi.advanceTimersByTime(100)
    })

    expect(errorSpy).not.toHaveBeenCalled()
    errorSpy.mockRestore()
  })
})
