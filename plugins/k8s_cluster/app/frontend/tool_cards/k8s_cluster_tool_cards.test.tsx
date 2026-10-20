import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { discoveredToolCardEntries, pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName, toolPresentation } from "@app/routes/chat/toolRendering"
import configMapsToolCard from "./k8s_cluster_configmaps"
import cronJobsToolCard from "./k8s_cluster_cronjobs"
import daemonSetsToolCard from "./k8s_cluster_daemonsets"
import deletePodToolCard, { examples as deletePodExamples } from "./k8s_cluster_delete_pod"
import deploymentsToolCard from "./k8s_cluster_deployments"
import eventsToolCard, { examples as eventExamples } from "./k8s_cluster_events"
import ingressesToolCard from "./k8s_cluster_ingresses"
import jobsToolCard from "./k8s_cluster_jobs"
import kubectlToolCard, { examples as kubectlExamples } from "./k8s_cluster_kubectl"
import listClustersToolCard from "./k8s_cluster_list_clusters"
import namespacesToolCard from "./k8s_cluster_namespaces"
import nodesToolCard from "./k8s_cluster_nodes"
import overviewToolCard from "./k8s_cluster_overview"
import podLogsToolCard from "./k8s_cluster_pod_logs"
import podsToolCard from "./k8s_cluster_pods"
import pvcsToolCard from "./k8s_cluster_pvcs"
import restartRolloutToolCard from "./k8s_cluster_restart_rollout"
import scaleDeploymentToolCard from "./k8s_cluster_scale_deployment"
import secretsToolCard, { examples as secretExamples } from "./k8s_cluster_secrets"
import servicesToolCard from "./k8s_cluster_services"
import setNodeCordonToolCard from "./k8s_cluster_set_node_cordon"
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
    ;[
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

  it("registers plugin-owned cards for Kubernetes action acknowledgement tools", () => {
    ;["k8s_cluster_restart_rollout", "k8s_cluster_scale_deployment", "k8s_cluster_delete_pod", "k8s_cluster_set_node_cordon", "k8s_cluster_kubectl"].forEach(
      (toolName) => {
        expect(pluginToolCardRendererFor(toolName)).not.toBeNull()
      }
    )
  })

  it("attributes the Kubernetes cards and examples to the plugin catalog", () => {
    const entry = discoveredToolCardEntries.find((candidate) => candidate.renderer.toolName === "k8s_cluster_events")

    expect(entry?.owner).toEqual({ ownerType: "plugin", ownerName: "k8s_cluster" })
    expect(eventExamples.map((example) => example.id)).toEqual(["healthy", "warning_heavy", "empty", "error"])
    expect(secretExamples.map((example) => example.id)).toEqual(["healthy", "warning_heavy", "empty", "error"])
    expect(deletePodExamples.map((example) => example.id)).toEqual(["successful_action", "no_op", "validation_failure", "api_failure", "permission_denied"])
    expect(kubectlExamples.map((example) => example.id)).toEqual(["successful_get", "policy_denied"])
  })

  it("summarizes credential-backed kubectl output without rendering raw credential payloads", () => {
    const cardContext = context({
      toolName: "k8s_cluster_kubectl",
      input: { credential: "prod-k3s", kube_context: "prod", namespace: "default", args: ["get", "pods"] },
      parsedResult: {
        ok: true,
        status: 0,
        stdout: { text: "NAME READY STATUS\nweb 1/1 Running\n", truncated: false },
        stderr: { text: "", truncated: false },
        command: { executable: "kubectl", args: ["--context", "prod", "--namespace", "default", "get", "pods"] },
        target: { kube_context: "prod", kube_namespace: "default" },
        credential: { credential_id: 12, credential_name: "prod-k3s", credential_type: "k8s_cluster.kubeconfig" }
      }
    })

    expect(kubectlToolCard.collapsedSummary?.(cardContext)).toBe("kubectl --context prod --namespace default get pods in Context prod / default · succeeded")
    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("prod-k3s")).toBeInTheDocument()
    expect(screen.getByText(/web 1\/1 Running/)).toBeInTheDocument()
    expect(screen.queryByText(/token/)).not.toBeInTheDocument()
  })

  it("renders structured non-zero kubectl exits as API failures without dumping the raw payload", () => {
    const parsedResult = {
      ok: false,
      status: 1,
      stdout: { text: "", truncated: false },
      stderr: { text: 'Error from server (NotFound): namespaces "nope" not found\n', truncated: false },
      command: { executable: "kubectl", args: ["get", "pods", "--namespace", "nope"] }
    }
    const cardContext = context({
      toolName: "k8s_cluster_kubectl",
      input: { args: ["get", "pods", "--namespace", "nope"] },
      parsedResult,
      resultBody: JSON.stringify(parsedResult),
      resultError: true
    })

    expect(kubectlToolCard.collapsedSummary?.(cardContext)).toContain("API failed")
    expect(kubectlToolCard.collapsedSummary?.(cardContext)).not.toContain("validation failed")
    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("API failed")).toBeInTheDocument()
    expect(screen.getAllByText(/namespaces "nope" not found/).length).toBeGreaterThan(0)
    expect(screen.queryByText(JSON.stringify(parsedResult))).not.toBeInTheDocument()
  })

  it("shows when kubectl stdout or stderr was capped", () => {
    const cardContext = context({
      toolName: "k8s_cluster_kubectl",
      resultError: true,
      parsedResult: {
        ok: false,
        status: 1,
        stdout: { text: "partial stdout", truncated: true, bytes: 65536, omitted_bytes: 4096 },
        stderr: { text: "partial stderr", truncated: true, bytes: 65536, omitted_bytes: 2048 }
      }
    })

    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("truncated · 4.0 KB omitted")).toBeInTheDocument()
    expect(screen.getByText("truncated · 2.0 KB omitted")).toBeInTheDocument()
  })

  it("summarizes successful action acknowledgements with action, target, scope, and result", () => {
    const cardContext = context({
      toolName: "k8s_cluster_scale_deployment",
      input: { cluster_id: 7, namespace: "default", name: "web", replicas: 5, reason: "Scale for morning traffic" },
      parsedResult: {
        available: true,
        generated_at: "2026-09-30T12:00:00Z",
        deployment: "web",
        namespace: "default",
        before: { replicas: 2 },
        after: { replicas: 5 },
        audit_id: "audit-123"
      }
    })

    expect(scaleDeploymentToolCard.collapsedSummary?.(cardContext)).toBe("Scale deployment default/web in Cluster 7 / default · succeeded")
    render(<>{scaleDeploymentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Set replicas to 5")).toBeInTheDocument()
    expect(screen.getByText("2 replicas")).toBeInTheDocument()
    expect(screen.getByText("5 replicas")).toBeInTheDocument()
    expect(screen.getByText("Scale for morning traffic")).toBeInTheDocument()
    expect(screen.getByText("audit-123")).toBeInTheDocument()
    expect(screen.getByText("Confirm desired and ready replica counts converge.")).toBeInTheDocument()
  })

  it("marks no-op acknowledgements when previous and current state match", () => {
    const cardContext = context({
      toolName: "k8s_cluster_set_node_cordon",
      input: { cluster_id: 7, name: "node-1", cordoned: true },
      parsedResult: {
        available: true,
        node: "node-1",
        before: { unschedulable: true },
        after: { unschedulable: true }
      }
    })

    expect(setNodeCordonToolCard.collapsedSummary?.(cardContext)).toBe("Cordon node node-1 in Cluster 7 · no-op")
    render(<>{setNodeCordonToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("no-op")).toBeInTheDocument()
    expect(screen.getAllByText("unschedulable").length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText("Read the node to confirm it is unschedulable.")).toBeInTheDocument()
  })

  it("distinguishes validation, permission, missing resource, and API failures", () => {
    const validationContext = context({
      toolName: "k8s_cluster_scale_deployment",
      input: { cluster_id: 7, namespace: "default", name: "web", replicas: -1 },
      resultBody: "Error: replicas must be a non-negative integer",
      resultError: true,
      parsedResult: null
    })
    const permissionContext = context({
      toolName: "k8s_cluster_delete_pod",
      input: { cluster_id: 7, namespace: "default", name: "web-1" },
      resultBody: "Error: Write access is disabled for Kubernetes cluster 7",
      resultError: true,
      parsedResult: null
    })
    const missingContext = context({
      toolName: "k8s_cluster_restart_rollout",
      input: { cluster_id: 7, namespace: "default", name: "missing" },
      resultBody: 'Error: deployments.apps "missing" not found',
      resultError: true,
      parsedResult: null
    })
    const apiContext = context({
      toolName: "k8s_cluster_set_node_cordon",
      input: { cluster_id: 7, name: "node-1", cordoned: false },
      resultBody: "Error: Kubeclient::HttpError: apiserver timed out",
      resultError: true,
      parsedResult: null
    })

    expect(scaleDeploymentToolCard.collapsedSummary?.(validationContext)).toContain("validation failed")
    expect(deletePodToolCard.collapsedSummary?.(permissionContext)).toContain("permission denied")
    expect(restartRolloutToolCard.collapsedSummary?.(missingContext)).toContain("missing resource")
    expect(setNodeCordonToolCard.collapsedSummary?.(apiContext)).toContain("API failed")

    render(
      <>
        {scaleDeploymentToolCard.renderExpanded(validationContext)}
        {deletePodToolCard.renderExpanded(permissionContext)}
        {restartRolloutToolCard.renderExpanded(missingContext)}
        {setNodeCordonToolCard.renderExpanded(apiContext)}
      </>
    )

    expect(screen.getByText("Validation failure")).toBeInTheDocument()
    expect(screen.getByText("Permission error")).toBeInTheDocument()
    expect(screen.getByText("Missing resource")).toBeInTheDocument()
    expect(screen.getByText("Backend/API error")).toBeInTheDocument()
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
          {
            namespace: "default",
            name: "worker-1",
            status: "CrashLoopBackOff",
            ready: "0/1",
            restart_count: 12,
            node_name: "node-2",
            created_at: "2026-09-30T11:00:00Z"
          }
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

  it("filters the complete resource result before limiting the table preview", () => {
    const pods = Array.from({ length: 1000 }, (_, index) => ({ namespace: "default", name: `pod-${index}`, status: "Running", ready: "1/1", restart_count: 0 }))
    const cardContext = context({ toolName: "k8s_cluster_pods", parsedResult: { available: true, truncated: false, pods } })

    render(<>{podsToolCard.renderExpanded(cardContext)}</>)
    fireEvent.change(screen.getByLabelText("Filter resources"), { target: { value: "pod-400" } })

    expect(screen.getByText("pod-400")).toBeInTheDocument()
    expect(screen.getByText("1 of 1000")).toBeInTheDocument()
    expect(screen.queryByText("No matching rows.")).not.toBeInTheDocument()
  })

  it("renders nodes, namespaces, PVCs, and events with their expected operational columns", () => {
    render(
      <>
        {nodesToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_nodes",
            parsedResult: {
              available: true,
              generated_at: "2026-09-30T12:00:00Z",
              nodes: [
                {
                  name: "node-1",
                  ready: false,
                  roles: ["worker"],
                  kubelet_version: "v1.31.2",
                  internal_ip: "10.0.0.12",
                  capacity_cpu: "8",
                  capacity_memory: "32Gi",
                  allocatable_cpu: "7600m",
                  allocatable_memory: "30Gi",
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {namespacesToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_namespaces",
            parsedResult: { available: true, namespaces: [{ name: "default", status: "Active", created_at: "2026-09-01T00:00:00Z" }] }
          })
        )}
        {pvcsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_pvcs",
            parsedResult: {
              available: true,
              persistent_volume_claims: [
                {
                  namespace: "default",
                  name: "data",
                  status: "Pending",
                  capacity: "10Gi",
                  storage_class: "fast",
                  access_modes: ["ReadWriteOnce"],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {eventsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_events",
            parsedResult: {
              available: true,
              events: [
                {
                  namespace: "default",
                  type: "Warning",
                  reason: "FailedScheduling",
                  message: "No nodes available",
                  involved_object: { kind: "Pod", name: "web-1" },
                  count: 3,
                  last_timestamp: "2026-09-30T12:00:00Z"
                }
              ]
            }
          })
        )}
      </>
    )

    expect(screen.getByRole("columnheader", { name: "Roles" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Kubelet" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Internal IP" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Allocatable" })).toBeInTheDocument()
    expect(screen.getByText("Not ready")).toBeInTheDocument()
    expect(screen.getByText("v1.31.2")).toBeInTheDocument()
    expect(screen.getByText("10.0.0.12")).toBeInTheDocument()
    expect(screen.getByText("7.6 vCPU / 30.0 GB")).toBeInTheDocument()
    expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy node-1 to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByText("default").length).toBeGreaterThan(0)
    expect(screen.getByText("ReadWriteOnce")).toBeInTheDocument()
    expect(screen.getByText("FailedScheduling")).toBeInTheDocument()
    expect(screen.getByText("Pod / web-1")).toBeInTheDocument()
  })

  it("renders node lists identically from every MCP envelope", () => {
    const payload = {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      nodes: [
        {
          name: "node-envelope-1",
          ready: true,
          roles: ["worker"],
          kubelet_version: "v1.31.3",
          internal_ip: "10.0.0.13",
          capacity_cpu: "8",
          capacity_memory: "32Gi",
          allocatable_cpu: "7500m",
          allocatable_memory: "29Gi",
          created_at: "2026-09-01T00:00:00Z"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_nodes")
      const cardContext = context({ toolName, input: { cluster_id: 7 }, parsedResult: normalizedToolCardParsedResult(envelope) })

      expect(toolName).toBe("k8s_cluster_nodes")
      expect(nodesToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 · 1 nodes")
      const rendered = render(<>{nodesToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
      expect(screen.getByRole("button", { name: "Copy node-envelope-1 to clipboard" })).toBeInTheDocument()
      expect(screen.getByText("v1.31.3")).toBeInTheDocument()
      expect(screen.getByText("10.0.0.13")).toBeInTheDocument()
      expect(screen.getByText("8 vCPU / 32.0 GB")).toBeInTheDocument()
      expect(screen.getByText("7.5 vCPU / 29.0 GB")).toBeInTheDocument()
      expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders node describes from every MCP envelope with operational details and redacted label values", () => {
    const payload = {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      node: {
        metadata: {
          name: "node-1",
          creationTimestamp: "2026-09-01T00:00:00Z",
          labels: { "node-role.kubernetes.io/worker": "", owner: "private-team-name" }
        },
        spec: { taints: [{ key: "dedicated", value: "batch", effect: "NoSchedule" }] },
        status: {
          capacity: { cpu: "8", memory: "32Gi" },
          allocatable: { cpu: "7600m", memory: "30Gi" },
          addresses: [
            { type: "InternalIP", address: "10.0.0.12" },
            { type: "Hostname", address: "node-1" }
          ],
          conditions: [{ type: "Ready", status: "False", reason: "KubeletNotReady", message: "container runtime is unavailable" }],
          nodeInfo: { kubeletVersion: "v1.31.2", operatingSystem: "linux", architecture: "amd64" }
        }
      }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_nodes")
      const cardContext = context({ toolName, input: { cluster_id: 7, name: "node-1" }, parsedResult: normalizedToolCardParsedResult(envelope) })

      expect(nodesToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / node-1 · 1 nodes · 1 warning")
      const rendered = render(<>{nodesToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
      expect(screen.getAllByRole("button", { name: "Copy node-1 to clipboard" }).length).toBeGreaterThan(0)
      expect(screen.getByText("KubeletNotReady")).toBeInTheDocument()
      expect(screen.getByText("container runtime is unavailable")).toBeInTheDocument()
      expect(screen.getByText("dedicated=batch:NoSchedule")).toBeInTheDocument()
      expect(screen.getByText("InternalIP: 10.0.0.12, Hostname: node-1")).toBeInTheDocument()
      expect(screen.getByText("2: node-role.kubernetes.io/worker, owner")).toBeInTheDocument()
      expect(screen.getByText(/kubeletVersion: v1.31.2/)).toBeInTheDocument()
      expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
      expect(screen.queryByText("private-team-name")).not.toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders node empty and error states with their input scope", () => {
    const empty = render(
      <>
        {nodesToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_nodes",
            input: { cluster_id: 7 },
            parsedResult: { available: true, generated_at: "2026-09-30T12:00:00Z", nodes: [] }
          })
        )}
      </>
    )
    expect(screen.getByText("No nodes returned.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
    empty.unmount()

    render(
      <>
        {nodesToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_nodes",
            input: { cluster_id: 7, name: "missing-node" },
            resultBody: "Error: Node not found",
            resultError: true,
            parsedResult: null
          })
        )}
      </>
    )
    expect(screen.getByText("Node not found")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByRole("button", { name: "Copy missing-node to clipboard" })).toBeInTheDocument()
  })

  it("renders namespace describes from every MCP envelope with linked scope and safe metadata summaries", () => {
    const payload = {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      namespace: {
        metadata: {
          name: "payments",
          creationTimestamp: "2026-09-01T00:00:00Z",
          labels: { owner: "private-team-name", environment: "production" },
          annotations: { "example.test/contact": "secret-contact@example.test", "kubectl.kubernetes.io/last-applied-configuration": "secret-manifest" }
        },
        status: { phase: "Active" }
      }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_namespaces")
      const cardContext = context({ toolName, input: { cluster_id: 7, name: "payments" }, parsedResult: normalizedToolCardParsedResult(envelope) })

      expect(toolName).toBe("k8s_cluster_namespaces")
      expect(namespacesToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments · 1 namespaces")
      const rendered = render(<>{namespacesToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
      expect(screen.getByRole("link", { name: "payments" })).toHaveAttribute("href", "/k8s_clusters/7")
      expect(screen.getByText("Active")).toBeInTheDocument()
      expect(screen.getByRole("columnheader", { name: "Age" })).toBeInTheDocument()
      expect(screen.getByText("2: environment, owner")).toBeInTheDocument()
      expect(screen.getByText("2: example.test/contact, kubectl.kubernetes.io/last-applied-configuration")).toBeInTheDocument()
      expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
      expect(screen.queryByText(/private-team-name|secret-contact|secret-manifest/)).not.toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders namespace list, empty, and error results with linked scope and no raw input detail", () => {
    expect(toolPresentation("mcp__syrus-chat-sidecar__k8s_cluster_namespaces", { cluster_id: 7 }).argument_summary).toBe("")

    const listContext = context({
      toolName: "k8s_cluster_namespaces",
      input: { cluster_id: 7 },
      parsedResult: { available: true, namespaces: [{ name: "default", status: "Active", created_at: "2026-09-01T00:00:00Z" }] }
    })
    expect(namespacesToolCard.renderExpanded(listContext)).not.toBeNull()

    const emptyContext = context({
      toolName: "k8s_cluster_namespaces",
      input: { cluster_id: 7 },
      parsedResult: { available: true, generated_at: "2026-09-30T12:00:00Z", namespaces: [] }
    })
    const empty = render(<>{namespacesToolCard.renderExpanded(emptyContext)}</>)
    expect(screen.getByText("No namespaces returned.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
    empty.unmount()

    const errorContext = context({
      toolName: "k8s_cluster_namespaces",
      input: { cluster_id: 7, name: "missing" },
      resultBody: "Error: Namespace not found",
      resultError: true,
      parsedResult: null
    })
    render(<>{namespacesToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Namespace not found")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByRole("link", { name: "missing" })).toHaveAttribute("href", "/k8s_clusters/7")
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
        {deploymentsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_deployments",
            parsedResult: {
              available: true,
              deployments: [
                {
                  namespace: "default",
                  name: "web",
                  replicas: 3,
                  ready_replicas: 2,
                  available_replicas: 2,
                  updated_replicas: 3,
                  selector: { app: "web" },
                  conditions: [{ type: "Available", status: "False", reason: "MinimumReplicasUnavailable" }],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {statefulSetsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_statefulsets",
            parsedResult: {
              available: true,
              stateful_sets: [
                {
                  namespace: "default",
                  name: "postgres",
                  replicas: 2,
                  ready_replicas: 2,
                  current_replicas: 2,
                  updated_replicas: 2,
                  selector: { app: "postgres" },
                  conditions: [{ type: "Ready", status: "True" }],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {daemonSetsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_daemonsets",
            parsedResult: {
              available: true,
              daemon_sets: [
                {
                  namespace: "kube-system",
                  name: "agent",
                  desired_number_scheduled: 4,
                  current_number_scheduled: 4,
                  number_ready: 3,
                  number_available: 3,
                  selector: { app: "agent" },
                  conditions: [{ type: "Available", status: "False" }],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {jobsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_jobs",
            parsedResult: {
              available: true,
              jobs: [
                {
                  namespace: "default",
                  name: "migrate",
                  completions: 1,
                  parallelism: 1,
                  active_count: 0,
                  succeeded: 0,
                  failed: 1,
                  selector: { "job-name": "migrate" },
                  conditions: [{ type: "Failed", status: "True" }],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {cronJobsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_cronjobs",
            parsedResult: {
              available: true,
              cron_jobs: [
                {
                  namespace: "default",
                  name: "nightly",
                  schedule: "0 2 * * *",
                  suspended: true,
                  active_count: 0,
                  last_schedule_time: "2026-09-30T02:00:00Z",
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
      </>
    )

    expect(
      deploymentsToolCard.collapsedSummary?.(
        context({
          toolName: "k8s_cluster_deployments",
          parsedResult: { available: true, deployments: [{ replicas: 3, ready_replicas: 2 }] }
        })
      )
    ).toBe("Cluster 7 · 1 deployments · 1 warning")
    expect(screen.getAllByRole("columnheader", { name: "Selector" }).length).toBeGreaterThan(0)
    expect(screen.getByText("app=web")).toBeInTheDocument()
    expect(screen.getByText("Available:False:MinimumReplicasUnavailable")).toBeInTheDocument()
    expect(screen.getByText("0/1")).toBeInTheDocument()
    expect(screen.getByText("0 2 * * *")).toBeInTheDocument()
  })

  it("renders services and ingresses with ports, endpoint warnings, hosts, TLS, and backend metadata", () => {
    render(
      <>
        {servicesToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_services",
            parsedResult: {
              available: true,
              services: [
                {
                  namespace: "default",
                  name: "web",
                  type: "ClusterIP",
                  cluster_ip: "10.0.0.10",
                  ports: [{ name: "http", port: 80, target_port: 8080, protocol: "TCP" }],
                  selector: { app: "web" },
                  ready_addresses: 0,
                  not_ready_addresses: 0,
                  missing_target_warning: true,
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
        {ingressesToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_ingresses",
            parsedResult: {
              available: true,
              ingresses: [
                {
                  namespace: "default",
                  name: "web",
                  ingress_class: "nginx",
                  hosts: ["app.example.test"],
                  rules: [{ host: "app.example.test", paths: [{ path: "/", path_type: "Prefix", service_name: "web", service_port: 80 }] }],
                  tls_hosts: ["app.example.test"],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
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

  it("keeps the requested resource name in linked scope details", () => {
    const cardContext = context({
      toolName: "k8s_cluster_deployments",
      input: { cluster_id: 7, namespace: "default", name: "web" },
      parsedResult: {
        available: true,
        deployments: [{ namespace: "default", name: "web", replicas: 1, ready_replicas: 1 }]
      }
    })

    render(<>{deploymentsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByRole("link", { name: "default" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getAllByText("web").length).toBeGreaterThan(0)
  })

  it("renders config and secret metadata without exposing secret values", () => {
    render(
      <>
        {configMapsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_configmaps",
            parsedResult: {
              available: true,
              config_maps: [
                { namespace: "default", name: "web-config", key_count: 2, key_names: ["LOG_LEVEL", "PUBLIC_URL"], created_at: "2026-09-01T00:00:00Z" }
              ]
            }
          })
        )}
        {secretsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_secrets",
            parsedResult: {
              available: true,
              secrets: [
                {
                  namespace: "default",
                  name: "web-secret",
                  type: "Opaque",
                  key_count: 2,
                  key_names: ["API_TOKEN", "DATABASE_URL"],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
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
    expect(screen.getAllByText("web-1").length).toBeGreaterThan(0)
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
