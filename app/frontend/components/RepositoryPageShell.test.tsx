import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import * as repoPluginTabsApi from "../api/repoPluginTabs"
import { RepositoryPageShell } from "./RepositoryPageShell"

vi.mock("../api/repoPluginTabs", () => ({ fetchRepoPluginTabs: vi.fn() }))

const TABS = [
  { key: "overview", label: "Overview", path: "/repositories/1" },
  { key: "documents", label: "Documents", path: "/repositories/1/documents" }
]

function renderShell(children = <div>Tab content</div>, includeTip = true) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/repositories/1"]}>
        <Routes>
          <Route path="/repositories/:repositoryId" element={
            <RepositoryPageShell
              activeTab="overview"
              ariaLabel="Repository"
              heading={<h1>acme/widgets</h1>}
              prefix=""
              tipBanner={includeTip ? (
                <div role="region" aria-label="Recommended actions">
                  Tip
                </div>
              ) : undefined}
            >
              {children}
            </RepositoryPageShell>
          } />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryPageShell", () => {
  beforeEach(() => {
    vi.mocked(repoPluginTabsApi.fetchRepoPluginTabs).mockResolvedValue({ tabs: TABS.map((tab) => ({ ...tab, id: tab.key, paths: [tab.path], order: 0 })) })
  })

  it("renders the standard container with heading, tip banner, tab bar, then children in order", () => {
    renderShell()

    const main = screen.getByRole("main", { name: "Repository" })
    expect(main.className).toContain("max-w-[96rem]")
    expect(main.className).toContain("px-0")
    expect(main.className).toContain("sm:px-[var(--space-page-x)]")

    const heading = screen.getByRole("heading", { name: "acme/widgets" })
    const banner = screen.getByRole("region", { name: "Recommended actions" })
    const tabs = screen.getByRole("navigation")
    const content = screen.getByText("Tab content")

    expect(Boolean(heading.compareDocumentPosition(banner) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(Boolean(banner.compareDocumentPosition(tabs) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(Boolean(tabs.compareDocumentPosition(content) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
  })

  it("restores the mobile gutter on the header, tip banner, and tab bar, but lets content run flush", () => {
    renderShell()

    const heading = screen.getByRole("heading", { name: "acme/widgets" })
    const header = heading.closest("header")
    expect(header?.className).toContain("px-4 sm:px-0")

    const banner = screen.getByRole("region", { name: "Recommended actions" })
    expect(banner.parentElement?.className).toContain("mx-4 sm:mx-0")

    const tabs = screen.getByRole("navigation")
    const nav = tabs.closest("div")
    expect(nav?.className).toContain("px-4 sm:px-0")
  })

  it("renders tab bar links from the repository plugin-tabs query and marks the active tab", async () => {
    renderShell()

    const overviewLink = await screen.findByRole("link", { name: "Overview" })
    const documentsLink = await screen.findByRole("link", { name: "Documents" })
    expect(overviewLink).toHaveAttribute("href", "/repositories/1")
    expect(documentsLink).toHaveAttribute("href", "/repositories/1/documents")
    expect(overviewLink.className).toContain("border-brand")
    expect(documentsLink.className).not.toContain("border-brand")
  })

  it("omits the tip banner when none is provided", () => {
    renderShell(<div>Tab content</div>, false)

    expect(screen.queryByRole("region", { name: "Recommended actions" })).not.toBeInTheDocument()
    expect(screen.getByText("Tab content")).toBeInTheDocument()
  })
})
