import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesEvents, fetchKubernetesPods } from "../../api/kubernetesResources"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

// Canned polling queries, directly mirroring
// plugins/mysql_db_browser/app/frontend/components/MysqlLiveTab.tsx: a fixed
// set of read-only queries with a 10s auto-refresh, not a bespoke live feed.
const CANNED_QUERIES = [
  { id: "pod_status", labelKey: "live_pod_status" },
  { id: "recent_events", labelKey: "live_recent_events" }
] as const

export function LiveTab({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const [selectedId, setSelectedId] = useState<(typeof CANNED_QUERIES)[number]["id"]>(CANNED_QUERIES[0].id)

  return (
    <section aria-label={t("aria_live_tab")} className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap gap-2" role="tablist">
          {CANNED_QUERIES.map((query) => (
            <button
              aria-selected={query.id === selectedId}
              className={`rounded border px-3 py-1.5 text-sm font-medium ${
                query.id === selectedId
                  ? "border-brand bg-brand/10 text-brand dark:border-brand/70 dark:text-brand-emphasis"
                  : "border-border bg-surface text-text-primary hover:bg-surface-raised"
              }`}
              key={query.id}
              onClick={() => setSelectedId(query.id)}
              role="tab"
              type="button"
            >
              {t(query.labelKey)}
            </button>
          ))}
        </div>
        <p className="text-xs text-text-secondary">{t("live_auto_refresh")}</p>
      </div>

      {selectedId === "pod_status" ? <PodStatusLive clusterId={clusterId} /> : null}
      {selectedId === "recent_events" ? <RecentEventsLive clusterId={clusterId} /> : null}
    </section>
  )
}

function PodStatusLive({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const { query, setQuery } = useTableSearch()
  const pods = useQuery({
    queryKey: [ "k8s_cluster", "live", "pods", clusterId ],
    queryFn: () => fetchKubernetesPods(clusterId),
    refetchInterval: 10_000
  })

  if (pods.isPending) return <PanelMessage>{t("live_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("live_error_loading_pods"))}</PanelMessage>
  if (pods.data.pods.length === 0) return <PanelMessage>{t("workloads_empty_pods")}</PanelMessage>

  const visible = pods.data.pods.filter((pod) => matchesSearch(query, pod.name, pod.namespace, pod.status))

  return (
    <div className="space-y-3">
      <TableSearch onChange={setQuery} query={query} />
      {pods.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <ul className="divide-y divide-border rounded border border-border bg-surface">
          {visible.map((pod) => (
            <li className="flex items-center justify-between gap-3 px-4 py-2 text-sm" key={`${pod.namespace}/${pod.name}`}>
              <span className="min-w-0 truncate font-medium text-text-primary">{pod.namespace}/{pod.name}</span>
              <StatusBadge tone={pod.status === "Running" ? "success" : pod.status === "Failed" ? "error" : "neutral"}>{pod.status || "-"}</StatusBadge>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

function RecentEventsLive({ clusterId }: { clusterId: number }) {
  const { t } = useT("k8s_cluster")
  const { query, setQuery } = useTableSearch()
  const events = useQuery({
    queryKey: [ "k8s_cluster", "live", "events", clusterId ],
    queryFn: () => fetchKubernetesEvents(clusterId),
    refetchInterval: 10_000
  })

  if (events.isPending) return <PanelMessage>{t("live_loading_events")}</PanelMessage>
  if (events.isError) return <PanelMessage tone="error">{errorMessage(events.error, t("live_error_loading_events"))}</PanelMessage>
  if (events.data.events.length === 0) return <PanelMessage>{t("events_empty")}</PanelMessage>

  const visible = events.data.events
    .filter((event) => matchesSearch(query, event.reason, event.message, event.involved_object.kind, event.involved_object.name))
    .slice(0, 20)

  return (
    <div className="space-y-3">
      <TableSearch onChange={setQuery} query={query} />
      {events.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <ul className="divide-y divide-border rounded border border-border bg-surface">
          {visible.map((event, index) => (
            <li className="flex items-center gap-3 px-4 py-2 text-sm" key={`${event.namespace}/${event.name}/${index}`}>
              <StatusBadge tone={event.type === "Warning" ? "warning" : "neutral"}>{event.type || "-"}</StatusBadge>
              <span className="min-w-0 flex-1 truncate text-text-secondary">{event.reason}: {event.message}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
