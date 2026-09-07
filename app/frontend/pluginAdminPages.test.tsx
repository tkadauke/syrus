import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import * as adminPluginPagesApi from "./api/adminPluginPages"
import type { AdminPluginPage } from "./api/adminPluginPages"
import { PluginAdminPageRoute, pluginAdminComponentFor, pluginAdminComponentKeys, usePluginAdminPage } from "./pluginAdminPages"

vi.mock("./api/adminPluginPages", () => ({ fetchAdminPluginPages: vi.fn() }))

describe("plugin admin page registry", () => {
  it("discovers installed plugin admin route components by component key", () => {
    expect(pluginAdminComponentKeys()).toContain("syrus_dev/AdminPerformance")
    expect(pluginAdminComponentFor("syrus_dev/AdminPerformance")).toBeTruthy()
    expect(pluginAdminComponentFor("missing/Nope")).toBeNull()
  })
})

describe("usePluginAdminPage", () => {
  afterEach(() => vi.restoreAllMocks())

  function Harness() {
    const { isPending, page } = usePluginAdminPage()
    if (isPending) return <p>pending</p>
    return <p>{page ? `matched:${page.id}` : "no match"}</p>
  }

  function renderAt(path: string, pages: Array<Partial<AdminPluginPage> & { id: string; paths: string[] }>) {
    vi.mocked(adminPluginPagesApi.fetchAdminPluginPages).mockResolvedValue({
      pages: pages.map((page) => ({ label: page.id, path: page.paths[0], order: 0, ...page }))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    return render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[path]}>
          <Harness />
        </MemoryRouter>
      </QueryClientProvider>
    )
  }

  // Regression guard: this dispatcher used to compare paths with plain
  // string equality, unlike its sibling `usePluginSidebarPage`, so a
  // declared path carrying a route parameter could never match.
  it("matches a declared path carrying a route parameter", async () => {
    renderAt("/admin/widgets/42", [{ id: "widgets.detail", paths: ["/admin/widgets/:id"] }])

    expect(await screen.findByText("matched:widgets.detail")).toBeInTheDocument()
  })

  it("matches a plainly declared path with no parameters", async () => {
    renderAt("/admin/widgets", [{ id: "widgets.index", paths: ["/admin/widgets"] }])

    expect(await screen.findByText("matched:widgets.index")).toBeInTheDocument()
  })

  it("does not match an unrelated path", async () => {
    renderAt("/admin/other", [{ id: "widgets.index", paths: ["/admin/widgets"] }])

    expect(await screen.findByText("no match")).toBeInTheDocument()
  })
})

describe("PluginAdminPageRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  function renderRoute(path: string, pages: Array<Partial<AdminPluginPage> & { id: string; paths: string[]; component: string }>) {
    vi.mocked(adminPluginPagesApi.fetchAdminPluginPages).mockResolvedValue({
      pages: pages.map((page) => ({ label: page.id, path: page.paths[0], order: 0, ...page }))
    })
    // The matched plugin page's own data query is irrelevant to the chrome
    // contract under test here, so it is left to fail fast rather than
    // stubbed with a full payload -- the header renders unconditionally
    // either way.
    vi.spyOn(window, "fetch").mockRejectedValue(new Error("not stubbed in this test"))
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    return render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[path]}>
          <PluginAdminPageRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )
  }

  it("renders the matched plugin page's own heading for a plainly declared path", async () => {
    renderRoute("/admin/mysql", [{ id: "admin_mysql.mysql", paths: ["/admin/mysql"], component: "admin_mysql/AdminMysql" }])

    expect(await screen.findByRole("heading", { level: 1, name: "MySQL" })).toBeInTheDocument()
  })

  it("renders the matched plugin page's own heading for a path carrying a route parameter", async () => {
    renderRoute("/admin/insights/42", [{ id: "agent_insights.admin", paths: ["/admin/insights/:id"], component: "agent_insights/AdminInsights" }])

    expect(await screen.findByRole("heading", { level: 1, name: "Insights" })).toBeInTheDocument()
  })
})
