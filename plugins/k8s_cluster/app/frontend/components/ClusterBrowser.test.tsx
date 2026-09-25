import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { afterEach, describe, expect, it, vi } from "vitest"
import { Page } from "@app/components/ui"
import i18n from "@app/i18n"
import { ClusterBrowser } from "./ClusterBrowser"

const GENERATED_AT = "2026-01-01T00:00:00Z"

const DEFAULT_NAMESPACES = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  namespaces: [
    { name: "default", status: "Active", created_at: GENERATED_AT },
    { name: "kube-system", status: "Active", created_at: GENERATED_AT }
  ]
}

const DEFAULT_NODES = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  nodes: [
    {
      name: "node-1",
      ready: true,
      roles: ["control-plane"],
      kubelet_version: "v1.30.0",
      internal_ip: "10.0.0.1",
      capacity_cpu: "4",
      capacity_memory: "16373052Ki",
      allocatable_cpu: "3800m",
      allocatable_memory: "16373048Ki",
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_OVERVIEW = {
  generated_at: GENERATED_AT,
  nodes: {
    available: true,
    items: [{ name: "node-1", cpu_millicores: 500, memory_bytes: 1073741824 }],
    total_cpu_millicores: 500,
    total_memory_bytes: 1073741824
  },
  pods: { available: false, reason: "metrics_unavailable", message: "metrics-server is not installed" }
}

const DEFAULT_PODS = {
  available: true,
  generated_at: GENERATED_AT,
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
      created_at: GENERATED_AT
    }
  ]
}

const MULTI_CONTAINER_POD = {
  name: "web-2",
  namespace: "default",
  status: "Running",
  pod_ip: "10.0.0.6",
  node_name: "node-1",
  ready: "2/2",
  restart_count: 1,
  container_names: ["app", "sidecar"],
  created_at: GENERATED_AT
}

const DEFAULT_DEPLOYMENTS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  deployments: [{ name: "web", namespace: "default", replicas: 3, ready_replicas: 3, available_replicas: 3, updated_replicas: 3, created_at: GENERATED_AT }]
}

const DEFAULT_CRONJOBS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  cron_jobs: [
    { name: "nightly", namespace: "default", schedule: "0 0 * * *", suspended: false, active_count: 0, last_schedule_time: null, created_at: GENERATED_AT }
  ]
}

const DEFAULT_STATEFULSETS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  stateful_sets: [{ name: "db", namespace: "default", replicas: 3, ready_replicas: 3, current_replicas: 3, updated_replicas: 3, created_at: GENERATED_AT }]
}

