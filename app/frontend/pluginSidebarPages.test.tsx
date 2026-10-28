import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
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

  it("keeps hard-loaded plugin paths out of the generic shell while declarations load", async () => {
    let resolvePages: (payload: Awaited<ReturnType<typeof sidebarPagesApi.fetchSidebarPluginPages>>) => void = () => {}
    vi.mocked(sidebarPagesApi.fetchSidebarPluginPages).mockReturnValue(
      new Promise((resolve) => {
        resolvePages = resolve
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/coworkers/new"]}>
          <Routes>
            <Route path="*" element={<PluginSidebarPageRoute fallback={<div>Generic shell</div>} />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Loading...")).toBeInTheDocument()
    expect(screen.queryByText("Generic shell")).not.toBeInTheDocument()

    resolvePages({
      pages: [
        {
          id: "coworkers.index",
          label: "Coworkers",
          label_key: "coworkers:nav",
          path: "/coworkers",
          paths: ["/coworkers", "/coworkers/new", "/coworkers/:id"],
          component: "coworkers/Coworkers",
          section: "primary",
          icon: "team",
          badge_api_path: null,
          smart_folder_api_path: null,
          smart_folder_subject: null,
          smart_folder_all_link: true,
          order: 45
        }
      ]
    })

    expect(await screen.findByRole("heading", { name: "New coworker" })).toBeInTheDocument()
    expect(screen.queryByText("Generic shell")).not.toBeInTheDocument()
  })
})
