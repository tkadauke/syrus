import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { setSlugReferenceRegistryForTests } from "../lib/slugReferenceRegistry"
import { MarkdownPreview } from "./MarkdownPreview"

describe("MarkdownPreview", () => {
  afterEach(() => setSlugReferenceRegistryForTests(null))

  it("renders an empty state for blank text", () => {
    render(<MarkdownPreview text="   " />)
    expect(screen.getByText("No text provided.")).toBeInTheDocument()
  })

  it("linkifies slugs and URLs and forwards link clicks", () => {
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

  it("truncates by maxChars and opens a full modal with a copy control", () => {
    render(<MarkdownPreview maxChars={12} text="A sufficiently long markdown note." />)

    expect(screen.getByText("A sufficient…")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))

    expect(screen.getByRole("dialog", { name: "Full markdown preview" })).toBeInTheDocument()
    expect(screen.getByText("A sufficiently long markdown note.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy" })).toBeInTheDocument()
  })
})
