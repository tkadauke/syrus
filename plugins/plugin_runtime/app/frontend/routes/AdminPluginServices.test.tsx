import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import * as useConfirmModule from "@app/hooks/useConfirm"
import type { PluginServicesPayload } from "../api/pluginServices"
import { AdminPluginServices } from "./AdminPluginServices"

function mockUseConfirm(confirmed: boolean) {
  const mockConfirm = vi.fn<ReturnType<typeof useConfirmModule.useConfirm>["confirm"]>().mockResolvedValue(confirmed)
  vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm, dialog: <></> })
  return mockConfirm
}

function payload(overrides: Partial<PluginServicesPayload> = {}): PluginServicesPayload {
  return {
    mode: "managed",
    manageable: true,
    manager_error: null,
    services: [
      {
        service: "git-mirror",
        plugin: "git_mirror",
        state: "running",
        endpoint: "http://git-mirror:8080",
        image: "ghcr.io/tkadauke/syrus-plugin-git-mirror:dev",
        container_id: "abc",
        desired: true,
        held: false,
        actions: ["stop", "restart", "logs"]
      }
    ],
    volumes: [],
    ...overrides
  }
}

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/admin/plugin_services"]}>{children}</MemoryRouter>
    </QueryClientProvider>
  )
}

function mockApi(list: PluginServicesPayload, onRequest: (path: string, method: string) => Response | undefined = () => undefined) {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    const method = init?.method ?? "GET"
    return Promise.resolve(onRequest(path, method) ?? jsonResponse(list))
  })
}

afterEach(() => vi.restoreAllMocks())

