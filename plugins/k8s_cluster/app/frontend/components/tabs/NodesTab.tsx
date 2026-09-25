import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNodes, type KubernetesNodeRow } from "../../api/kubernetesResources"
import { formatAge, formatKubernetesCpu, formatKubernetesMemory } from "../../lib/k8sFormat"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { StatusBadge } from "../StatusBadge"

export function NodesTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const nodes = useQuery({
    queryKey: ["k8s_cluster", "nodes", clusterId],
    queryFn: () => fetchKubernetesNodes(clusterId)
  })

  return (
    <div aria-label={t("aria_nodes_tab")}>
      {nodes.isPending ? <PanelMessage>{t("nodes_loading")}</PanelMessage> : null}
      {nodes.isError ? <PanelMessage tone="error">{errorMessage(nodes.error, t("nodes_error_loading"))}</PanelMessage> : null}
      {nodes.isSuccess ? (
        nodes.data.nodes.length === 0 ? (
          <PanelMessage>{t("nodes_empty")}</PanelMessage>
        ) : (
          <KubernetesResourceTable
            columns={nodeColumns(t)}
            defaultSort={{ column: "name", direction: "asc" }}
            empty={<PanelMessage>{t("nodes_empty")}</PanelMessage>}
            getRowKey={(node) => node.name}
            rows={nodes.data.nodes}
            storageKey="syrus.k8s_cluster.nodes.columns"
            summary={t("tab_nodes")}
          />
        )
      ) : null}
    </div>
  )
}

function nodeColumns(t: ReturnType<typeof useT>["t"]): Array<KubernetesResourceTableColumn<KubernetesNodeRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (node) => node.name,
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
