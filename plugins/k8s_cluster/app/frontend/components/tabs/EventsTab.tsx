import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesEvents } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

export function EventsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const { query, setQuery } = useTableSearch()
  const events = useQuery({
    queryKey: [ "k8s_cluster", "events", clusterId, namespace ],
    queryFn: () => fetchKubernetesEvents(clusterId, namespace)
  })

  if (events.isPending) return <PanelMessage>{t("events_loading")}</PanelMessage>
  if (events.isError) return <PanelMessage tone="error">{errorMessage(events.error, t("events_error_loading"))}</PanelMessage>
  if (events.data.events.length === 0) return <PanelMessage>{t("events_empty")}</PanelMessage>

  const visible = events.data.events.filter((event) =>
    matchesSearch(query, event.name, event.namespace, event.type, event.reason, event.message, event.involved_object.kind, event.involved_object.name)
  )

  return (
    <div aria-label={t("aria_events_tab")} className="space-y-3">
      <TableSearch onChange={setQuery} query={query} />
      {events.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <ul className="divide-y divide-border rounded border border-border bg-surface">
          {visible.map((event, index) => {
            const timestamp = event.last_timestamp || event.first_timestamp
            return (
              <li className="flex flex-wrap items-start gap-3 px-4 py-3 text-sm" key={`${event.namespace}/${event.name}/${index}`}>
                <StatusBadge tone={event.type === "Warning" ? "warning" : "neutral"}>{event.type || "-"}</StatusBadge>
                <div className="min-w-0 flex-1">
                  <p className="font-medium text-text-primary">
                    {event.reason} <span className="font-normal text-text-secondary">({event.involved_object.kind} {event.involved_object.name})</span>
                  </p>
                  <p className="text-text-secondary">{event.message}</p>
                </div>
                <span className="shrink-0 text-xs text-text-secondary" title={timestamp || undefined}>{formatAge(timestamp)}</span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
