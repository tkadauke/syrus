import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { setSlugReferenceRegistryForTests } from "../../lib/slugReferenceRegistry"
import { MarkdownPreview, TextPreview, truncateMarkdown } from "./toolCardMarkdown"

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

    expect(screen.getByText("No content provided.")).toBeInTheDocument()
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

  it("supports a character cap and passes link behavior to the preview and modal", () => {
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
    const onLinkClick = vi.fn((_, event) => event.preventDefault())
    render(
      <MemoryRouter>
        <MarkdownPreview linkifyUrls maxChars={30} onLinkClick={onLinkClick} text={`JOB-42 https://example.test ${"details ".repeat(20)}`} />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("link", { name: "https://example.test" }))
    expect(onLinkClick).toHaveBeenCalled()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog")).getByRole("button", { name: /Copy/ })).toBeInTheDocument()
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
