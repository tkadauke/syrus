import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesCronJobs,
  fetchKubernetesDaemonSets,
  fetchKubernetesDeployments,
  fetchKubernetesJobs,
  fetchKubernetesPods,
  fetchKubernetesStatefulSets
} from "../../api/kubernetesResources"
import { explainCronSchedule, formatAge, type CronScheduleExplanation } from "../../lib/k8sFormat"
import { Dropdown } from "../Dropdown"
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
  const pods = useQuery({
    queryKey: ["k8s_cluster", "pods", clusterId, namespace],
    queryFn: () => fetchKubernetesPods(clusterId, namespace)
  })

  if (pods.isPending) return <PanelMessage>{t("workloads_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("workloads_error_loading_pods"))}</PanelMessage>
  if (pods.data.pods.length === 0) return <PanelMessage>{t("workloads_empty_pods")}</PanelMessage>

  return (
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_status")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_ready")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_restarts")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {pods.data.pods.map((pod) => (
          <DataTable.Row key={`${pod.namespace}/${pod.name}`}>
            <DataTable.Cell className="font-medium">{pod.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{pod.namespace}</DataTable.Cell>
            <DataTable.Cell>
              <StatusBadge tone={pod.status === "Running" ? "success" : pod.status === "Failed" ? "error" : "neutral"}>{pod.status || "-"}</StatusBadge>
            </DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{pod.ready}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{pod.restart_count}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(pod.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
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
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_ready")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_available")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_updated")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {deployments.data.deployments.map((deployment) => (
          <DataTable.Row key={`${deployment.namespace}/${deployment.name}`}>
            <DataTable.Cell className="font-medium">{deployment.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{deployment.namespace}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">
              {deployment.ready_replicas}/{deployment.replicas ?? "-"}
            </DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{deployment.available_replicas}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{deployment.updated_replicas}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(deployment.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function StatefulSetsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const statefulSets = useQuery({
    queryKey: ["k8s_cluster", "statefulsets", clusterId, namespace],
    queryFn: () => fetchKubernetesStatefulSets(clusterId, namespace)
  })

  if (statefulSets.isPending) return <PanelMessage>{t("workloads_loading_statefulsets")}</PanelMessage>
  if (statefulSets.isError) return <PanelMessage tone="error">{errorMessage(statefulSets.error, t("workloads_error_loading_statefulsets"))}</PanelMessage>
  if (statefulSets.data.stateful_sets.length === 0) return <PanelMessage>{t("workloads_empty_statefulsets")}</PanelMessage>

  return (
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_ready")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_current")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_updated")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {statefulSets.data.stateful_sets.map((statefulSet) => (
          <DataTable.Row key={`${statefulSet.namespace}/${statefulSet.name}`}>
            <DataTable.Cell className="font-medium">{statefulSet.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{statefulSet.namespace}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">
              {statefulSet.ready_replicas}/{statefulSet.replicas ?? "-"}
            </DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{statefulSet.current_replicas}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{statefulSet.updated_replicas}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(statefulSet.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function DaemonSetsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const daemonSets = useQuery({
    queryKey: ["k8s_cluster", "daemonsets", clusterId, namespace],
    queryFn: () => fetchKubernetesDaemonSets(clusterId, namespace)
  })

  if (daemonSets.isPending) return <PanelMessage>{t("workloads_loading_daemonsets")}</PanelMessage>
  if (daemonSets.isError) return <PanelMessage tone="error">{errorMessage(daemonSets.error, t("workloads_error_loading_daemonsets"))}</PanelMessage>
  if (daemonSets.data.daemon_sets.length === 0) return <PanelMessage>{t("workloads_empty_daemonsets")}</PanelMessage>

  return (
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_scheduled")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_ready")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_available")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {daemonSets.data.daemon_sets.map((daemonSet) => (
          <DataTable.Row key={`${daemonSet.namespace}/${daemonSet.name}`}>
            <DataTable.Cell className="font-medium">{daemonSet.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{daemonSet.namespace}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">
              {daemonSet.current_number_scheduled}/{daemonSet.desired_number_scheduled}
            </DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{daemonSet.number_ready}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{daemonSet.number_available}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(daemonSet.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function JobsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const jobs = useQuery({
    queryKey: ["k8s_cluster", "jobs", clusterId, namespace],
    queryFn: () => fetchKubernetesJobs(clusterId, namespace)
  })

  if (jobs.isPending) return <PanelMessage>{t("workloads_loading_jobs")}</PanelMessage>
  if (jobs.isError) return <PanelMessage tone="error">{errorMessage(jobs.error, t("workloads_error_loading_jobs"))}</PanelMessage>
  if (jobs.data.jobs.length === 0) return <PanelMessage>{t("workloads_empty_jobs")}</PanelMessage>

  return (
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_completions")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_active")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_succeeded")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_failed")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {jobs.data.jobs.map((job) => (
          <DataTable.Row key={`${job.namespace}/${job.name}`}>
            <DataTable.Cell className="font-medium">{job.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{job.namespace}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{job.completions ?? "-"}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{job.active_count}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{job.succeeded}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{job.failed}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(job.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
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
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_schedule")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_suspended")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_active")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {cronJobs.data.cron_jobs.map((cronJob) => (
          <DataTable.Row key={`${cronJob.namespace}/${cronJob.name}`}>
            <DataTable.Cell className="font-medium">{cronJob.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{cronJob.namespace}</DataTable.Cell>
            <DataTable.Cell className="font-mono text-text-secondary">
              <CronSchedule schedule={cronJob.schedule} />
            </DataTable.Cell>
            <DataTable.Cell>
              <StatusBadge tone={cronJob.suspended ? "warning" : "success"}>{cronJob.suspended ? t("yes") : t("no")}</StatusBadge>
            </DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{cronJob.active_count}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(cronJob.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
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
