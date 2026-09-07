import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

const GENERATED_AT = "2026-01-01T00:00:00Z"
const CLUSTER_LABEL = "Home lab"

const KUBECONFIG = `apiVersion: v1
kind: Config
current-context: e2e
contexts:
  - name: e2e
    context:
      cluster: e2e-cluster
      user: e2e-user
clusters:
  - name: e2e-cluster
    cluster:
      server: https://k8s.e2e.example.internal:6443
users:
  - name: e2e-user
    user:
      token: fake-e2e-token
`

const RESOURCE_PATH = /\/api\/v1\/app\/admin\/kubernetes_clusters\/\d+\/(namespaces|pods|nodes|overview)$/

// There is no reachable external Kubernetes API server in the preview
// sandbox, so route interception stands in for one -- creating/editing a
// cluster only ever parses the pasted kubeconfig locally (no live
// connection attempt), but browsing a cluster's namespaces/pods/nodes hits
// the real backend, which in turn would try to reach the (fake) cluster
// API server. Intercepting those resource endpoints lets this spec exercise
// the real "register cluster -> browse -> view read-only resources" path.
async function mockClusterResources(page: Page) {
  await page.route((url) => RESOURCE_PATH.test(url.pathname), async (route) => {
    const path = new URL(route.request().url()).pathname

    if (path.endsWith("/namespaces")) {
      await route.fulfill({
        json: {
          available: true,
          generated_at: GENERATED_AT,
          truncated: false,
          namespaces: [
            { name: "default", status: "Active", created_at: GENERATED_AT },
            { name: "kube-system", status: "Active", created_at: GENERATED_AT }
          ]
        }
      })
      return
    }

    if (path.endsWith("/nodes")) {
      await route.fulfill({
        json: {
          available: true,
          generated_at: GENERATED_AT,
          truncated: false,
          nodes: [
            {
              name: "node-1",
              ready: true,
              roles: [ "control-plane" ],
              kubelet_version: "v1.29.0",
              internal_ip: "10.0.0.1",
              capacity_cpu: "4",
              capacity_memory: "16Gi",
              allocatable_cpu: "3800m",
              allocatable_memory: "15Gi",
              created_at: GENERATED_AT
            }
          ]
        }
      })
      return
    }

    if (path.endsWith("/overview")) {
      await route.fulfill({
        json: {
          generated_at: GENERATED_AT,
          nodes: { available: false, reason: "metrics_unavailable", message: "metrics-server not installed" },
          pods: { available: false, reason: "metrics_unavailable", message: "metrics-server not installed" }
        }
      })
      return
    }

    if (path.endsWith("/pods")) {
      await route.fulfill({
        json: {
          available: true,
          generated_at: GENERATED_AT,
          truncated: false,
          pods: [
            {
              name: "web-6f8d9c-abc12",
              namespace: "default",
              status: "Running",
              pod_ip: "10.0.0.5",
              node_name: "node-1",
              ready: "1/1",
              restart_count: 0,
              container_names: [ "web" ],
              created_at: GENERATED_AT
            }
          ]
        }
      })
      return
    }

    await route.continue()
  })
}

const WRITE_ACTION_BUTTON = /scale|restart rollout|cordon|delete pod|uncordon/i

test("K8s Cluster Viewer registers a cluster and browses it read-only, with no write-action controls", async ({ page }) => {
  await signInAsDemo(page)
  await mockClusterResources(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", { hasText: "Kubernetes Cluster Viewer" })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
  }

  await page.goto("/k8s_clusters")
  await expect(page.getByRole("heading", { name: "Kubernetes Clusters" })).toBeVisible()
  await expect(page.getByText("No clusters yet. Add one to get started.")).toBeVisible()

  await page.getByLabel("Label", { exact: true }).fill(CLUSTER_LABEL)
  await page.getByLabel("Kubeconfig", { exact: true }).fill(KUBECONFIG)
  await page.getByRole("button", { name: "Add cluster", exact: true }).click()

  const clusterRow = page.getByRole("row", { name: new RegExp(CLUSTER_LABEL) })
  await expect(clusterRow).toBeVisible()
  await expect(clusterRow.getByText("Read-only")).toBeVisible()
  await expect(clusterRow.getByText("Bearer token")).toBeVisible()

  // Read-only-by-default posture: no scale/restart/cordon controls exist in
  // the admin cluster list, before a cluster is even browsed.
  await expect(page.getByRole("button", { name: WRITE_ACTION_BUTTON })).toHaveCount(0)

  await clusterRow.getByRole("button", { name: "Browse" }).click()
  await expect(page.getByRole("heading", { name: `Browsing ${CLUSTER_LABEL}` })).toBeVisible()

  // Overview tab (the default view) shows node count and metrics read-only.
  await expect(page.getByText("1/1 ready")).toBeVisible()
  await expect(page.getByRole("button", { name: WRITE_ACTION_BUTTON })).toHaveCount(0)

  await page.getByRole("button", { name: "Cluster view" }).click()
  await page.getByRole("option", { name: "Workloads" }).click()
  await expect(page.getByRole("cell", { name: "web-6f8d9c-abc12" })).toBeVisible()
  await expect(page.getByRole("cell", { name: "Running" })).toBeVisible()
  await expect(page.getByRole("button", { name: WRITE_ACTION_BUTTON })).toHaveCount(0)

  const namespacePicker = page.getByRole("button", { name: "Namespace" })
  await expect(namespacePicker).toBeVisible()
  await namespacePicker.click()
  await expect(page.getByRole("option", { name: "default" })).toBeVisible()
  await expect(page.getByRole("option", { name: "kube-system" })).toBeVisible()

  await page.getByRole("button", { name: "Cluster view" }).click()
  await page.getByRole("option", { name: "Nodes", exact: true }).click()
  await expect(page.getByRole("cell", { name: "node-1" })).toBeVisible()
  await expect(page.getByRole("cell", { name: "control-plane" })).toBeVisible()
  await expect(page.getByRole("button", { name: WRITE_ACTION_BUTTON })).toHaveCount(0)

  // Enabling "Allow write actions" on the cluster does not unlock any write
  // controls in this read-only admin UI -- allow_writes only gates the
  // separate agentic MCP tool set, never the web browser.
  await page.getByRole("button", { name: "Back to clusters" }).click()
  await clusterRow.getByRole("button", { name: "Edit" }).click()
  await clusterRow.getByLabel("Allow write actions").check()
  await clusterRow.getByRole("button", { name: "Save", exact: true }).click()
  await expect(clusterRow.getByText("Read-write")).toBeVisible()

  await clusterRow.getByRole("button", { name: "Browse" }).click()
  await expect(page.getByRole("heading", { name: `Browsing ${CLUSTER_LABEL}` })).toBeVisible()
  await expect(page.getByRole("button", { name: WRITE_ACTION_BUTTON })).toHaveCount(0)
})