describe("AdminPluginServices", () => {
  it("lists each plugin service with its state and the actions that apply", async () => {
    mockApi(payload())

    renderRoute(<AdminPluginServices />)

    const row = (await screen.findByText("git-mirror")).closest("tr") as HTMLElement
    expect(within(row).getByText("Running")).toBeInTheDocument()
    expect(within(row).getByText("http://git-mirror:8080")).toBeInTheDocument()
    expect(within(row).getByRole("button", { name: "Stop" })).toBeInTheDocument()
    expect(within(row).getByRole("button", { name: "Restart" })).toBeInTheDocument()
    expect(within(row).queryByRole("button", { name: "Start" })).not.toBeInTheDocument()
  })

  // Page.Header lays its children out in a row; the label, title, and
  // description belong in one group so they stack.
  it("stacks the page title with its label and description", async () => {
    mockApi(payload())

    renderRoute(<AdminPluginServices />)

    const heading = await screen.findByRole("heading", { name: "Plugin Services", level: 1 })
    const group = heading.parentElement as HTMLElement
    expect(group.tagName).not.toBe("HEADER")
    expect(within(group).getByText("Admin")).toBeInTheDocument()
    expect(within(group).getByText(/Containers that plugins run/)).toBeInTheDocument()
  })

  it("asks before stopping, then stops the service", async () => {
    const confirm = mockUseConfirm(true)
    const fetchSpy = mockApi(payload(), (path, method) =>
      path.endsWith("/git-mirror/stop") && method === "POST" ? jsonResponse({ service: { service: "git-mirror", state: "stopped" } }) : undefined)

    renderRoute(<AdminPluginServices />)
    fireEvent.click(await screen.findByRole("button", { name: "Stop" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/plugin_services/git-mirror/stop", expect.objectContaining({ method: "POST" })))
    expect(confirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
  })

  it("does nothing when the stop is not confirmed", async () => {
    mockUseConfirm(false)
    const fetchSpy = mockApi(payload())

    renderRoute(<AdminPluginServices />)
    fireEvent.click(await screen.findByRole("button", { name: "Stop" }))

    await waitFor(() => expect(fetchSpy.mock.calls.some(([, init]) => init?.method === "POST")).toBe(false))
  })

  it("starts a stopped service without asking", async () => {
    const confirm = mockUseConfirm(true)
    const stopped = payload({ services: [ { ...payload().services[0], state: "stopped", held: true, actions: [ "start", "logs" ] } ] })
    const fetchSpy = mockApi(stopped, (path, method) =>
      path.endsWith("/git-mirror/start") && method === "POST" ? jsonResponse({ service: { service: "git-mirror", state: "running" } }) : undefined)

    renderRoute(<AdminPluginServices />)
    expect(await screen.findByText("Stopped by an admin")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Start" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/plugin_services/git-mirror/start", expect.objectContaining({ method: "POST" })))
    expect(confirm).not.toHaveBeenCalled()
  })

  it("shows a service's logs", async () => {
    mockApi(payload(), (path) =>
      path.startsWith("/api/v1/app/admin/plugin_services/git-mirror/logs?tail=200")
        ? jsonResponse({ service: "git-mirror", logs: "GET /v1/repositories/1/blob 200 13B 2ms\n" })
        : undefined)

    renderRoute(<AdminPluginServices />)
    fireEvent.click(await screen.findByRole("button", { name: "Logs" }))

    const output = await screen.findByLabelText("Log output for git-mirror")
    await waitFor(() => expect(output).toHaveTextContent("GET /v1/repositories/1/blob 200 13B 2ms"))
  })

  it("explains that externally managed services cannot be controlled", async () => {
    mockApi(payload({ mode: "external", manageable: false, services: [ { ...payload().services[0], actions: [] } ] }))

    renderRoute(<AdminPluginServices />)

    expect(await screen.findByText(/managed outside Syrus/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Stop" })).not.toBeInTheDocument()
  })

  it("lists stored data and deletes only what no running service uses, after asking", async () => {
    const confirm = mockUseConfirm(true)
    const fetchSpy = mockApi(payload({
      volumes: [
        { name: "syrus_plugin_git-mirror_data", service: "git-mirror", plugin: "git_mirror", in_use: true, size_bytes: 1_288_490_189 },
        { name: "syrus_plugin_old-service_data", service: "old-service", plugin: "old_plugin", in_use: false, size_bytes: 2048 }
      ]
    }), (path, method) =>
      method === "DELETE" ? new Response(null, { status: 204 }) : undefined)

    renderRoute(<AdminPluginServices />)

    const inUse = (await screen.findByText("syrus_plugin_git-mirror_data")).closest("tr") as HTMLElement
    expect(within(inUse).getByText("1.2 GB")).toBeInTheDocument()
    expect(within(inUse).queryByRole("button", { name: "Delete data" })).not.toBeInTheDocument()

    const unused = screen.getByText("syrus_plugin_old-service_data").closest("tr") as HTMLElement
    fireEvent.click(within(unused).getByRole("button", { name: "Delete data" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/plugin_services/volumes/syrus_plugin_old-service_data",
      expect.objectContaining({ method: "DELETE" })
    ))
    expect(confirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
  })

  it("shows what a service says about itself under Details", async () => {
    mockApi(payload({ services: [ { ...payload().services[0], actions: [ "stop", "restart", "details", "logs" ] } ] }), (path) =>
      path === "/api/v1/app/admin/plugin_services/git-mirror/details"
        ? jsonResponse({
          service: "git-mirror",
          details: {
            summary: [ { label_key: "git_mirror:details.repositories", value: 2, format: "number" },
              { label_key: "git_mirror:details.mirror_size", value: 5_242_880, format: "bytes" } ],
            table: {
              columns: [ { key: "repository", label_key: "git_mirror:details.col_repository", format: "text" },
                { key: "size", label_key: "git_mirror:details.col_size", format: "bytes" } ],
              rows: [ { repository: "acme/widgets", size: 4_194_304 } ]
            }
          }
        })
        : undefined)

    renderRoute(<AdminPluginServices />)
    fireEvent.click(await screen.findByRole("button", { name: "Details" }))

    const panel = await screen.findByRole("region", { name: "Details: git-mirror" })
    expect(await within(panel).findByText("Mirror size")).toBeInTheDocument()
    expect(within(panel).getByText("5.0 MB")).toBeInTheDocument()
    expect(within(panel).getByText("acme/widgets")).toBeInTheDocument()
    expect(within(panel).getByText("4.0 MB")).toBeInTheDocument()
  })
})
