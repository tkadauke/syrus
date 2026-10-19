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

  it("can render a caller-provided empty state", () => {
    render(<MarkdownPreview emptyState="No details provided" text="  " />)
    expect(screen.getByText("No details provided")).toBeInTheDocument()
  })

  it("supports a character bound and copies complete text from the modal", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } })
    const text = "A complete sentence with more content than the compact preview."
    render(<MarkdownPreview maxChars={20} text={text} title="Details" />)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Copy Details" }))
    expect(writeText).toHaveBeenCalledWith(text)
  })

  it("passes URL linking and click handling to compact and modal markdown", () => {
    const onLinkClick = vi.fn((_, event) => event.preventDefault())
    render(<MarkdownPreview linkifyUrls maxChars={37} onLinkClick={onLinkClick} text="Visit https://example.test/docs for many more details" />)

    fireEvent.click(screen.getByRole("link", { name: "https://example.test/docs" }))
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("link", { name: "https://example.test/docs" }))
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
