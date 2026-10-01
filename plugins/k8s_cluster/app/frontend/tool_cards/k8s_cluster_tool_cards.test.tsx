import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { discoveredToolCardEntries, pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import configMapsToolCard from "./k8s_cluster_configmaps"
import cronJobsToolCard from "./k8s_cluster_cronjobs"
import daemonSetsToolCard from "./k8s_cluster_daemonsets"
import deploymentsToolCard from "./k8s_cluster_deployments"
import eventsToolCard, { examples as eventExamples } from "./k8s_cluster_events"
import ingressesToolCard from "./k8s_cluster_ingresses"
import jobsToolCard from "./k8s_cluster_jobs"
import listClustersToolCard from "./k8s_cluster_list_clusters"
import namespacesToolCard from "./k8s_cluster_namespaces"
import nodesToolCard from "./k8s_cluster_nodes"
import overviewToolCard from "./k8s_cluster_overview"
import podLogsToolCard from "./k8s_cluster_pod_logs"
import podsToolCard from "./k8s_cluster_pods"
import pvcsToolCard from "./k8s_cluster_pvcs"
import secretsToolCard, { examples as secretExamples } from "./k8s_cluster_secrets"
import servicesToolCard from "./k8s_cluster_services"
import statefulSetsToolCard from "./k8s_cluster_statefulsets"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "k8s_cluster_pods",
    input: { cluster_id: 7 },
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

describe("Kubernetes cluster tool cards", () => {
  it("registers plugin-owned cards for the read-only Kubernetes inventory tools", () => {
    [
      "k8s_cluster_overview",
      "k8s_cluster_list_clusters",
      "k8s_cluster_namespaces",
      "k8s_cluster_nodes",
      "k8s_cluster_pods",
      "k8s_cluster_pvcs",
      "k8s_cluster_events",
      "k8s_cluster_deployments",
      "k8s_cluster_statefulsets",
      "k8s_cluster_daemonsets",
      "k8s_cluster_jobs",
      "k8s_cluster_cronjobs",
      "k8s_cluster_services",
      "k8s_cluster_ingresses",
      "k8s_cluster_configmaps",
      "k8s_cluster_pod_logs",
      "k8s_cluster_secrets"
    ].forEach((toolName) => {
      expect(pluginToolCardRendererFor(toolName)).not.toBeNull()
    })
  })

  it("attributes the Kubernetes cards and examples to the plugin catalog", () => {
    const entry = discoveredToolCardEntries.find((candidate) => candidate.renderer.toolName === "k8s_cluster_events")

    expect(entry?.owner).toEqual({ ownerType: "plugin", ownerName: "k8s_cluster" })
    expect(eventExamples.map((example) => example.id)).toEqual(["healthy", "warning_heavy", "empty", "error"])
    expect(secretExamples.map((example) => example.id)).toEqual(["healthy", "warning_heavy", "empty", "error"])
  })

  it("summarizes cluster inventory with resource counts and warning status", () => {
    const cardContext = context({
      toolName: "k8s_cluster_list_clusters",
      input: {},
      parsedResult: {
        clusters: [
          { id: 7, label: "Prod", agentic_access_enabled: true, allow_writes: false, updated_at: "2026-09-30T12:00:00Z" },
          { id: 8, label: "Staging", agentic_access_enabled: false, allow_writes: false, updated_at: "2026-09-30T12:00:00Z" }
        ]
      }
    })

    expect(listClustersToolCard.collapsedSummary?.(cardContext)).toBe("All clusters · 2 clusters · 1 warning")
    render(<>{listClustersToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("columnheader", { name: "Label" })).toBeInTheDocument()
    expect(screen.getByText("Prod")).toBeInTheDocument()
    expect(screen.getByText("Disabled")).toBeInTheDocument()
  })

  it("renders pods as a filterable table with namespace scope, badges, restarts, age, and truncation notice", () => {
    const cardContext = context({
      toolName: "k8s_cluster_pods",
      input: { cluster_id: 7, namespace: "default" },
      parsedResult: {
        available: true,
        truncated: true,
        pods: [
          { namespace: "default", name: "web-1", status: "Running", ready: "1/1", restart_count: 0, node_name: "node-1", created_at: "2026-09-30T10:00:00Z" },
          { namespace: "default", name: "worker-1", status: "CrashLoopBackOff", ready: "0/1", restart_count: 12, node_name: "node-2", created_at: "2026-09-30T11:00:00Z" }
        ]
      }
    })

    expect(podsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / default · 2 pods · 1 warning · truncated")
    render(<>{podsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByLabelText("Filter resources")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Restarts" })).toBeInTheDocument()
    expect(screen.getByText("CrashLoopBackOff")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("Showing partial results — the server capped this list.")).toBeInTheDocument()
  })

  it("renders nodes, namespaces, PVCs, and events with their expected operational columns", () => {
    render(
      <>
        {nodesToolCard.renderExpanded(context({
          toolName: "k8s_cluster_nodes",
          parsedResult: { available: true, nodes: [{ name: "node-1", ready: false, roles: ["worker"], capacity_cpu: "8", capacity_memory: "32Gi", created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {namespacesToolCard.renderExpanded(context({
          toolName: "k8s_cluster_namespaces",
          parsedResult: { available: true, namespaces: [{ name: "default", status: "Active", created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {pvcsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_pvcs",
          parsedResult: { available: true, persistent_volume_claims: [{ namespace: "default", name: "data", status: "Pending", capacity: "10Gi", storage_class: "fast", access_modes: ["ReadWriteOnce"], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {eventsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_events",
          parsedResult: { available: true, events: [{ namespace: "default", type: "Warning", reason: "FailedScheduling", message: "No nodes available", involved_object: { kind: "Pod", name: "web-1" }, count: 3, last_timestamp: "2026-09-30T12:00:00Z" }] }
        }))}
      </>
    )

    expect(screen.getByRole("columnheader", { name: "Roles" })).toBeInTheDocument()
    expect(screen.getByText("Not ready")).toBeInTheDocument()
    expect(screen.getAllByText("default").length).toBeGreaterThan(0)
    expect(screen.getByText("ReadWriteOnce")).toBeInTheDocument()
    expect(screen.getByText("FailedScheduling")).toBeInTheDocument()
    expect(screen.getByText("Pod / web-1")).toBeInTheDocument()
  })

  it("renders overview totals and metrics-unavailable warnings without dumping raw JSON", () => {
    const cardContext = context({
      toolName: "k8s_cluster_overview",
      input: { cluster_id: 7 },
      parsedResult: {
        generated_at: "2026-09-30T12:00:00Z",
        nodes: { available: false, reason: "metrics_unavailable", message: "metrics.k8s.io is not available" },
        pods: {
          available: true,
          items: [{ namespace: "default", name: "web-1", cpu_millicores: 125, memory_bytes: 268435456 }],
          total_cpu_millicores: 125,
          total_memory_bytes: 268435456
        }
      }
    })

    expect(overviewToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 · 0 nodes, 1 pods · 1 warning")
    render(<>{overviewToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("metrics.k8s.io is not available")).toBeInTheDocument()
    expect(screen.getAllByText("125m").length).toBeGreaterThan(0)
    expect(screen.getAllByText("256.0 MB").length).toBeGreaterThan(0)
  })

  it("renders workload cards with readiness, selectors, rollout counts, and recent conditions", () => {
    render(
      <>
        {deploymentsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_deployments",
          parsedResult: { available: true, deployments: [{ namespace: "default", name: "web", replicas: 3, ready_replicas: 2, available_replicas: 2, updated_replicas: 3, selector: { app: "web" }, conditions: [{ type: "Available", status: "False", reason: "MinimumReplicasUnavailable" }], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {statefulSetsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_statefulsets",
          parsedResult: { available: true, stateful_sets: [{ namespace: "default", name: "postgres", replicas: 2, ready_replicas: 2, current_replicas: 2, updated_replicas: 2, selector: { app: "postgres" }, conditions: [{ type: "Ready", status: "True" }], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {daemonSetsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_daemonsets",
          parsedResult: { available: true, daemon_sets: [{ namespace: "kube-system", name: "agent", desired_number_scheduled: 4, current_number_scheduled: 4, number_ready: 3, number_available: 3, selector: { app: "agent" }, conditions: [{ type: "Available", status: "False" }], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {jobsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_jobs",
          parsedResult: { available: true, jobs: [{ namespace: "default", name: "migrate", completions: 1, parallelism: 1, active_count: 0, succeeded: 0, failed: 1, selector: { "job-name": "migrate" }, conditions: [{ type: "Failed", status: "True" }], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {cronJobsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_cronjobs",
          parsedResult: { available: true, cron_jobs: [{ namespace: "default", name: "nightly", schedule: "0 2 * * *", suspended: true, active_count: 0, last_schedule_time: "2026-09-30T02:00:00Z", created_at: "2026-09-01T00:00:00Z" }] }
        }))}
      </>
    )

    expect(deploymentsToolCard.collapsedSummary?.(context({
      toolName: "k8s_cluster_deployments",
      parsedResult: { available: true, deployments: [{ replicas: 3, ready_replicas: 2 }] }
    }))).toBe("Cluster 7 · 1 deployments · 1 warning")
    expect(screen.getAllByRole("columnheader", { name: "Selector" }).length).toBeGreaterThan(0)
    expect(screen.getByText("app=web")).toBeInTheDocument()
    expect(screen.getByText("Available:False:MinimumReplicasUnavailable")).toBeInTheDocument()
    expect(screen.getByText("0/1")).toBeInTheDocument()
    expect(screen.getByText("0 2 * * *")).toBeInTheDocument()
  })

  it("renders services and ingresses with ports, endpoint warnings, hosts, TLS, and backend metadata", () => {
    render(
      <>
        {servicesToolCard.renderExpanded(context({
          toolName: "k8s_cluster_services",
          parsedResult: { available: true, services: [{ namespace: "default", name: "web", type: "ClusterIP", cluster_ip: "10.0.0.10", ports: [{ name: "http", port: 80, target_port: 8080, protocol: "TCP" }], selector: { app: "web" }, ready_addresses: 0, not_ready_addresses: 0, missing_target_warning: true, created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {ingressesToolCard.renderExpanded(context({
          toolName: "k8s_cluster_ingresses",
          parsedResult: { available: true, ingresses: [{ namespace: "default", name: "web", ingress_class: "nginx", hosts: ["app.example.test"], rules: [{ host: "app.example.test", paths: [{ path: "/", path_type: "Prefix", service_name: "web", service_port: 80 }] }], tls_hosts: ["app.example.test"], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
      </>
    )

    expect(screen.getByText("80/TCP -> 8080")).toBeInTheDocument()
    expect(screen.getByText("No ready targets")).toBeInTheDocument()
    expect(screen.getAllByText("app.example.test").length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText("web:80")).toBeInTheDocument()
    expect(screen.getByText("nginx")).toBeInTheDocument()
  })

  it("normalizes describe-shaped ingress backends before rendering", () => {
    const cardContext = context({
      toolName: "k8s_cluster_ingresses",
      input: { cluster_id: 7, namespace: "default", name: "web" },
      parsedResult: {
        available: true,
        ingress: {
          metadata: { namespace: "default", name: "web", creationTimestamp: "2026-09-01T00:00:00Z" },
          spec: {
            ingressClassName: "nginx",
            rules: [
              {
                host: "app.example.test",
                http: {
                  paths: [
                    {
                      path: "/",
                      pathType: "Prefix",
                      backend: { service: { name: "web", port: { number: 80 } } }
                    }
                  ]
                }
              }
            ],
            tls: [{ hosts: ["app.example.test"] }]
          }
        }
      }
    })

    expect(ingressesToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / default / web · 1 ingresses")
    render(<>{ingressesToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("web:80")).toBeInTheDocument()
    expect(screen.queryByText("No backend")).not.toBeInTheDocument()
  })

  it("renders config and secret metadata without exposing secret values", () => {
    render(
      <>
        {configMapsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_configmaps",
          parsedResult: { available: true, config_maps: [{ namespace: "default", name: "web-config", key_count: 2, key_names: ["LOG_LEVEL", "PUBLIC_URL"], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
        {secretsToolCard.renderExpanded(context({
          toolName: "k8s_cluster_secrets",
          parsedResult: { available: true, secrets: [{ namespace: "default", name: "web-secret", type: "Opaque", key_count: 2, key_names: ["API_TOKEN", "DATABASE_URL"], created_at: "2026-09-01T00:00:00Z" }] }
        }))}
      </>
    )

    expect(screen.getByText("LOG_LEVEL, PUBLIC_URL")).toBeInTheDocument()
    expect(screen.getByText("API_TOKEN, DATABASE_URL")).toBeInTheDocument()
    expect(screen.queryByText("super-secret-value")).not.toBeInTheDocument()
  })

  it("renders pod logs with searchable truncated preview metadata", () => {
    const cardContext = context({
      toolName: "k8s_cluster_pod_logs",
      input: { cluster_id: 7, namespace: "default", name: "web-1", container: "web" },
      parsedResult: {
        available: true,
        pod: "web-1",
        namespace: "default",
        container: "web",
        log: "2026-09-30T12:00:00Z boot complete\n2026-09-30T12:00:01Z request complete"
      }
    })

    expect(podLogsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / default / web-1 · 2 log lines")
    render(<>{podLogsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByLabelText("Search logs…")).toBeInTheDocument()
    expect(screen.getByText("web-1")).toBeInTheDocument()
    expect(screen.getByText(/boot complete/)).toBeInTheDocument()
  })

  it("renders empty and error cases as friendly card bodies", () => {
    const emptyContext = context({ toolName: "k8s_cluster_events", parsedResult: { available: true, events: [] } })
    expect(eventsToolCard.collapsedSummary?.(emptyContext)).toBe("Cluster 7 · 0 events")
    render(<>{eventsToolCard.renderExpanded(emptyContext)}</>)
    expect(screen.getByText("No events returned.")).toBeInTheDocument()

    const errorContext = context({
      toolName: "k8s_cluster_pods",
      resultBody: "Error: namespace is required to describe a specific resource",
      resultError: true,
      parsedResult: null
    })
    expect(podsToolCard.collapsedSummary?.(errorContext)).toBe("Cluster 7 · error")
    render(<>{podsToolCard.renderExpanded(errorContext)}</>)
    const latestCard = screen.getAllByText("Error").at(-1)?.closest("div")
    expect(latestCard).toBeTruthy()
    expect(screen.getByText("namespace is required to describe a specific resource")).toBeInTheDocument()
  })

  it("falls back to generic rendering for malformed success payloads", () => {
    const malformedContext = context({ toolName: "k8s_cluster_pods", parsedResult: { available: true, podz: [] } })

    expect(podsToolCard.collapsedSummary?.(malformedContext)).toBeNull()
    expect(podsToolCard.renderExpanded(malformedContext)).toBeNull()
  })
})
