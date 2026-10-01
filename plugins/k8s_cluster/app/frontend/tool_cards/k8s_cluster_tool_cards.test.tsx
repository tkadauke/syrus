import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { discoveredToolCardEntries, pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import eventsToolCard, { examples as eventExamples } from "./k8s_cluster_events"
import listClustersToolCard from "./k8s_cluster_list_clusters"
import namespacesToolCard from "./k8s_cluster_namespaces"
import nodesToolCard from "./k8s_cluster_nodes"
import overviewToolCard from "./k8s_cluster_overview"
import podsToolCard from "./k8s_cluster_pods"
import pvcsToolCard from "./k8s_cluster_pvcs"

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
      "k8s_cluster_events"
    ].forEach((toolName) => {
      expect(pluginToolCardRendererFor(toolName)).not.toBeNull()
    })
  })

  it("attributes the Kubernetes cards and examples to the plugin catalog", () => {
    const entry = discoveredToolCardEntries.find((candidate) => candidate.renderer.toolName === "k8s_cluster_events")

    expect(entry?.owner).toEqual({ ownerType: "plugin", ownerName: "k8s_cluster" })
    expect(eventExamples.map((example) => example.id)).toEqual(["healthy", "warning_heavy", "empty", "error"])
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
