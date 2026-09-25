import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable, DescriptionList } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesNamespaces,
  fetchKubernetesNodes,
  fetchKubernetesOverview,
  type KubernetesMetricsSection,
  type KubernetesNamespaceRow
} from "../../api/kubernetesResources"
import { formatAge, formatBytes, formatMillicores } from "../../lib/k8sFormat"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"

export function OverviewTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const nodes = useQuery({
    queryKey: [ "k8s_cluster", "nodes", clusterId ],
    queryFn: () => fetchKubernetesNodes(clusterId)
  })
  const namespaces = useQuery({
    queryKey: [ "k8s_cluster", "namespaces", clusterId ],
    queryFn: () => fetchKubernetesNamespaces(clusterId)
  })
  const overview = useQuery({
    queryKey: [ "k8s_cluster", "overview", clusterId ],
    queryFn: () => fetchKubernetesOverview(clusterId)
  })

  const openNamespace = (row: KubernetesNamespaceRow) =>
    detail.openDetail({
      kind: "namespace",
      kindLabel: t("namespaces_heading"),
      name: row.name,
      namespace: null,
      fields: [
        { label: t("col_status"), value: row.status || "-" },
        { label: t("col_age"), value: formatAge(row.created_at) }
      ]
    })

  return (
    <div aria-label={t("aria_overview_tab")} className="space-y-4">
      <section>
        <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("namespaces_heading")}</h3>
        {namespaces.isPending ? <PanelMessage>{t("namespaces_loading")}</PanelMessage> : null}
        {namespaces.isError ? <PanelMessage tone="error">{errorMessage(namespaces.error, t("namespaces_error_loading"))}</PanelMessage> : null}
        {namespaces.isSuccess ? (
          namespaces.data.namespaces.length === 0 ? (
            <PanelMessage>{t("namespaces_empty")}</PanelMessage>
          ) : (
            <DataTable.Root density="compact">
              <DataTable.Header>
                <DataTable.Row>
                  <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
                  <DataTable.HeadCell>{t("col_status")}</DataTable.HeadCell>
                  <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
                </DataTable.Row>
              </DataTable.Header>
              <DataTable.Body>
                {namespaces.data.namespaces.map((row) => (
                  <DataTable.Row interactive key={row.name} onClick={() => openNamespace(row)}>
                    <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">
                      <DetailNameButton name={row.name} onOpen={() => openNamespace(row)} />
                    </DataTable.Cell>
                    <DataTable.Cell>
                      <StatusBadge tone={row.status === "Active" ? "success" : "neutral"}>{row.status || "-"}</StatusBadge>
                    </DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{formatAge(row.created_at)}</DataTable.Cell>
                  </DataTable.Row>
                ))}
              </DataTable.Body>
            </DataTable.Root>
          )
        ) : null}
      </section>

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

      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />

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
    <div className="rounded border border-border bg-surface p-4">
      <h4 className="text-sm font-semibold text-text-primary">{heading}</h4>
      {section.available ? (
        <DescriptionList.Root className="mt-2 grid-cols-2 sm:grid-cols-2" density="compact">
          <DescriptionList.Item descriptionClassName="font-medium text-text-primary" label={t("overview_total_cpu")} termClassName="normal-case tracking-normal">
            {formatMillicores(section.total_cpu_millicores)}
          </DescriptionList.Item>
          <DescriptionList.Item descriptionClassName="font-medium text-text-primary" label={t("overview_total_memory")} termClassName="normal-case tracking-normal">
            {formatBytes(section.total_memory_bytes)}
          </DescriptionList.Item>
        </DescriptionList.Root>
      ) : (
        <div className="mt-2 text-xs text-text-muted">
          <p>{t("overview_metrics_unavailable")}</p>
          <p className="mt-1 font-mono">{section.message}</p>
        </div>
      )}
    </div>
  )
}
