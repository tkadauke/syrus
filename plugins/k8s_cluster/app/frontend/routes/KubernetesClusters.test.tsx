import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { KubernetesClusters } from "./KubernetesClusters"
import * as useConfirmModule from "@app/hooks/useConfirm"

function mockUseConfirm(confirmed: boolean) {
  const mockConfirm = vi.fn<ReturnType<typeof useConfirmModule.useConfirm>["confirm"]>().mockResolvedValue(confirmed)
  vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm, dialog: <></> })
  return mockConfirm
}

function encodeFilterTree(tree: Record<string, unknown>) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(tree)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function stagingCluster(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    label: "Staging",
    api_server_url: "https://staging.k8s.internal:6443",
    agentic_access_enabled: false,
    allow_writes: false,
    insecure_skip_tls_verify: false,
    credential_kind: "token",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides
  }
}

function setupFetchMock(initial = [stagingCluster()]) {
  let clusters = initial
  let nextId = Math.max(0, ...initial.map((cluster) => cluster.id)) + 1
  const calls: { body?: Record<string, unknown>; method: string; url: string }[] = []

  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const method = (init?.method || "GET").toUpperCase()
    const body = init?.body ? JSON.parse(String(init.body)) : undefined
    calls.push({ body, method, url })

    if (url === "/api/v1/app/admin/kubernetes_clusters" && method === "GET") {
      return Promise.resolve(jsonResponse({ kubernetes_clusters: clusters }))
    }
    if (url === "/api/v1/app/admin/kubernetes_clusters" && method === "POST") {
      const created = { ...stagingCluster(), ...body?.kubernetes_cluster, id: nextId }
      nextId += 1
      clusters = [...clusters, created]
      return Promise.resolve(jsonResponse({ kubernetes_cluster: created }, 201))
    }
    if (url === "/api/v1/app/admin/kubernetes_clusters/test" && method === "POST") {
      return Promise.resolve(jsonResponse({ success: false, error: "kubeconfig is not valid YAML" }))
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/test$/.test(url) && method === "POST") {
      return Promise.resolve(jsonResponse({ success: true }))
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+$/.test(url) && method === "PATCH") {
      const id = Number(url.split("/").pop())
      clusters = clusters.map((cluster) => (cluster.id === id ? { ...cluster, ...body?.kubernetes_cluster } : cluster))
      return Promise.resolve(jsonResponse({ kubernetes_cluster: clusters.find((cluster) => cluster.id === id) }))
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+$/.test(url) && method === "DELETE") {
      const id = Number(url.split("/").pop())
      clusters = clusters.filter((cluster) => cluster.id !== id)
      return Promise.resolve(new Response(null, { status: 204 }))
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/nodes$/.test(url) && method === "GET") {
      return Promise.resolve(jsonResponse({ available: true, generated_at: "2026-01-01T00:00:00Z", truncated: false, nodes: [] }))
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/namespaces$/.test(url) && method === "GET") {
      return Promise.resolve(
        jsonResponse({
          available: true,
          generated_at: "2026-01-01T00:00:00Z",
          truncated: false,
          namespaces: [{ name: "default", status: "Active", created_at: "2026-01-01T00:00:00Z" }]
        })
      )
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/pods$/.test(url) && method === "GET") {
      return Promise.resolve(
        jsonResponse({
          available: true,
          generated_at: "2026-01-01T00:00:00Z",
          truncated: false,
          pods: [
            {
              name: "web-1",
              namespace: "default",
              status: "Running",
              pod_ip: "10.0.0.5",
              node_name: "node-1",
              ready: "1/1",
              restart_count: 0,
              container_names: ["app"],
              created_at: "2026-01-01T00:00:00Z"
            }
          ]
        })
      )
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/cronjobs$/.test(url) && method === "GET") {
      return Promise.resolve(
        jsonResponse({
          available: true,
          generated_at: "2026-01-01T00:00:00Z",
          truncated: false,
          cron_jobs: [
            {
              name: "nightly-backup",
              namespace: "default",
              schedule: "0 2 * * *",
              suspended: false,
              active_count: 0,
              last_schedule_time: null,
              created_at: "2026-01-01T00:00:00Z"
            }
          ]
        })
      )
    }
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/overview$/.test(url) && method === "GET") {
      return Promise.resolve(
        jsonResponse({
          generated_at: "2026-01-01T00:00:00Z",
          nodes: { available: false, reason: "metrics_unavailable", message: "no metrics-server" },
          pods: { available: false, reason: "metrics_unavailable", message: "no metrics-server" }
        })
      )
    }

    throw new Error(`Unhandled fetch: ${method} ${url}`)
  }) as typeof window.fetch)

  return { calls, fetchSpy }
}

