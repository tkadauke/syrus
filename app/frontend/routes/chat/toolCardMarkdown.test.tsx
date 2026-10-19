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
    render(<MarkdownPreview emptyState={<span>No prompt</span>} text=" " />)

    expect(screen.getByText("No prompt")).toBeInTheDocument()
  })

  it("honors a character limit and copies the complete text from the modal", async () => {
    const text = "A compact single-line prompt. ".repeat(30)
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
    render(<MarkdownPreview maxChars={80} modalLabel="Full prompt" text={text} />)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: /Copy Full prompt/ }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(text)
  })

  it("passes URL and click handling through both preview renderers", () => {
    const onLinkClick = vi.fn((href, event) => event.preventDefault())
    const text = `Visit https://example.test/path then ${"continue reading. ".repeat(20)}`
    render(<MarkdownPreview linkifyUrls maxChars={60} onLinkClick={onLinkClick} text={text} />)

    fireEvent.click(screen.getByRole("link"))
    expect(onLinkClick).toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("link"))
    expect(onLinkClick).toHaveBeenCalledTimes(2)
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
