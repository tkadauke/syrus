# K8s Cluster Viewer

K8s Cluster Viewer lets admins register external Kubernetes/k3s clusters, parsed from a pasted kubeconfig, with encrypted credential storage, and browse them read-only from a tabbed sidebar UI. Read-only cluster inspection is also available to the Syrus agent as MCP tools, gated per-cluster via `agentic_access_enabled`. A short, explicit allowlist of write/mutating MCP tools (restart a deployment rollout, scale a deployment, delete a pod, cordon/uncordon a node) is additionally gated per-cluster via a separate `allow_writes` opt-in, per EPIC-306 / DOC-21 phase 2.

## What It Adds

- Admin UI and API endpoints for Kubernetes/k3s cluster connection management.
- A kubeconfig parser that resolves the current-context's cluster/user and extracts only the connection info Syrus needs (server URL, bearer token or client-certificate/key, CA data).
- A lightweight connection test (`GET /version`) before saving.
- A `kubeclient`-backed API client and one read-only service per resource kind (namespaces, pods, deployments, services, events, PersistentVolumeClaims, nodes, CronJobs), plus a `metrics.k8s.io`-backed cluster overview that soft-fails when metrics-server isn't installed.
- Admin-only JSON API endpoints for all of the above under `/api/v1/app/admin/kubernetes_clusters/:id/...`.
- A tabbed cluster-browsing UI (Overview/Workloads/Services/Storage/Nodes/Events/Logs/Live) reached via a **Browse** action per registered cluster.
- Four gated write/mutating MCP tools (`k8s_cluster_restart_rollout`, `k8s_cluster_scale_deployment`, `k8s_cluster_delete_pod`, `k8s_cluster_set_node_cordon`), each requiring both `agentic_access_enabled` and `allow_writes` on the target cluster, with a curated before/after audit line per call.

## When To Enable

Enable this plugin when Syrus operators need to register Kubernetes/k3s clusters for read-only inspection and gated agent access (read-only, or read+write once `allow_writes` is explicitly turned on per cluster). Keep it disabled when no cluster inspection is needed yet.

## Operational Notes

Treat configured credentials (bearer tokens, client certificates/keys) as sensitive cluster access. Prefer narrowly scoped service account tokens for each registered cluster. `insecure_skip_tls_verify` should stay off unless the cluster's API server uses a self-signed certificate you trust on your own network.