const DEFAULT_DAEMONSETS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  daemon_sets: [
    {
      name: "monitoring",
      namespace: "default",
      desired_number_scheduled: 3,
      current_number_scheduled: 3,
      number_ready: 3,
      number_available: 3,
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_JOBS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  jobs: [{ name: "migrate", namespace: "default", completions: 1, parallelism: 1, active_count: 0, succeeded: 1, failed: 0, created_at: GENERATED_AT }]
}

const DEFAULT_SERVICES = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  services: [
    {
      name: "web",
      namespace: "default",
      type: "ClusterIP",
      cluster_ip: "10.0.0.10",
      external_ips: [],
      ports: [{ name: "http", port: 80, target_port: 8080, protocol: "TCP" }],
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_INGRESSES = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  ingresses: [
    {
      name: "web",
      namespace: "default",
      ingress_class: "nginx",
      hosts: ["web.example.com"],
      rules: [{ host: "web.example.com", paths: [{ path: "/", path_type: "Prefix", service_name: "web", service_port: 80 }] }],
      tls_hosts: ["web.example.com"],
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_ENDPOINTS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  endpoints: [
    {
      name: "web",
      namespace: "default",
      ready_addresses: 2,
      not_ready_addresses: 0,
      ports: [{ name: "http", port: 8080, protocol: "TCP" }],
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_CONFIGMAPS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  config_maps: [
    {
      name: "app-settings",
      namespace: "default",
      key_count: 2,
      key_names: ["feature_flags", "log_level"],
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_SECRETS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  secrets: [
    {
      name: "db-credentials",
      namespace: "default",
      type: "Opaque",
      key_count: 2,
      key_names: ["password", "username"],
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_PVCS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  persistent_volume_claims: [
    {
      name: "data",
      namespace: "default",
      status: "Bound",
      capacity: "10Gi",
      storage_class: "standard",
      access_modes: ["ReadWriteOnce"],
      volume_name: "pvc-1",
      created_at: GENERATED_AT
    }
  ]
}

const DEFAULT_EVENTS = {
  available: true,
  generated_at: GENERATED_AT,
  truncated: false,
  events: [
    {
      name: "web-1.abc",
      namespace: "default",
      type: "Normal",
      reason: "Scheduled",
      message: "Successfully assigned default/web-1 to node-1",
      involved_object: { kind: "Pod", name: "web-1" },
      count: 1,
      first_timestamp: GENERATED_AT,
      last_timestamp: GENERATED_AT
    }
  ]
}

const DEFAULT_POD_LOGS = {
  available: true,
  generated_at: GENERATED_AT,
  pod: "web-1",
  namespace: "default",
  container: "app",
  log: "line one\nline two\n"
}

type ResourceKey =
  | "namespaces"
  | "nodes"
  | "overview"
  | "pods"
  | "deployments"
  | "statefulsets"
  | "daemonsets"
  | "jobs"
  | "cronjobs"
  | "services"
  | "ingresses"
  | "endpoints"
  | "configmaps"
  | "secrets"
  | "pvcs"
  | "events"
  | "podLogs"

const DESCRIBE_ENVELOPES: Record<string, { key: ResourceKey; envelope: string; kind: string }> = {
  "/namespaces": { key: "namespaces", envelope: "namespace", kind: "Namespace" },
  "/nodes": { key: "nodes", envelope: "node", kind: "Node" },
  "/pods": { key: "pods", envelope: "pod", kind: "Pod" },
  "/deployments": { key: "deployments", envelope: "deployment", kind: "Deployment" },
  "/statefulsets": { key: "statefulsets", envelope: "stateful_set", kind: "StatefulSet" },
  "/daemonsets": { key: "daemonsets", envelope: "daemon_set", kind: "DaemonSet" },
  "/jobs": { key: "jobs", envelope: "job", kind: "Job" },
  "/cronjobs": { key: "cronjobs", envelope: "cron_job", kind: "CronJob" },
  "/services": { key: "services", envelope: "service", kind: "Service" },
  "/ingresses": { key: "ingresses", envelope: "ingress", kind: "Ingress" },
  "/configmaps": { key: "configmaps", envelope: "config_map", kind: "ConfigMap" },
  "/secrets": { key: "secrets", envelope: "secret", kind: "Secret" },
  "/pvcs": { key: "pvcs", envelope: "persistent_volume_claim", kind: "PersistentVolumeClaim" }
}

function setupFetchMock(
  overrides: Partial<Record<ResourceKey, unknown>> = {},
  errors: Partial<Record<ResourceKey, number>> = {},
  describeErrors: Partial<Record<ResourceKey, number>> = {}
) {
  const calls: string[] = []

  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(((input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)
    const path = url.split("?")[0]
    const query = new URLSearchParams(url.split("?")[1] ?? "")

    const respond = (key: ResourceKey, fallback: unknown) => {
      const status = errors[key]
      if (status) return Promise.resolve(jsonResponse({ error: { message: `boom-${key}` } }, status))
      return Promise.resolve(jsonResponse(overrides[key] ?? fallback))
    }

    // A `name` query param switches the shared route from list to describe.
    const describeName = query.get("name")
    const describe = Object.entries(DESCRIBE_ENVELOPES).find(([suffix]) => path.endsWith(suffix))
    if (describeName && describe) {
      const { key, envelope, kind } = describe[1]
      const status = describeErrors[key]
      if (status) return Promise.resolve(jsonResponse({ error: { message: `boom-${key}-describe` } }, status))
      return Promise.resolve(
        jsonResponse({
          available: true,
          generated_at: GENERATED_AT,
          [envelope]: { apiVersion: "v1", kind, metadata: { name: describeName, namespace: query.get("namespace") } }
        })
      )
    }

    if (/\/namespaces$/.test(path)) return respond("namespaces", DEFAULT_NAMESPACES)
    if (/\/nodes$/.test(path)) return respond("nodes", DEFAULT_NODES)
    if (/\/overview$/.test(path)) return respond("overview", DEFAULT_OVERVIEW)
    if (/\/pods\/[^/]+\/logs$/.test(path)) return respond("podLogs", DEFAULT_POD_LOGS)
    if (/\/pods$/.test(path)) return respond("pods", DEFAULT_PODS)
    if (/\/deployments$/.test(path)) return respond("deployments", DEFAULT_DEPLOYMENTS)
    if (/\/statefulsets$/.test(path)) return respond("statefulsets", DEFAULT_STATEFULSETS)
    if (/\/daemonsets$/.test(path)) return respond("daemonsets", DEFAULT_DAEMONSETS)
    if (/\/jobs$/.test(path)) return respond("jobs", DEFAULT_JOBS)
    if (/\/cronjobs$/.test(path)) return respond("cronjobs", DEFAULT_CRONJOBS)
    if (/\/services$/.test(path)) return respond("services", DEFAULT_SERVICES)
    if (/\/ingresses$/.test(path)) return respond("ingresses", DEFAULT_INGRESSES)
    if (/\/endpoints$/.test(path)) return respond("endpoints", DEFAULT_ENDPOINTS)
    if (/\/configmaps$/.test(path)) return respond("configmaps", DEFAULT_CONFIGMAPS)
    if (/\/secrets$/.test(path)) return respond("secrets", DEFAULT_SECRETS)
    if (/\/pvcs$/.test(path)) return respond("pvcs", DEFAULT_PVCS)
    if (/\/events$/.test(path)) return respond("events", DEFAULT_EVENTS)

    throw new Error(`Unhandled fetch: ${url}`)
  }) as typeof window.fetch)

  return { calls, fetchSpy }
}

function renderBrowser() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <ClusterBrowser clusterId={1} label="Staging" onBack={vi.fn()} />
      </QueryClientProvider>
    </I18nextProvider>
  )
}

function renderBrowserInResponsiveShell() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <Page.Root aria-label="Kubernetes clusters" className="flex h-full flex-col overflow-hidden" gutter="responsive" size="wide">
          <ClusterBrowser clusterId={1} label="Staging" onBack={vi.fn()} />
        </Page.Root>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

async function switchTab(name: string) {
  fireEvent.click(screen.getByRole("button", { name: "Cluster view" }))
  fireEvent.click(await screen.findByRole("option", { name }))
}

describe("ClusterBrowser", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("shows the heading and starts on the Overview tab", async () => {
    setupFetchMock()
    renderBrowser()

    expect(screen.getByText("Browsing Staging")).toBeInTheDocument()
    expect(await screen.findByText("1")).toBeInTheDocument()
    expect(screen.getByText("1/1 ready")).toBeInTheDocument()
  })

  it("uses a toolbar dropdown (button+listbox), not a native select, to switch tabs", async () => {
    setupFetchMock()
    renderBrowser()
    await screen.findByText("Browsing Staging")

    const button = screen.getByRole("button", { name: "Cluster view" })
    expect(button).toHaveAttribute("aria-haspopup", "listbox")
    fireEvent.click(button)
    expect(await screen.findByRole("listbox")).toBeInTheDocument()
    expect(document.querySelector("select")).not.toBeInTheDocument()
  })

  describe("responsive gutter", () => {
    it("restores margin on the header and tab nav while the surrounding Page.Root stays flush", async () => {
      setupFetchMock()
      renderBrowserInResponsiveShell()

      const heading = await screen.findByRole("heading", { name: "Browsing Staging" })
      const header = heading.closest("header")
      expect(header?.className).toContain("px-4 sm:px-0")

      const dropdownButton = screen.getByRole("button", { name: "Cluster view" })
      const nav = dropdownButton.closest("div.flex.shrink-0.flex-wrap.items-center.gap-2")
      expect(nav?.className).toContain("px-4 sm:px-0")

      const overviewPane = (await screen.findByText("1")).closest("div.min-h-0.flex-1.overflow-y-auto")
      expect(overviewPane?.className ?? "").not.toContain("px-4 sm:px-0")
    })
  })

  describe("Overview tab", () => {
    it("shows a graceful empty state when metrics are unavailable, including the backend's diagnostic message", async () => {
      setupFetchMock()
      renderBrowser()

      expect(await screen.findByText("Metrics unavailable. Install metrics-server on this cluster to see CPU/memory usage.")).toBeInTheDocument()
      expect(screen.getByText("metrics-server is not installed")).toBeInTheDocument()
    })

    it("shows aggregate CPU/memory when metrics are available", async () => {
      setupFetchMock({
        overview: {
          generated_at: GENERATED_AT,
          nodes: { available: true, items: [], total_cpu_millicores: 2500, total_memory_bytes: 2147483648 },
          pods: { available: true, items: [], total_cpu_millicores: 800, total_memory_bytes: 536870912 }
        }
      })
      renderBrowser()

      expect(await screen.findByText("2.50 vCPU")).toBeInTheDocument()
      expect(screen.getByText("2.0 GB")).toBeInTheDocument()
      expect(screen.getByText("800m")).toBeInTheDocument()
    })

    it("reports an empty cluster with no nodes", async () => {
      setupFetchMock({ nodes: { available: true, generated_at: GENERATED_AT, truncated: false, nodes: [] } })
      renderBrowser()

      expect(await screen.findByText("This cluster has no nodes.")).toBeInTheDocument()
    })

    it("shows an error when nodes fail to load", async () => {
      setupFetchMock({}, { nodes: 502 })
      renderBrowser()

      expect(await screen.findByText("boom-nodes")).toBeInTheDocument()
    })
  })

  describe("Workloads tab", () => {
    it("lists pods by default", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")

      expect(await screen.findByText("web-1")).toBeInTheDocument()
      expect(screen.getByText("Running")).toBeInTheDocument()
      expect(screen.getByText("1/1")).toBeInTheDocument()
    })

    it("switches to deployments and cronjobs via the workload kind dropdown", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")
      await screen.findByText("web-1")

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Deployments" }))
      expect(await screen.findByText("web")).toBeInTheDocument()
      expect(screen.getByText("3/3")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "CronJobs" }))
      expect(await screen.findByText("nightly")).toBeInTheDocument()
      expect(screen.getByText("0 0 * * *")).toBeInTheDocument()
    })

    it("switches to statefulsets, daemonsets, and jobs via the workload kind dropdown", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")
      await screen.findByText("web-1")

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "StatefulSets" }))
      expect(await screen.findByText("db")).toBeInTheDocument()
      expect(screen.getByText("3/3")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "DaemonSets" }))
      expect(await screen.findByText("monitoring")).toBeInTheDocument()
      expect(screen.getByText("3/3")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Jobs" }))
      expect(await screen.findByText("migrate")).toBeInTheDocument()
    })

    it("shows the empty state when there are no statefulsets", async () => {
      setupFetchMock({ statefulsets: { available: true, generated_at: GENERATED_AT, truncated: false, stateful_sets: [] } })
      renderBrowser()
      await switchTab("Workloads")

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "StatefulSets" }))

      expect(await screen.findByText("No StatefulSets found.")).toBeInTheDocument()
    })

    it("shows an error when jobs fail to load", async () => {
      setupFetchMock({}, { jobs: 502 })
      renderBrowser()
      await switchTab("Workloads")

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Jobs" }))

      expect(await screen.findByText("boom-jobs")).toBeInTheDocument()
    })

    it("re-fetches statefulsets scoped to the selected namespace", async () => {
      const { calls } = setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")

      fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "StatefulSets" }))
      await screen.findByText("db")

      fireEvent.click(screen.getByRole("button", { name: "Namespace" }))
      fireEvent.click(await screen.findByRole("option", { name: "default" }))

      await screen.findByText("db")
      expect(calls.some((url) => url.includes("/statefulsets?namespace=default"))).toBe(true)
    })

    it("shows the empty state when there are no pods", async () => {
      setupFetchMock({ pods: { available: true, generated_at: GENERATED_AT, truncated: false, pods: [] } })
      renderBrowser()
      await switchTab("Workloads")

      expect(await screen.findByText("No pods found.")).toBeInTheDocument()
    })

    it("shows an error when pods fail to load", async () => {
      setupFetchMock({}, { pods: 502 })
      renderBrowser()
      await switchTab("Workloads")

      expect(await screen.findByText("boom-pods")).toBeInTheDocument()
    })

    it("re-fetches pods scoped to the selected namespace", async () => {
      const { calls } = setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")
      await screen.findByText("web-1")

      fireEvent.click(screen.getByRole("button", { name: "Namespace" }))
      fireEvent.click(await screen.findByRole("option", { name: "default" }))

      await screen.findByText("web-1")
      expect(calls.some((url) => url.includes("/pods?namespace=default"))).toBe(true)
    })
  })

  describe("Services tab", () => {
    it("lists services with their ports and paired Endpoints readiness", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Services")

      expect(await screen.findByText("web")).toBeInTheDocument()
      expect(screen.getByText("ClusterIP")).toBeInTheDocument()
      expect(screen.getByText("80/TCP")).toBeInTheDocument()
      expect(screen.getByText("2/2 ready")).toBeInTheDocument()
    })

    it("shows a not-ready tone when some backing addresses are not ready", async () => {
      setupFetchMock({
        endpoints: {
          available: true,
          generated_at: GENERATED_AT,
          truncated: false,
          endpoints: [{ name: "web", namespace: "default", ready_addresses: 1, not_ready_addresses: 1, ports: [], created_at: GENERATED_AT }]
        }
      })
      renderBrowser()
      await switchTab("Services")

      expect(await screen.findByText("1/2 ready")).toBeInTheDocument()
    })

    it("shows a dash when a Service has no matching Endpoints object", async () => {
      setupFetchMock({ endpoints: { available: true, generated_at: GENERATED_AT, truncated: false, endpoints: [] } })
      renderBrowser()
      await switchTab("Services")

      await screen.findByText("web")
      expect(screen.queryByText(/ready$/)).not.toBeInTheDocument()
    })

    it("still shows services when the Endpoints fetch fails", async () => {
      setupFetchMock({}, { endpoints: 502 })
      renderBrowser()
      await switchTab("Services")

      expect(await screen.findByText("web")).toBeInTheDocument()
      expect(screen.queryByText("boom-endpoints")).not.toBeInTheDocument()
    })

    it("shows the empty state when there are no services", async () => {
      setupFetchMock({ services: { available: true, generated_at: GENERATED_AT, truncated: false, services: [] } })
      renderBrowser()
      await switchTab("Services")

      expect(await screen.findByText("No services found.")).toBeInTheDocument()
    })

    it("shows an error when services fail to load", async () => {
      setupFetchMock({}, { services: 502 })
      renderBrowser()
      await switchTab("Services")

      expect(await screen.findByText("boom-services")).toBeInTheDocument()
    })

    it("switches to ingresses via the network kind dropdown, tracing hosts to backing services", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Services")
      await screen.findByText("web")

      fireEvent.click(screen.getByRole("button", { name: "Network kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Ingresses" }))

      expect(await screen.findByText("web.example.com")).toBeInTheDocument()
      expect(screen.getByText("web:80")).toBeInTheDocument()
      expect(screen.getByText("nginx")).toBeInTheDocument()
    })

    it("shows the empty state when there are no ingresses", async () => {
      setupFetchMock({ ingresses: { available: true, generated_at: GENERATED_AT, truncated: false, ingresses: [] } })
      renderBrowser()
      await switchTab("Services")

      fireEvent.click(screen.getByRole("button", { name: "Network kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Ingresses" }))

      expect(await screen.findByText("No ingresses found.")).toBeInTheDocument()
    })

    it("shows an error when ingresses fail to load", async () => {
      setupFetchMock({}, { ingresses: 502 })
      renderBrowser()
      await switchTab("Services")

      fireEvent.click(screen.getByRole("button", { name: "Network kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Ingresses" }))

      expect(await screen.findByText("boom-ingresses")).toBeInTheDocument()
    })

    it("re-fetches ingresses scoped to the selected namespace", async () => {
      const { calls } = setupFetchMock()
      renderBrowser()
      await switchTab("Services")

      fireEvent.click(screen.getByRole("button", { name: "Network kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Ingresses" }))
      await screen.findByText("web.example.com")

      fireEvent.click(screen.getByRole("button", { name: "Namespace" }))
      fireEvent.click(await screen.findByRole("option", { name: "default" }))

      await screen.findByText("web.example.com")
      expect(calls.some((url) => url.includes("/ingresses?namespace=default"))).toBe(true)
    })
  })

  describe("Config tab", () => {
    it("lists configmaps and secrets with key counts and the redaction note", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Config")

      expect(await screen.findByText("app-settings")).toBeInTheDocument()
      expect(screen.getByText("db-credentials")).toBeInTheDocument()
      expect(screen.getByText("Opaque")).toBeInTheDocument()
      expect(screen.getByText("Secret values are never displayed — names and metadata only.")).toBeInTheDocument()
      expect(screen.getAllByRole("button", { name: "Show 2 keys" })).toHaveLength(2)
    })

    it("expands a row to show its key names", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Config")
      await screen.findByText("app-settings")

      fireEvent.click(screen.getAllByRole("button", { name: "Show 2 keys" })[0])

      expect(await screen.findByText("feature_flags, log_level")).toBeInTheDocument()
    })

    it("shows the empty state when there are no configmaps", async () => {
      setupFetchMock({ configmaps: { available: true, generated_at: GENERATED_AT, truncated: false, config_maps: [] } })
      renderBrowser()
      await switchTab("Config")

      expect(await screen.findByText("No ConfigMaps found.")).toBeInTheDocument()
    })

    it("shows the empty state when there are no secrets", async () => {
      setupFetchMock({ secrets: { available: true, generated_at: GENERATED_AT, truncated: false, secrets: [] } })
      renderBrowser()
      await switchTab("Config")

      expect(await screen.findByText("No Secrets found.")).toBeInTheDocument()
    })

    it("shows an error when secrets fail to load", async () => {
      setupFetchMock({}, { secrets: 502 })
      renderBrowser()
      await switchTab("Config")

      expect(await screen.findByText("boom-secrets")).toBeInTheDocument()
    })

    it("re-fetches configmaps scoped to the selected namespace", async () => {
      const { calls } = setupFetchMock()
      renderBrowser()
      await switchTab("Config")
      await screen.findByText("app-settings")

      fireEvent.click(screen.getByRole("button", { name: "Namespace" }))
      fireEvent.click(await screen.findByRole("option", { name: "default" }))

      await screen.findByText("app-settings")
      expect(calls.some((url) => url.includes("/configmaps?namespace=default"))).toBe(true)
      expect(calls.some((url) => url.includes("/secrets?namespace=default"))).toBe(true)
    })
  })

  describe("Storage tab", () => {
    it("lists persistent volume claims", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Storage")

      expect(await screen.findByText("data")).toBeInTheDocument()
      expect(screen.getByText("Bound")).toBeInTheDocument()
      expect(screen.getByText("10Gi")).toBeInTheDocument()
    })

    it("shows the empty state when there are no claims", async () => {
      setupFetchMock({ pvcs: { available: true, generated_at: GENERATED_AT, truncated: false, persistent_volume_claims: [] } })
      renderBrowser()
      await switchTab("Storage")

      expect(await screen.findByText("No persistent volume claims found.")).toBeInTheDocument()
    })

    it("shows an error when claims fail to load", async () => {
      setupFetchMock({}, { pvcs: 502 })
      renderBrowser()
      await switchTab("Storage")

      expect(await screen.findByText("boom-pvcs")).toBeInTheDocument()
    })
  })

  describe("Nodes tab", () => {
    it("lists nodes with capacity, allocatable, and readiness", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Nodes")

      expect(await screen.findByText("node-1")).toBeInTheDocument()
      expect(screen.getByText("Ready")).toBeInTheDocument()
      expect(screen.getByText("4 vCPU / 15.6 GB")).toBeInTheDocument()
      expect(screen.getByText("3.8 vCPU / 15.6 GB")).toBeInTheDocument()
    })

    it("shows the empty state when the cluster has no nodes", async () => {
      setupFetchMock({ nodes: { available: true, generated_at: GENERATED_AT, truncated: false, nodes: [] } })
      renderBrowser()
      await switchTab("Nodes")

      expect(await screen.findByText("This cluster has no nodes.")).toBeInTheDocument()
    })

    it("shows an error when nodes fail to load", async () => {
      setupFetchMock({}, { nodes: 502 })
      renderBrowser()
      await switchTab("Nodes")

      expect(await screen.findByText("boom-nodes")).toBeInTheDocument()
    })
  })

  describe("Events tab", () => {
    it("lists events most-recent-first as returned by the API", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Events")

      expect(await screen.findByText("Scheduled", { exact: false })).toBeInTheDocument()
      expect(screen.getByText("Successfully assigned default/web-1 to node-1")).toBeInTheDocument()
    })

    it("shows the empty state when there are no events", async () => {
      setupFetchMock({ events: { available: true, generated_at: GENERATED_AT, truncated: false, events: [] } })
      renderBrowser()
      await switchTab("Events")

      expect(await screen.findByText("No events found.")).toBeInTheDocument()
    })

    it("shows an error when events fail to load", async () => {
      setupFetchMock({}, { events: 502 })
      renderBrowser()
      await switchTab("Events")

      expect(await screen.findByText("boom-events")).toBeInTheDocument()
    })
  })

  describe("Logs tab", () => {
    it("prompts for a pod before showing any log output", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Logs")

      expect(await screen.findByText("Select a pod to view its log tail.")).toBeInTheDocument()
    })

    it("shows the log tail for a selected single-container pod without a container picker", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Logs")
      await screen.findByText("Select a pod to view its log tail.")

      fireEvent.click(screen.getByRole("button", { name: "Pod" }))
      fireEvent.click(await screen.findByRole("option", { name: "default/web-1" }))

      expect(await screen.findByText("line one", { exact: false })).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Container" })).not.toBeInTheDocument()
    })

    it("shows a container picker for a multi-container pod", async () => {
      setupFetchMock({ pods: { available: true, generated_at: GENERATED_AT, truncated: false, pods: [MULTI_CONTAINER_POD] } })
      renderBrowser()
      await switchTab("Logs")
      await screen.findByText("Select a pod to view its log tail.")

      fireEvent.click(screen.getByRole("button", { name: "Pod" }))
      fireEvent.click(await screen.findByRole("option", { name: "default/web-2" }))

      const containerButton = await screen.findByRole("button", { name: "Container" })
      fireEvent.click(containerButton)
      expect(await screen.findByRole("option", { name: "sidecar" })).toBeInTheDocument()
    })

    it("shows the empty state when the cluster has no pods", async () => {
      setupFetchMock({ pods: { available: true, generated_at: GENERATED_AT, truncated: false, pods: [] } })
      renderBrowser()
      await switchTab("Logs")

      expect(await screen.findByText("No pods found.")).toBeInTheDocument()
    })

    it("shows an error when the pod list fails to load", async () => {
      setupFetchMock({}, { pods: 502 })
      renderBrowser()
      await switchTab("Logs")

      expect(await screen.findByText("boom-pods")).toBeInTheDocument()
    })
  })

  describe("Live tab", () => {
    it("polls pod status by default and can switch to recent events", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Live")

      expect(await screen.findByText("default/web-1")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("tab", { name: "Recent events" }))
      expect(await screen.findByText("Scheduled: Successfully assigned default/web-1 to node-1")).toBeInTheDocument()
    })
  })

  describe("Detail drawer", () => {
    it("lists namespaces on the overview tab and opens a read-only drawer with YAML", async () => {
      const { calls } = setupFetchMock()
      renderBrowser()

      fireEvent.click(await screen.findByRole("button", { name: "default" }))

      expect(await screen.findByRole("dialog", { name: "Namespaces default" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: Namespace/)).toBeInTheDocument()
      expect(screen.getByText("Read-only — values cannot be edited here.")).toBeInTheDocument()
      expect(calls.some((url) => url.includes("/namespaces?name=default"))).toBe(true)

      fireEvent.click(screen.getByRole("button", { name: "Close details" }))
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    })

    it("opens a read-only pod drawer with key fields and YAML from the workloads table", async () => {
      const { calls } = setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")
      fireEvent.click(await screen.findByRole("button", { name: "web-1" }))

      expect(await screen.findByRole("dialog", { name: "Pods default/web-1" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: Pod/)).toBeInTheDocument()
      expect(calls.some((url) => url.includes("/pods?") && url.includes("name=web-1") && url.includes("namespace=default"))).toBe(true)
    })

    it("shows a drawer error when the describe fetch fails", async () => {
      setupFetchMock({}, {}, { pods: 502 })
      renderBrowser()
      await switchTab("Workloads")
      fireEvent.click(await screen.findByRole("button", { name: "web-1" }))

      expect(await screen.findByRole("dialog", { name: "Pods default/web-1" })).toBeInTheDocument()
      expect(await screen.findByText("boom-pods-describe")).toBeInTheDocument()
    })

    it("opens drawers for every other workload kind", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Workloads")
      await screen.findByText("web-1")

      const cases: Array<{ option: string; button: string; dialog: string; yaml: RegExp }> = [
        { option: "Deployments", button: "web", dialog: "Deployments default/web", yaml: /kind: Deployment/ },
        { option: "StatefulSets", button: "db", dialog: "StatefulSets default/db", yaml: /kind: StatefulSet/ },
        { option: "DaemonSets", button: "monitoring", dialog: "DaemonSets default/monitoring", yaml: /kind: DaemonSet/ },
        { option: "Jobs", button: "migrate", dialog: "Jobs default/migrate", yaml: /kind: Job/ },
        { option: "CronJobs", button: "nightly", dialog: "CronJobs default/nightly", yaml: /kind: CronJob/ }
      ]

      for (const { option, button, dialog, yaml } of cases) {
        fireEvent.click(screen.getByRole("button", { name: "Workload kind" }))
        fireEvent.click(await screen.findByRole("option", { name: option }))
        fireEvent.click(await screen.findByRole("button", { name: button }))

        expect(await screen.findByRole("dialog", { name: dialog })).toBeInTheDocument()
        expect(await screen.findByText(yaml)).toBeInTheDocument()

        fireEvent.click(screen.getByRole("button", { name: "Close details" }))
        expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
      }
    })

    it("opens drawers for services and ingresses", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Services")
      fireEvent.click(await screen.findByRole("button", { name: "web" }))
      expect(await screen.findByRole("dialog", { name: "Services default/web" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: Service/)).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Close details" }))

      fireEvent.click(screen.getByRole("button", { name: "Network kind" }))
      fireEvent.click(await screen.findByRole("option", { name: "Ingresses" }))
      await screen.findByText("web.example.com")
      fireEvent.click(await screen.findByRole("button", { name: "web" }))
      expect(await screen.findByRole("dialog", { name: "Ingresses default/web" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: Ingress/)).toBeInTheDocument()
    })

    it("opens drawers for configmaps and redacted secrets", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Config")
      fireEvent.click(await screen.findByRole("button", { name: "app-settings" }))
      expect(await screen.findByRole("dialog", { name: "ConfigMaps default/app-settings" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: ConfigMap/)).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Close details" }))

      fireEvent.click(await screen.findByRole("button", { name: "db-credentials" }))
      expect(await screen.findByRole("dialog", { name: "Secrets default/db-credentials" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: Secret/)).toBeInTheDocument()
    })

    it("opens drawers for nodes and persistent volume claims", async () => {
      setupFetchMock()
      renderBrowser()
      await switchTab("Nodes")
      fireEvent.click(await screen.findByRole("button", { name: "node-1" }))

      expect(await screen.findByRole("dialog", { name: "Nodes node-1" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: Node/)).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Close details" }))

      await switchTab("Storage")
      fireEvent.click(await screen.findByRole("button", { name: "data" }))
      expect(await screen.findByRole("dialog", { name: "Storage default/data" })).toBeInTheDocument()
      expect(await screen.findByText(/kind: PersistentVolumeClaim/)).toBeInTheDocument()
    })
  })
})
