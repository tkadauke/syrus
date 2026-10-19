import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { setSlugReferenceRegistryForTests } from "../../lib/slugReferenceRegistry"
import { MarkdownPreview, truncateMarkdown } from "./toolCardMarkdown"

describe("MarkdownPreview", () => {
  afterEach(() => setSlugReferenceRegistryForTests(null))

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

  it("renders an empty state for empty or whitespace-only text", () => {
    render(<MarkdownPreview text={"  \n\t "} />)

    expect(screen.getByText("No text provided.")).toBeInTheDocument()
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

  it("linkifies slugs and URLs and forwards link clicks", () => {
    setSlugReferenceRegistryForTests([
      {
        prefix: "JOB",
        type: "job",
        displayLabel: "Job",
        copyable: false,
        linkable: true,
        previewAvailable: false,
        linkifiesGeneratedText: true,
        hrefTemplate: "/jobs/:id",
        mobileInteractionHints: {},
        pluginPreviewComponent: null
      }
    ])
    const onLinkClick = vi.fn()
    render(
      <MemoryRouter>
        <MarkdownPreview linkifySlugs linkifyUrls onLinkClick={onLinkClick} text="See JOB-42 at https://example.test/jobs/42." />
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    const url = screen.getByRole("link", { name: "https://example.test/jobs/42" })
    fireEvent.click(url)
    expect(onLinkClick).toHaveBeenCalledWith("https://example.test/jobs/42", expect.anything())
  })

  it("truncates by maxChars and provides a modal copy control", () => {
    render(<MarkdownPreview maxChars={12} text="A sufficiently long markdown note." />)

    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("A sufficient…")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))

    const dialog = screen.getByRole("dialog", { name: "Show more" })
    expect(within(dialog).getByText("A sufficiently long markdown note.")).toBeInTheDocument()
    expect(within(dialog).getByRole("button", { name: "Copy" })).toBeInTheDocument()
  })
})
