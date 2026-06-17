import { useQuery } from "@tanstack/react-query"
import { Link, useLocation } from "react-router-dom"
import { fetchAdminOverview, type AdminOverviewPayload } from "../api/adminOverview"

export function AdminOverview() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const overview = useQuery({
    queryKey: ["admin", "overview"],
    queryFn: fetchAdminOverview
  })

  if (overview.isPending) {
    return <main aria-label="Admin overview" className="p-6 text-sm text-gray-600 dark:text-gray-300">Loading...</main>
  }

  if (overview.isError) {
    return (
      <main aria-label="Admin overview" className="p-6">
        <p className="text-sm text-red-700 dark:text-red-300">Unable to load admin overview.</p>
      </main>
    )
  }

  const data = overview.data
  const captureRate = data.agent_session_capture_rate.rate
  const overdueRecurring = data.recurring.overdue || []
  const dataRoot = data.data_root_disk_usage

  return (
    <main aria-label="Admin overview" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">Overview</h1>
      </header>

      <section aria-label="System metrics" className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Metric title="Active runs" value={data.active_runs.total} context={triggerContext(data.active_runs.by_trigger, "all idle")} href={withRoutePrefix("/admin/queue/active", prefix)} />
        <Metric title="Queued runs" value={data.queued_runs.total} context={data.queued_runs.total > 0 ? "waiting for a worker" : "queue empty"} href={withRoutePrefix("/admin/queue/pending", prefix)} />
        <Metric title="Workers" value={data.workers.unreachable ? "?" : data.workers.total ?? 0} context={workersContext(data.workers)} href={withRoutePrefix("/admin/queue/workers", prefix)} tone={data.workers.stale ? "alarm" : "ok"} />
        <Metric title="Recurring jobs" value={overdueRecurring.length} context={overdueRecurring.length > 0 ? overdueRecurring.map((task) => task.key).join(", ") : "all firing"} href={withRoutePrefix("/admin/queue/recurring", prefix)} tone={overdueRecurring.length > 0 ? "alarm" : "ok"} />
        <Metric title="Failed runs (24h)" value={data.recent_failures_24h.total} context={triggerContext(data.recent_failures_24h.by_trigger, "no failures")} href={withRoutePrefix("/admin/queue/failed", prefix)} tone={data.recent_failures_24h.total > 0 ? "warn" : "ok"} />
        <Metric title="Provider circuits" value={data.provider_circuits.length} context={data.provider_circuits.length > 0 ? data.provider_circuits.map((circuit) => circuit.provider).join(", ") : "all closed"} tone={data.provider_circuits.length > 0 ? "alarm" : "ok"} />
        <Metric title="GitHub rate limits" value={data.github_rate_limits.length} context={data.github_rate_limits.length > 0 ? data.github_rate_limits.map((user) => user.email).join(", ") : "all healthy"} tone={data.github_rate_limits.length > 0 ? "warn" : "ok"} />
        <Metric title="Agent session capture" value={captureRate == null ? "-" : `${Math.round(captureRate * 100)}%`} context={`${data.agent_session_capture_rate.captured} of ${data.agent_session_capture_rate.total}`} tone={captureRate == null || captureRate >= 0.95 ? "ok" : "warn"} />
        <Metric title="Data root disk" value={dataRoot ? `${dataRoot.used_percent}%` : "?"} context={dataRoot ? `${formatBytes(dataRoot.available_bytes)} free at ${dataRoot.path}` : "unavailable"} tone={dataRootTone(dataRoot?.level)} />
        <Metric title="Stuck things" value={data.stuck.length} context={data.stuck.length > 0 ? "needs attention" : "nothing flagged"} href={withRoutePrefix("/admin/stuck", prefix)} tone={data.stuck.some((item) => item.severity === "alarm") ? "alarm" : data.stuck.length > 0 ? "warn" : "ok"} />
      </section>

      {data.stuck.length > 0 ? (
        <section aria-label="Stuck things" className="overflow-hidden rounded border border-amber-200 dark:border-amber-800 bg-white dark:bg-gray-900">
          <div className="bg-amber-50 dark:bg-amber-950/40 px-4 py-2 text-xs font-medium uppercase text-amber-700 dark:text-amber-300">Stuck things</div>
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

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
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

function triggerContext(values: Record<string, number>, fallback: string) {
  const entries = Object.entries(values)
  if (entries.length === 0) return fallback

  return entries.map(([trigger, count]) => `${count} ${trigger}`).join(" · ")
}

function workersContext(workers: { stale?: number; unreachable?: boolean }) {
  if (workers.unreachable) return "queue tables unreachable"
  if (workers.stale && workers.stale > 0) return `${workers.stale} stale`
  return "all healthy"
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
