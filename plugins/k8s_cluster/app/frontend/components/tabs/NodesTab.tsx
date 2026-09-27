import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNodes, type KubernetesNodeRow } from "../../api/kubernetesResources"
import { formatAge, formatKubernetesCpu, formatKubernetesMemory } from "../../lib/k8sFormat"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

export function NodesTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const nodes = useQuery({
    queryKey: ["k8s_cluster", "nodes", clusterId],
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
        <KubernetesResourceTable
          columns={nodeColumns(t, open)}
          defaultSort={{ column: "name", direction: "asc" }}
          empty={<PanelMessage>{t("nodes_empty")}</PanelMessage>}
          getRowKey={(node) => node.name}
          rows={visible}
          storageKey="syrus.k8s_cluster.nodes.columns"
          summary={t("tab_nodes")}
        />
      )}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </div>
  )
}

function nodeColumns(t: ReturnType<typeof useT>["t"], onOpen: (node: KubernetesNodeRow) => void): Array<KubernetesResourceTableColumn<KubernetesNodeRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (node) => <DetailNameButton name={node.name} onOpen={() => onOpen(node)} />,
      required: true,
      sort: "name",
      sortValue: (node) => node.name
    },
    {
      key: "ready",
      header: t("col_conditions"),
      filterValue: (node) => (node.ready ? t("node_ready") : t("node_not_ready")),
      render: (node) => <StatusBadge tone={node.ready ? "success" : "error"}>{node.ready ? t("node_ready") : t("node_not_ready")}</StatusBadge>,
      sort: "ready",
      sortValue: (node) => Number(node.ready)
    },
    {
      key: "roles",
      header: t("col_roles"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (node) => node.roles,
      render: (node) => node.roles.join(", "),
      sort: "roles",
      sortValue: (node) => node.roles.join(", ")
    },
    {
      key: "capacity",
      header: t("col_capacity"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      filterValue: (node) => `${formatKubernetesCpu(node.capacity_cpu)} / ${formatKubernetesMemory(node.capacity_memory)}`,
      render: (node) => `${formatKubernetesCpu(node.capacity_cpu)} / ${formatKubernetesMemory(node.capacity_memory)}`
    },
    {
      key: "allocatable",
      header: t("col_allocatable"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      filterValue: (node) => `${formatKubernetesCpu(node.allocatable_cpu)} / ${formatKubernetesMemory(node.allocatable_memory)}`,
      render: (node) => `${formatKubernetesCpu(node.allocatable_cpu)} / ${formatKubernetesMemory(node.allocatable_memory)}`
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (node) => formatAge(node.created_at),
      sort: "created_at",
      sortValue: (node) => node.created_at
    }
  ]
}
