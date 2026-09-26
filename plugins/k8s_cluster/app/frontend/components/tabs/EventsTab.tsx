import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesEvents, type KubernetesEventRow } from "../../api/kubernetesResources"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { StatusBadge } from "../StatusBadge"

export function EventsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const events = useQuery({
    queryKey: ["k8s_cluster", "events", clusterId, namespace],
    queryFn: () => fetchKubernetesEvents(clusterId, namespace)
  })

  return (
    <div aria-label={t("aria_events_tab")}>
      {events.isPending ? <PanelMessage>{t("events_loading")}</PanelMessage> : null}
      {events.isError ? <PanelMessage tone="error">{errorMessage(events.error, t("events_error_loading"))}</PanelMessage> : null}
      {events.isSuccess ? (
        events.data.events.length === 0 ? (
          <PanelMessage>{t("events_empty")}</PanelMessage>
        ) : (
          <KubernetesResourceTable
            columns={eventColumns(t)}
            defaultSort={{ column: "last_timestamp", direction: "desc" }}
            empty={<PanelMessage>{t("events_empty")}</PanelMessage>}
            getRowKey={(event) => `${event.namespace}/${event.name}/${event.last_timestamp || event.first_timestamp || ""}/${event.count}`}
            rows={events.data.events}
            storageKey="syrus.k8s_cluster.events.columns"
            summary={t("tab_events")}
          />
        )
      ) : null}
    </div>
  )
}

function eventColumns(t: ReturnType<typeof useT>["t"]): Array<KubernetesResourceTableColumn<KubernetesEventRow>> {
  return [
    {
      key: "type",
      header: t("col_type"),
      filterValue: (event) => event.type,
      render: (event) => <StatusBadge tone={event.type === "Warning" ? "warning" : "neutral"}>{event.type || "-"}</StatusBadge>,
      sort: "type",
      sortValue: (event) => event.type
    },
    {
      key: "reason",
      header: t("col_reason"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (event) => event.reason || "-",
      required: true,
      sort: "reason",
      sortValue: (event) => event.reason
    },
    {
      key: "object",
      header: t("col_object"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (event) => [event.involved_object.kind, event.involved_object.name],
      render: (event) => `${event.involved_object.kind} ${event.involved_object.name}`,
      sort: "object",
      sortValue: (event) => `${event.involved_object.kind} ${event.involved_object.name}`
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (event) => event.namespace || "-",
      sort: "namespace",
      sortValue: (event) => event.namespace
    },
    {
      key: "message",
      header: t("col_message"),
      className: "min-w-80 whitespace-normal text-gray-700 dark:text-gray-300",
      render: (event) => event.message || "-",
      defaultVisible: true
    },
    {
      key: "count",
      header: t("col_count"),
      className: "text-gray-700 dark:text-gray-300",
      render: (event) => event.count,
      sort: "count",
      sortValue: (event) => event.count
    },
    {
      key: "last_timestamp",
      header: t("col_last_seen"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (event) => event.last_timestamp || event.first_timestamp,
      render: (event) => event.last_timestamp || event.first_timestamp || "-",
      sort: "last_timestamp",
      sortValue: (event) => event.last_timestamp || event.first_timestamp
    }
  ]
}
