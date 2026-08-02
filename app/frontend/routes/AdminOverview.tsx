import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation } from "react-router-dom"
import { fetchAdminOverview, type AdminOverviewPayload } from "../api/adminOverview"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"

export function AdminOverview() {
  const { t } = useT("admin")
  usePageTitle(t("title"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const overview = useQuery({
    queryKey: ["admin", "overview"],
    queryFn: fetchAdminOverview
  })

  if (overview.isPending) {
    return <main aria-label={t("overview.aria_overview")} className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("overview.loading")}</main>
  }

  if (overview.isError) {
    return (
      <main aria-label={t("overview.aria_overview")} className="p-6">
        <p className="text-sm text-red-700 dark:text-red-300">{t("overview.error_load")}</p>
      </main>
    )
  }

  const data = overview.data
  const captureRate = data.agent_session_capture_rate.rate
  const overdueRecurring = data.recurring.overdue || []
  const dataRoot = data.data_root_disk_usage
  const workerHealthTone = aggregateWorkerHealthTone(data.workers, data.worker_health)

  return (
    <main aria-label={t("overview.aria_overview")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("overview.heading")}</h1>
      </header>

      <section aria-label={t("overview.aria_metrics")} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Metric title={t("overview.active_runs")} value={data.active_runs.total} context={triggerContext(data.active_runs.by_trigger, t("overview.all_idle"))} href={withRoutePrefix("/admin/queue/active", prefix)} />
        <Metric title={t("overview.queued_runs")} value={data.queued_runs.total} context={data.queued_runs.total > 0 ? t("overview.waiting_for_worker") : t("overview.queue_empty")} href={withRoutePrefix("/admin/queue/pending", prefix)} />
        <Metric title={t("overview.workers")} value={data.workers.unreachable ? "?" : data.workers.total ?? 0} context={workersContext(data.workers, t, data.worker_health)} href={withRoutePrefix("/admin/queue/workers", prefix)} tone={workerHealthTone} />
        <Metric title={t("overview.recurring_jobs")} value={overdueRecurring.length} context={overdueRecurring.length > 0 ? overdueRecurring.map((task) => task.key).join(", ") : t("overview.all_firing")} href={withRoutePrefix("/admin/queue/recurring", prefix)} tone={overdueRecurring.length > 0 ? "alarm" : "ok"} />
        <Metric title={t("overview.failed_runs")} value={data.recent_failures_24h.total} context={triggerContext(data.recent_failures_24h.by_trigger, t("overview.no_failures"))} href={withRoutePrefix("/admin/queue/failed", prefix)} tone={data.recent_failures_24h.total > 0 ? "warn" : "ok"} />
        <Metric title={t("overview.provider_circuits")} value={data.provider_circuits.length} context={data.provider_circuits.length > 0 ? data.provider_circuits.map((circuit) => circuit.provider).join(", ") : t("overview.all_closed")} tone={data.provider_circuits.length > 0 ? "alarm" : "ok"} />
        <Metric title={t("overview.github_rate_limits")} value={data.github_rate_limits.length} context={data.github_rate_limits.length > 0 ? data.github_rate_limits.map((user) => user.email).join(", ") : t("overview.all_healthy")} tone={data.github_rate_limits.length > 0 ? "warn" : "ok"} />
        <Metric title={t("overview.agent_session_capture")} value={captureRate == null ? "-" : `${Math.round(captureRate * 100)}%`} context={t("overview.capture_of", { captured: data.agent_session_capture_rate.captured, total: data.agent_session_capture_rate.total })} tone={captureRate == null || captureRate >= 0.95 ? "ok" : "warn"} />
        <Metric title={t("overview.data_root_disk")} value={dataRoot ? `${dataRoot.used_percent}%` : "?"} context={dataRoot ? `${t("overview.disk_free", { free: formatBytes(dataRoot.available_bytes), path: dataRoot.path })}${dataRoot.hostname ? ` (${dataRoot.hostname})` : ""}` : t("overview.unavailable")} tone={dataRootTone(dataRoot?.level)} />
        <Metric title={t("overview.stuck_things")} value={data.stuck_pagination.total} context={data.stuck_pagination.total > 0 ? t("overview.needs_attention") : t("overview.nothing_flagged")} href={withRoutePrefix("/admin/stuck", prefix)} tone={data.stuck.some((item) => item.severity === "alarm") ? "alarm" : data.stuck_pagination.total > 0 ? "warn" : "ok"} />
      </section>

      {data.stuck.length > 0 ? (
        <section aria-label={t("overview.aria_stuck")} className="overflow-hidden rounded border border-amber-200 dark:border-amber-800 bg-white dark:bg-gray-900">
          <div className="bg-amber-50 dark:bg-amber-950/40 px-4 py-2 text-xs font-medium uppercase text-amber-700 dark:text-amber-300">{t("overview.stuck_section")}</div>
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {data.stuck.map((item) => (
              <li className="flex items-center justify-between gap-3 px-4 py-3 text-sm" key={`${item.kind}-${item.run_id}-${item.workflow_id}`}>
                <StuckDetail item={item} prefix={prefix} />
                <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-mono text-xs text-gray-600 dark:text-gray-300">{item.age_label}</span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <ChatScopedEventsSection data={data.chat_scoped_events} prefix={prefix} />
    </main>
  )
}

function StuckDetail({ item, prefix }: { item: AdminOverviewPayload["stuck"][number]; prefix: string }) {
  const href = item.workflow_path || item.job_path
  if (!href) return <span className="text-gray-800 dark:text-gray-100">{item.detail}</span>

  return (
    <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix(href, prefix)}>
      {item.detail}
    </Link>
  )
}

function Metric({
  title,
  value,
  context,
  href,
  tone = "idle"
}: {
  title: string
  value: number | string
  context: string
  href?: string
  tone?: "idle" | "ok" | "warn" | "alarm"
}) {
  const toneClass = {
    idle: "border-gray-200 dark:border-gray-700",
    ok: "border-emerald-200 dark:border-emerald-800",
    warn: "border-amber-200 dark:border-amber-800",
    alarm: "border-red-200 dark:border-red-800"
  }[tone]
  const className = `rounded border ${toneClass} bg-white dark:bg-gray-900 p-4 ${href ? "block hover:bg-gray-50 dark:hover:bg-gray-800" : ""}`
  const content = (
    <>
      <h2 className="text-sm font-medium text-gray-700 dark:text-gray-200">{title}</h2>
      <p className="mt-2 text-3xl font-semibold text-gray-900 dark:text-gray-100">{value}</p>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{context}</p>
    </>
  )

  if (href) {
    return <Link className={className} to={href}>{content}</Link>
  }

  return (
    <article className={className}>
      {content}
    </article>
  )
}

function ChatScopedEventsSection({ data, prefix }: { data: AdminOverviewPayload["chat_scoped_events"]; prefix: string }) {
  const { t } = useT("admin")
  const failures = data.failures || []
  const recent = data.recent || []

  return (
    <section aria-label={t("overview.aria_chat_events")} className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-100 bg-gray-50 px-4 py-3 dark:border-gray-800 dark:bg-gray-800 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("overview.chat_events_section")}</h2>
          <p className="text-xs text-gray-500 dark:text-gray-400">{t("overview.chat_events_window", { hours: data.window_hours, total: data.total })}</p>
        </div>
        <div className="flex flex-wrap gap-2 text-xs">
          <DecisionPill label="no_op" value={data.by_decision.no_op} />
          <DecisionPill label="respond" value={data.by_decision.respond} />
          <DecisionPill label="act" value={data.by_decision.act} />
          <DecisionPill label="failed" value={data.by_state.failed || 0} tone={(data.by_state.failed || 0) > 0 ? "alarm" : "idle"} />
        </div>
      </div>

      {failures.length > 0 ? (
        <div className="border-b border-red-100 bg-red-50 px-4 py-3 dark:border-red-900 dark:bg-red-950/30">
          <div className="mb-2 text-xs font-medium uppercase text-red-700 dark:text-red-300">{t("overview.chat_event_failures")}</div>
          <ul className="space-y-2">
            {failures.map((event) => (
              <li className="text-xs text-red-800 dark:text-red-200" key={`failure-${event.id}`}>
                <EventLinks event={event} prefix={prefix} />
                <span className="ml-2 font-mono">{event.error}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {recent.length > 0 ? (
        <ul className="divide-y divide-gray-100 dark:divide-gray-800">
          {recent.map((event) => (
            <li className="grid gap-2 px-4 py-3 text-sm lg:grid-cols-[minmax(0,1fr)_auto]" key={event.id}>
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-gray-900 dark:text-gray-100">{event.summary || event.source_kind}</span>
                  <span className="rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{event.source_kind}</span>
                  {event.severity ? <span className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{event.severity}</span> : null}
                </div>
                <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                  <EventLinks event={event} prefix={prefix} />
                  {event.reason ? <span className="ml-2">{event.reason}</span> : null}
                </div>
              </div>
              <div className="flex flex-wrap gap-2 text-xs lg:justify-end">
                <DecisionPill label={event.decision || event.evaluator_state} value={event.delivery_state} tone={event.evaluator_state === "failed" ? "alarm" : "idle"} />
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <div className="px-4 py-6 text-sm text-gray-500 dark:text-gray-400">{t("overview.no_chat_events")}</div>
      )}
    </section>
  )
}

function EventLinks({ event, prefix }: { event: AdminOverviewPayload["chat_scoped_events"]["recent"][number]; prefix: string }) {
  const links = []
  if (event.chat) links.push(<Link className="underline hover:no-underline" key="chat" to={withRoutePrefix(event.chat.path, prefix)}>{event.chat.title}</Link>)
  if (event.job) links.push(<Link className="underline hover:no-underline" key="job" to={withRoutePrefix(event.job.path, prefix)}>{event.job.slug}</Link>)
  if (event.epic) links.push(<Link className="underline hover:no-underline" key="epic" to={withRoutePrefix(event.epic.path, prefix)}>{event.epic.slug}</Link>)
  if (event.repository) links.push(<span key="repo">{event.repository.slug}</span>)

  return <span className="text-gray-600 dark:text-gray-300">{links.length > 0 ? intersperse(links, " · ") : `event ${event.id}`}</span>
}

function DecisionPill({ label, value, tone = "idle" }: { label: string; value: number | string; tone?: "idle" | "alarm" }) {
  const className = tone === "alarm"
    ? "rounded bg-red-100 px-2 py-0.5 font-mono text-red-700 dark:bg-red-950 dark:text-red-300"
    : "rounded bg-gray-100 px-2 py-0.5 font-mono text-gray-600 dark:bg-gray-800 dark:text-gray-300"

  return <span className={className}>{label}: {value}</span>
}

function intersperse(items: ReactNode[], separator: string) {
  return items.flatMap((item, index) => index === 0 ? [item] : [separator, item])
}

function triggerContext(values: Record<string, number>, fallback: string) {
  const entries = Object.entries(values)
  if (entries.length === 0) return fallback

  return entries.map(([trigger, count]) => `${count} ${trigger}`).join(" · ")
}

function workersContext(workers: { stale?: number; unreachable?: boolean }, t: (key: string, opts?: Record<string, unknown>) => string, workerHealth?: AdminOverviewPayload["worker_health"]) {
  if (workers.unreachable) return t("overview.queue_unreachable")
  const critical = workerHealth?.current.filter((worker) => worker.health.level === "critical").length ?? 0
  if (critical > 0) return t("overview.critical_workers", { count: critical })
  const warning = workerHealth?.current.filter((worker) => worker.health.level === "warning" || worker.health.level === "unknown").length ?? 0
  if (warning > 0) return t("overview.warning_workers", { count: warning })
  if (workers.stale && workers.stale > 0) return t("overview.stale_workers", { count: workers.stale })
  return t("overview.all_healthy")
}

function aggregateWorkerHealthTone(workers: { stale?: number; unreachable?: boolean }, workerHealth?: AdminOverviewPayload["worker_health"]): "idle" | "ok" | "warn" | "alarm" {
  if (workers.stale && workers.stale > 0) return "alarm"
  if (!workerHealth) return "idle"
  if (workerHealth.current.some((worker) => worker.health.level === "critical")) return "alarm"
  if (workerHealth.current.some((worker) => worker.health.level === "warning" || worker.health.level === "unknown")) return "warn"
  return "ok"
}

function dataRootTone(level?: string) {
  if (level === "critical") return "alarm"
  if (level === "warning") return "warn"
  if (level === "ok") return "ok"
  return "idle"
}

function formatBytes(bytes: number) {
  const units: Array<[number, string]> = [
    [1024 ** 4, "TB"],
    [1024 ** 3, "GB"],
    [1024 ** 2, "MB"]
  ]
  const [factor, suffix] = units.find(([unit]) => bytes >= unit) || [1024, "KB"]
  const value = bytes / factor

  return `${value >= 10 ? Math.round(value) : Math.round(value * 10) / 10}${suffix}`
}
