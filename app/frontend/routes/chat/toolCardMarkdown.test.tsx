import { fireEvent, render, screen, within } from "@testing-library/react"
import type { MouseEvent } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MarkdownPreview, truncateMarkdown } from "./toolCardMarkdown"
import { setSlugReferenceRegistryForTests } from "../../lib/slugReferenceRegistry"

afterEach(() => setSlugReferenceRegistryForTests(null))

describe("MarkdownPreview", () => {
  it("renders short light markdown without an expansion button", () => {
    render(<MarkdownPreview text="A **short** note." />)

    expect(screen.getByText("short").tagName).toBe("STRONG")
    expect(screen.queryByRole("button", { name: "Show more" })).not.toBeInTheDocument()
  })

  it("opens and closes a modal containing the complete long markdown", () => {
    const text = `${"Introductory prose. ".repeat(70)}\n\n## Complete ending\nThe final details are here.`
    render(<MarkdownPreview modalLabel="Full report" text={text} title="Report" />)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Full report" })
    expect(within(dialog).getByRole("heading", { name: "Complete ending" })).toBeInTheDocument()
    expect(within(dialog).getByText("The final details are here.")).toBeInTheDocument()

    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }))
    expect(screen.queryByRole("dialog", { name: "Full report" })).not.toBeInTheDocument()
  })

  it("renders nothing for empty or whitespace-only text", () => {
    const { container } = render(<MarkdownPreview text={"  \n\t "} />)

    expect(container).toBeEmptyDOMElement()
  })

  it("wraps long unbroken strings without horizontal overflow", () => {
    render(<MarkdownPreview maxLines={2} text={"x".repeat(500)} />)

    expect(screen.getByTestId("markdown-preview-content")).toHaveClass("break-words", "[overflow-wrap:anywhere]")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog")).getByText("x".repeat(500)).closest(".chat-prose")).toHaveClass("break-words", "[overflow-wrap:anywhere]")
  })

  it("does not cut through an inline markdown construct", () => {
    const text = `${"Words ".repeat(150)}[linked label](https://example.test/path) trailing text`

    expect(truncateMarkdown(text, 6).preview).not.toMatch(/\[[^\]]*$/)
  })

  it("supports character bounds, link handling, modal copy, and an empty state", () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } })
    setSlugReferenceRegistryForTests([
      {
        prefix: "JOB",
        type: "job",
        displayLabel: "Job",
        copyable: true,
        linkable: true,
        previewAvailable: false,
        linkifiesGeneratedText: true,
        hrefTemplate: "/jobs/:id",
        mobileInteractionHints: {},
        pluginPreviewComponent: null
      }
    ])
    const onLinkClick = vi.fn((_, event: MouseEvent<HTMLAnchorElement>) => event.preventDefault())
    const text = `See JOB-42 and https://example.test/docs. ${"More details. ".repeat(20)}`
    const { rerender } = render(
      <MemoryRouter>
        <MarkdownPreview linkifyUrls maxChars={80} onLinkClick={onLinkClick} text={text} />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("link", { name: "https://example.test/docs" }))
    expect(onLinkClick).toHaveBeenCalledWith("https://example.test/docs", expect.anything())
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Copy content" }))
    expect(writeText).toHaveBeenCalledWith(text)

    rerender(
      <MemoryRouter>
        <MarkdownPreview emptyState={<div>No content available.</div>} text="  " />
      </MemoryRouter>
    )
    expect(screen.getByText("No content available.")).toBeInTheDocument()
  })
})
