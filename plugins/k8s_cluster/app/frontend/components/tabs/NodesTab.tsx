import { useQuery } from "@tanstack/react-query"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNodes } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { Panel, StatusBadge } from "../Panel"

export function NodesTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const nodes = useQuery({
    queryKey: [ "k8s_cluster", "nodes", clusterId ],
    queryFn: () => fetchKubernetesNodes(clusterId)
  })

  return (
    <div aria-label={t("aria_nodes_tab")}>
      {nodes.isPending ? <Panel>{t("nodes_loading")}</Panel> : null}
      {nodes.isError ? <Panel tone="error">{errorMessage(nodes.error, t("nodes_error_loading"))}</Panel> : null}
      {nodes.isSuccess ? (
        nodes.data.nodes.length === 0 ? (
          <Panel>{t("nodes_empty")}</Panel>
        ) : (
          <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
              <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
                <tr>
                  <th className="px-4 py-2">{t("col_name")}</th>
                  <th className="px-4 py-2">{t("col_conditions")}</th>
                  <th className="px-4 py-2">{t("col_roles")}</th>
                  <th className="px-4 py-2">{t("col_capacity")}</th>
                  <th className="px-4 py-2">{t("col_allocatable")}</th>
                  <th className="px-4 py-2">{t("col_age")}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
                {nodes.data.nodes.map((node) => (
                  <tr key={node.name}>
                    <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{node.name}</td>
                    <td className="px-4 py-2">
                      <StatusBadge tone={node.ready ? "success" : "error"}>{node.ready ? t("node_ready") : t("node_not_ready")}</StatusBadge>
                    </td>
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{node.roles.join(", ")}</td>
                    <td className="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">
                      {node.capacity_cpu || "-"} / {node.capacity_memory || "-"}
                    </td>
                    <td className="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">
                      {node.allocatable_cpu || "-"} / {node.allocatable_memory || "-"}
                    </td>
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(node.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      ) : null}
    </div>
  )
}
