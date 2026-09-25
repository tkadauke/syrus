import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesCronJobs,
  fetchKubernetesDeployments,
  fetchKubernetesPods,
  type KubernetesCronJobRow,
  type KubernetesDeploymentRow,
  type KubernetesPodRow
} from "../../api/kubernetesResources"
import { explainCronSchedule, formatAge, type CronScheduleExplanation } from "../../lib/k8sFormat"
import { Dropdown } from "../Dropdown"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
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
    queryKey: ["k8s_cluster", "pods", clusterId, namespace],
    queryFn: () => fetchKubernetesPods(clusterId, namespace)
  })

  if (pods.isPending) return <PanelMessage>{t("workloads_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("workloads_error_loading_pods"))}</PanelMessage>
  if (pods.data.pods.length === 0) return <PanelMessage>{t("workloads_empty_pods")}</PanelMessage>

  return (
    <KubernetesResourceTable
      columns={podColumns(t)}
      defaultSort={{ column: "name", direction: "asc" }}
      empty={<PanelMessage>{t("workloads_empty_pods")}</PanelMessage>}
      getRowKey={(pod) => `${pod.namespace}/${pod.name}`}
      rows={pods.data.pods}
      storageKey="syrus.k8s_cluster.pods.columns"
      summary={t("workload_kind_pods")}
    />
  )
}

function DeploymentsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const deployments = useQuery({
    queryKey: ["k8s_cluster", "deployments", clusterId, namespace],
    queryFn: () => fetchKubernetesDeployments(clusterId, namespace)
  })

  if (deployments.isPending) return <PanelMessage>{t("workloads_loading_deployments")}</PanelMessage>
  if (deployments.isError) return <PanelMessage tone="error">{errorMessage(deployments.error, t("workloads_error_loading_deployments"))}</PanelMessage>
  if (deployments.data.deployments.length === 0) return <PanelMessage>{t("workloads_empty_deployments")}</PanelMessage>

  return (
    <KubernetesResourceTable
      columns={deploymentColumns(t)}
      defaultSort={{ column: "name", direction: "asc" }}
      empty={<PanelMessage>{t("workloads_empty_deployments")}</PanelMessage>}
      getRowKey={(deployment) => `${deployment.namespace}/${deployment.name}`}
      rows={deployments.data.deployments}
      storageKey="syrus.k8s_cluster.deployments.columns"
      summary={t("workload_kind_deployments")}
    />
  )
}

function CronJobsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const cronJobs = useQuery({
    queryKey: ["k8s_cluster", "cronjobs", clusterId, namespace],
    queryFn: () => fetchKubernetesCronJobs(clusterId, namespace)
  })

  if (cronJobs.isPending) return <PanelMessage>{t("workloads_loading_cronjobs")}</PanelMessage>
  if (cronJobs.isError) return <PanelMessage tone="error">{errorMessage(cronJobs.error, t("workloads_error_loading_cronjobs"))}</PanelMessage>
  if (cronJobs.data.cron_jobs.length === 0) return <PanelMessage>{t("workloads_empty_cronjobs")}</PanelMessage>

  return (
    <KubernetesResourceTable
      columns={cronJobColumns(t)}
      defaultSort={{ column: "name", direction: "asc" }}
      empty={<PanelMessage>{t("workloads_empty_cronjobs")}</PanelMessage>}
      getRowKey={(cronJob) => `${cronJob.namespace}/${cronJob.name}`}
      rows={cronJobs.data.cron_jobs}
      storageKey="syrus.k8s_cluster.cron_jobs.columns"
      summary={t("workload_kind_cronjobs")}
    />
  )
}

function podColumns(t: ReturnType<typeof useT>["t"]): Array<KubernetesResourceTableColumn<KubernetesPodRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (pod) => pod.name,
      required: true,
      sort: "name",
      sortValue: (pod) => pod.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pod) => pod.namespace,
      sort: "namespace",
      sortValue: (pod) => pod.namespace
    },
    {
      key: "status",
      header: t("col_status"),
      filterValue: (pod) => pod.status,
      render: (pod) => (
        <StatusBadge tone={pod.status === "Running" ? "success" : pod.status === "Failed" ? "error" : "neutral"}>{pod.status || "-"}</StatusBadge>
      ),
      sort: "status",
      sortValue: (pod) => pod.status
    },
    {
      key: "ready",
      header: t("col_ready"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pod) => pod.ready,
      sort: "ready",
      sortValue: (pod) => pod.ready
    },
    {
      key: "restart_count",
      header: t("col_restarts"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pod) => pod.restart_count,
      sort: "restart_count",
      sortValue: (pod) => pod.restart_count
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pod) => formatAge(pod.created_at),
      sort: "created_at",
      sortValue: (pod) => pod.created_at
    }
  ]
}

