import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import * as repoPluginTabsApi from "./api/repoPluginTabs"
import { PluginRepoPageTabRoute, pluginRepoComponentFor, pluginRepoComponentKeys } from "./pluginRepoPageTabs"

vi.mock("./api/repoPluginTabs", () => ({ fetchRepoPluginTabs: vi.fn() }))

describe("plugin repo page tab registry", () => {
  it("discovers installed plugin repo tab route components by component key", () => {
    expect(pluginRepoComponentKeys()).toEqual(expect.arrayContaining([
      "design_docs/RepositoryDesignDocs",
      "test_insights/RepositoryTests"
    ]))
    expect(pluginRepoComponentFor("missing/Nope")).toBeNull()
    expect(pluginRepoComponentFor(null)).toBeNull()
    expect(pluginRepoComponentFor(undefined)).toBeNull()
  })

  it("renders a native unavailable notice when a repository plugin tab is disabled or missing", async () => {
    vi.mocked(repoPluginTabsApi.fetchRepoPluginTabs).mockResolvedValue({ tabs: [] })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/repositories/42/plugin/tests"]}>
          <Routes>
            <Route element={<PluginRepoPageTabRoute />} path="/repositories/:repositoryId/plugin/*" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Page unavailable" })).toBeInTheDocument()
    expect(screen.getByText("This repository tab is not available. The plugin that provides it may be disabled or missing.")).toBeInTheDocument()
    expect(screen.queryByText("plugin_repo_tabs.unavailable_heading")).not.toBeInTheDocument()
  })
})
