import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesEvents } from "../../api/kubernetesResources"
import { StatusBadge } from "../StatusBadge"

export function EventsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const events = useQuery({
    queryKey: [ "k8s_cluster", "events", clusterId, namespace ],
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
          <ul className="divide-y divide-gray-100 dark:divide-gray-900 rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
            {events.data.events.map((event, index) => (
              <li className="flex flex-wrap items-start gap-3 px-4 py-3 text-sm" key={`${event.namespace}/${event.name}/${index}`}>
                <StatusBadge tone={event.type === "Warning" ? "warning" : "neutral"}>{event.type || "-"}</StatusBadge>
                <div className="min-w-0 flex-1">
                  <p className="font-medium text-gray-900 dark:text-gray-100">
                    {event.reason} <span className="font-normal text-gray-500 dark:text-gray-400">({event.involved_object.kind} {event.involved_object.name})</span>
                  </p>
                  <p className="text-gray-700 dark:text-gray-300">{event.message}</p>
                </div>
                <span className="shrink-0 text-xs text-gray-500 dark:text-gray-400">{event.last_timestamp || event.first_timestamp || "-"}</span>
              </li>
            ))}
          </ul>
        )
      ) : null}
    </div>
  )
}
