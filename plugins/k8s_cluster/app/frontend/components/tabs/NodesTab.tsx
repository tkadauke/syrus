import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNodes, type KubernetesNodeRow } from "../../api/kubernetesResources"
import { formatAge, formatKubernetesCpu, formatKubernetesMemory } from "../../lib/k8sFormat"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

export function NodesTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const nodes = useQuery({
    queryKey: [ "k8s_cluster", "nodes", clusterId ],
    queryFn: () => fetchKubernetesNodes(clusterId)
  })

  if (nodes.isPending) return <PanelMessage>{t("nodes_loading")}</PanelMessage>
  if (nodes.isError) return <PanelMessage tone="error">{errorMessage(nodes.error, t("nodes_error_loading"))}</PanelMessage>
  if (nodes.data.nodes.length === 0) return <PanelMessage>{t("nodes_empty")}</PanelMessage>

  const visible = nodes.data.nodes.filter((node) =>
    matchesSearch(query, node.name, node.internal_ip, node.kubelet_version, ...node.roles)
  )

  const open = (node: KubernetesNodeRow) =>
    detail.openDetail({
      kind: "node",
      kindLabel: t("tab_nodes"),
      name: node.name,
      namespace: null,
      fields: [
        { label: t("col_roles"), value: node.roles.length === 0 ? "-" : node.roles.join(", ") },
        { label: t("col_capacity"), value: `${formatKubernetesCpu(node.capacity_cpu)} / ${formatKubernetesMemory(node.capacity_memory)}` },
        { label: t("col_allocatable"), value: `${formatKubernetesCpu(node.allocatable_cpu)} / ${formatKubernetesMemory(node.allocatable_memory)}` },
        { label: t("col_age"), value: formatAge(node.created_at) }
      ]
    })

  return (
    <div aria-label={t("aria_nodes_tab")} className="space-y-3">
      <TableSearch onChange={setQuery} query={query} />
      {nodes.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <DataTable.Root density="compact">
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_conditions")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_roles")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_capacity")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_allocatable")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {visible.map((node) => (
              <DataTable.Row interactive key={node.name} onClick={() => open(node)}>
                <DataTable.Cell className="font-medium">
                  <DetailNameButton name={node.name} onOpen={() => open(node)} />
                </DataTable.Cell>
                <DataTable.Cell>
                  <StatusBadge tone={node.ready ? "success" : "error"}>{node.ready ? t("node_ready") : t("node_not_ready")}</StatusBadge>
                </DataTable.Cell>
                <DataTable.Cell className="text-text-secondary">{node.roles.join(", ")}</DataTable.Cell>
                <DataTable.Cell className="font-mono text-text-secondary">
                  {formatKubernetesCpu(node.capacity_cpu)} / {formatKubernetesMemory(node.capacity_memory)}
                </DataTable.Cell>
                <DataTable.Cell className="font-mono text-text-secondary">
                  {formatKubernetesCpu(node.allocatable_cpu)} / {formatKubernetesMemory(node.allocatable_memory)}
                </DataTable.Cell>
                <DataTable.Cell className="text-text-secondary">{formatAge(node.created_at)}</DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </div>
  )
}
