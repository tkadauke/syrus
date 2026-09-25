import { getJson } from "@app/api/client"

export type KubernetesNamespaceRow = {
  name: string
  status: string | null
  created_at: string | null
}

export type KubernetesNamespacesResponse = {
  available: true
  generated_at: string
  truncated: boolean
  namespaces: KubernetesNamespaceRow[]
}

export type KubernetesNodeRow = {
  name: string
  ready: boolean
  roles: string[]
  kubelet_version: string | null
  internal_ip: string | null
  capacity_cpu: string | null
  capacity_memory: string | null
  allocatable_cpu: string | null
  allocatable_memory: string | null
  created_at: string | null
}

export type KubernetesNodesResponse = {
  available: true
  generated_at: string
  truncated: boolean
  nodes: KubernetesNodeRow[]
}

export type KubernetesPodRow = {
  name: string
  namespace: string
  status: string | null
  pod_ip: string | null
  node_name: string | null
  ready: string
  restart_count: number
  container_names: string[]
  created_at: string | null
}

export type KubernetesPodsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  pods: KubernetesPodRow[]
}

export type KubernetesPodLogsResponse = {
  available: true
  generated_at: string
  pod: string
  namespace: string
  container: string | null
  log: string
}

export type KubernetesDeploymentRow = {
  name: string
  namespace: string
  replicas: number | null
  ready_replicas: number
  available_replicas: number
  updated_replicas: number
  created_at: string | null
}

export type KubernetesDeploymentsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  deployments: KubernetesDeploymentRow[]
}

export type KubernetesCronJobRow = {
  name: string
  namespace: string
  schedule: string | null
  suspended: boolean
  active_count: number
  last_schedule_time: string | null
  created_at: string | null
}

export type KubernetesCronJobsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  cron_jobs: KubernetesCronJobRow[]
}

export type KubernetesServicePort = {
  name: string | null
  port: number | null
  target_port: number | string | null
  protocol: string | null
}

export type KubernetesServiceRow = {
  name: string
  namespace: string
  type: string | null
  cluster_ip: string | null
  external_ips: string[]
  ports: KubernetesServicePort[]
  created_at: string | null
}

export type KubernetesServicesResponse = {
  available: true
  generated_at: string
  truncated: boolean
  services: KubernetesServiceRow[]
}

export type KubernetesEndpointPort = {
  name: string | null
  port: number | null
  protocol: string | null
}

export type KubernetesEndpointRow = {
  name: string
  namespace: string
  ready_addresses: number
  not_ready_addresses: number
  ports: KubernetesEndpointPort[]
  created_at: string | null
}

export type KubernetesEndpointsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  endpoints: KubernetesEndpointRow[]
}

export type KubernetesPersistentVolumeClaimRow = {
  name: string
  namespace: string
  status: string | null
  capacity: string | null
  storage_class: string | null
  access_modes: string[]
  volume_name: string | null
  created_at: string | null
}

export type KubernetesPersistentVolumeClaimsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  persistent_volume_claims: KubernetesPersistentVolumeClaimRow[]
}

export type KubernetesEventRow = {
  name: string
  namespace: string
  type: string | null
  reason: string | null
  message: string | null
  involved_object: { kind: string | null; name: string | null }
  count: number | null
  first_timestamp: string | null
  last_timestamp: string | null
}

export type KubernetesEventsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  events: KubernetesEventRow[]
}

export type KubernetesNodeMetricRow = { name: string; cpu_millicores: number; memory_bytes: number }
export type KubernetesPodMetricRow = { name: string; namespace: string; cpu_millicores: number; memory_bytes: number }

export type KubernetesMetricsSection<TRow> =
  | { available: true; items: TRow[]; total_cpu_millicores: number; total_memory_bytes: number }
  | { available: false; reason: string; message: string }

export type KubernetesOverviewResponse = {
  generated_at: string
  nodes: KubernetesMetricsSection<KubernetesNodeMetricRow>
  pods: KubernetesMetricsSection<KubernetesPodMetricRow>
}

function withNamespace(path: string, namespace?: string | null) {
  return namespace ? `${path}?namespace=${encodeURIComponent(namespace)}` : path
}

