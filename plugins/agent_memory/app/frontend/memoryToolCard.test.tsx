import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ContentPreview } from "./memoryToolCard"

describe("ContentPreview", () => {
  it("renders a heading as bold with no line break in the collapsed preview", () => {
    const { container } = render(<ContentPreview content={"# Title\n\nBody text."} />)

    expect(container.querySelector("strong")).toHaveTextContent("Title")
    expect(container.querySelector("h1")).toBeNull()
    expect(container.textContent).not.toContain("#")
    expect(container.textContent).toBe("Title Body text.")
  })

  it("still 3-line-clamps a long multi-paragraph memory, shows Show more, and opens a modal with full markdown", () => {
    const longContent = Array.from({ length: 8 }, (_, index) => `# Section ${index}\n\nSome body text for section ${index}.`).join("\n\n")
    const { container } = render(<ContentPreview content={longContent} />)

    expect(container.querySelector(".line-clamp-3")).toBeInTheDocument()
    const showMore = screen.getByText("Show more")
    expect(showMore).toBeInTheDocument()
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    fireEvent.click(showMore)

    const dialog = screen.getByRole("dialog")
    expect(dialog).toBeInTheDocument()
    expect(dialog.querySelector("h1")).toHaveTextContent("Section 0")
    expect(dialog).toHaveTextContent("Some body text for section 0.")
  })
})
