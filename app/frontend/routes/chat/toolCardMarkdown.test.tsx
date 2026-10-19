import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { MarkdownPreview, TextPreview, truncateMarkdown } from "./toolCardMarkdown"

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

  it("can render an empty state for blank text", () => {
    render(<MarkdownPreview emptyState="No comment supplied." text="  " />)

    expect(screen.getByText("No comment supplied.")).toBeInTheDocument()
  })

  it("honors a character limit and copies the complete text from the modal", () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } })
    const text = "Complete comment text that is longer than the compact preview."
    render(<MarkdownPreview maxChars={18} modalLabel="Full comment" text={text} title="Comment" />)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Full comment" })).getByRole("button", { name: "Copy Comment" }))

    expect(writeText).toHaveBeenCalledWith(text)
  })

  it("passes URL, slug, and link-click behavior to both preview renderers", () => {
    const onLinkClick = vi.fn()
    const text = `See DOC-20 and https://example.test/path ${"long ".repeat(40)}`
    render(<MarkdownPreview linkifyUrls maxChars={60} onLinkClick={onLinkClick} text={text} />)

    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("DOC-20")
    fireEvent.click(within(screen.getByTestId("markdown-preview-content")).getByRole("link", { name: "https://example.test/path" }))
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const link = within(screen.getByRole("dialog")).getByRole("link", { name: "https://example.test/path" })
    fireEvent.click(link)
    expect(onLinkClick).toHaveBeenCalledTimes(2)
    expect(onLinkClick).toHaveBeenCalledWith((link as HTMLAnchorElement).href, expect.anything())
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

describe("TextPreview", () => {
  it("renders short text with whitespace preserved and no expansion button", () => {
    render(<TextPreview text={"first line\n  indented line"} />)

    expect(screen.getByTestId("text-preview-content")).toHaveClass("whitespace-pre-wrap", "font-mono")
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("first line\n  indented line", { normalizeWhitespace: false })
    expect(screen.queryByRole("button", { name: "Show more" })).not.toBeInTheDocument()
  })

  it("opens and closes a modal containing the complete long text", () => {
    const text = Array.from({ length: 10 }, (_, index) => `log line ${index + 1}`).join("\n")
    render(<TextPreview maxLines={3} modalLabel="Full command output" text={text} title="Command output" />)

    expect(screen.getByTestId("text-preview-content")).not.toHaveTextContent("log line 10")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Full command output" })
    expect(dialog.querySelector("pre")).toHaveTextContent(text, { normalizeWhitespace: false })

    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }))
    expect(screen.queryByRole("dialog", { name: "Full command output" })).not.toBeInTheDocument()
  })

  it("renders nothing for empty or whitespace-only text", () => {
    const { container } = render(<TextPreview text={"  \n\t "} />)

    expect(container).toBeEmptyDOMElement()
  })

  it("truncates and safely wraps a very long single line", () => {
    const text = "x".repeat(500)
    render(<TextPreview maxLines={2} text={text} />)

    expect(screen.getByTestId("text-preview-content")).toHaveClass("break-words", "[overflow-wrap:anywhere]")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog")).getByText(text)).toHaveClass("break-words", "[overflow-wrap:anywhere]")
  })
})
