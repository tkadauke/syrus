import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { MarkdownPreview, TextPreview, truncateMarkdown, truncateTextLines } from "./toolCardMarkdown"
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

describe("TextPreview", () => {
  it("truncates from the head by default and normalizes CRLF", () => {
    expect(truncateTextLines("one\r\ntwo\r\nthree", { maxLines: 2 })).toEqual({
      preview: "one\ntwo…",
      totalLines: 3,
      truncated: true
    })
  })

  it("keeps the final lines in tail mode and reports earlier lines", () => {
    expect(truncateTextLines("one\ntwo\nthree\nfour", { mode: "tail", maxLines: 2 }).preview).toBe("… 2 earlier lines\nthree\nfour")
  })

  it("keeps both ends and reports the exact omitted line count", () => {
    expect(truncateTextLines("one\ntwo\nthree\nfour\nfive", { mode: "headTail", maxLines: 4 }).preview).toBe("one\ntwo\n… 1 line omitted\nfour\nfive")
  })

  it("caps a single huge line by characters in every mode", () => {
    const text = "0123456789"

    expect(truncateTextLines(text, { mode: "head", maxLines: 3, maxChars: 4 }).preview).toBe("0123…")
    expect(truncateTextLines(text, { mode: "tail", maxLines: 3, maxChars: 4 }).preview).toBe("… earlier text\n6789")
    expect(truncateTextLines(text, { mode: "headTail", maxLines: 3, maxChars: 4 }).preview).toBe("01\n… text omitted\n89")
  })

  it("uses a non-numeric tail marker when character clipping drops selected multiline content", () => {
    const result = truncateTextLines("aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc", { mode: "tail", maxLines: 2, maxChars: 5 })

    expect(result.preview).toBe("… earlier text\nccccc")
    expect(result.preview).not.toContain("1 earlier line")
  })

  it("uses a non-numeric head-tail marker when character clipping trims either retained end", () => {
    const result = truncateTextLines("aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc", { mode: "headTail", maxLines: 2, maxChars: 8 })

    expect(result.preview).toBe("aaaa\n… text omitted\ncccc")
    expect(result.preview).not.toContain("line omitted")
  })

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
    expect(within(dialog).getByRole("button", { name: /Copy .*clipboard/i })).toBeInTheDocument()
    expect(dialog).toHaveClass("h-[100dvh]", "w-full", "sm:max-w-3xl")
    expect(dialog.parentElement).toHaveClass("h-[100dvh]", "w-[100dvw]", "p-0", "sm:p-4")

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

  it("renders the tail marker above the final lines", () => {
    render(<TextPreview maxLines={2} text={"one\ntwo\nthree\nfour"} truncate="tail" />)

    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("… 2 earlier lines\nthree\nfour", { normalizeWhitespace: false })
  })
})

describe("MarkdownPreview link handling", () => {
  it("linkifies slugs and URLs and forwards link clicks", () => {
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
    expect(within(dialog).getByRole("button", { name: /Copy .*clipboard/i })).toBeInTheDocument()
  })
})
