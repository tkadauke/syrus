import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { MarkdownPreview, truncateMarkdown } from "./toolCardMarkdown"
import { setSlugReferenceRegistryForTests } from "../../lib/slugReferenceRegistry"

beforeEach(() => {
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
  Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
})

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

  it("honors a character limit and links URLs and Syrus references", () => {
    render(
      <MemoryRouter>
        <MarkdownPreview linkifySlugs linkifyUrls maxChars={80} text={`See JOB-42 and https://example.test/path for details. ${"More text. ".repeat(20)}`} />
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.test/path" })).toHaveAttribute("href", "https://example.test/path")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("preserves disabled slug linking in the expanded modal", () => {
    const text = `See JOB-42 for details. ${"Additional prose. ".repeat(30)}`
    render(
      <MemoryRouter>
        <MarkdownPreview linkifySlugs={false} maxChars={40} text={text} />
      </MemoryRouter>
    )

    expect(screen.queryByRole("link", { name: /JOB-42/ })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog")
    expect(within(dialog).queryByRole("link", { name: /JOB-42/ })).not.toBeInTheDocument()
    expect(within(dialog).getByText(/See JOB-42 for details/)).toBeInTheDocument()
  })

  it("shows a caller-supplied empty state and copies complete modal text", () => {
    const text = "Long content. ".repeat(100)
    const { rerender } = render(<MarkdownPreview emptyState={<span>No prose supplied.</span>} text="  " />)
    expect(screen.getByText("No prose supplied.")).toBeInTheDocument()

    rerender(<MarkdownPreview maxChars={40} text={text} title="Question" />)
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(screen.getByRole("button", { name: "Copy Question to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(text)
  })
})
