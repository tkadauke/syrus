import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { RepositoryTabs } from "./RepositoryTabs"

function renderTabs(tabs: Parameters<typeof RepositoryTabs>[0]["tabs"]) {
  return render(
    <MemoryRouter>
      <RepositoryTabs active="overview" prefix="" tabs={tabs} />
    </MemoryRouter>
  )
}

describe("RepositoryTabs", () => {
  it("renders a red exclamation badge on the Health tab when the main branch is unhealthy", () => {
    renderTabs([
      { key: "overview", label: "Overview", path: "/repositories/1" },
      { key: "health", label: "Health", path: "/repositories/1/health", badge: "!" }
    ])

    const badge = screen.getByText("!")
    expect(badge).toBeInTheDocument()
    expect(badge).toHaveClass("bg-red-500")
  })

  it("renders no badge on the Health tab when the main branch is healthy", () => {
    renderTabs([
      { key: "overview", label: "Overview", path: "/repositories/1" },
      { key: "health", label: "Health", path: "/repositories/1/health" }
    ])

    expect(screen.queryByText("!")).not.toBeInTheDocument()
  })
})