function renderClusters(initialEntry = "/k8s_clusters") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[initialEntry]}>
          <KubernetesClusters />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("KubernetesClusters", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("lists clusters without ever rendering credentials", async () => {
    setupFetchMock()
    renderClusters()

    expect(screen.getByRole("main", { name: "Kubernetes Cluster Viewer" })).toBeInTheDocument()
    expect(await screen.findByText("Staging")).toBeInTheDocument()
    expect(screen.getByText("https://staging.k8s.internal:6443")).toBeInTheDocument()
    expect(screen.getByText("Bearer token")).toBeInTheDocument()
    expect(document.body.textContent).not.toContain("s3cret-token")
  })

  it("shows the empty state when there are no clusters", async () => {
    setupFetchMock([])
    renderClusters()

    expect(await screen.findByText("No clusters yet. Add one to get started.")).toBeInTheDocument()
  })

  it("renders clusters with shared sortable and configurable table controls", async () => {
    setupFetchMock([
      stagingCluster({ id: 1, label: "Staging", api_server_url: "https://staging.k8s.internal:6443" }),
      stagingCluster({ id: 2, label: "Production", api_server_url: "https://prod.k8s.internal:6443" })
    ])
    renderClusters()

    await screen.findByText("Production")
    const tablePanel = screen.getByRole("table").closest("section") as HTMLElement
    expect(within(tablePanel).getByRole("button", { name: "Columns" })).toBeInTheDocument()

    let rows = within(tablePanel).getAllByRole("row")
    expect(rows[1]).toHaveTextContent("Production")
    expect(rows[2]).toHaveTextContent("Staging")

    fireEvent.click(within(tablePanel).getByRole("button", { name: "Label" }))

    await waitFor(() => {
      rows = within(tablePanel).getAllByRole("row")
      expect(rows[1]).toHaveTextContent("Staging")
      expect(rows[2]).toHaveTextContent("Production")
    })

    fireEvent.click(within(tablePanel).getByRole("button", { name: "Columns" }))
    expect(within(tablePanel).getByLabelText("API server")).toBeChecked()
    expect(within(tablePanel).getByLabelText("Created")).not.toBeChecked()
    expect(within(tablePanel).getByLabelText("Updated")).not.toBeChecked()
    expect(within(tablePanel).getByRole("button", { name: "Move API server down" })).toBeInTheDocument()
  })

  it("filters clusters through the shared FilterBar query", async () => {
    setupFetchMock([
      stagingCluster({ id: 1, label: "Staging", api_server_url: "https://staging.k8s.internal:6443" }),
      stagingCluster({ id: 2, label: "Production", api_server_url: "https://prod.k8s.internal:6443" })
    ])
    renderClusters("/k8s_clusters?query=prod")

    const table = await screen.findByRole("table")
    expect(within(table).getByText("Production")).toBeInTheDocument()
    expect(within(table).queryByText("Staging")).not.toBeInTheDocument()
    expect(screen.getByText("1 of 2 resources")).toBeInTheDocument()
  })

  it("filters clusters through structured FilterBar fields", async () => {
    const q = encodeFilterTree({
      and: [
        { field: "credential_kind", op: "is", value: "client_cert" },
        { field: "allow_writes", op: "is", value: "true" },
        { field: "created_at", op: "after", value: "2026-01-15" }
      ]
    })
    setupFetchMock([
      stagingCluster({ id: 1, label: "Staging", credential_kind: "token", allow_writes: false, created_at: "2026-01-01T00:00:00Z" }),
      stagingCluster({ id: 2, label: "Production", credential_kind: "client_cert", allow_writes: true, created_at: "2026-02-01T00:00:00Z" })
    ])
    renderClusters(`/k8s_clusters?q=${q}`)

    const table = await screen.findByRole("table")
    expect(within(table).getByText("Production")).toBeInTheDocument()
    expect(within(table).queryByText("Staging")).not.toBeInTheDocument()
    expect(screen.getByText("1 of 2 resources")).toBeInTheDocument()
  })

  it("creates a cluster from the add form by pasting a kubeconfig", async () => {
    setupFetchMock([])
    renderClusters()

    await screen.findByText("No clusters yet. Add one to get started.")

    fireEvent.click(screen.getByRole("button", { name: "Add cluster" }))

    const dialog = await screen.findByRole("dialog", { name: "Add cluster" })
    fireEvent.change(within(dialog).getByLabelText("Label"), { target: { value: "Prod" } })
    fireEvent.change(within(dialog).getByLabelText("Kubeconfig"), { target: { value: "current-context: default" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Add cluster" }))

    expect(await screen.findByText("Prod")).toBeInTheDocument()
    expect(await screen.findByText('Cluster "Prod" added.')).toBeInTheDocument()
  })

  it("edits a cluster's label in a modal without requiring a new kubeconfig", async () => {
    setupFetchMock()
    renderClusters()

    fireEvent.click(await screen.findByRole("button", { name: "Edit" }))

    const dialog = await screen.findByRole("dialog", { name: "Edit cluster" })
    fireEvent.change(within(dialog).getByLabelText("Label"), { target: { value: "Staging (renamed)" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Save" }))

    expect(await screen.findByText("Staging (renamed)")).toBeInTheDocument()
    expect(await screen.findByText('Cluster "Staging (renamed)" updated.')).toBeInTheDocument()
  })

  it("deletes a cluster after confirmation", async () => {
    setupFetchMock()
    const mockConfirm = mockUseConfirm(true)
    renderClusters()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true })))
    await waitFor(() => expect(screen.queryByText("Staging")).not.toBeInTheDocument())
    expect(await screen.findByText("No clusters yet. Add one to get started.")).toBeInTheDocument()
  })

  it("tests an existing cluster and reports success", async () => {
    setupFetchMock()
    renderClusters()

    const row = (await screen.findByText("Staging")).closest("tr") as HTMLElement
    fireEvent.click(within(row).getByRole("button", { name: "Test" }))

    expect(await within(row).findByText("Connection succeeded.")).toBeInTheDocument()
  })

  it("reports a failed draft test with the server's error message", async () => {
    setupFetchMock([])
    renderClusters()

    await screen.findByText("No clusters yet. Add one to get started.")
    fireEvent.click(screen.getByRole("button", { name: "Add cluster" }))
    const dialog = await screen.findByRole("dialog", { name: "Add cluster" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Test" }))

    expect(await within(dialog).findByText("Connection failed: kubeconfig is not valid YAML")).toBeInTheDocument()
  })

  it("browses into the tabbed cluster viewer from the connections list", async () => {
    setupFetchMock()
    renderClusters()

    const row = (await screen.findByText("Staging")).closest("tr") as HTMLElement
    fireEvent.click(within(row).getByRole("button", { name: "Browse" }))

    expect(await screen.findByText("Browsing Staging")).toBeInTheDocument()
  })

  it("does not apply a cluster-list filter to resource tables after browsing", async () => {
    setupFetchMock([
      stagingCluster({ id: 1, label: "Production", api_server_url: "https://prod.k8s.internal:6443" }),
      stagingCluster({ id: 2, label: "Staging", api_server_url: "https://staging.k8s.internal:6443" })
    ])
    renderClusters("/k8s_clusters?query=prod")

    const row = (await screen.findByText("Production")).closest("tr") as HTMLElement
    expect(screen.queryByText("Staging")).not.toBeInTheDocument()
    fireEvent.click(within(row).getByRole("button", { name: "Browse" }))

    expect(await screen.findByText("Browsing Production")).toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: "Cluster view" }))
    fireEvent.click(await screen.findByRole("option", { name: "Workloads" }))

    expect(await screen.findByText("web-1")).toBeInTheDocument()
    expect(screen.getByText("1 resource")).toBeInTheDocument()
  })

  it("shows a human-readable CronJob schedule explanation on hover", async () => {
    setupFetchMock()
    renderClusters()

    const row = (await screen.findByText("Staging")).closest("tr") as HTMLElement
    fireEvent.click(within(row).getByRole("button", { name: "Browse" }))
    fireEvent.click(await screen.findByRole("button", { name: "Cluster view" }))
    fireEvent.click(await screen.findByRole("option", { name: "Workloads" }))
    fireEvent.click(await screen.findByRole("button", { name: "Workload kind" }))
    fireEvent.click(await screen.findByRole("option", { name: "CronJobs" }))

    expect(await screen.findByText("nightly-backup")).toBeInTheDocument()
    expect(screen.getByText("0 2 * * *")).toHaveAttribute("title", "Every day at 02:00")
  })

  it("lets the page scroll instead of clipping the list/edit form vertically", async () => {
    setupFetchMock()
    renderClusters()

    const main = await screen.findByRole("main", { name: "Kubernetes Cluster Viewer" })

    expect(main.className).not.toContain("overflow-hidden")
    expect(main.className).not.toContain("h-full")
  })
})
