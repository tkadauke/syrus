import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNodes } from "../../api/kubernetesResources"
import { formatAge, formatKubernetesCpu, formatKubernetesMemory } from "../../lib/k8sFormat"
import { StatusBadge } from "../StatusBadge"

export function NodesTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const nodes = useQuery({
    queryKey: [ "k8s_cluster", "nodes", clusterId ],
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
                {nodes.data.nodes.map((node) => (
                  <DataTable.Row key={node.name}>
                    <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">{node.name}</DataTable.Cell>
                    <DataTable.Cell>
                      <StatusBadge tone={node.ready ? "success" : "error"}>{node.ready ? t("node_ready") : t("node_not_ready")}</StatusBadge>
                    </DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{node.roles.join(", ")}</DataTable.Cell>
                    <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">
                      {formatKubernetesCpu(node.capacity_cpu)} / {formatKubernetesMemory(node.capacity_memory)}
                    </DataTable.Cell>
                    <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">
                      {formatKubernetesCpu(node.allocatable_cpu)} / {formatKubernetesMemory(node.allocatable_memory)}
                    </DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{formatAge(node.created_at)}</DataTable.Cell>
                  </DataTable.Row>
                ))}
            </DataTable.Body>
          </DataTable.Root>
        )
      ) : null}
    </div>
  )
}
