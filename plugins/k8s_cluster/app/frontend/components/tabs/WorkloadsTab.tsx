import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesCronJobs,
  fetchKubernetesDeployments,
  fetchKubernetesPods
} from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { Dropdown } from "../Dropdown"
import { StatusBadge } from "../StatusBadge"

type WorkloadKind = "pods" | "deployments" | "cronjobs"

export function WorkloadsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const [kind, setKind] = useState<WorkloadKind>("pods")

  const kindOptions = [
    { value: "pods" as const, label: t("workload_kind_pods") },
    { value: "deployments" as const, label: t("workload_kind_deployments") },
    { value: "cronjobs" as const, label: t("workload_kind_cronjobs") }
  ]

  return (
    <div aria-label={t("aria_workloads_tab")} className="space-y-3">
      <Dropdown ariaLabel={t("workload_kind_label")} onChange={setKind} options={kindOptions} value={kind} />
      {kind === "pods" ? <PodsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "deployments" ? <DeploymentsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "cronjobs" ? <CronJobsTable clusterId={clusterId} namespace={namespace} /> : null}
    </div>
  )
}

function PodsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const pods = useQuery({
    queryKey: [ "k8s_cluster", "pods", clusterId, namespace ],
    queryFn: () => fetchKubernetesPods(clusterId, namespace)
  })

  if (pods.isPending) return <PanelMessage>{t("workloads_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("workloads_error_loading_pods"))}</PanelMessage>
  if (pods.data.pods.length === 0) return <PanelMessage>{t("workloads_empty_pods")}</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("col_name")}</th>
            <th className="px-4 py-2">{t("col_namespace")}</th>
            <th className="px-4 py-2">{t("col_status")}</th>
            <th className="px-4 py-2">{t("col_ready")}</th>
            <th className="px-4 py-2">{t("col_restarts")}</th>
            <th className="px-4 py-2">{t("col_age")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
          {pods.data.pods.map((pod) => (
            <tr key={`${pod.namespace}/${pod.name}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{pod.name}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{pod.namespace}</td>
              <td className="px-4 py-2">
                <StatusBadge tone={pod.status === "Running" ? "success" : pod.status === "Failed" ? "error" : "neutral"}>{pod.status || "-"}</StatusBadge>
              </td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{pod.ready}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{pod.restart_count}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(pod.created_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function DeploymentsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const deployments = useQuery({
    queryKey: [ "k8s_cluster", "deployments", clusterId, namespace ],
    queryFn: () => fetchKubernetesDeployments(clusterId, namespace)
  })

  if (deployments.isPending) return <PanelMessage>{t("workloads_loading_deployments")}</PanelMessage>
  if (deployments.isError) return <PanelMessage tone="error">{errorMessage(deployments.error, t("workloads_error_loading_deployments"))}</PanelMessage>
  if (deployments.data.deployments.length === 0) return <PanelMessage>{t("workloads_empty_deployments")}</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("col_name")}</th>
            <th className="px-4 py-2">{t("col_namespace")}</th>
            <th className="px-4 py-2">{t("col_ready")}</th>
            <th className="px-4 py-2">{t("col_available")}</th>
            <th className="px-4 py-2">{t("col_updated")}</th>
            <th className="px-4 py-2">{t("col_age")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
          {deployments.data.deployments.map((deployment) => (
            <tr key={`${deployment.namespace}/${deployment.name}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{deployment.name}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{deployment.namespace}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{deployment.ready_replicas}/{deployment.replicas ?? "-"}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{deployment.available_replicas}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{deployment.updated_replicas}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(deployment.created_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function CronJobsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const cronJobs = useQuery({
    queryKey: [ "k8s_cluster", "cronjobs", clusterId, namespace ],
    queryFn: () => fetchKubernetesCronJobs(clusterId, namespace)
  })

  if (cronJobs.isPending) return <PanelMessage>{t("workloads_loading_cronjobs")}</PanelMessage>
  if (cronJobs.isError) return <PanelMessage tone="error">{errorMessage(cronJobs.error, t("workloads_error_loading_cronjobs"))}</PanelMessage>
  if (cronJobs.data.cron_jobs.length === 0) return <PanelMessage>{t("workloads_empty_cronjobs")}</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("col_name")}</th>
            <th className="px-4 py-2">{t("col_namespace")}</th>
            <th className="px-4 py-2">{t("col_schedule")}</th>
            <th className="px-4 py-2">{t("col_suspended")}</th>
            <th className="px-4 py-2">{t("col_active")}</th>
            <th className="px-4 py-2">{t("col_age")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
          {cronJobs.data.cron_jobs.map((cronJob) => (
            <tr key={`${cronJob.namespace}/${cronJob.name}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{cronJob.name}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{cronJob.namespace}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">{cronJob.schedule}</td>
              <td className="px-4 py-2">
                <StatusBadge tone={cronJob.suspended ? "warning" : "success"}>
                  {cronJob.suspended ? t("yes") : t("no")}
                </StatusBadge>
              </td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{cronJob.active_count}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(cronJob.created_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
