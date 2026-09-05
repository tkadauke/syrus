# K8s Cluster Viewer

K8s Cluster Viewer lets admins register external Kubernetes/k3s clusters, parsed from a pasted kubeconfig, with encrypted credential storage, and manage them from the Syrus admin UI. This first scaffold covers connection management only (add/edit/delete/test); read-only cluster-resource browsing and gated agentic access ship in later Jobs under EPIC-306.

## What It Adds

- Admin UI and API endpoints for Kubernetes/k3s cluster connection management.
- A kubeconfig parser that resolves the current-context's cluster/user and extracts only the connection info Syrus needs (server URL, bearer token or client-certificate/key, CA data).
- A lightweight connection test (`GET /version`) before saving.

## When To Enable

Enable this plugin when Syrus operators need to register Kubernetes/k3s clusters for later read-only browsing and gated agent access. Keep it disabled when no cluster inspection is needed yet.

## Operational Notes

Treat configured credentials (bearer tokens, client certificates/keys) as sensitive cluster access. Prefer narrowly scoped service account tokens for each registered cluster. `insecure_skip_tls_verify` should stay off unless the cluster's API server uses a self-signed certificate you trust on your own network.
