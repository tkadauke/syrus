import { useQuery } from "@tanstack/react-query"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPersistentVolumeClaims } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { Panel, StatusBadge } from "../Panel"

export function StorageTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const pvcs = useQuery({
    queryKey: [ "k8s_cluster", "pvcs", clusterId, namespace ],
    queryFn: () => fetchKubernetesPersistentVolumeClaims(clusterId, namespace)
  })

  return (
    <div aria-label={t("aria_storage_tab")}>
      {pvcs.isPending ? <Panel>{t("storage_loading")}</Panel> : null}
      {pvcs.isError ? <Panel tone="error">{errorMessage(pvcs.error, t("storage_error_loading"))}</Panel> : null}
      {pvcs.isSuccess ? (
        pvcs.data.persistent_volume_claims.length === 0 ? (
          <Panel>{t("storage_empty")}</Panel>
        ) : (
          <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
              <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
                <tr>
                  <th className="px-4 py-2">{t("col_name")}</th>
                  <th className="px-4 py-2">{t("col_namespace")}</th>
                  <th className="px-4 py-2">{t("col_status")}</th>
                  <th className="px-4 py-2">{t("col_capacity")}</th>
                  <th className="px-4 py-2">{t("col_storage_class")}</th>
                  <th className="px-4 py-2">{t("col_age")}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
                {pvcs.data.persistent_volume_claims.map((pvc) => (
                  <tr key={`${pvc.namespace}/${pvc.name}`}>
                    <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{pvc.name}</td>
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{pvc.namespace}</td>
                    <td className="px-4 py-2">
                      <StatusBadge tone={pvc.status === "Bound" ? "success" : "warning"}>{pvc.status || "-"}</StatusBadge>
                    </td>
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{pvc.capacity || "-"}</td>
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{pvc.storage_class || "-"}</td>
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(pvc.created_at)}</td>
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
