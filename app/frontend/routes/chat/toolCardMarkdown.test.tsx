import { fireEvent, render, screen, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MarkdownPreview, truncateMarkdown } from "./toolCardMarkdown"

describe("MarkdownPreview", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

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

  it("renders an empty state for whitespace-only text", () => {
    render(<MarkdownPreview emptyLabel="Nothing was written." text={"  \n\t "} />)

    expect(screen.getByText("Nothing was written.")).toBeInTheDocument()
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

  it("honors a character limit and offers a modal copy action", () => {
    const text = "Long content ".repeat(20)
    render(<MarkdownPreview maxChars={20} text={text} title="Notes" />)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Notes" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Copy Notes" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(text)
  })
})
