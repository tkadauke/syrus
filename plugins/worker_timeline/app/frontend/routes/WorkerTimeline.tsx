import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { UnderlineTabs } from "@app/components/Tabs"
import { FilterBar } from "@app/components/FilterBar"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { SlugHoverCard } from "@app/components/SlugHoverCard"
import { Notice, Page, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
import {
  fetchWorkerTimelineLive,
  fetchWorkerTimelineMacro,
  fetchWorkerTimelineWorkflow,
  recordWorkerTimelineFilterUsage,
  type WorkerTimelineLiveHost,
  type WorkerTimelineLivePayload,
  type WorkerTimelineLiveSlot,
  type WorkerTimelineMacroPayload
} from "../api/workerTimeline"
import { TimelineLanes } from "../components/TimelineLanes"
import { WorkflowWaterfall } from "../components/WorkflowWaterfall"

export function WorkerTimelineRoute() {
  const location = useLocation()
  if (location.pathname.endsWith("/workflow")) return <WorkerTimelineWorkflowDetail />

  return <WorkerTimelineIndex />
}

type WorkerTimelineTab = "timeline" | "live"

function WorkerTimelineIndex() {
  const { t } = useT("worker_timeline")
  usePageTitle(t("heading"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const [searchParams] = useSearchParams()
  const activeTab: WorkerTimelineTab = searchParams.get("tab") === "live" ? "live" : "timeline"

  const macro = useQuery({
    enabled: activeTab === "timeline",
    queryKey: ["worker_timeline", "macro", location.search],
    queryFn: () => fetchWorkerTimelineMacro(location.search),
    placeholderData: keepPreviousData
  })

  const live = useQuery({
    enabled: activeTab === "live",
    queryKey: ["worker_timeline", "live", location.search],
    queryFn: () => fetchWorkerTimelineLive(location.search),
    placeholderData: keepPreviousData
  })

  function handleSelectWorkflow(workflowId: number) {
    navigate(withRoutePrefix(`/worker_timeline/workflow?id=${workflowId}`, prefix))
  }

  const activeData = activeTab === "live" ? live.data : macro.data
  const activeQuery = activeTab === "live" ? live : macro

  return (
    <Page.Root aria-label={t("aria_page")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">
          {t("eyebrow")}
        </Text>
        <PageHeading>{t("heading")}</PageHeading>
        <Page.Description>{t("description")}</Page.Description>
      </Page.Header>

      <Page.Nav className="space-y-3">
        <UnderlineTabs
          activeKey={activeTab}
          ariaLabel={t("tabs_aria")}
          items={[
            { key: "timeline", label: t("tab_timeline"), to: withRoutePrefix(`/worker_timeline${tabSearch(location.search, "timeline")}`, prefix) },
            { key: "live", label: t("tab_live_workers"), to: withRoutePrefix(`/worker_timeline${tabSearch(location.search, "live")}`, prefix) }
          ]}
        />
        <FilterBar
          filter={activeData?.filter ?? null}
          filterSchema={activeData?.filter_schema ?? []}
          onFilterApplied={(tree) => {
            void recordWorkerTimelineFilterUsage({ filter: tree as Record<string, unknown> }).catch(() => {})
          }}
          pathname={location.pathname}
          search={location.search}
          suggestionSearch={{ surface: "worker_timeline", subject: "worker_timeline" }}
        />
      </Page.Nav>

      {activeQuery.isPending ? <Notice>{t("loading")}</Notice> : null}
      {activeQuery.isError ? <Notice tone="danger">{errorMessage(activeQuery.error, t("error_loading"))}</Notice> : null}

      {activeTab === "timeline" && macro.data ? <TimelineLanes onSelectWorkflow={handleSelectWorkflow} payload={macro.data} /> : null}
      {activeTab === "live" && live.data ? <LiveWorkers payload={live.data} /> : null}

      {activeTab === "timeline" && macro.data ? <PendingList pending={macro.data.pending} prefix={prefix} /> : null}
    </Page.Root>
  )
}

function tabSearch(search: string, tab: WorkerTimelineTab) {
  const params = new URLSearchParams(search)
  if (tab === "live") {
    params.set("tab", tab)
  } else {
    params.delete("tab")
  }
  const encoded = params.toString()
  return encoded ? `?${encoded}` : ""
}

function LiveWorkers({ payload }: { payload: WorkerTimelineLivePayload }) {
  const { t } = useT("worker_timeline")

  if (payload.hosts.length === 0) return <Notice>{t("live_empty")}</Notice>

  return (
    <div className="space-y-4">
      <section aria-label={t("live_summary_aria")} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <LiveMetric label={t("live_metric_hosts")} value={payload.summary.total_hosts} />
        <LiveMetric label={t("live_metric_active_slots")} value={`${payload.summary.active_slots}/${payload.summary.total_slots || "?"}`} />
        <LiveMetric label={t("live_metric_busy")} value={payload.summary.busy_hosts} />
        <LiveMetric label={t("live_metric_degraded")} value={payload.summary.degraded_hosts} />
        <LiveMetric label={t("live_metric_overloaded")} value={payload.summary.overloaded_hosts} />
      </section>

      <section aria-label={t("live_hosts_aria")} className="grid items-start gap-3 xl:grid-cols-2">
        {payload.hosts.map((host) => (
          <LiveHostCard host={host} key={host.key} />
        ))}
      </section>
    </div>
  )
}

function LiveMetric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="min-w-0 rounded border border-border bg-surface p-3">
      <Text as="div" className="font-medium" variant="caption" tone="muted">
        {label}
      </Text>
      <div className="mt-1 text-xl font-semibold tabular-nums text-text-primary">{value}</div>
    </div>
  )
}

function LiveHostCard({ host }: { host: WorkerTimelineLiveHost }) {
  const { t } = useT("worker_timeline")
  const capacity = host.pools.reduce((total, pool) => total + pool.threads, 0)
  const stateClass = liveStateClass(host.state)

  return (
    <article className={`overflow-hidden rounded border bg-surface ${stateClass.card}`} aria-label={t("live_host_card_aria", { host: host.hostname })}>
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border bg-surface-raised px-4 py-3">
        <div className="min-w-0">
          <div className="flex min-w-0 items-center gap-2">
            <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${stateClass.dot}`} aria-hidden="true" />
            <h2 className="truncate font-mono text-sm font-semibold text-text-primary">{host.worker_storage_key || host.hostname}</h2>
          </div>
          <Text className="mt-1 truncate" variant="caption" tone="muted">
            {host.worker_storage_key ? host.hostname : t("live_no_storage_key")} · {t("live_capacity", { active: host.slots.length, total: capacity || "?" })}
          </Text>
        </div>
        <div className="flex flex-wrap justify-end gap-1.5">
          <LivePill state={host.state}>{t(`live_state_${host.state}`)}</LivePill>
          <span className="rounded border border-border px-2 py-0.5 text-xs font-medium text-text-secondary">{host.health.level}</span>
        </div>
      </header>

      <div className="space-y-4 p-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Sparkline label={t("live_cpu")} points={host.sparklines.cpu} tone="#2563eb" />
          <Sparkline label={t("live_memory")} points={host.sparklines.memory} tone="#16a34a" />
          <Sparkline label={t("live_io")} points={host.sparklines.io} tone="#b45309" />
        </div>

        <div>
          <Text className="font-medium" variant="caption" tone="muted">
            {t("live_pools")}
          </Text>
          <div className="mt-2 flex flex-wrap gap-2">
            {host.pools.length === 0 ? (
              <Text variant="caption" tone="muted">
                {t("live_no_pools")}
              </Text>
            ) : null}
            {host.pools.map((pool) => (
              <span className="rounded border border-border bg-surface px-2 py-1 font-mono text-xs text-text-secondary" key={`${pool.hostname}:${pool.pid}`}>
                pid {pool.pid ?? "?"} · {pool.threads} · {pool.queues.join(", ") || "?"}
              </span>
            ))}
          </div>
        </div>

        <div className="space-y-2">
          <Text className="font-medium" variant="caption" tone="muted">
            {t("live_slots")}
          </Text>
          {host.slots.length === 0 ? (
            <div className="rounded border border-dashed border-border px-3 py-4 text-sm text-text-secondary">{t("live_idle_slots")}</div>
          ) : (
            host.slots.map((slot) => <LiveSlotRow key={slot.id} slot={slot} />)
          )}
        </div>

        {host.health.reasons.length > 0 ? <p className="text-xs text-text-secondary">{host.health.reasons.join("; ")}</p> : null}
      </div>
    </article>
  )
}

function LiveSlotRow({ slot }: { slot: WorkerTimelineLiveSlot }) {
  const { t } = useT("worker_timeline")
  const jobLabel = slot.job.slug || (slot.job.id ? `JOB-${slot.job.id}` : t("live_unknown_job"))
  const workflowLabel = slot.workflow.slug || (slot.workflow.id ? `WF-${slot.workflow.id}` : t("live_unknown_workflow"))
  const stepLabel = [slot.step.kind, slot.step.status].filter(Boolean).join(" · ") || t("live_unknown_step")
  const runLabel = slot.run.id ? `RUN-${slot.run.id}` : t("live_unknown_run")

  return (
    <div className="rounded border border-border bg-surface-raised p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-1.5 text-sm font-medium text-text-primary">
            <span>{jobLabel}</span>
            <span className="text-text-muted">·</span>
            <span>{workflowLabel}</span>
            {slot.workflow.trigger_kind ? <span className="rounded bg-brand/10 px-1.5 py-0.5 text-xs text-brand">{slot.workflow.trigger_kind}</span> : null}
          </div>
          {slot.job.title ? <p className="mt-1 truncate text-sm text-text-secondary">{slot.job.title}</p> : null}
        </div>
        <span className="rounded border border-border px-2 py-0.5 text-xs font-medium text-text-secondary">{slot.attribution_confidence}</span>
      </div>
      <dl className="mt-3 grid gap-2 text-xs text-text-secondary sm:grid-cols-2">
        <LiveSlotFact label={t("live_step")} value={stepLabel} />
        <LiveSlotFact label={t("live_run")} value={`${runLabel}${slot.run.status ? ` · ${slot.run.status}` : ""}`} />
        <LiveSlotFact label={t("live_process")} value={`pid ${slot.spawned_process.pid ?? "?"} · ${slot.spawned_process.kind ?? "unlinked"}`} />
        <LiveSlotFact label={t("live_elapsed")} value={formatSeconds(slot.spawned_process.elapsed_s)} />
      </dl>
      <pre className="mt-3 overflow-hidden text-ellipsis whitespace-nowrap rounded bg-surface px-2 py-1 font-mono text-xs text-text-secondary">
        {slot.spawned_process.command_excerpt}
      </pre>
      <p className="mt-2 text-xs text-text-muted">{slot.attribution_note}</p>
    </div>
  )
}

function LiveSlotFact({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="font-medium text-text-muted">{label}</dt>
      <dd className="truncate">{value}</dd>
    </div>
  )
}

function LivePill({ state, children }: { state: WorkerTimelineLiveHost["state"]; children: string }) {
  return <span className={`rounded px-2 py-0.5 text-xs font-semibold ${liveStateClass(state).pill}`}>{children}</span>
}

function liveStateClass(state: WorkerTimelineLiveHost["state"]) {
  const classes = {
    idle: { card: "border-border", dot: "bg-green-600", pill: "bg-green-100 text-green-700 dark:bg-green-950/40 dark:text-green-300" },
    busy: { card: "border-brand/40", dot: "bg-brand", pill: "bg-brand/10 text-brand dark:text-brand-emphasis" },
    degraded: {
      card: "border-yellow-300 dark:border-yellow-700",
      dot: "bg-yellow-600",
      pill: "bg-yellow-100 text-yellow-800 dark:bg-yellow-950/40 dark:text-yellow-300"
    },
    overloaded: { card: "border-red-300 dark:border-red-700", dot: "bg-red-600", pill: "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-300" }
  }
  return classes[state]
}

function Sparkline({ label, points, tone }: { label: string; points: Array<{ value: number | null }>; tone: string }) {
  const values = points.map((point) => point.value).filter((value): value is number => typeof value === "number")
  const path = sparklinePath(values)
  const latest = values.at(-1)

  return (
    <div className="rounded border border-border bg-surface px-3 py-2">
      <div className="flex items-center justify-between gap-2">
        <Text variant="caption" tone="muted">
          {label}
        </Text>
        <span className="text-xs font-medium tabular-nums text-text-secondary">{latest == null ? "-" : `${Math.round(latest)}%`}</span>
      </div>
      <svg aria-label={label} className="mt-2 h-8 w-full" preserveAspectRatio="none" role="img" viewBox="0 0 100 32">
        <polyline fill="none" points={path} stroke={tone} strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
      </svg>
    </div>
  )
}

function sparklinePath(values: number[]) {
  if (values.length === 0) return ""
  if (values.length === 1) return `0,${32 - clamp(values[0]) * 0.32} 100,${32 - clamp(values[0]) * 0.32}`

  return values
    .map((value, index) => {
      const x = (index / (values.length - 1)) * 100
      const y = 32 - clamp(value) * 0.32
      return `${x.toFixed(2)},${y.toFixed(2)}`
    })
    .join(" ")
}

function clamp(value: number) {
  return Math.max(0, Math.min(100, value))
}

function formatSeconds(seconds: number) {
  const rounded = Math.max(0, Math.round(seconds))
  const minutes = Math.floor(rounded / 60)
  const remaining = rounded % 60
  if (minutes === 0) return `${remaining}s`
  return `${minutes}m ${remaining}s`
}

function PendingList({ pending, prefix }: { pending: WorkerTimelineMacroPayload["pending"]; prefix: string }) {
  const { t } = useT("worker_timeline")
  if (pending.length === 0) return null

  return (
    <Section.Root aria-label={t("pending_aria")}>
      <SectionHeading>{t("pending_heading")}</SectionHeading>
      <ul className="mt-2 divide-y divide-border text-sm">
        {pending.map((entry) => {
          const label = pendingLabelParts(entry)

          return (
            <li className="flex items-center justify-between gap-3 py-2" key={entry.workflow_id}>
              <span className="flex min-w-0 items-center gap-1.5">
                <SlugHoverCard id={entry.job_id} kind="job">
                  <CopyableSlug className="text-xs" slug={label.jobSlug} />
                </SlugHoverCard>
                <span className="text-gray-400 dark:text-gray-500" aria-hidden="true">
                  ·
                </span>
                <Link
                  className="truncate text-left text-brand underline hover:no-underline dark:text-brand-emphasis"
                  to={withRoutePrefix(`/worker_timeline/workflow?id=${entry.workflow_id}`, prefix)}
                >
                  {label.triggerKind}
                </Link>
              </span>
              <Text as="span" variant="caption" tone="muted">
                {entry.blocked.available ? t("blocked_reason_line", { reason: entry.blocked.blocked_reason }) : t("no_blocker_data")}
              </Text>
            </li>
          )
        })}
      </ul>
    </Section.Root>
  )
}

function pendingLabelParts(entry: WorkerTimelineMacroPayload["pending"][number]) {
  const [jobSlug, triggerKind] = entry.label.split(" · ")

  return {
    jobSlug: jobSlug || `JOB-${entry.job_id}`,
    triggerKind: triggerKind || entry.label
  }
}

function WorkerTimelineWorkflowDetail() {
  const { t } = useT("worker_timeline")
  usePageTitle(t("detail_heading"))
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const workflowId = searchParams.get("id")
  const prefix = routePrefix(location.pathname)

  const detail = useQuery({
    enabled: Boolean(workflowId),
    queryKey: ["worker_timeline", "workflow", workflowId],
    queryFn: () => fetchWorkerTimelineWorkflow(workflowId as string)
  })

  return (
    <Page.Root aria-label={t("detail_aria")} gutter="responsive">
      <Page.Header className="block space-y-2">
        <Link className="text-sm text-brand dark:text-brand-emphasis underline hover:no-underline" to={withRoutePrefix("/worker_timeline", prefix)}>
          {t("back_to_timeline")}
        </Link>
        <PageHeading>{t("detail_heading")}</PageHeading>
      </Page.Header>

      {!workflowId ? <Notice>{t("detail_placeholder_no_workflow")}</Notice> : null}
      {detail.isPending && workflowId ? <Notice>{t("loading")}</Notice> : null}
      {detail.isError ? <Notice tone="danger">{errorMessage(detail.error, t("error_loading"))}</Notice> : null}
      {detail.data ? <WorkflowWaterfall payload={detail.data} prefix={prefix} /> : null}
    </Page.Root>
  )
}

export default WorkerTimelineRoute
