import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesCronJobs,
  fetchKubernetesDaemonSets,
  fetchKubernetesDeployments,
  fetchKubernetesJobs,
  fetchKubernetesPods,
  fetchKubernetesStatefulSets,
  type KubernetesCronJobRow,
  type KubernetesDaemonSetRow,
  type KubernetesDeploymentRow,
  type KubernetesJobRow,
  type KubernetesPodRow,
  type KubernetesStatefulSetRow
} from "../../api/kubernetesResources"
import { explainCronSchedule, formatAge, type CronScheduleExplanation } from "../../lib/k8sFormat"
import { Dropdown } from "../Dropdown"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"

type WorkloadKind = "pods" | "deployments" | "statefulsets" | "daemonsets" | "jobs" | "cronjobs"

export function WorkloadsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const [kind, setKind] = useState<WorkloadKind>("pods")

  const kindOptions = [
    { value: "pods" as const, label: t("workload_kind_pods") },
    { value: "deployments" as const, label: t("workload_kind_deployments") },
    { value: "statefulsets" as const, label: t("workload_kind_statefulsets") },
    { value: "daemonsets" as const, label: t("workload_kind_daemonsets") },
    { value: "jobs" as const, label: t("workload_kind_jobs") },
    { value: "cronjobs" as const, label: t("workload_kind_cronjobs") }
  ]

  return (
    <div aria-label={t("aria_workloads_tab")} className="space-y-3">
      <Dropdown ariaLabel={t("workload_kind_label")} onChange={setKind} options={kindOptions} value={kind} />
      {kind === "pods" ? <PodsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "deployments" ? <DeploymentsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "statefulsets" ? <StatefulSetsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "daemonsets" ? <DaemonSetsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "jobs" ? <JobsTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "cronjobs" ? <CronJobsTable clusterId={clusterId} namespace={namespace} /> : null}
    </div>
  )
}

function PodsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const pods = useQuery({
    queryKey: ["k8s_cluster", "pods", clusterId, namespace],
    queryFn: () => fetchKubernetesPods(clusterId, namespace)
  })

  if (pods.isPending) return <PanelMessage>{t("workloads_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("workloads_error_loading_pods"))}</PanelMessage>
  if (pods.data.pods.length === 0) return <PanelMessage>{t("workloads_empty_pods")}</PanelMessage>

  const open = (pod: KubernetesPodRow) =>
    detail.openDetail({
      kind: "pod",
      kindLabel: t("workload_kind_pods"),
      name: pod.name,
      namespace: pod.namespace,
      fields: [
        { label: t("col_namespace"), value: pod.namespace },
        { label: t("col_status"), value: pod.status || "-" },
        { label: t("col_ready"), value: pod.ready },
        { label: t("col_restarts"), value: String(pod.restart_count) },
        { label: t("col_age"), value: formatAge(pod.created_at) }
      ]
    })

  return (
    <>
      <KubernetesResourceTable
        columns={podColumns(t, open)}
        defaultSort={{ column: "name", direction: "asc" }}
        empty={<PanelMessage>{t("workloads_empty_pods")}</PanelMessage>}
        getRowKey={(pod) => `${pod.namespace}/${pod.name}`}
        rows={pods.data.pods}
        storageKey="syrus.k8s_cluster.pods.columns"
        summary={t("workload_kind_pods")}
      />
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function DeploymentsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const deployments = useQuery({
    queryKey: ["k8s_cluster", "deployments", clusterId, namespace],
    queryFn: () => fetchKubernetesDeployments(clusterId, namespace)
  })

  if (deployments.isPending) return <PanelMessage>{t("workloads_loading_deployments")}</PanelMessage>
  if (deployments.isError) return <PanelMessage tone="error">{errorMessage(deployments.error, t("workloads_error_loading_deployments"))}</PanelMessage>
  if (deployments.data.deployments.length === 0) return <PanelMessage>{t("workloads_empty_deployments")}</PanelMessage>

  const open = (deployment: KubernetesDeploymentRow) =>
    detail.openDetail({
      kind: "deployment",
      kindLabel: t("workload_kind_deployments"),
      name: deployment.name,
      namespace: deployment.namespace,
      fields: [
        { label: t("col_namespace"), value: deployment.namespace },
        { label: t("col_ready"), value: `${deployment.ready_replicas}/${deployment.replicas ?? "-"}` },
        { label: t("col_available"), value: String(deployment.available_replicas) },
        { label: t("col_updated"), value: String(deployment.updated_replicas) },
        { label: t("col_age"), value: formatAge(deployment.created_at) }
      ]
    })

  return (
    <>
      <KubernetesResourceTable
        columns={deploymentColumns(t, open)}
        defaultSort={{ column: "name", direction: "asc" }}
        empty={<PanelMessage>{t("workloads_empty_deployments")}</PanelMessage>}
        getRowKey={(deployment) => `${deployment.namespace}/${deployment.name}`}
        rows={deployments.data.deployments}
        storageKey="syrus.k8s_cluster.deployments.columns"
        summary={t("workload_kind_deployments")}
      />
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function StatefulSetsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const statefulSets = useQuery({
    queryKey: ["k8s_cluster", "statefulsets", clusterId, namespace],
    queryFn: () => fetchKubernetesStatefulSets(clusterId, namespace)
  })

  if (statefulSets.isPending) return <PanelMessage>{t("workloads_loading_statefulsets")}</PanelMessage>
  if (statefulSets.isError) return <PanelMessage tone="error">{errorMessage(statefulSets.error, t("workloads_error_loading_statefulsets"))}</PanelMessage>
  if (statefulSets.data.stateful_sets.length === 0) return <PanelMessage>{t("workloads_empty_statefulsets")}</PanelMessage>

  const open = (statefulSet: KubernetesStatefulSetRow) =>
    detail.openDetail({
      kind: "statefulset",
      kindLabel: t("workload_kind_statefulsets"),
      name: statefulSet.name,
      namespace: statefulSet.namespace,
      fields: [
        { label: t("col_namespace"), value: statefulSet.namespace },
        { label: t("col_ready"), value: `${statefulSet.ready_replicas}/${statefulSet.replicas ?? "-"}` },
        { label: t("col_current"), value: String(statefulSet.current_replicas) },
        { label: t("col_updated"), value: String(statefulSet.updated_replicas) },
        { label: t("col_age"), value: formatAge(statefulSet.created_at) }
      ]
    })

  return (
    <>
      <KubernetesResourceTable
        columns={statefulSetColumns(t, open)}
        defaultSort={{ column: "name", direction: "asc" }}
        empty={<PanelMessage>{t("workloads_empty_statefulsets")}</PanelMessage>}
        getRowKey={(statefulSet) => `${statefulSet.namespace}/${statefulSet.name}`}
        rows={statefulSets.data.stateful_sets}
        storageKey="syrus.k8s_cluster.stateful_sets.columns"
        summary={t("workload_kind_statefulsets")}
      />
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function DaemonSetsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const daemonSets = useQuery({
    queryKey: ["k8s_cluster", "daemonsets", clusterId, namespace],
    queryFn: () => fetchKubernetesDaemonSets(clusterId, namespace)
  })

  if (daemonSets.isPending) return <PanelMessage>{t("workloads_loading_daemonsets")}</PanelMessage>
  if (daemonSets.isError) return <PanelMessage tone="error">{errorMessage(daemonSets.error, t("workloads_error_loading_daemonsets"))}</PanelMessage>
  if (daemonSets.data.daemon_sets.length === 0) return <PanelMessage>{t("workloads_empty_daemonsets")}</PanelMessage>

  const open = (daemonSet: KubernetesDaemonSetRow) =>
    detail.openDetail({
      kind: "daemonset",
      kindLabel: t("workload_kind_daemonsets"),
      name: daemonSet.name,
      namespace: daemonSet.namespace,
      fields: [
        { label: t("col_namespace"), value: daemonSet.namespace },
        { label: t("col_scheduled"), value: `${daemonSet.current_number_scheduled}/${daemonSet.desired_number_scheduled}` },
        { label: t("col_ready"), value: String(daemonSet.number_ready) },
        { label: t("col_available"), value: String(daemonSet.number_available) },
        { label: t("col_age"), value: formatAge(daemonSet.created_at) }
      ]
    })

  return (
    <>
      <KubernetesResourceTable
        columns={daemonSetColumns(t, open)}
        defaultSort={{ column: "name", direction: "asc" }}
        empty={<PanelMessage>{t("workloads_empty_daemonsets")}</PanelMessage>}
        getRowKey={(daemonSet) => `${daemonSet.namespace}/${daemonSet.name}`}
        rows={daemonSets.data.daemon_sets}
        storageKey="syrus.k8s_cluster.daemon_sets.columns"
        summary={t("workload_kind_daemonsets")}
      />
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function JobsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const jobs = useQuery({
    queryKey: ["k8s_cluster", "jobs", clusterId, namespace],
    queryFn: () => fetchKubernetesJobs(clusterId, namespace)
  })

  if (jobs.isPending) return <PanelMessage>{t("workloads_loading_jobs")}</PanelMessage>
  if (jobs.isError) return <PanelMessage tone="error">{errorMessage(jobs.error, t("workloads_error_loading_jobs"))}</PanelMessage>
  if (jobs.data.jobs.length === 0) return <PanelMessage>{t("workloads_empty_jobs")}</PanelMessage>

  const open = (job: KubernetesJobRow) =>
    detail.openDetail({
      kind: "job",
      kindLabel: t("workload_kind_jobs"),
      name: job.name,
      namespace: job.namespace,
      fields: [
        { label: t("col_namespace"), value: job.namespace },
        { label: t("col_completions"), value: job.completions === null ? "-" : String(job.completions) },
        { label: t("col_active"), value: String(job.active_count) },
        { label: t("col_succeeded"), value: String(job.succeeded) },
        { label: t("col_failed"), value: String(job.failed) },
        { label: t("col_age"), value: formatAge(job.created_at) }
      ]
    })

  return (
    <>
      <KubernetesResourceTable
        columns={jobColumns(t, open)}
        defaultSort={{ column: "name", direction: "asc" }}
        empty={<PanelMessage>{t("workloads_empty_jobs")}</PanelMessage>}
        getRowKey={(job) => `${job.namespace}/${job.name}`}
        rows={jobs.data.jobs}
        storageKey="syrus.k8s_cluster.jobs.columns"
        summary={t("workload_kind_jobs")}
      />
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function CronJobsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const cronJobs = useQuery({
    queryKey: ["k8s_cluster", "cronjobs", clusterId, namespace],
    queryFn: () => fetchKubernetesCronJobs(clusterId, namespace)
  })

  if (cronJobs.isPending) return <PanelMessage>{t("workloads_loading_cronjobs")}</PanelMessage>
  if (cronJobs.isError) return <PanelMessage tone="error">{errorMessage(cronJobs.error, t("workloads_error_loading_cronjobs"))}</PanelMessage>
  if (cronJobs.data.cron_jobs.length === 0) return <PanelMessage>{t("workloads_empty_cronjobs")}</PanelMessage>

  const open = (cronJob: KubernetesCronJobRow) =>
    detail.openDetail({
      kind: "cronjob",
      kindLabel: t("workload_kind_cronjobs"),
      name: cronJob.name,
      namespace: cronJob.namespace,
      fields: [
        { label: t("col_namespace"), value: cronJob.namespace },
        { label: t("col_schedule"), value: cronJob.schedule || "-" },
        { label: t("col_suspended"), value: cronJob.suspended ? t("yes") : t("no") },
        { label: t("col_active"), value: String(cronJob.active_count) },
        { label: t("col_age"), value: formatAge(cronJob.created_at) }
      ]
    })

  return (
    <>
      <KubernetesResourceTable
        columns={cronJobColumns(t, open)}
        defaultSort={{ column: "name", direction: "asc" }}
        empty={<PanelMessage>{t("workloads_empty_cronjobs")}</PanelMessage>}
        getRowKey={(cronJob) => `${cronJob.namespace}/${cronJob.name}`}
        rows={cronJobs.data.cron_jobs}
        storageKey="syrus.k8s_cluster.cron_jobs.columns"
        summary={t("workload_kind_cronjobs")}
      />
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function podColumns(t: ReturnType<typeof useT>["t"], onOpen: (pod: KubernetesPodRow) => void): Array<KubernetesResourceTableColumn<KubernetesPodRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (pod) => <DetailNameButton name={pod.name} onOpen={() => onOpen(pod)} />,
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

function deploymentColumns(
  t: ReturnType<typeof useT>["t"],
  onOpen: (deployment: KubernetesDeploymentRow) => void
): Array<KubernetesResourceTableColumn<KubernetesDeploymentRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (deployment) => <DetailNameButton name={deployment.name} onOpen={() => onOpen(deployment)} />,
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

function statefulSetColumns(
  t: ReturnType<typeof useT>["t"],
  onOpen: (statefulSet: KubernetesStatefulSetRow) => void
): Array<KubernetesResourceTableColumn<KubernetesStatefulSetRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (statefulSet) => <DetailNameButton name={statefulSet.name} onOpen={() => onOpen(statefulSet)} />,
      required: true,
      sort: "name",
      sortValue: (statefulSet) => statefulSet.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (statefulSet) => statefulSet.namespace,
      sort: "namespace",
      sortValue: (statefulSet) => statefulSet.namespace
    },
    {
      key: "ready",
      header: t("col_ready"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (statefulSet) => `${statefulSet.ready_replicas}/${statefulSet.replicas ?? "-"}`,
      render: (statefulSet) => `${statefulSet.ready_replicas}/${statefulSet.replicas ?? "-"}`,
      sort: "ready",
      sortValue: (statefulSet) => statefulSet.ready_replicas
    },
    {
      key: "current_replicas",
      header: t("col_current"),
      className: "text-gray-700 dark:text-gray-300",
      render: (statefulSet) => statefulSet.current_replicas,
      sort: "current_replicas",
      sortValue: (statefulSet) => statefulSet.current_replicas
    },
    {
      key: "updated_replicas",
      header: t("col_updated"),
      className: "text-gray-700 dark:text-gray-300",
      render: (statefulSet) => statefulSet.updated_replicas,
      sort: "updated_replicas",
      sortValue: (statefulSet) => statefulSet.updated_replicas
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (statefulSet) => formatAge(statefulSet.created_at),
      sort: "created_at",
      sortValue: (statefulSet) => statefulSet.created_at
    }
  ]
}

function daemonSetColumns(
  t: ReturnType<typeof useT>["t"],
  onOpen: (daemonSet: KubernetesDaemonSetRow) => void
): Array<KubernetesResourceTableColumn<KubernetesDaemonSetRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (daemonSet) => <DetailNameButton name={daemonSet.name} onOpen={() => onOpen(daemonSet)} />,
      required: true,
      sort: "name",
      sortValue: (daemonSet) => daemonSet.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (daemonSet) => daemonSet.namespace,
      sort: "namespace",
      sortValue: (daemonSet) => daemonSet.namespace
    },
    {
      key: "scheduled",
      header: t("col_scheduled"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (daemonSet) => `${daemonSet.current_number_scheduled}/${daemonSet.desired_number_scheduled}`,
      render: (daemonSet) => `${daemonSet.current_number_scheduled}/${daemonSet.desired_number_scheduled}`,
      sort: "scheduled",
      sortValue: (daemonSet) => daemonSet.current_number_scheduled
    },
    {
      key: "number_ready",
      header: t("col_ready"),
      className: "text-gray-700 dark:text-gray-300",
      render: (daemonSet) => daemonSet.number_ready,
      sort: "number_ready",
      sortValue: (daemonSet) => daemonSet.number_ready
    },
    {
      key: "number_available",
      header: t("col_available"),
      className: "text-gray-700 dark:text-gray-300",
      render: (daemonSet) => daemonSet.number_available,
      sort: "number_available",
      sortValue: (daemonSet) => daemonSet.number_available
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (daemonSet) => formatAge(daemonSet.created_at),
      sort: "created_at",
      sortValue: (daemonSet) => daemonSet.created_at
    }
  ]
}

function jobColumns(t: ReturnType<typeof useT>["t"], onOpen: (job: KubernetesJobRow) => void): Array<KubernetesResourceTableColumn<KubernetesJobRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (job) => <DetailNameButton name={job.name} onOpen={() => onOpen(job)} />,
      required: true,
      sort: "name",
      sortValue: (job) => job.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (job) => job.namespace,
      sort: "namespace",
      sortValue: (job) => job.namespace
    },
    {
      key: "completions",
      header: t("col_completions"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (job) => `${job.completions ?? "-"}`,
      render: (job) => job.completions ?? "-",
      sort: "completions",
      sortValue: (job) => job.completions ?? -1
    },
    {
      key: "active_count",
      header: t("col_active"),
      className: "text-gray-700 dark:text-gray-300",
      render: (job) => job.active_count,
      sort: "active_count",
      sortValue: (job) => job.active_count
    },
    {
      key: "succeeded",
      header: t("col_succeeded"),
      className: "text-gray-700 dark:text-gray-300",
      render: (job) => job.succeeded,
      sort: "succeeded",
      sortValue: (job) => job.succeeded
    },
    {
      key: "failed",
      header: t("col_failed"),
      className: "text-gray-700 dark:text-gray-300",
      render: (job) => job.failed,
      sort: "failed",
      sortValue: (job) => job.failed
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (job) => formatAge(job.created_at),
      sort: "created_at",
      sortValue: (job) => job.created_at
    }
  ]
}

function cronJobColumns(
  t: ReturnType<typeof useT>["t"],
  onOpen: (cronJob: KubernetesCronJobRow) => void
): Array<KubernetesResourceTableColumn<KubernetesCronJobRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (cronJob) => <DetailNameButton name={cronJob.name} onOpen={() => onOpen(cronJob)} />,
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
