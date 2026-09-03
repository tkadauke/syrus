import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { SectionHeading } from "@app/components/Heading"
import { PanelMessage } from "@app/components/PanelMessage"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchRepositoryThroughputMetrics, type RepositoryThroughputConfidence, type RepositoryThroughputDuration, type RepositoryThroughputMetricsPayload, type RepositoryThroughputRate, type RepositoryThroughputWindow, type RepositoryThroughputWindowKey } from "../api/throughput"

const THROUGHPUT_WINDOWS: Array<{ key: RepositoryThroughputWindowKey; label: string }> = [
  { key: "1h", label: "1h" },
  { key: "4h", label: "4h" },
  { key: "24h", label: "24h" },
  { key: "7d", label: "7d" },
  { key: "last_active", label: "Last active" }
]

function RepositoryThroughputPanel({ repositoryId }: { repositoryId: number }) {
  const [windowKey, setWindowKey] = useState<RepositoryThroughputWindowKey>("4h")
  const metrics = useQuery({
    queryKey: ["repositories", String(repositoryId), "throughput_metrics"],
    queryFn: () => fetchRepositoryThroughputMetrics(repositoryId)
  })

  if (metrics.isPending) {
    return (
      <section>
        <SectionHeading className="mb-3">Throughput</SectionHeading>
        <PanelMessage>Loading throughput metrics...</PanelMessage>
      </section>
    )
  }

  if (metrics.isError) {
    return (
      <section>
        <SectionHeading className="mb-3">Throughput</SectionHeading>
        <PanelMessage tone="error">{errorMessage(metrics.error, "Unable to load throughput metrics.")}</PanelMessage>
      </section>
    )
  }

  if (!metrics.data.windows || !metrics.data.windows["4h"]) return null

  return <RepositoryThroughputDashboard metrics={metrics.data} windowKey={windowKey} onWindowChange={setWindowKey} />
}

function RepositoryThroughputDashboard({ metrics, windowKey, onWindowChange }: { metrics: RepositoryThroughputMetricsPayload; windowKey: RepositoryThroughputWindowKey; onWindowChange: (key: RepositoryThroughputWindowKey) => void }) {
  const window = metrics.windows[windowKey]

  return (
    <section aria-label="Repository throughput">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
        <div>
          <SectionHeading>Throughput</SectionHeading>
          <p className="text-xs text-gray-500 dark:text-gray-400">
            {formatWindowRange(window)}
          </p>
        </div>
        <div aria-label="Throughput window" className="inline-flex overflow-hidden rounded border border-gray-300 bg-white text-xs dark:border-gray-700 dark:bg-gray-900">
          {THROUGHPUT_WINDOWS.map((item) => (
            <button
              aria-pressed={windowKey === item.key}
              className={`px-2.5 py-1 font-medium ${windowKey === item.key ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-800"}`}
              key={item.key}
              onClick={() => onWindowChange(item.key)}
              type="button"
            >
              {item.label}
            </button>
          ))}
        </div>
      </div>
      <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        <div className="grid gap-px bg-gray-200 dark:bg-gray-800 sm:grid-cols-2 xl:grid-cols-4">
          <ThroughputMetric title="PR creation" value={`${formatRate(window.pr_creation)}/h`} detail={`${window.pr_creation.count} Syrus-authored, ${window.pr_creation.total_observed_count} observed`} confidence={window.pr_creation.confidence} sampleCount={window.pr_creation.sample_count} />
          <ThroughputMetric title="Output" value={`${formatRate(window.output.commits)}/h`} detail={`${formatSignedNumber(window.output.loc.net)} net LOC, ${window.output.loc.additions}+/${window.output.loc.deletions}-`} confidence={window.output.commits.confidence} sampleCount={window.output.commits.sample_count} />
          <ThroughputMetric title="Landing units" value={`${formatRate(window.landing.landing_units)}/h`} detail={`${window.landing.unit_types.auto_merge.landing_units} auto, ${window.landing.unit_types.merge_train.landing_units} trains`} confidence={window.landing.landing_units.confidence} sampleCount={window.landing.landing_units.sample_count} />
          <ThroughputMetric title="Jobs landed" value={`${formatRate(window.landing.jobs_landed)}/h`} detail={`${window.landing.jobs_landed.count} jobs; train avg ${formatNullableNumber(window.landing.merge_train_size.average)}`} confidence={window.landing.jobs_landed.confidence} sampleCount={window.landing.jobs_landed.sample_count} />
        </div>
        <div className="grid gap-4 p-4 lg:grid-cols-3">
          <ThroughputFunnel window={window} />
          <ThroughputBottlenecks window={window} />
          <ThroughputLatency window={window} />
        </div>
      </div>
    </section>
  )
}

