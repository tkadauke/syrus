import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPersistentVolumeClaims } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

export function StorageTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const pvcs = useQuery({
    queryKey: [ "k8s_cluster", "pvcs", clusterId, namespace ],
    queryFn: () => fetchKubernetesPersistentVolumeClaims(clusterId, namespace)
  })

  if (pvcs.isPending) return <PanelMessage>{t("storage_loading")}</PanelMessage>
  if (pvcs.isError) return <PanelMessage tone="error">{errorMessage(pvcs.error, t("storage_error_loading"))}</PanelMessage>
  if (pvcs.data.persistent_volume_claims.length === 0) return <PanelMessage>{t("storage_empty")}</PanelMessage>

  const visible = pvcs.data.persistent_volume_claims.filter((pvc) =>
    matchesSearch(query, pvc.name, pvc.namespace, pvc.status, pvc.storage_class, pvc.volume_name)
  )

  return (
    <div aria-label={t("aria_storage_tab")} className="space-y-3">
      <TableSearch onChange={setQuery} query={query} />
      {pvcs.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <>
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
              {visible.map((pvc) => {
                const open = () =>
                  detail.openDetail({
                    kind: "pvc",
                    kindLabel: t("tab_storage"),
                    name: pvc.name,
                    namespace: pvc.namespace,
                    fields: [
                      { label: t("col_namespace"), value: pvc.namespace },
                      { label: t("col_status"), value: pvc.status || "-" },
                      { label: t("col_capacity"), value: pvc.capacity || "-" },
                      { label: t("col_storage_class"), value: pvc.storage_class || "-" },
                      { label: t("col_age"), value: formatAge(pvc.created_at) }
                    ]
                  })

                return (
                  <DataTable.Row interactive key={`${pvc.namespace}/${pvc.name}`} onClick={open}>
                    <DataTable.Cell className="font-medium">
                      <DetailNameButton name={pvc.name} onOpen={open} />
                    </DataTable.Cell>
                    <DataTable.Cell className="text-text-secondary">{pvc.namespace}</DataTable.Cell>
                    <DataTable.Cell>
                      <StatusBadge tone={pvc.status === "Bound" ? "success" : "warning"}>{pvc.status || "-"}</StatusBadge>
                    </DataTable.Cell>
                    <DataTable.Cell className="text-text-secondary">{pvc.capacity || "-"}</DataTable.Cell>
                    <DataTable.Cell className="text-text-secondary">{pvc.storage_class || "-"}</DataTable.Cell>
                    <DataTable.Cell className="text-text-secondary">{formatAge(pvc.created_at)}</DataTable.Cell>
                  </DataTable.Row>
                )
              })}
            </DataTable.Body>
          </DataTable.Root>
          <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
        </>
      )}
    </div>
  )
}
