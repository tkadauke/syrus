import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { MouseEvent } from "react"
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

  it("renders an optional empty state for blank text", () => {
    render(<MarkdownPreview emptyText="No preview text." text="  " />)

    expect(screen.getByText("No preview text.")).toBeInTheDocument()
  })

  it("passes URL, slug, and click handling through the preview and modal and copies full text", async () => {
    const onLinkClick = vi.fn((_: string, event: MouseEvent<HTMLAnchorElement>) => event.preventDefault())
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } })
    const text = `${"See JOB-101 and https://example.test/runbook. ".repeat(12)}complete`
    render(<MarkdownPreview linkifySlugs linkifyUrls maxChars={120} onLinkClick={onLinkClick} text={text} />)

    fireEvent.click(screen.getAllByRole("link", { name: "https://example.test/runbook" })[0])
    expect(onLinkClick).toHaveBeenCalledWith("https://example.test/runbook", expect.anything())
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog")
    fireEvent.click(within(dialog).getByRole("button", { name: "Copy text" }))
    expect(writeText).toHaveBeenCalledWith(text)
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
