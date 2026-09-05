import { deleteJson, getJson, patchJson, postJson } from "@app/api/client"

export type KubernetesClusterRow = {
  id: number
  label: string
  api_server_url: string
  agentic_access_enabled: boolean
  allow_writes: boolean
  insecure_skip_tls_verify: boolean
  credential_kind: "token" | "client_cert" | null
  created_at: string
  updated_at: string
}

export type KubernetesClusterInput = {
  label: string
  agentic_access_enabled: boolean
  allow_writes: boolean
  insecure_skip_tls_verify: boolean
  kubeconfig?: string
}

export type KubernetesClusterTestResult = {
  success: boolean
  error?: string
}

export function fetchKubernetesClusters() {
  return getJson<{ kubernetes_clusters: KubernetesClusterRow[] }>("/api/v1/app/admin/kubernetes_clusters")
}

export function createKubernetesCluster(values: KubernetesClusterInput) {
  return postJson<{ kubernetes_cluster: KubernetesClusterRow }>("/api/v1/app/admin/kubernetes_clusters", { kubernetes_cluster: values })
}

export function updateKubernetesCluster(id: number, values: Partial<KubernetesClusterInput>) {
  return patchJson<{ kubernetes_cluster: KubernetesClusterRow }>(`/api/v1/app/admin/kubernetes_clusters/${id}`, { kubernetes_cluster: values })
}

export function deleteKubernetesCluster(id: number) {
  return deleteJson<void>(`/api/v1/app/admin/kubernetes_clusters/${id}`)
}

export function testDraftKubernetesCluster(values: Partial<KubernetesClusterInput>) {
  return postJson<KubernetesClusterTestResult>("/api/v1/app/admin/kubernetes_clusters/test", { kubernetes_cluster: values })
}

export function testKubernetesCluster(id: number, kubeconfig?: string) {
  return postJson<KubernetesClusterTestResult>(
    `/api/v1/app/admin/kubernetes_clusters/${id}/test`,
    kubeconfig ? { kubernetes_cluster: { kubeconfig } } : undefined
  )
}
