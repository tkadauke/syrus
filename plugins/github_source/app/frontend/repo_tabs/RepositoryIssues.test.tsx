import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import RepositoryIssuesTab from "./RepositoryIssues"

function issuesPayload() {
  return {
    repository: { id: 1, slug: "acme/widgets", github_url: "https://github.com/acme/widgets", trigger_label: "syrus" },
    tabs: [
      { key: "overview", label: "Overview", path: "/repositories/1" },
      { key: "github_source.issues", label: "GitHub Issues", path: "/repositories/1/plugin/issues" }
    ],
    state: "open" as const,
    issue_count: 0,
    issues: [],
    state_paths: { open: "/repositories/1/plugin/issues", closed: "/repositories/1/plugin/issues?state=closed" },
    paths: {
      github_issues_path: "https://github.com/acme/widgets/issues",
      app_comment_issue_path: "/api/v1/app/repositories/1/issues/comment",
      app_close_issue_path: "/api/v1/app/repositories/1/issues/close",
      app_delegate_issue_path: "/api/v1/app/repositories/1/issues/delegate",
      app_bulk_issues_path: "/api/v1/app/repositories/1/issues/bulk"
    }
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ "/repositories/1/plugin/issues" ]}>
        <Routes>
          <Route element={<RepositoryIssuesTab />} path="/repositories/:repositoryId/plugin/issues" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryIssuesTab tab bar", () => {
  afterEach(() => vi.restoreAllMocks())

  it("highlights the GitHub Issues tab using the real repo_page_tab id, not a mismatched literal", async () => {
    renderRoute()

    const issuesLink = await screen.findByRole("link", { name: "GitHub Issues" })
    expect(issuesLink.className).toContain("border-brand")
  })
})
