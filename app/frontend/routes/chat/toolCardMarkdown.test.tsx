import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
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

  it("renders an empty state for empty or whitespace-only text", () => {
    render(<MarkdownPreview text={"  \n\t "} />)

    expect(screen.getByText("No text was provided.")).toBeInTheDocument()
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

  it("supports character bounds, URL links, slug links, and copying full modal text", () => {
    const text = `Read https://example.test/docs and JOB-42. ${"More details. ".repeat(40)}`
    render(<MarkdownPreview linkifySlugs linkifyUrls maxChars={80} text={text} />)

    expect(screen.getByRole("link", { name: "https://example.test/docs" })).toHaveAttribute("href", "https://example.test/docs")
    expect(screen.getByText(/JOB-42/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog")).getByRole("button", { name: "Copy text" })).toBeInTheDocument()
  })
})
