import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPersistentVolumeClaims, type KubernetesPersistentVolumeClaimRow } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

export function StorageTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const pvcs = useQuery({
    queryKey: ["k8s_cluster", "pvcs", clusterId, namespace],
    queryFn: () => fetchKubernetesPersistentVolumeClaims(clusterId, namespace)
  })

  const visible = (pvcs.data?.persistent_volume_claims ?? []).filter((pvc) =>
    matchesSearch(query, pvc.name, pvc.namespace, pvc.status, pvc.storage_class, pvc.volume_name)
  )

  const open = (pvc: KubernetesPersistentVolumeClaimRow) =>
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
    <div aria-label={t("aria_storage_tab")} className="space-y-3">
      {pvcs.isPending ? <PanelMessage>{t("storage_loading")}</PanelMessage> : null}
      {pvcs.isError ? <PanelMessage tone="error">{errorMessage(pvcs.error, t("storage_error_loading"))}</PanelMessage> : null}
      {pvcs.isSuccess ? (
        pvcs.data.persistent_volume_claims.length === 0 ? (
          <PanelMessage>{t("storage_empty")}</PanelMessage>
        ) : (
          <>
            <TableSearch onChange={setQuery} query={query} />
            {pvcs.data.truncated ? <TruncatedNotice /> : null}
            {visible.length === 0 ? (
              <SearchNoMatches />
            ) : (
              <KubernetesResourceTable
                columns={pvcColumns(t, open)}
                defaultSort={{ column: "name", direction: "asc" }}
                empty={<PanelMessage>{t("storage_empty")}</PanelMessage>}
                getRowKey={(pvc) => `${pvc.namespace}/${pvc.name}`}
                rows={visible}
                storageKey="syrus.k8s_cluster.pvcs.columns"
                summary={t("tab_storage")}
              />
            )}
          </>
        )
      ) : null}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </div>
  )
}

function pvcColumns(t: ReturnType<typeof useT>["t"], open: (pvc: KubernetesPersistentVolumeClaimRow) => void): Array<KubernetesResourceTableColumn<KubernetesPersistentVolumeClaimRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (pvc) => <DetailNameButton name={pvc.name} onOpen={() => open(pvc)} />,
      required: true,
      sort: "name",
      sortValue: (pvc) => pvc.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pvc) => pvc.namespace,
      sort: "namespace",
      sortValue: (pvc) => pvc.namespace
    },
    {
      key: "status",
      header: t("col_status"),
      filterValue: (pvc) => pvc.status,
      render: (pvc) => <StatusBadge tone={pvc.status === "Bound" ? "success" : "warning"}>{pvc.status || "-"}</StatusBadge>,
      sort: "status",
      sortValue: (pvc) => pvc.status
    },
    {
      key: "capacity",
      header: t("col_capacity"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pvc) => pvc.capacity || "-",
      sort: "capacity",
      sortValue: (pvc) => pvc.capacity
    },
    {
      key: "storage_class",
      header: t("col_storage_class"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pvc) => pvc.storage_class || "-",
      sort: "storage_class",
      sortValue: (pvc) => pvc.storage_class
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (pvc) => formatAge(pvc.created_at),
      sort: "created_at",
      sortValue: (pvc) => pvc.created_at
    }
  ]
}
