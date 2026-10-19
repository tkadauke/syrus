import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { MarkdownPreview, truncateMarkdown } from "./toolCardMarkdown"

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

  it("renders a caller-provided empty state", () => {
    render(<MarkdownPreview emptyState={<span>Nothing here</span>} text=" " />)
    expect(screen.getByText("Nothing here")).toBeInTheDocument()
  })

  it("supports a character limit and passes link behavior through both views", () => {
    const onLinkClick = vi.fn()
    render(<MarkdownPreview linkifyUrls maxChars={45} onLinkClick={onLinkClick} text={`See https://example.test and JOB-42. ${"more ".repeat(20)}`} />)
    fireEvent.click(screen.getByRole("link", { name: "https://example.test" }))
    expect(onLinkClick).toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog")
    expect(dialog).toHaveTextContent("JOB-42")
    expect(within(dialog).getByRole("button", { name: /Copy/ })).toBeInTheDocument()
  })

  it.each([
    ["mobile", 320],
    ["desktop", 960]
  ])("does not visually clamp untruncated text at %s width", (_viewport, width) => {
    const text = "Responsive paragraph content. ".repeat(35)
    render(
      <div style={{ width }}>
        <MarkdownPreview maxChars={2_400} maxLines={6} text={text} />
      </div>
    )

    const preview = screen.getByTestId("markdown-preview-content")
    expect(preview).toHaveTextContent(text.trim())
    expect(preview.style.getPropertyValue("-webkit-line-clamp")).toBe("")
    expect(preview.style.overflow).toBe("")
    expect(screen.queryByRole("button", { name: "Show more" })).not.toBeInTheDocument()
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
})
