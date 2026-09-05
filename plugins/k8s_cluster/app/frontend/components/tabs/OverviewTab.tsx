import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNodes, fetchKubernetesOverview, type KubernetesMetricsSection } from "../../api/kubernetesResources"
import { formatBytes, formatMillicores } from "../../lib/k8sFormat"
import { StatusBadge } from "../StatusBadge"

export function OverviewTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const nodes = useQuery({
    queryKey: [ "k8s_cluster", "nodes", clusterId ],
    queryFn: () => fetchKubernetesNodes(clusterId)
  })
  const overview = useQuery({
    queryKey: [ "k8s_cluster", "overview", clusterId ],
    queryFn: () => fetchKubernetesOverview(clusterId)
  })

  return (
    <div aria-label={t("aria_overview_tab")} className="space-y-4">
      <section>
        <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("overview_nodes_heading")}</h3>
        {nodes.isPending ? <PanelMessage>{t("overview_loading_nodes")}</PanelMessage> : null}
        {nodes.isError ? <PanelMessage tone="error">{errorMessage(nodes.error, t("overview_error_loading_nodes"))}</PanelMessage> : null}
        {nodes.isSuccess ? (
          nodes.data.nodes.length === 0 ? (
            <PanelMessage>{t("overview_no_nodes")}</PanelMessage>
          ) : (
            <div className="flex flex-wrap items-center gap-3 rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 p-4">
              <span className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{nodes.data.nodes.length}</span>
              <span className="text-sm text-gray-500 dark:text-gray-400">{t("overview_node_count_label")}</span>
              <StatusBadge tone={nodes.data.nodes.every((node) => node.ready) ? "success" : "warning"}>
                {t("overview_nodes_ready", { ready: nodes.data.nodes.filter((node) => node.ready).length, total: nodes.data.nodes.length })}
              </StatusBadge>
            </div>
          )
        ) : null}
      </section>

      <section>
        <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("overview_metrics_heading")}</h3>
        {overview.isPending ? <PanelMessage>{t("overview_loading_metrics")}</PanelMessage> : null}
        {overview.isError ? <PanelMessage tone="error">{errorMessage(overview.error, t("overview_error_loading_metrics"))}</PanelMessage> : null}
        {overview.isSuccess ? (
          <div className="grid gap-3 sm:grid-cols-2">
            <MetricsCard heading={t("overview_node_usage")} section={overview.data.nodes} />
            <MetricsCard heading={t("overview_pod_usage")} section={overview.data.pods} />
          </div>
        ) : null}
      </section>
    </div>
  )
}

function MetricsCard({ heading, section }: { heading: string; section: KubernetesMetricsSection<{ name: string; cpu_millicores: number; memory_bytes: number }> }) {
  const { t } = useT("k8s_cluster")

  return (
    <div className="rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 p-4">
      <h4 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{heading}</h4>
      {section.available ? (
        <dl className="mt-2 grid grid-cols-2 gap-2 text-sm">
          <div>
            <dt className="text-xs text-gray-500 dark:text-gray-400">{t("overview_total_cpu")}</dt>
            <dd className="font-medium text-gray-900 dark:text-gray-100">{formatMillicores(section.total_cpu_millicores)}</dd>
          </div>
          <div>
            <dt className="text-xs text-gray-500 dark:text-gray-400">{t("overview_total_memory")}</dt>
            <dd className="font-medium text-gray-900 dark:text-gray-100">{formatBytes(section.total_memory_bytes)}</dd>
          </div>
        </dl>
      ) : (
        <div className="mt-2 text-xs text-gray-500 dark:text-gray-400">
          <p>{t("overview_metrics_unavailable")}</p>
          <p className="mt-1 font-mono">{section.message}</p>
        </div>
      )}
    </div>
  )
}
