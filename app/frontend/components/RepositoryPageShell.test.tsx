import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { RepositoryPageShell } from "./RepositoryPageShell"

const TABS = [
  { key: "overview", label: "Overview", path: "/repositories/1" },
  { key: "documents", label: "Documents", path: "/repositories/1/documents" }
]

function renderShell(children = <div>Tab content</div>) {
  return render(
    <MemoryRouter>
      <RepositoryPageShell
        activeTab="overview"
        ariaLabel="Repository"
        heading={<h1>acme/widgets</h1>}
        prefix=""
        tabs={TABS}
        tipBanner={<div role="region" aria-label="Recommended actions">Tip</div>}
      >
        {children}
      </RepositoryPageShell>
    </MemoryRouter>
  )
}

describe("RepositoryPageShell", () => {
  it("renders the standard container with heading, tip banner, tab bar, then children in order", () => {
    renderShell()

    const main = screen.getByRole("main", { name: "Repository" })
    expect(main.className).toContain("mx-auto max-w-[96rem] space-y-6 p-6")

    const heading = screen.getByRole("heading", { name: "acme/widgets" })
    const banner = screen.getByRole("region", { name: "Recommended actions" })
    const tabs = screen.getByRole("navigation")
    const content = screen.getByText("Tab content")

    expect(Boolean(heading.compareDocumentPosition(banner) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(Boolean(banner.compareDocumentPosition(tabs) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(Boolean(tabs.compareDocumentPosition(content) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
  })

  it("renders the tab bar links from the tabs prop and marks the active tab", () => {
    renderShell()

    const overviewLink = screen.getByRole("link", { name: "Overview" })
    const documentsLink = screen.getByRole("link", { name: "Documents" })
    expect(overviewLink).toHaveAttribute("href", "/repositories/1")
    expect(documentsLink).toHaveAttribute("href", "/repositories/1/documents")
    expect(overviewLink.className).toContain("border-brand")
    expect(documentsLink.className).not.toContain("border-brand")
  })

  it("omits the tip banner when none is provided", () => {
    render(
      <MemoryRouter>
        <RepositoryPageShell activeTab="overview" heading={<h1>acme/widgets</h1>} prefix="" tabs={TABS}>
          <div>Tab content</div>
        </RepositoryPageShell>
      </MemoryRouter>
    )

    expect(screen.queryByRole("region", { name: "Recommended actions" })).not.toBeInTheDocument()
    expect(screen.getByText("Tab content")).toBeInTheDocument()
  })
})
