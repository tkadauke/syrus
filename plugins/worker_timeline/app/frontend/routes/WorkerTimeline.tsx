import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { FilterBar } from "@app/components/FilterBar"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { SlugHoverCard } from "@app/components/SlugHoverCard"
import { Notice, Page, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
import { fetchWorkerTimelineLive, fetchWorkerTimelineMacro, fetchWorkerTimelineWorkflow, recordWorkerTimelineFilterUsage, type WorkerTimelineLivePayload, type WorkerTimelineLiveSlot, type WorkerTimelineLiveStatus, type WorkerTimelineMacroPayload } from "../api/workerTimeline"
import { TimelineLanes } from "../components/TimelineLanes"
import { WorkflowWaterfall } from "../components/WorkflowWaterfall"
import { formatDuration } from "../components/timeline/spanFormatting"

export function WorkerTimelineRoute() {
  const location = useLocation()
  if (location.pathname.endsWith("/workflow")) return <WorkerTimelineWorkflowDetail />

  return <WorkerTimelineMacroView />
}

export function WorkerTimelineMacroView() {
  const { t } = useT("worker_timeline")
  usePageTitle(t("heading"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const searchParams = new URLSearchParams(location.search)
  const activeTab = searchParams.get("tab") === "live" ? "live" : "timeline"
  const querySearch = searchWithoutTab(location.search)

  const macro = useQuery({
    enabled: activeTab === "timeline",
    queryKey: ["worker_timeline", "macro", querySearch],
    queryFn: () => fetchWorkerTimelineMacro(querySearch),
    placeholderData: keepPreviousData
  })
  const live = useQuery({
    enabled: activeTab === "live",
    queryKey: ["worker_timeline", "live", querySearch],
    queryFn: () => fetchWorkerTimelineLive(querySearch),
    placeholderData: keepPreviousData
  })

  function handleSelectWorkflow(workflowId: number) {
    navigate(withRoutePrefix(`/worker_timeline/workflow?id=${workflowId}`, prefix))
  }

  return (
    <Page.Root aria-label={t("aria_page")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Page.HeadingGroup>
          <Text className="font-medium uppercase" variant="caption" tone="muted">
            {t("eyebrow")}
          </Text>
          <PageHeading>{t("heading")}</PageHeading>
          <Page.Description>{t("description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      <Page.Nav>
        <div className="flex gap-1 border-b border-border" role="tablist" aria-label={t("tabs_aria")}>
          <Link aria-selected={activeTab === "timeline"} className={tabClass(activeTab === "timeline")} role="tab" to={withRoutePrefix("/worker_timeline", prefix)}>
            {t("tab_timeline")}
          </Link>
          <Link aria-selected={activeTab === "live"} className={tabClass(activeTab === "live")} role="tab" to={withRoutePrefix("/worker_timeline?tab=live", prefix)}>
            {t("tab_live_workers")}
          </Link>
        </div>
      </Page.Nav>

      <Page.Nav>
        <FilterBar
          filter={(activeTab === "live" ? live.data?.filter : macro.data?.filter) ?? null}
          filterSchema={(activeTab === "live" ? live.data?.filter_schema : macro.data?.filter_schema) ?? []}
          onFilterApplied={(tree) => {
            void recordWorkerTimelineFilterUsage({ filter: tree as Record<string, unknown> }).catch(() => {})
          }}
          pathname={location.pathname}
          search={location.search}
          suggestionSearch={{ surface: "worker_timeline", subject: "worker_timeline" }}
        />
      </Page.Nav>

      {activeTab === "timeline" ? (
        <>
          {macro.isPending ? <Notice>{t("loading")}</Notice> : null}
          {macro.isError ? <Notice tone="danger">{errorMessage(macro.error, t("error_loading"))}</Notice> : null}
          {macro.data ? <TimelineLanes onSelectWorkflow={handleSelectWorkflow} payload={macro.data} /> : null}

          {macro.data ? <PendingList pending={macro.data.pending} prefix={prefix} /> : null}
        </>
      ) : (
        <>
          {live.isPending ? <Notice>{t("loading_live")}</Notice> : null}
          {live.isError ? <Notice tone="danger">{errorMessage(live.error, t("error_loading_live"))}</Notice> : null}
          {live.data ? <LiveWorkers payload={live.data} prefix={prefix} /> : null}
        </>
      )}
    </Page.Root>
  )
}

function searchWithoutTab(search: string) {
  const params = new URLSearchParams(search)
  params.delete("tab")
  const query = params.toString()
  return query ? `?${query}` : ""
}

function tabClass(active: boolean) {
  return [
    "inline-flex h-9 items-center border-b-2 px-3 text-sm font-semibold",
    active ? "border-brand text-brand dark:text-brand-emphasis" : "border-transparent text-text-muted hover:text-text-primary"
  ].join(" ")
}

function LiveWorkers({ payload, prefix }: { payload: WorkerTimelineLivePayload; prefix: string }) {
  const { t } = useT("worker_timeline")

  if (payload.workers.length === 0) return <Notice>{t("live_empty")}</Notice>

  return (
    <section aria-label={t("live_aria")} className="space-y-4">
      <div className="grid gap-2 sm:grid-cols-3 lg:grid-cols-6">
        <LiveMetric label={t("live_metric_workers")} value={payload.summary.total_workers} />
        <LiveMetric label={t("live_metric_slots")} value={`${payload.summary.used_slots}/${payload.summary.total_slots}`} />
        <LiveMetric label={t("status_idle")} value={payload.summary.idle} />
        <LiveMetric label={t("status_busy")} value={payload.summary.busy} />
        <LiveMetric label={t("status_degraded")} value={payload.summary.degraded} />
        <LiveMetric label={t("status_overloaded")} value={payload.summary.overloaded} />
      </div>
      <Text variant="caption" tone="muted">
        {payload.attribution.strategy}
      </Text>
      <div className="grid gap-3 xl:grid-cols-2">
        {payload.workers.map((worker) => (
          <article className={`overflow-hidden rounded-lg border bg-surface shadow-sm ${statusBorderClass(worker.status)}`} key={worker.key}>
            <header className="grid grid-cols-[minmax(0,1fr)_auto] gap-3 border-b border-border bg-surface-subtle px-3 py-3">
              <div className="min-w-0">
                <div className="flex min-w-0 items-center gap-2">
                  <h2 className="truncate text-sm font-semibold">{worker.hostname || worker.worker_storage_key || t("unknown_storage_key")}</h2>
                  <StatusPill status={worker.status} />
                </div>
                <Text className="mt-1 truncate" variant="caption" tone="muted">
                  {worker.worker_storage_key || t("unknown_storage_key")}
                </Text>
              </div>
              <div className="text-right">
                <div className="text-lg font-semibold tabular-nums">{worker.occupancy.used}/{worker.occupancy.total}</div>
                <Text variant="caption" tone="muted">{t("live_slots")}</Text>
              </div>
            </header>

            <div className="grid gap-3 p-3">
              <div className="grid gap-2 sm:grid-cols-3">
                <Sparkline label="CPU" points={worker.sparklines.cpu} value={worker.health.cpu_used_percent} />
                <Sparkline label="Memory" points={worker.sparklines.memory} value={worker.health.memory_used_percent} />
                <Sparkline label="I/O" points={worker.sparklines.io} value={worker.health.io_pressure_some} />
              </div>
              <div className="space-y-2">
                {worker.pools.map((pool) => (
                  <div className="rounded-md border border-border bg-surface-inset" key={pool.key}>
                    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border px-3 py-2">
                      <div className="min-w-0">
                        <div className="truncate text-xs font-semibold">{pool.queues.length > 0 ? pool.queues.join(", ") : t("unknown_queue_role")}</div>
                        <Text className="truncate" variant="caption" tone="muted">
                          {pool.pid ? `${pool.hostname}:${pool.pid}` : t("live_inferred_pool")}
                        </Text>
                      </div>
                      <span className="rounded-full border border-border px-2 py-0.5 text-xs font-semibold tabular-nums text-text-muted">
                        {pool.used}/{pool.capacity}
                      </span>
                    </div>
                    <div className="grid gap-2 p-2">
                      {pool.slots.map((slot) => <LiveSlotCard key={slot.id} prefix={prefix} slot={slot} />)}
                      {Array.from({ length: Math.max(0, pool.capacity - pool.slots.length) }, (_, index) => (
                        <div className="rounded-md border border-dashed border-border px-3 py-2 text-xs text-text-muted" key={`${pool.key}-idle-${index}`}>
                          {t("live_idle_slot")}
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
              {worker.status_reasons.length > 0 ? <Text variant="caption" tone="muted">{worker.status_reasons.join(" · ")}</Text> : null}
            </div>
          </article>
        ))}
      </div>
    </section>
  )
}

function LiveMetric({ label, value }: { label: string; value: number | string }) {
  return (
    <div className="rounded-lg border border-border bg-surface px-3 py-2 shadow-sm">
      <Text variant="caption" tone="muted">{label}</Text>
      <div className="mt-1 text-xl font-semibold tabular-nums">{value}</div>
    </div>
  )
}

function LiveSlotCard({ slot, prefix }: { slot: WorkerTimelineLiveSlot; prefix: string }) {
  const { t } = useT("worker_timeline")
  const title = [ slot.job_slug, slot.trigger_kind ].filter(Boolean).join(" · ") || slot.process_kind || slot.attribution
  const subtitle = [ slot.workflow_slug, slot.step_kind && (slot.step_slug ? `${slot.step_kind} ${slot.step_slug}` : slot.step_kind), slot.run_slug, slot.pid ? `pid ${slot.pid}` : null ].filter(Boolean).join(" · ")
  const elapsed = slot.started_at ? formatDuration(slot.started_at, null) : null

  return (
    <div className="rounded-md border border-border bg-surface px-3 py-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        {slot.job_id && slot.job_slug ? (
          <Link className="font-semibold text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(`/jobs/${slot.job_id}`, prefix)}>{slot.job_slug}</Link>
        ) : <span className="font-semibold">{title}</span>}
        {slot.workflow_id && slot.workflow_slug && slot.job_id ? (
          <Link className="text-xs text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(`/jobs/${slot.job_id}?tab=workflows#workflow-${slot.workflow_id}`, prefix)}>{slot.workflow_slug}</Link>
        ) : null}
        <span className="rounded-full bg-surface-subtle px-2 py-0.5 text-xs font-semibold text-text-muted">{slot.confidence}</span>
      </div>
      {slot.job_title ? <div className="mt-1 truncate text-sm">{slot.job_title}</div> : null}
      <Text className="mt-1 truncate" variant="caption" tone="muted">{subtitle || t("live_unattributed_slot")}</Text>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {slot.workflow_type ? <TinyPill>{slot.workflow_type}</TinyPill> : null}
        {slot.trigger_kind ? <TinyPill>{slot.trigger_kind}</TinyPill> : null}
        {slot.process_kind ? <TinyPill>{slot.process_kind}</TinyPill> : null}
        {elapsed ? <TinyPill>{elapsed}</TinyPill> : null}
      </div>
      {slot.command_excerpt ? <code className="mt-2 block truncate rounded bg-surface-subtle px-2 py-1 text-xs text-text-muted">{slot.command_excerpt}</code> : null}
    </div>
  )
}

function Sparkline({ label, points, value }: { label: string; points: { value: number }[]; value?: number | null }) {
  const width = 96
  const height = 28
  const values = points.map((point) => point.value)
  const max = Math.max(100, ...values)
  const d = values.map((pointValue, index) => {
    const x = values.length <= 1 ? 0 : (index / (values.length - 1)) * width
    const y = height - Math.max(0, Math.min(1, pointValue / max)) * height
    return `${index === 0 ? "M" : "L"}${x.toFixed(1)} ${y.toFixed(1)}`
  }).join(" ")

  return (
    <div className="rounded-md border border-border bg-surface-inset px-2 py-1.5">
      <div className="mb-1 flex items-center justify-between gap-2 text-xs">
        <span className="font-semibold text-text-muted">{label}</span>
        <span className="tabular-nums text-text-muted">{typeof value === "number" ? `${value.toFixed(0)}%` : "n/a"}</span>
      </div>
      <svg aria-hidden="true" className="h-7 w-full text-brand" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none">
        {d ? <path d={d} fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="2" /> : null}
      </svg>
    </div>
  )
}

function TinyPill({ children }: { children: string }) {
  return <span className="rounded-full bg-surface-subtle px-2 py-0.5 text-xs font-semibold text-text-muted">{children}</span>
}

function StatusPill({ status }: { status: WorkerTimelineLiveStatus }) {
  const { t } = useT("worker_timeline")
  return <span className={`rounded-full border px-2 py-0.5 text-xs font-semibold ${statusPillClass(status)}`}>{t(`status_${status}`)}</span>
}

function statusPillClass(status: WorkerTimelineLiveStatus) {
  return {
    idle: "border-gray-200 bg-gray-50 text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200",
    busy: "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200",
    degraded: "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200",
    overloaded: "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
  }[status]
}

function statusBorderClass(status: WorkerTimelineLiveStatus) {
  return {
    idle: "border-border",
    busy: "border-blue-200 dark:border-blue-900",
    degraded: "border-amber-300 dark:border-amber-800",
    overloaded: "border-red-300 dark:border-red-800"
  }[status]
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
