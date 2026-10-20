import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { discoveredToolCardEntries, pluginToolCardRendererFor, toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName, toolPresentation } from "@app/routes/chat/toolRendering"
import { redactToolCardValue } from "@app/toolCardSecurity"
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
import scaleDeploymentToolCard, { examples as scaleDeploymentExamples } from "./k8s_cluster_scale_deployment"
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
    expect(scaleDeploymentExamples.map((example) => example.id)).toEqual([
      "successful_action",
      "no_op",
      "validation_failure",
      "api_failure",
      "permission_denied"
    ])
    expect(kubectlExamples.map((example) => example.id)).toEqual(["successful_get", "policy_denied"])
  })

  it("summarizes credential-backed kubectl output without rendering raw credential payloads", () => {
    const cardContext = context({
      toolName: "k8s_cluster_kubectl",
      input: { credential: "prod-k3s", cluster: "production", kube_context: "prod", namespace: "default", args: ["get", "pods"] },
      parsedResult: {
        ok: true,
        status: 0,
        stdout: { text: "NAME READY STATUS\nweb 1/1 Running\n", truncated: false },
        stderr: { text: "", truncated: false },
        command: { executable: "kubectl", args: ["--context", "prod", "--namespace", "default", "get", "pods"] },
        target: { kube_context: "prod", kube_namespace: "default" },
        safe_metadata: { cluster: "production", context: "prod", host: "https://kube.example.test" },
        credential: { credential_id: 12, credential_name: "prod-k3s", credential_type: "k8s_cluster.kubeconfig" }
      }
    })

    expect(kubectlToolCard.collapsedSummary?.(cardContext)).toBe("kubectl --context prod --namespace default get pods in Context prod / default · succeeded")
    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("prod-k3s")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("k8s_cluster.kubeconfig")).toBeInTheDocument()
    expect(screen.getByText("https://kube.example.test")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy command" })).toBeInTheDocument()
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
    expect(screen.getByText("stderr").closest("details")).toHaveAttribute("open")
  })

  it("normalizes every kubectl MCP envelope, preserves safe credential metadata, and suppresses secret-capable output", () => {
    const payload = {
      ok: true,
      status: 0,
      stdout: {
        text: "apiVersion: v1\nkind: Secret\ndata:\n  tls.crt: YXJiaXRyYXJ5LWNlcnRpZmljYXRl\nstringData:\n  arbitrary-app-key: visible-secret-value",
        truncated: false
      },
      stderr: { text: "", truncated: false },
      credential: { credential_id: 42, credential_name: "ops-kubeconfig", credential_type: "kubeconfig" },
      target: { kube_context: "ops", kube_namespace: "monitoring" },
      safe_metadata: { cluster: "ops", context: "ops", host: "kube.internal" }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored" }] },
      { content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const cardContext = context({
        toolName: normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_kubectl"),
        input: { args: ["get", "pods"], allow_secret_output: true, allow_risky_command: true },
        parsedResult: redactToolCardValue(normalizedToolCardParsedResult(envelope))
      })

      const view = render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByText("ops-kubeconfig")).toBeInTheDocument()
      expect(screen.getByText("42")).toBeInTheDocument()
      expect(screen.getByText("kubeconfig")).toBeInTheDocument()
      expect(screen.getByText("Secret output allowed")).toBeInTheDocument()
      expect(screen.getByText("Risky command allowed")).toBeInTheDocument()
      expect(screen.getByText(/Command output is hidden because secret output was allowed/)).toBeInTheDocument()
      expect(screen.queryByText(/tls\.crt|YXJiaXRyYXJ5|arbitrary-app-key|visible-secret-value/)).not.toBeInTheDocument()
      expect(screen.queryByText("stdout")).not.toBeInTheDocument()
      view.unmount()
    }
  })

  it("classifies kubectl policy denials separately from validation errors", () => {
    const cardContext = context({
      toolName: "k8s_cluster_kubectl",
      input: { args: ["get", "secrets"] },
      resultBody: "Error: kubectl command could expose secret values",
      resultError: true,
      parsedResult: null
    })

    expect(kubectlToolCard.collapsedSummary?.(cardContext)).toContain("permission denied")
    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Permission error")).toBeInTheDocument()
  })

  it("keeps safe credential metadata in the redacted policy-denied catalog example", () => {
    const example = kubectlExamples.find((candidate) => candidate.id === "policy_denied")!
    const exampleContext = toolCardContextForExample("k8s_cluster_kubectl", example)
    const cardContext = {
      ...exampleContext,
      input: redactToolCardValue(exampleContext.input) as Record<string, unknown>,
      parsedResult: redactToolCardValue(exampleContext.parsedResult)
    }

    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Permission error")).toBeInTheDocument()
    expect(screen.getByText("prod-k3s")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("k8s_cluster.kubeconfig")).toBeInTheDocument()
    expect(screen.queryByText("[redacted]")).not.toBeInTheDocument()
  })

  it("does not leak secret-capable stderr through the failure notice", () => {
    const secret = "arbitrary-app-key: visible-secret-value"
    const cardContext = context({
      toolName: "k8s_cluster_kubectl",
      input: { args: ["get", "secret", "app", "-o", "yaml"], allow_secret_output: true },
      resultError: true,
      parsedResult: { ok: false, status: 1, stdout: { text: "" }, stderr: { text: secret } }
    })

    render(<>{kubectlToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("kubectl exited with status 1")).toBeInTheDocument()
    expect(screen.queryByText(/arbitrary-app-key|visible-secret-value/)).not.toBeInTheDocument()
    expect(screen.queryByText("stderr")).not.toBeInTheDocument()
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

    expect(screen.getByText("64.0 KB returned · 4.0 KB omitted")).toBeInTheDocument()
    expect(screen.getByText("64.0 KB returned · 2.0 KB omitted")).toBeInTheDocument()
  })

  it("shows the tail of failed kubectl output", () => {
    const stderr = Array.from({ length: 9 }, (_, index) => `error line ${index + 1}`).join("\n")
    render(
      <>
        {kubectlToolCard.renderExpanded(
          context({ toolName: "k8s_cluster_kubectl", resultError: true, parsedResult: { ok: false, status: 1, stderr: { text: stderr } } })
        )}
      </>
    )

    const preview = screen.getByTestId("text-preview-content")
    expect(preview).not.toHaveTextContent("error line 1")
    expect(preview).toHaveTextContent("error line 9")
  })

  it("summarizes successful action acknowledgements with action, target, scope, and result", () => {
    const cardContext = context({
      toolName: "k8s_cluster_scale_deployment",
      input: { cluster_id: 7, namespace: "default", name: "web", replicas: 5 },
      parsedResult: {
        available: true,
        generated_at: "2026-09-30T12:00:00Z",
        deployment: "web",
        namespace: "default",
        before: { replicas: 2 },
        after: { replicas: 5 }
      }
    })

    expect(scaleDeploymentToolCard.collapsedSummary?.(cardContext)).toBe("Scale deployment default/web in Cluster 7 / default · succeeded")
    render(<>{scaleDeploymentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Set replicas to 5")).toBeInTheDocument()
    expect(screen.getByText("2 replicas")).toBeInTheDocument()
    expect(screen.getByText("5 replicas")).toBeInTheDocument()
    expect(screen.queryByText("Reason")).not.toBeInTheDocument()
    expect(screen.queryByText("Audit")).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByRole("link", { name: "default" })).toHaveAttribute("href", "/k8s_clusters/7?tab=namespaces&namespace=default")
    expect(screen.getByRole("link", { name: "default/web" })).toHaveAttribute("href", "/k8s_clusters/7?tab=deployments&namespace=default&deployment=web")
    expect(screen.getByText("Confirm desired and ready replica counts converge.")).toBeInTheDocument()
  })

  it("renders restart rollout audit evidence from every MCP envelope with links and redaction", () => {
    const payload = redactToolCardValue({
      available: true,
      generated_at: "2026-09-30T12:00:01Z",
      deployment: "web",
      namespace: "payments",
      before: { restarted_at: "2026-09-29T08:15:00Z", bearer_token: "top-secret-value" },
      after: { restarted_at: "2026-09-30T12:00:00Z" }
    })
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    envelopes.forEach((envelope) => {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_restart_rollout")
      const cardContext = context({
        toolName,
        input: { cluster_id: 7, namespace: "payments", name: "web" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      const { unmount } = render(<>{restartRolloutToolCard.renderExpanded(cardContext)}</>)

      expect(screen.getByText("restartedAt=2026-09-29T08:15:00Z")).toBeInTheDocument()
      expect(screen.getByText("restartedAt=2026-09-30T12:00:00Z")).toBeInTheDocument()
      expect(screen.getByText("Generated at 2026-09-30T12:00:01Z")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "payments/web" })).toHaveAttribute("href", "/k8s_clusters/7?tab=deployments&namespace=payments&deployment=web")
      expect(screen.queryByText("top-secret-value")).not.toBeInTheDocument()
      expect(screen.queryByText("[redacted]")).not.toBeInTheDocument()
      unmount()
    })
  })

  it("renders scale deployment changes identically from every agent envelope", () => {
    const payload = redactToolCardValue({
      available: true,
      generated_at: "2026-09-30T12:00:01Z",
      deployment: "api",
      namespace: "payments",
      before: { replicas: 2, bearer_token: "top-secret-value" },
      after: { replicas: 6 }
    })
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    envelopes.forEach((envelope) => {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_scale_deployment")
      const cardContext = context({
        toolName,
        input: { cluster_id: 7, namespace: "payments", name: "api", replicas: 6 },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      const { container, unmount } = render(<>{scaleDeploymentToolCard.renderExpanded(cardContext)}</>)

      expect(scaleDeploymentToolCard.collapsedSummary?.(cardContext)).toBe("Scale deployment payments/api in Cluster 7 / payments · succeeded")
      expect(screen.getByText("Set replicas to 6")).toBeInTheDocument()
      expect(screen.getByText("2 replicas")).toBeInTheDocument()
      expect(screen.getByText("6 replicas")).toBeInTheDocument()
      expect(screen.getByText("Generated at 2026-09-30T12:00:01Z")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
      expect(screen.getByRole("link", { name: "payments" })).toHaveAttribute("href", "/k8s_clusters/7?tab=namespaces&namespace=payments")
      expect(screen.getByRole("link", { name: "payments/api" })).toHaveAttribute("href", "/k8s_clusters/7?tab=deployments&namespace=payments&deployment=api")
      expect(container.querySelector(".grid.gap-2.sm\\:grid-cols-2")).toBeInTheDocument()
      expect(screen.queryByText("top-secret-value")).not.toBeInTheDocument()
      expect(screen.queryByText("[redacted]")).not.toBeInTheDocument()
      unmount()
    })
  })

  it("distinguishes changed and already-at-target scale results", () => {
    const cardContext = context({
      toolName: "k8s_cluster_scale_deployment",
      input: { cluster_id: 7, namespace: "default", name: "web", replicas: 5 },
      parsedResult: {
        available: true,
        deployment: "web",
        namespace: "default",
        before: { replicas: 5 },
        after: { replicas: 5 }
      }
    })

    expect(scaleDeploymentToolCard.collapsedSummary?.(cardContext)).toBe("Scale deployment default/web in Cluster 7 / default · no-op")
    render(<>{scaleDeploymentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("no-op")).toBeInTheDocument()
    expect(screen.getAllByText("5 replicas")).toHaveLength(2)
  })

  it.each([
    ["writes disabled", "Write access is disabled for Kubernetes cluster 7", "Permission error", "permission denied"],
    ["forbidden", 'deployments.apps "web" is forbidden: RBAC denied the request', "Permission error", "permission denied"],
    ["not found", 'deployments.apps "web" not found', "Missing resource", "missing resource"],
    ["validation", "replicas must be a non-negative integer", "Validation failure", "validation failed"]
  ])("renders scale deployment %s failures", (_failureClass, message, title, state) => {
    const cardContext = context({
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_scale_deployment"),
      input: { cluster_id: 7, namespace: "default", name: "web", replicas: 5 },
      resultBody: `Error: ${message}`,
      resultError: true,
      parsedResult: null
    })

    expect(scaleDeploymentToolCard.collapsedSummary?.(cardContext)).toContain(state)
    const { unmount } = render(<>{scaleDeploymentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText(title)).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
    expect(screen.getByText("Set replicas to 5")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "default/web" })).toHaveAttribute("href", "/k8s_clusters/7?tab=deployments&namespace=default&deployment=web")
    unmount()
  })

  it("does not invent replica state for pre-request scale failures", () => {
    const cardContext = context({
      toolName: "k8s_cluster_scale_deployment",
      input: { cluster_id: 7, namespace: "default", name: "web", replicas: -1 },
      resultBody: "Error: replicas must be a non-negative integer",
      resultError: true,
      parsedResult: null
    })

    render(<>{scaleDeploymentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.queryByText("0 replicas")).not.toBeInTheDocument()
    expect(screen.getAllByText("Not available")).toHaveLength(2)
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
    expect(screen.getByText("Write access is disabled for Kubernetes cluster 7")).toBeInTheDocument()
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
          {
            namespace: "default",
            name: "web-1",
            status: "Running",
            ready: "1/1",
            restart_count: 0,
            pod_ip: "10.42.0.8",
            container_names: ["web", "metrics"],
            node_name: "node-1",
            created_at: "2026-09-30T10:00:00Z"
          },
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
    expect(screen.getByText("10.42.0.8")).toBeInTheDocument()
    expect(screen.getByText("web, metrics")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "default" })[0]).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByRole("link", { name: "web-1" })).toHaveAttribute("href", "/k8s_clusters/7?tab=logs&namespace=default&pod=web-1")
    expect(screen.getByRole("link", { name: "node-1" })).toHaveAttribute("href", "/k8s_clusters/7?tab=nodes&namespace=default&node=node-1")
    expect(screen.getByRole("button", { name: "Copy default/web-1 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Showing partial results — the server capped this list.")).toBeInTheDocument()
  })

  it("renders pod describes from every MCP envelope with safe operational details", () => {
    const payload = {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      pod: {
        metadata: {
          namespace: "payments",
          name: "api-1",
          creationTimestamp: "2026-09-30T10:00:00Z",
          labels: { app: "api", owner: "private-team-name" },
          ownerReferences: [{ kind: "ReplicaSet", name: "api-7d9b" }]
        },
        spec: {
          nodeName: "node-2",
          containers: [{ name: "api", image: "example/api:v2", args: ["--token=secret-argument"], env: [{ name: "TOKEN", value: "secret-value" }] }]
        },
        status: {
          phase: "Running",
          podIP: "10.42.0.9",
          podIPs: [{ ip: "10.42.0.9" }, { ip: "fd00::9" }],
          conditions: [{ type: "Ready", status: "False", reason: "ContainersNotReady", message: "container api is not ready" }],
          containerStatuses: [
            {
              name: "api",
              ready: false,
              restartCount: 3,
              state: { waiting: { reason: "CrashLoopBackOff", message: "back-off" } },
              lastState: { terminated: { reason: "Error", message: "secret termination detail" } }
            }
          ]
        }
      }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_pods")
      const cardContext = context({
        toolName,
        input: { cluster_id: 7, namespace: "payments", name: "api-1" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })

      expect(toolName).toBe("k8s_cluster_pods")
      expect(podsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments / api-1 · 1 pods · 1 warning")
      const rendered = render(<>{podsToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByRole("link", { name: "api-1" })).toHaveAttribute("href", "/k8s_clusters/7?tab=logs&namespace=payments&pod=api-1")
      expect(screen.getByRole("button", { name: "Copy payments/api-1 to clipboard" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "node-2" })).toHaveAttribute("href", "/k8s_clusters/7?tab=nodes&namespace=payments&node=node-2")
      expect(screen.getByText("10.42.0.9, fd00::9")).toBeInTheDocument()
      expect(screen.getByText("ReplicaSet/api-7d9b")).toBeInTheDocument()
      expect(screen.getByText("2: app, owner")).toBeInTheDocument()
      expect(screen.getByText("example/api:v2")).toBeInTheDocument()
      expect(screen.getByText("waiting: CrashLoopBackOff")).toBeInTheDocument()
      expect(screen.getByText("Error")).toBeInTheDocument()
      expect(screen.getByText("ContainersNotReady")).toBeInTheDocument()
      expect(screen.getByText("container api is not ready")).toBeInTheDocument()
      expect(screen.queryByText(/private-team-name|secret-value|secret-argument|secret termination detail/)).not.toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders pod lists identically from every MCP envelope", () => {
    const payload = {
      available: true,
      pods: [
        {
          namespace: "default",
          name: "web-envelope-1",
          status: "Running",
          ready: "2/2",
          restart_count: 0,
          pod_ip: "10.42.0.10",
          container_names: ["web", "metrics"],
          node_name: "node-envelope-1"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_pods")
      const cardContext = context({ toolName, input: { cluster_id: 7 }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{podsToolCard.renderExpanded(cardContext)}</>)

      expect(podsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 · 1 pods")
      expect(screen.getByRole("link", { name: "web-envelope-1" })).toHaveAttribute("href", "/k8s_clusters/7?tab=logs&namespace=default&pod=web-envelope-1")
      expect(screen.getByText("10.42.0.10")).toBeInTheDocument()
      expect(screen.getByText("web, metrics")).toBeInTheDocument()
      rendered.unmount()
    }
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
                  volume_name: "pvc-1234",
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
    expect(screen.getAllByText("2026-09-30T12:00:00Z").length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Copy node-1 to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByText("default").length).toBeGreaterThan(0)
    expect(screen.getByText("ReadWriteOnce")).toBeInTheDocument()
    expect(screen.getByText("pvc-1234")).toBeInTheDocument()
    expect(screen.getByText("FailedScheduling")).toBeInTheDocument()
    expect(screen.getByText("Pod / web-1")).toBeInTheDocument()
  })

  it("renders PVC lists identically from every MCP envelope with volume names", () => {
    const payload = {
      available: true,
      persistent_volume_claims: [
        {
          namespace: "payments",
          name: "database",
          status: "Bound",
          capacity: "20Gi",
          storage_class: "fast",
          access_modes: ["ReadWriteOnce"],
          volume_name: "pvc-envelope-1234",
          created_at: "2026-09-01T00:00:00Z"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_pvcs")
      const cardContext = context({ toolName, input: { cluster_id: 7, namespace: "payments" }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{pvcsToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_pvcs")
      expect(pvcsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments · 1 PVCs")
      expect(screen.getByRole("columnheader", { name: "Volume name" })).toBeInTheDocument()
      expect(screen.getByText("pvc-envelope-1234")).toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders complete event details from every MCP envelope with linked objects, timestamps, filtering, and redaction", () => {
    const longMessage = `Failed to pull image from the configured registry. ${"Retrying after an authentication failure. ".repeat(12)}`
    const payload = {
      available: true,
      events: [
        {
          namespace: "payments",
          name: "web-pull-failure.1234",
          type: "Warning",
          reason: "Failed",
          message: longMessage,
          involved_object: { kind: "Pod", name: "web-1", uid: "private-object-uid" },
          count: 4,
          first_timestamp: "2026-09-30T11:00:00Z",
          last_timestamp: "2026-09-30T12:00:00Z",
          secret_token: "must-not-render"
        },
        {
          namespace: "payments",
          name: "web-scheduled.5678",
          type: "Normal",
          reason: "Scheduled",
          message: "Assigned payments/web-1 to node-1",
          involved_object: { kind: "Deployment", name: "web" },
          count: 1,
          first_timestamp: "2026-09-30T10:00:00Z",
          last_timestamp: "2026-09-30T10:01:00Z"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_events")
      const cardContext = context({ toolName, input: { cluster_id: 7, namespace: "payments" }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{eventsToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_events")
      expect(eventsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments · 2 events · 1 warning")
      expect(screen.getByText("web-pull-failure.1234")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Pod / web-1" })).toHaveAttribute("href", "/k8s_clusters/7?tab=pods&namespace=payments&pod=web-1")
      expect(screen.getByRole("link", { name: "Deployment / web" })).toHaveAttribute(
        "href",
        "/k8s_clusters/7?tab=deployments&namespace=payments&deployment=web"
      )
      expect(screen.getByText("2026-09-30T11:00:00Z")).toBeInTheDocument()
      expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
      expect(screen.queryByText(/private-object-uid|must-not-render/)).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Warnings only" }))
      expect(screen.getByText("1 of 2 events")).toBeInTheDocument()
      expect(screen.queryByText("web-scheduled.5678")).not.toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("preserves each event namespace in cluster-wide mixed-namespace results", () => {
    const cardContext = context({
      toolName: "k8s_cluster_events",
      input: { cluster_id: 7 },
      parsedResult: {
        available: true,
        events: [
          { namespace: "payments", name: "payment-event", type: "Warning", reason: "Failed", message: "Payment failed" },
          { namespace: "shipping", name: "shipping-event", type: "Normal", reason: "Scheduled", message: "Shipping scheduled" }
        ]
      }
    })

    render(<>{eventsToolCard.renderExpanded(cardContext)}</>)

    expect(eventsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 · 2 events · 1 warning")
    expect(screen.getByText("payments")).toBeInTheDocument()
    expect(screen.getByText("shipping")).toBeInTheDocument()
  })

  it("renders PVC describes from every MCP envelope with safe operational details", () => {
    const payload = {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      persistent_volume_claim: {
        metadata: {
          namespace: "payments",
          name: "database",
          creationTimestamp: "2026-09-01T00:00:00Z",
          annotations: { "example.test/token": "secret-annotation-value" }
        },
        spec: {
          storageClassName: "fast",
          accessModes: ["ReadWriteOnce"],
          resources: { requests: { storage: "10Gi" } },
          volumeName: "pvc-5678"
        },
        status: {
          phase: "Bound",
          capacity: { storage: "20Gi" },
          conditions: [{ type: "Resizing", status: "False", reason: "ExpansionComplete", message: "volume expansion completed" }]
        }
      }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_pvcs")
      const cardContext = context({
        toolName,
        input: { cluster_id: 7, namespace: "payments", name: "database" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })

      expect(pvcsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments / database · 1 PVCs")
      const rendered = render(<>{pvcsToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByRole("button", { name: "Copy payments/database to clipboard" })).toBeInTheDocument()
      expect(screen.getByText("Bound")).toBeInTheDocument()
      expect(screen.getByText("fast")).toBeInTheDocument()
      expect(screen.getByText("ReadWriteOnce")).toBeInTheDocument()
      expect(screen.getByText("10Gi")).toBeInTheDocument()
      expect(screen.getByText("20Gi")).toBeInTheDocument()
      expect(screen.getByText("pvc-5678")).toBeInTheDocument()
      expect(screen.getByText("ExpansionComplete")).toBeInTheDocument()
      expect(screen.getByText("volume expansion completed")).toBeInTheDocument()
      expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
      expect(screen.queryByText("secret-annotation-value")).not.toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders PVC empty and error states with their input scope", () => {
    const empty = render(
      <>
        {pvcsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_pvcs",
            input: { cluster_id: 7, namespace: "payments" },
            parsedResult: { available: true, persistent_volume_claims: [] }
          })
        )}
      </>
    )
    expect(screen.getByText("No PVCs returned.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "payments" })).toHaveAttribute("href", "/k8s_clusters/7")
    empty.unmount()

    render(
      <>
        {pvcsToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_pvcs",
            input: { cluster_id: 7, namespace: "payments", name: "missing" },
            resultBody: "Error: Persistent volume claim not found",
            resultError: true,
            parsedResult: null
          })
        )}
      </>
    )
    expect(screen.getByText("Persistent volume claim not found")).toBeInTheDocument()
    expect(screen.getByText("missing")).toBeInTheDocument()
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

  it("renders overview section availability, reason, totals, and generated time", () => {
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
    expect(screen.getByText("Unavailable")).toBeInTheDocument()
    expect(screen.getByText("Reason")).toBeInTheDocument()
    expect(screen.getByText("metrics_unavailable")).toBeInTheDocument()
    expect(screen.getAllByText("125m").length).toBeGreaterThan(0)
    expect(screen.getAllByText("256.0 MB").length).toBeGreaterThan(0)
    expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
  })

  it("renders overview empty and error states with the requested cluster scope", () => {
    const empty = render(
      <>
        {overviewToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_overview",
            input: { cluster_id: 7 },
            parsedResult: {
              generated_at: "2026-09-30T12:00:00Z",
              nodes: { available: true, items: [], total_cpu_millicores: 0, total_memory_bytes: 0 },
              pods: { available: true, items: [], total_cpu_millicores: 0, total_memory_bytes: 0 }
            }
          })
        )}
      </>
    )
    expect(screen.getAllByText("No items returned.")).toHaveLength(2)
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
    expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
    empty.unmount()

    render(
      <>
        {overviewToolCard.renderExpanded(
          context({
            toolName: "k8s_cluster_overview",
            input: { cluster_id: 7 },
            resultBody: "Error: Kubernetes API unavailable",
            resultError: true,
            parsedResult: null
          })
        )}
      </>
    )
    expect(screen.getByText("Kubernetes API unavailable")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cluster 7" })).toHaveAttribute("href", "/k8s_clusters/7")
  })

  it("renders filterable, linked, responsive overview metrics from every MCP envelope and can show all rows", () => {
    const pods = Array.from({ length: 101 }, (_, index) => ({
      namespace: index === 100 ? "payments" : "default",
      name: `web-${index + 1}`,
      cpu_millicores: index === 100 ? 1500 : 125,
      memory_bytes: index === 100 ? 1_073_741_824 : 268_435_456,
      private_token: "must-not-render"
    }))
    const payload = {
      generated_at: "2026-09-30T12:00:00Z",
      nodes: {
        available: true,
        items: [{ name: "node-a", cpu_millicores: 2250, memory_bytes: 8_589_934_592, private_token: "must-not-render" }],
        total_cpu_millicores: 2250,
        total_memory_bytes: 8_589_934_592
      },
      pods: { available: true, items: pods, total_cpu_millicores: 14_000, total_memory_bytes: 27_917_287_424 }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_overview")
      const cardContext = context({ toolName, input: { cluster_id: 7 }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{overviewToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_overview")
      expect(screen.getByRole("link", { name: "node-a" })).toHaveAttribute("href", "/k8s_clusters/7?tab=nodes&node=node-a")
      expect(screen.queryByRole("link", { name: "web-101" })).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Show all 101 rows" })).toBeInTheDocument()
      expect(screen.getAllByPlaceholderText("Filter resources")).toHaveLength(2)
      expect(screen.getAllByText("2.25 vCPU").length).toBeGreaterThan(0)
      expect(screen.getAllByText("8.0 GB").length).toBeGreaterThan(0)
      expect(screen.queryByText(/must-not-render/)).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Show all 101 rows" }))
      expect(screen.getByRole("link", { name: "payments" })).toHaveAttribute("href", "/k8s_clusters/7?tab=pods&namespace=payments")
      expect(screen.getByRole("link", { name: "web-101" })).toHaveAttribute("href", "/k8s_clusters/7?tab=pods&namespace=payments&pod=web-101")

      fireEvent.change(screen.getAllByPlaceholderText("Filter resources")[1], { target: { value: "payments" } })
      expect(screen.getByText("1 of 101")).toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "web-1" })).not.toBeInTheDocument()
      expect(screen.getByRole("link", { name: "web-101" })).toBeInTheDocument()

      const responsiveBody = screen.getByRole("link", { name: "web-101" }).closest("tbody")
      expect(responsiveBody).toHaveClass("block")
      expect(responsiveBody).toHaveClass("sm:table-row-group")
      rendered.unmount()
    }
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
                  external_ips: ["203.0.113.10", "2001:db8::10"],
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
                  load_balancer_addresses: ["203.0.113.30"],
                  created_at: "2026-09-01T00:00:00Z"
                }
              ]
            }
          })
        )}
      </>
    )

    expect(screen.getByText("80/TCP -> 8080")).toBeInTheDocument()
    expect(screen.getByText("203.0.113.10, 2001:db8::10")).toBeInTheDocument()
    expect(screen.getByText("No ready targets")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy default to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy default/web to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "app.example.test" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "app.example.test" })[0]).toHaveAttribute("href", "https://app.example.test")
    expect(screen.getAllByRole("link", { name: "app.example.test" })[0]).toHaveAttribute("rel", "noopener noreferrer")
    expect(screen.getByText("app.example.test/")).toBeInTheDocument()
    expect(screen.getByText("(Prefix)")).toBeInTheDocument()
    expect(screen.getByText("→ web:80")).toBeInTheDocument()
    expect(screen.getByText("nginx")).toBeInTheDocument()
    expect(screen.getByText("203.0.113.30")).toBeInTheDocument()
  })

  it("renders service fields identically from every MCP envelope without exposing unrelated sensitive values", () => {
    const payload = {
      available: true,
      services: [
        {
          namespace: "payments",
          name: "api",
          type: "LoadBalancer",
          cluster_ip: "10.0.0.20",
          external_ips: ["203.0.113.20"],
          ports: [{ name: "https", port: 443, target_port: "http", protocol: "TCP" }],
          selector: { app: "api", tier: "frontend" },
          ready_addresses: 1,
          not_ready_addresses: 1,
          missing_target_warning: false,
          private_token: "must-not-render"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_services")
      const cardContext = context({ toolName, input: { cluster_id: 7 }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{servicesToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_services")
      expect(servicesToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 · 1 services · 1 warning")
      expect(screen.getByText("LoadBalancer")).toBeInTheDocument()
      expect(screen.getByText("10.0.0.20")).toBeInTheDocument()
      expect(screen.getByText("203.0.113.20")).toBeInTheDocument()
      expect(screen.getByText("443/TCP -> http")).toBeInTheDocument()
      expect(screen.getByText("app=api, tier=frontend")).toBeInTheDocument()
      expect(screen.getByText("1/2 ready")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Copy payments/api to clipboard" })).toBeInTheDocument()
      expect(screen.queryByText(/must-not-render/)).not.toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders service empty and error states with their requested scope", () => {
    const emptyContext = context({
      toolName: "k8s_cluster_services",
      input: { cluster_id: 7, namespace: "payments" },
      parsedResult: { available: true, services: [] }
    })
    const empty = render(<>{servicesToolCard.renderExpanded(emptyContext)}</>)
    expect(servicesToolCard.collapsedSummary?.(emptyContext)).toBe("Cluster 7 / payments · 0 services")
    expect(screen.getByText("No services returned.")).toBeInTheDocument()
    empty.unmount()

    const errorContext = context({
      toolName: "k8s_cluster_services",
      input: { cluster_id: 7, namespace: "payments", name: "api" },
      resultBody: "Error: Kubernetes API unavailable",
      resultError: true,
      parsedResult: null
    })
    render(<>{servicesToolCard.renderExpanded(errorContext)}</>)
    expect(servicesToolCard.collapsedSummary?.(errorContext)).toBe("Cluster 7 / payments / api · error")
    expect(screen.getByText("Kubernetes API unavailable")).toBeInTheDocument()
    expect(screen.getByText("api")).toBeInTheDocument()
  })

  it("renders ingress mappings identically from every MCP envelope without exposing unrelated sensitive values", () => {
    const payload = {
      available: true,
      ingresses: [
        {
          namespace: "payments",
          name: "api",
          ingress_class: "nginx",
          hosts: ["api.example.test"],
          rules: [
            {
              host: "api.example.test",
              paths: [
                { path: "/v1", path_type: "Prefix", service_name: "api-v1", service_port: "http" },
                { path: "/health", path_type: "Exact", service_name: "health", service_port: 8080 }
              ]
            }
          ],
          tls_hosts: ["api.example.test"],
          load_balancer_addresses: ["lb.example.test"],
          private_token: "must-not-render"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_ingresses")
      const cardContext = context({ toolName, input: { cluster_id: 7, namespace: "payments" }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{ingressesToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_ingresses")
      expect(screen.getByText("api.example.test/v1")).toBeInTheDocument()
      expect(screen.getByText("(Prefix)")).toBeInTheDocument()
      expect(screen.getByText("→ api-v1:http")).toBeInTheDocument()
      expect(screen.getByText("api.example.test/health")).toBeInTheDocument()
      expect(screen.getByText("(Exact)")).toBeInTheDocument()
      expect(screen.getByText("→ health:8080")).toBeInTheDocument()
      expect(screen.getByText("lb.example.test")).toBeInTheDocument()
      expect(screen.queryByText(/must-not-render/)).not.toBeInTheDocument()
      expect(screen.getByRole("table")).toHaveClass("block", "sm:table", "min-w-0", "sm:min-w-max")
      expect(screen.getByRole("columnheader", { name: "Backend" }).closest("thead")).toHaveClass("hidden", "sm:table-header-group")
      const backendCell = screen.getByText("→ api-v1:http").closest("td")
      expect(backendCell).toHaveAttribute("data-label", "Backend")
      expect(backendCell).toHaveClass("grid", "sm:table-cell", "max-w-none", "sm:max-w-80")
      expect(backendCell).toHaveTextContent("Backendapi.example.test/v1 (Prefix)→ api-v1:http")
      expect(screen.getByText("api.example.test/v1").parentElement?.parentElement).toHaveClass("min-w-0", "sm:min-w-56")
      rendered.unmount()
    }
  })

  it("renders ingress empty and error states with their requested scope", () => {
    const emptyContext = context({
      toolName: "k8s_cluster_ingresses",
      input: { cluster_id: 7, namespace: "payments" },
      parsedResult: { available: true, ingresses: [] }
    })
    const empty = render(<>{ingressesToolCard.renderExpanded(emptyContext)}</>)
    expect(ingressesToolCard.collapsedSummary?.(emptyContext)).toBe("Cluster 7 / payments · 0 ingresses")
    expect(screen.getByText("No ingresses returned.")).toBeInTheDocument()
    empty.unmount()

    const errorContext = context({
      toolName: "k8s_cluster_ingresses",
      input: { cluster_id: 7, namespace: "payments", name: "api" },
      resultBody: "Error: Kubernetes API unavailable",
      resultError: true,
      parsedResult: null
    })
    render(<>{ingressesToolCard.renderExpanded(errorContext)}</>)
    expect(ingressesToolCard.collapsedSummary?.(errorContext)).toBe("Cluster 7 / payments / api · error")
    expect(screen.getByText("Kubernetes API unavailable")).toBeInTheDocument()
  })

  it("normalizes describe-shaped service ports and external IPs", () => {
    const cardContext = context({
      toolName: "k8s_cluster_services",
      input: { cluster_id: 7, namespace: "payments", name: "api" },
      parsedResult: {
        available: true,
        service: {
          metadata: { namespace: "payments", name: "api", creationTimestamp: "2026-09-01T00:00:00Z" },
          spec: {
            type: "LoadBalancer",
            clusterIP: "10.0.0.20",
            externalIPs: ["203.0.113.20"],
            ports: [{ name: "https", port: 443, targetPort: "http", protocol: "TCP" }],
            selector: { app: "api" }
          }
        }
      }
    })

    expect(servicesToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments / api · 1 services")
    render(<>{servicesToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("443/TCP -> http")).toBeInTheDocument()
    expect(screen.getByText("203.0.113.20")).toBeInTheDocument()
    expect(screen.getByText("10.0.0.20")).toBeInTheDocument()
    expect(screen.getByText("app=api")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy payments/api to clipboard" })).toBeInTheDocument()
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

    expect(screen.getByText("app.example.test/")).toBeInTheDocument()
    expect(screen.getByText("→ web:80")).toBeInTheDocument()
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

  it("renders responsive ConfigMap key listings from every MCP envelope", () => {
    const payload = {
      available: true,
      config_maps: [
        {
          namespace: "payments",
          name: "api-config",
          key_count: 3,
          key_names: ["api-token.txt", "LOG_LEVEL", "tls.crt"],
          created_at: "2026-09-01T00:00:00Z"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_configmaps")
      const cardContext = context({ toolName, input: { cluster_id: 7, namespace: "payments" }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{configMapsToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_configmaps")
      expect(configMapsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments · 1 ConfigMaps")
      expect(screen.getByText("api-token.txt, LOG_LEVEL, tls.crt")).toBeInTheDocument()
      expect(screen.getByRole("table")).toHaveClass("block", "sm:table", "min-w-0", "sm:min-w-max")
      expect(screen.getByText("api-token.txt, LOG_LEVEL, tls.crt").closest("td")).toHaveAttribute("data-label", "Key names")
      rendered.unmount()
    }
  })

  it("renders metadata-only Secret list results from every MCP envelope", () => {
    const payload = {
      available: true,
      secrets: [
        {
          namespace: "payments",
          name: "api-secret",
          type: "kubernetes.io/tls",
          key_count: 2,
          key_names: ["PASSWORD", "TLS_TOKEN"],
          immutable: true,
          owner_references: ["Deployment/api"],
          created_at: "2026-09-01T00:00:00Z"
        }
      ]
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_secrets")
      const cardContext = context({ toolName, input: { cluster_id: 7, namespace: "payments" }, parsedResult: normalizedToolCardParsedResult(envelope) })
      const rendered = render(<>{secretsToolCard.renderExpanded(cardContext)}</>)

      expect(toolName).toBe("k8s_cluster_secrets")
      expect(screen.getByText("PASSWORD, TLS_TOKEN")).toBeInTheDocument()
      expect(screen.getByText("kubernetes.io/tls")).toBeInTheDocument()
      expect(screen.getByText("Deployment/api")).toBeInTheDocument()
      expect(screen.getByRole("table")).toHaveClass("block", "sm:table", "min-w-0", "sm:min-w-max")
      rendered.unmount()
    }
  })

  it("renders redaction-safe Secret describe metadata without mangling key names", () => {
    const payload = redactToolCardValue({
      available: true,
      secret: {
        name: "api-secret",
        namespace: "payments",
        type: "Opaque",
        key_count: 2,
        key_names: ["DATABASE_PASSWORD", "SERVICE_TOKEN"],
        immutable: false,
        owner_references: ["Deployment/api"],
        created_at: "2026-09-01T00:00:00Z"
      }
    })
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const cardContext = context({
        toolName: normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_secrets"),
        input: { cluster_id: 7, namespace: "payments", name: "api-secret" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      const rendered = render(<>{secretsToolCard.renderExpanded(cardContext)}</>)

      expect(screen.getByText("DATABASE_PASSWORD, SERVICE_TOKEN")).toBeInTheDocument()
      expect(screen.getByText("Opaque")).toBeInTheDocument()
      expect(screen.getByText("Deployment/api")).toBeInTheDocument()
      expect(screen.getByText("No")).toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("never renders or indexes raw Secret values", () => {
    const cardContext = context({
      toolName: "k8s_cluster_secrets",
      parsedResult: {
        available: true,
        secrets: [
          {
            metadata: { namespace: "payments", name: "api-secret", creationTimestamp: "2026-09-01T00:00:00Z" },
            type: "Opaque",
            data: { password: "hunter2" }
          }
        ]
      }
    })
    const rendered = render(<>{secretsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.queryByText("hunter2")).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Filter resources"), { target: { value: "hunter2" } })
    expect(screen.getByText("0 of 1")).toBeInTheDocument()
    expect(screen.queryByText("hunter2")).not.toBeInTheDocument()
    rendered.unmount()
  })

  it("safely describes ConfigMap text and binary keys from every MCP envelope", () => {
    const payload = {
      available: true,
      config_map: {
        metadata: { name: "api-config", namespace: "payments", creationTimestamp: "2026-09-01T00:00:00Z" },
        data: {
          "api-token.txt": "password=hunter2\nmode=production",
          "public-url": "https://example.test/" + "x".repeat(5_000)
        },
        binaryData: { "logo.bin": "AAECAwQ=", "malformed.bin": "bad!" }
      }
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_configmaps")
      const cardContext = context({
        toolName,
        input: { cluster_id: 7, namespace: "payments", name: "api-config" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      const rendered = render(<>{configMapsToolCard.renderExpanded(cardContext)}</>)

      expect(configMapsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / payments / api-config · 1 ConfigMaps")
      expect(screen.getByText("api-token.txt")).toBeInTheDocument()
      expect(screen.getByText(/password=\[redacted\]/)).toBeInTheDocument()
      expect(screen.queryByText(/hunter2/)).not.toBeInTheDocument()
      expect(screen.getByText("logo.bin")).toBeInTheDocument()
      expect(screen.getByText("5 B")).toBeInTheDocument()
      expect(screen.getByText("malformed.bin")).toBeInTheDocument()
      expect(screen.getByText("4 B")).toBeInTheDocument()
      expect(screen.getAllByText("binary")).toHaveLength(2)
      expect(screen.getAllByText("Binary value is not previewed.")).toHaveLength(2)
      expect(screen.getByText("Displayed value capped at 4.0 KB.")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("renders ConfigMap empty and error states with requested input scope", () => {
    const emptyContext = context({
      toolName: "k8s_cluster_configmaps",
      input: { cluster_id: 7, namespace: "payments" },
      parsedResult: { available: true, config_maps: [] }
    })
    const empty = render(<>{configMapsToolCard.renderExpanded(emptyContext)}</>)
    expect(configMapsToolCard.collapsedSummary?.(emptyContext)).toBe("Cluster 7 / payments · 0 ConfigMaps")
    expect(screen.getByText("No ConfigMaps returned.")).toBeInTheDocument()
    empty.unmount()

    const errorContext = context({
      toolName: "k8s_cluster_configmaps",
      input: { cluster_id: 7, namespace: "payments", name: "api-config" },
      resultBody: "Error: Kubernetes API unavailable",
      resultError: true,
      parsedResult: null
    })
    render(<>{configMapsToolCard.renderExpanded(errorContext)}</>)
    expect(configMapsToolCard.collapsedSummary?.(errorContext)).toBe("Cluster 7 / payments / api-config · error")
    expect(screen.getByText("Kubernetes API unavailable")).toBeInTheDocument()
  })

  it("renders redacted tail-first pod logs and all metadata from every MCP envelope", () => {
    const payload = {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      pod: "web-1",
      namespace: "result-namespace",
      container: "web",
      log: [
        "first line",
        ...Array.from({ length: 79 }, (_, index) => `middle line ${index}`),
        "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
        "API_KEY=top-secret-value",
        "DATABASE_URL=https://db-user:db-password@example.test/app",
        "final line"
      ].join("\n")
    }
    const envelopes = [
      { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__syrus-chat-sidecar__k8s_cluster_pod_logs")
      const cardContext = context({
        toolName,
        input: { cluster_id: 7, namespace: "default", name: "web-1", container: "web", previous: true, timestamps: true, tail_lines: 200 },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })

      expect(toolName).toBe("k8s_cluster_pod_logs")
      expect(podLogsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / default / web-1 · 84 log lines")
      const rendered = render(<>{podLogsToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByLabelText("Search logs…")).toBeInTheDocument()
      expect(screen.getByText("result-namespace")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "web-1" })).toHaveAttribute("href", "/k8s_clusters/7?tab=logs&namespace=result-namespace&pod=web-1")
      expect(screen.getByRole("button", { name: "Copy result-namespace/web-1 to clipboard" })).toBeInTheDocument()
      expect(screen.getByText("200")).toBeInTheDocument()
      expect(screen.getByText("84")).toBeInTheDocument()
      expect(screen.getAllByText("Yes")).toHaveLength(2)
      expect(screen.getByText("2026-09-30T12:00:00Z")).toBeInTheDocument()
      expect(screen.getByTestId("text-preview-content")).toHaveClass("overflow-x-auto", "whitespace-pre")
      expect(screen.getByTestId("text-preview-content")).toHaveTextContent("final line")
      expect(screen.getByTestId("text-preview-content")).not.toHaveTextContent("first line")
      expect(screen.getByText(/Bearer \[redacted\]/)).toBeInTheDocument()
      expect(screen.getByTestId("text-preview-content").textContent?.match(/\[redacted\]/g)).toHaveLength(3)
      expect(screen.queryByText(/top-secret-value|db-password|abcdefghijklmnopqrstuvwxyz/)).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
      fireEvent.change(screen.getByLabelText("Search logs…"), { target: { value: "final line" } })
      expect(screen.getByTestId("text-preview-content")).toHaveTextContent("final line")
      expect(screen.getByTestId("text-preview-content")).not.toHaveTextContent("middle line")
      fireEvent.click(screen.getByRole("button", { name: "Show more" }))
      const dialog = screen.getByRole("dialog", { name: "Full pod log" })
      expect(within(dialog).getByText(/first line/)).toBeInTheDocument()
      expect(within(dialog).getByText(/final line/)).toBeInTheDocument()
      rendered.unmount()
    }
  })

  it("keeps pod-log empty and error states friendly", () => {
    const emptyContext = context({
      toolName: "k8s_cluster_pod_logs",
      input: { cluster_id: 7, namespace: "default", name: "web-1", tail_lines: 50 },
      parsedResult: { available: true, pod: "web-1", namespace: "default", log: "" }
    })
    const empty = render(<>{podLogsToolCard.renderExpanded(emptyContext)}</>)
    expect(screen.getByText("No log output.")).toBeInTheDocument()
    empty.unmount()

    const errorContext = context({
      toolName: "k8s_cluster_pod_logs",
      input: { cluster_id: 7, namespace: "default", name: "missing" },
      resultBody: "Error: pod not found",
      resultError: true,
      parsedResult: null
    })
    render(<>{podLogsToolCard.renderExpanded(errorContext)}</>)
    expect(podLogsToolCard.collapsedSummary?.(errorContext)).toBe("Cluster 7 / default / missing · error")
    expect(screen.getByText("pod not found")).toBeInTheDocument()
  })

  it("does not count a terminal log newline as a returned line", () => {
    const cardContext = context({
      toolName: "k8s_cluster_pod_logs",
      input: { cluster_id: 7, namespace: "default", name: "web-1", tail_lines: 50 },
      parsedResult: { available: true, pod: "web-1", namespace: "default", log: "first\n\nthird\n" }
    })
    expect(podLogsToolCard.collapsedSummary?.(cardContext)).toBe("Cluster 7 / default / web-1 · 3 log lines")
    render(<>{podLogsToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("first\n\nthird", { normalizeWhitespace: false })
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
