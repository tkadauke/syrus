import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPersistentVolumeClaims } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { StatusBadge } from "../StatusBadge"

export function StorageTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const pvcs = useQuery({
    queryKey: [ "k8s_cluster", "pvcs", clusterId, namespace ],
    queryFn: () => fetchKubernetesPersistentVolumeClaims(clusterId, namespace)
  })

  return (
    <div aria-label={t("aria_storage_tab")}>
      {pvcs.isPending ? <PanelMessage>{t("storage_loading")}</PanelMessage> : null}
      {pvcs.isError ? <PanelMessage tone="error">{errorMessage(pvcs.error, t("storage_error_loading"))}</PanelMessage> : null}
      {pvcs.isSuccess ? (
        pvcs.data.persistent_volume_claims.length === 0 ? (
          <PanelMessage>{t("storage_empty")}</PanelMessage>
        ) : (
          <DataTable.Root density="compact">
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_status")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_capacity")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_storage_class")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
                {pvcs.data.persistent_volume_claims.map((pvc) => (
                  <DataTable.Row key={`${pvc.namespace}/${pvc.name}`}>
                    <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">{pvc.name}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{pvc.namespace}</DataTable.Cell>
                    <DataTable.Cell>
                      <StatusBadge tone={pvc.status === "Bound" ? "success" : "warning"}>{pvc.status || "-"}</StatusBadge>
                    </DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{pvc.capacity || "-"}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{pvc.storage_class || "-"}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-700 dark:text-gray-300">{formatAge(pvc.created_at)}</DataTable.Cell>
                  </DataTable.Row>
                ))}
            </DataTable.Body>
          </DataTable.Root>
        )
      ) : null}
    </div>
  )
}