function deploymentColumns(t: ReturnType<typeof useT>["t"]): Array<KubernetesResourceTableColumn<KubernetesDeploymentRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (deployment) => deployment.name,
      required: true,
      sort: "name",
      sortValue: (deployment) => deployment.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (deployment) => deployment.namespace,
      sort: "namespace",
      sortValue: (deployment) => deployment.namespace
    },
    {
      key: "ready",
      header: t("col_ready"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (deployment) => `${deployment.ready_replicas}/${deployment.replicas ?? "-"}`,
      render: (deployment) => `${deployment.ready_replicas}/${deployment.replicas ?? "-"}`,
      sort: "ready",
      sortValue: (deployment) => deployment.ready_replicas
    },
    {
      key: "available_replicas",
      header: t("col_available"),
      className: "text-gray-700 dark:text-gray-300",
      render: (deployment) => deployment.available_replicas,
      sort: "available_replicas",
      sortValue: (deployment) => deployment.available_replicas
    },
    {
      key: "updated_replicas",
      header: t("col_updated"),
      className: "text-gray-700 dark:text-gray-300",
      render: (deployment) => deployment.updated_replicas,
      sort: "updated_replicas",
      sortValue: (deployment) => deployment.updated_replicas
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (deployment) => formatAge(deployment.created_at),
      sort: "created_at",
      sortValue: (deployment) => deployment.created_at
    }
  ]
}

function cronJobColumns(t: ReturnType<typeof useT>["t"]): Array<KubernetesResourceTableColumn<KubernetesCronJobRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (cronJob) => cronJob.name,
      required: true,
      sort: "name",
      sortValue: (cronJob) => cronJob.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (cronJob) => cronJob.namespace,
      sort: "namespace",
      sortValue: (cronJob) => cronJob.namespace
    },
    {
      key: "schedule",
      header: t("col_schedule"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      render: (cronJob) => <CronSchedule schedule={cronJob.schedule} />,
      sort: "schedule",
      sortValue: (cronJob) => cronJob.schedule
    },
    {
      key: "suspended",
      header: t("col_suspended"),
      filterValue: (cronJob) => (cronJob.suspended ? t("yes") : t("no")),
      render: (cronJob) => <StatusBadge tone={cronJob.suspended ? "warning" : "success"}>{cronJob.suspended ? t("yes") : t("no")}</StatusBadge>,
      sort: "suspended",
      sortValue: (cronJob) => Number(cronJob.suspended)
    },
    {
      key: "active_count",
      header: t("col_active"),
      className: "text-gray-700 dark:text-gray-300",
      render: (cronJob) => cronJob.active_count,
      sort: "active_count",
      sortValue: (cronJob) => cronJob.active_count
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (cronJob) => formatAge(cronJob.created_at),
      sort: "created_at",
      sortValue: (cronJob) => cronJob.created_at
    }
  ]
}

function CronSchedule({ schedule }: { schedule: string | null }) {
  const { t } = useT("k8s_cluster")
  const explanation = explainCronSchedule(schedule)
  const label = schedule || "-"
  const title = explanation ? cronScheduleTitle(explanation, t) : null

  return title ? (
    <span className="cursor-help" title={title}>
      {label}
    </span>
  ) : (
    <span>{label}</span>
  )
}

function cronScheduleTitle(explanation: CronScheduleExplanation, t: (key: string, options?: Record<string, unknown>) => string) {
  const values = { ...(explanation.values || {}) }
  if (typeof values.weekday === "string") values.weekday = t(values.weekday)
  if (typeof values.month === "string") values.month = t(values.month)

  return t(explanation.key, values)
}