function ThroughputMetric({ title, value, detail, confidence, sampleCount }: { title: string; value: string; detail: string; confidence: RepositoryThroughputConfidence; sampleCount: number }) {
  return (
    <article className="bg-white p-4 dark:bg-gray-900">
      <div className="flex items-start justify-between gap-3">
        <h3 className="text-sm font-medium text-gray-700 dark:text-gray-200">{title}</h3>
        <ConfidencePill confidence={confidence} />
      </div>
      <p className="mt-2 text-2xl font-semibold text-gray-900 dark:text-gray-100">{value}</p>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{detail}</p>
      <p className="mt-2 text-xs text-gray-400 dark:text-gray-500">n={sampleCount}</p>
    </article>
  )
}

function ThroughputFunnel({ window }: { window: RepositoryThroughputWindow }) {
  const funnel = window.review_funnel
  const approvedWithoutFeedbackRate = funnel.approval_count > 0 ? funnel.jobs_approved_immediately_without_feedback / funnel.approval_count : null
  const feedbackRate = funnel.pr_opened_count > 0 ? funnel.jobs_with_pr_feedback / funnel.pr_opened_count : null

  return (
    <div>
      <SectionHeading as="h3">Approval funnel</SectionHeading>
      <dl className="mt-3 space-y-2 text-sm">
        <MetricRow label="PRs opened" value={funnel.pr_opened_count} />
        <MetricRow label="Feedback jobs" value={`${funnel.jobs_with_pr_feedback}${feedbackRate == null ? "" : ` (${formatPercent(feedbackRate)})`}`} />
        <MetricRow label="Feedback rounds" value={funnel.feedback_rounds} />
        <MetricRow label="Approvals" value={`${funnel.approval_count} jobs / ${funnel.approval_vote_count} votes`} />
        <MetricRow label="Approved without feedback" value={`${funnel.jobs_approved_immediately_without_feedback}${approvedWithoutFeedbackRate == null ? "" : ` (${formatPercent(approvedWithoutFeedbackRate)})`}`} />
      </dl>
    </div>
  )
}

function ThroughputBottlenecks({ window }: { window: RepositoryThroughputWindow }) {
  const waste = window.landing_waste
  const landing = window.landing

  return (
    <div>
      <SectionHeading as="h3">Bottlenecks</SectionHeading>
      <dl className="mt-3 space-y-2 text-sm">
        <MetricRow label="Landing occupied" value={formatDurationSeconds(landing.landing_start_to_closed_latency_seconds.average)} detail={sampleLabel(landing.landing_start_to_closed_latency_seconds)} />
        <MetricRow label="Failed landing waste" value={formatDurationSeconds(waste.failed_or_cancelled_landing_workflow_seconds)} detail={`${waste.failed_or_cancelled_landing_workflow_count} workflows`} />
        <MetricRow label="Rebase churn" value={formatDurationSeconds(waste.rebase_churn_seconds)} detail={`${waste.rebase_churn_workflow_count} workflows`} />
        <MetricRow label="Blocking rebases" value={waste.landing_blocking_rebase_count} />
        <MetricRow label="Base moved regrades" value={landing.base_moved_regrade_count} />
      </dl>
    </div>
  )
}

