import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPersistentVolumeClaims, type KubernetesPersistentVolumeClaimRow } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { StatusBadge } from "../StatusBadge"

export function StorageTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const pvcs = useQuery({
    queryKey: ["k8s_cluster", "pvcs", clusterId, namespace],
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
          <KubernetesResourceTable
            columns={pvcColumns(t)}
            defaultSort={{ column: "name", direction: "asc" }}
            empty={<PanelMessage>{t("storage_empty")}</PanelMessage>}
            getRowKey={(pvc) => `${pvc.namespace}/${pvc.name}`}
            rows={pvcs.data.persistent_volume_claims}
            storageKey="syrus.k8s_cluster.pvcs.columns"
            summary={t("tab_storage")}
          />
        )
      ) : null}
    </div>
  )
}

function pvcColumns(t: ReturnType<typeof useT>["t"]): Array<KubernetesResourceTableColumn<KubernetesPersistentVolumeClaimRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (pvc) => pvc.name,
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
