import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { KubernetesClusters } from "./KubernetesClusters"

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
    if (/\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/overview$/.test(url) && method === "GET") {
      return Promise.resolve(jsonResponse({
        generated_at: "2026-01-01T00:00:00Z",
        nodes: { available: false, reason: "metrics_unavailable", message: "no metrics-server" },
        pods: { available: false, reason: "metrics_unavailable", message: "no metrics-server" }
      }))
    }

    throw new Error(`Unhandled fetch: ${method} ${url}`)
  }) as typeof window.fetch)

  return { calls, fetchSpy }
}

function renderClusters() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/k8s_clusters"]}>
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

  it("creates a cluster from the add form by pasting a kubeconfig", async () => {
    setupFetchMock([])
    renderClusters()

    await screen.findByText("No clusters yet. Add one to get started.")

    fireEvent.change(screen.getByLabelText("Label"), { target: { value: "Prod" } })
    fireEvent.change(screen.getByLabelText("Kubeconfig"), { target: { value: "current-context: default" } })
    fireEvent.click(screen.getByRole("button", { name: "Add cluster" }))

    expect(await screen.findByText("Prod")).toBeInTheDocument()
    expect(await screen.findByText('Cluster "Prod" added.')).toBeInTheDocument()
  })

  it("edits a cluster's label without requiring a new kubeconfig", async () => {
    setupFetchMock()
    renderClusters()

    fireEvent.click(await screen.findByRole("button", { name: "Edit" }))

    const editRow = (await screen.findByText("Edit cluster")).closest("tr") as HTMLElement
    fireEvent.change(within(editRow).getByLabelText("Label"), { target: { value: "Staging (renamed)" } })
    fireEvent.click(within(editRow).getByRole("button", { name: "Save" }))

    expect(await screen.findByText("Staging (renamed)")).toBeInTheDocument()
    expect(await screen.findByText('Cluster "Staging (renamed)" updated.')).toBeInTheDocument()
  })

  it("deletes a cluster after confirmation", async () => {
    setupFetchMock()
    vi.spyOn(window, "confirm").mockReturnValue(true)
    renderClusters()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

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
    fireEvent.click(screen.getByRole("button", { name: "Test" }))

    expect(await screen.findByText("Connection failed: kubeconfig is not valid YAML")).toBeInTheDocument()
  })

  it("browses into the tabbed cluster viewer from the connections list", async () => {
    setupFetchMock()
    renderClusters()

    const row = (await screen.findByText("Staging")).closest("tr") as HTMLElement
    fireEvent.click(within(row).getByRole("button", { name: "Browse" }))

    expect(await screen.findByText("Browsing Staging")).toBeInTheDocument()
  })
})