export function fetchKubernetesNamespaces(clusterId: number) {
  return getJson<KubernetesNamespacesResponse>(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/namespaces`)
}

export function fetchKubernetesNodes(clusterId: number) {
  return getJson<KubernetesNodesResponse>(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/nodes`)
}

export function fetchKubernetesOverview(clusterId: number) {
  return getJson<KubernetesOverviewResponse>(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/overview`)
}

export function fetchKubernetesPods(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesPodsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/pods`, namespace))
}

export function fetchKubernetesPodLogs(
  clusterId: number,
  namespace: string,
  name: string,
  options: { container?: string | null; tail_lines?: number } = {}
) {
  const search = new URLSearchParams({ namespace })
  if (options.container) search.set("container", options.container)
  if (options.tail_lines) search.set("tail_lines", String(options.tail_lines))

  return getJson<KubernetesPodLogsResponse>(
    `/api/v1/app/admin/kubernetes_clusters/${clusterId}/pods/${encodeURIComponent(name)}/logs?${search.toString()}`
  )
}

export function fetchKubernetesDeployments(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesDeploymentsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/deployments`, namespace))
}

export type KubernetesStatefulSetRow = {
  name: string
  namespace: string
  replicas: number | null
  ready_replicas: number
  current_replicas: number
  updated_replicas: number
  created_at: string | null
}

export type KubernetesStatefulSetsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  stateful_sets: KubernetesStatefulSetRow[]
}

export type KubernetesDaemonSetRow = {
  name: string
  namespace: string
  desired_number_scheduled: number
  current_number_scheduled: number
  number_ready: number
  number_available: number
  created_at: string | null
}

export type KubernetesDaemonSetsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  daemon_sets: KubernetesDaemonSetRow[]
}

export type KubernetesJobRow = {
  name: string
  namespace: string
  completions: number | null
  parallelism: number | null
  active_count: number
  succeeded: number
  failed: number
  created_at: string | null
}

export type KubernetesJobsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  jobs: KubernetesJobRow[]
}

export function fetchKubernetesStatefulSets(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesStatefulSetsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/statefulsets`, namespace))
}

export function fetchKubernetesDaemonSets(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesDaemonSetsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/daemonsets`, namespace))
}

export function fetchKubernetesJobs(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesJobsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/jobs`, namespace))
}

export function fetchKubernetesCronJobs(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesCronJobsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/cronjobs`, namespace))
}

export function fetchKubernetesServices(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesServicesResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/services`, namespace))
}

export type KubernetesIngressPath = {
  path: string | null
  path_type: string | null
  service_name: string | null
  service_port: number | string | null
}

export type KubernetesIngressRule = {
  host: string | null
  paths: KubernetesIngressPath[]
}

export type KubernetesIngressRow = {
  name: string
  namespace: string
  ingress_class: string | null
  hosts: string[]
  rules: KubernetesIngressRule[]
  tls_hosts: string[]
  created_at: string | null
}

export type KubernetesIngressesResponse = {
  available: true
  generated_at: string
  truncated: boolean
  ingresses: KubernetesIngressRow[]
}

export function fetchKubernetesIngresses(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesIngressesResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/ingresses`, namespace))
}

export function fetchKubernetesEndpoints(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesEndpointsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/endpoints`, namespace))
}

export function fetchKubernetesPersistentVolumeClaims(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesPersistentVolumeClaimsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/pvcs`, namespace))
}

export type KubernetesConfigMapRow = {
  name: string
  namespace: string
  key_count: number
  key_names: string[]
  created_at: string | null
}

export type KubernetesConfigMapsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  config_maps: KubernetesConfigMapRow[]
}

export type KubernetesSecretRow = {
  name: string
  namespace: string
  type: string | null
  key_count: number
  key_names: string[]
  created_at: string | null
}

export type KubernetesSecretsResponse = {
  available: true
  generated_at: string
  truncated: boolean
  secrets: KubernetesSecretRow[]
}

export function fetchKubernetesConfigMaps(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesConfigMapsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/configmaps`, namespace))
}

export function fetchKubernetesSecrets(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesSecretsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/secrets`, namespace))
}

export function fetchKubernetesEvents(clusterId: number, namespace?: string | null) {
  return getJson<KubernetesEventsResponse>(withNamespace(`/api/v1/app/admin/kubernetes_clusters/${clusterId}/events`, namespace))
}