function ThroughputLatency({ window }: { window: RepositoryThroughputWindow }) {
  const funnel = window.review_funnel
  const capacity = window.landing.current_optimistic_capacity

  return (
    <div>
      <SectionHeading as="h3">Latency and capacity</SectionHeading>
      <dl className="mt-3 space-y-2 text-sm">
        <MetricRow label="Approval latency" value={formatDurationSeconds(funnel.approval_latency_seconds.average)} detail={sampleLabel(funnel.approval_latency_seconds)} />
        <MetricRow label="Feedback addressed" value={formatDurationSeconds(funnel.feedback_to_addressed_seconds.average)} detail={sampleLabel(funnel.feedback_to_addressed_seconds)} />
        <MetricRow label="Approval to landing" value={formatDurationSeconds(funnel.approval_to_landing_latency_seconds.average)} detail={sampleLabel(funnel.approval_to_landing_latency_seconds)} />
        <MetricRow label="Optimistic capacity" value={`${formatNumber(capacity.estimated_landing_units_per_hour)}/h`} detail={`${formatNumber(capacity.estimated_jobs_landed_per_hour)} jobs/h, n=${capacity.sample_count} ${capacity.confidence}`} />
        <MetricRow label="Samples" value={`${window.samples.jobs_seen} jobs`} detail={`${window.samples.feedback_comments} feedback comments`} />
      </dl>
    </div>
  )
}

function MetricRow({ label, value, detail }: { label: string; value: number | string; detail?: string }) {
  return (
    <div className="flex items-start justify-between gap-3 border-b border-gray-100 pb-2 last:border-0 dark:border-gray-800">
      <dt className="text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="text-right font-medium text-gray-800 dark:text-gray-200">
        <span>{value}</span>
        {detail ? <span className="block text-xs font-normal text-gray-400 dark:text-gray-500">{detail}</span> : null}
      </dd>
    </div>
  )
}

function ConfidencePill({ confidence }: { confidence: RepositoryThroughputConfidence }) {
  const className = {
    none: "border-gray-200 bg-gray-50 text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400",
    low: "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300",
    medium: "border-info/30 bg-info/10 text-info",
    high: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300"
  }[confidence]

  return <span className={`rounded border px-1.5 py-0.5 text-2xs font-medium uppercase ${className}`}>{confidence}</span>
}

function sampleLabel(duration: RepositoryThroughputDuration) {
  return `n=${duration.sample_count} ${duration.confidence}`
}

function formatWindowRange(window: RepositoryThroughputWindow) {
  const start = new Date(window.range.start)
  const end = new Date(window.range.end)
  return `${start.toLocaleString()} to ${end.toLocaleString()} (${formatNumber(window.range.hours)}h)`
}

function formatRate(rate: RepositoryThroughputRate) {
  return formatNumber(rate.per_hour)
}

function formatNumber(value: number) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(value)
}

function formatNullableNumber(value: number | null) {
  return value == null ? "-" : formatNumber(value)
}

function formatSignedNumber(value: number) {
  if (value === 0) return "0"
  return value > 0 ? `+${formatNumber(value)}` : formatNumber(value)
}

function formatPercent(value: number) {
  return `${Math.round(value * 100)}%`
}

function formatDurationSeconds(value: number | null) {
  if (value == null) return "-"
  if (value < 60) return `${Math.round(value)}s`
  if (value < 3600) return `${Math.round(value / 60)}m`
  return `${Math.round((value / 3600) * 10) / 10}h`
}
// Rendered into the repository.detail ui_slot. The host passes the resolved
// repository payload; only the id is needed to fetch metrics.
export default function ThroughputPanel({ repository }: { repository?: { id: number } }) {
  if (!repository?.id) return null

  return <RepositoryThroughputPanel repositoryId={repository.id} />
}
