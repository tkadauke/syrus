import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import * as sidebarPagesApi from "./api/sidebarPages"
import { PluginSidebarPageRoute, pluginSidebarComponentFor } from "./pluginSidebarPages"

vi.mock("./api/sidebarPages", () => ({ fetchSidebarPluginPages: vi.fn() }))

describe("plugin sidebar page registry", () => {
  it("discovers representative migrated plugin sidebar components by component key", () => {
    expect(pluginSidebarComponentFor("design_docs/DesignDocs")).toBeTruthy()
    expect(pluginSidebarComponentFor("k8s_cluster/KubernetesClusters")).toBeTruthy()
    expect(pluginSidebarComponentFor("mysql_db_browser/MysqlConnections")).toBeTruthy()
    expect(pluginSidebarComponentFor("missing/Nope")).toBeNull()
    expect(pluginSidebarComponentFor(null)).toBeNull()
    expect(pluginSidebarComponentFor(undefined)).toBeNull()
  })

  it("renders a native unavailable notice when a sidebar plugin page is disabled or missing", async () => {
    vi.mocked(sidebarPagesApi.fetchSidebarPluginPages).mockResolvedValue({ pages: [] })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/db_browser"]}>
          <PluginSidebarPageRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Page unavailable" })).toBeInTheDocument()
    expect(screen.getByText("This page is not available right now.")).toBeInTheDocument()
    expect(screen.queryByText("sidebar_pages.unavailable_heading")).not.toBeInTheDocument()
  })
})
