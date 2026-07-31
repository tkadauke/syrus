import { type RepositoryDetailQueryKey, appendSearch, buttonClass, PanelMessage, StatusPill } from "./repositoryDetail/shared"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { formatRelativeDate } from "../lib/relativeTime"
import { RepositoryIssues } from "./repositoryDetail/RepositoryIssues"
import { MainBranchHealthSection } from "./repositoryDetail/MainBranchHealth"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { NoticeToast } from "../components/NoticeToast"
import { ProviderAvailabilityWarning } from "../components/ProviderAvailabilityWarning"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { StatusPill as StateStatusPill, TonePill } from "../components/StatusPill"
import { CoverageSparkline } from "../components/CoverageSparkline"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { archiveRepositoryFromPath, fetchRepositoryDetail, fetchRepositoryFlakyTests, fetchRepositoryIssues, fetchRepositoryThroughputMetrics, pollRepositoryDetail, releaseNeedsTriageRepositoryJob, retryFailedRepositoryJobs, runInsightAnalysis, type InsightScheduleConfigRecord, type RepositoryDetailJob, type RepositoryDetailPayload, type RepositoryFlakyTest, type RepositoryThroughputConfidence, type RepositoryThroughputDuration, type RepositoryThroughputMetricsPayload, type RepositoryThroughputRate, type RepositoryThroughputWindow, type RepositoryThroughputWindowKey } from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"
import { useConfirm } from "../hooks/useConfirm"

export function RepositoryDetailRoute() {
  const { t } = useT("settings")
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const query = new URLSearchParams(location.search)
  const tabParam = query.get("tab")
  const tab = tabParam === "github_issues" ? "github_issues" : "overview"
  const state = query.get("state") === "closed" ? "closed" : "open"
  const search = pageSearch(location.search)
  const prefix = routePrefix(location.pathname)
  const detailQueryKey = repositoryDetailQueryKey(id, search)
  const detail = useQuery({
    queryKey: detailQueryKey,
    queryFn: () => fetchRepositoryDetail(id, search),
    enabled: id.length > 0 && tab !== "github_issues"
  })
  const issues = useQuery({
    queryKey: ["repositories", id, "issues", state],
    queryFn: () => fetchRepositoryIssues(id, state),
    enabled: id.length > 0 && tab === "github_issues"
  })
  usePageTitle(detail.data?.repository.slug ?? issues.data?.repository.slug)

  return (
    <main aria-label={t('repository.aria_repository')} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {tab !== "github_issues" ? (
        <>
          {detail.isPending ? (
            <PanelMessage>
              {t('repository.loading')}
            </PanelMessage>
          ) : null}
          {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, "Unable to load repository.")}</PanelMessage> : null}
          {detail.isSuccess ? <RepositoryDetail activeTab={tab} payload={detail.data} prefix={prefix} queryKey={detailQueryKey} /> : null}
        </>
      ) : (
        <>
          {issues.isPending ? (
            <PanelMessage>
              {t('repository.loading_issues')}
            </PanelMessage>
          ) : null}
          {issues.isError ? <PanelMessage tone="error">{errorMessage(issues.error, "Unable to load GitHub issues.")}</PanelMessage> : null}
          {issues.isSuccess ? <RepositoryIssues payload={issues.data} prefix={prefix} /> : null}
        </>
      )}
    </main>
  )
}

function repositoryDetailQueryKey(id: string | number, search: string): RepositoryDetailQueryKey {
  return ["repositories", String(id), "detail", search] as const
}

function RepositoryDetail({ activeTab, payload, prefix, queryKey }: { activeTab: "overview" | "github_issues"; payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey }) {
  const { t } = useT("settings")
  const setupStatus = useSetupStatus()
  const [notice, setNotice] = useState<string | null>(payload.message || null)

  return (
    <>
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <a className="hover:underline" href={payload.repository.github_url} rel="noopener" target="_blank">{payload.repository.slug}</a>
        </h1>
      </header>

      <RepositoryTabs active={activeTab} prefix={prefix} tabs={payload.tabs} />
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <div className="grid gap-6 lg:grid-cols-[62%_38%]">
        <div className="space-y-6">
          <RepositorySummary payload={payload} />
          <Actions payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
          <NeedsTriageJobs payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
          {payload.health_history ? <MainBranchHealthSection history={payload.health_history} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} /> : null}
          <RepositoryThroughputPanel repositoryId={payload.repository.id} />
          <RecentJobs payload={payload} prefix={prefix} setupStatus={setupStatus} />
          <FlakyTestsPanel payload={payload} />
        </div>
        <div className="space-y-6">
          <RepositoryDetailsCard payload={payload} prefix={prefix} />
          <CoverageSparkline repositoryId={payload.repository.id} />
          <CredentialNotice payload={payload} />
        </div>
      </div>
    </>
  )
}

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
        <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">Throughput</h2>
        <PanelMessage>Loading throughput metrics...</PanelMessage>
      </section>
    )
  }

  if (metrics.isError) {
    return (
      <section>
        <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">Throughput</h2>
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
          <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">Throughput</h2>
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
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Approval funnel</h3>
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
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Bottlenecks</h3>
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
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Latency and capacity</h3>
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
    medium: "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-800 dark:bg-blue-950/40 dark:text-blue-300",
    high: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300"
  }[confidence]

  return <span className={`rounded border px-1.5 py-0.5 text-[11px] font-medium uppercase ${className}`}>{confidence}</span>
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


function RepositorySummary({ payload }: { payload: RepositoryDetailPayload }) {
  const { t } = useT("settings")
  const repository = payload.repository
  const nonzeroCounts = [
    { label: "running", value: payload.counts.running, tone: "blue" as const },
    { label: "queued", value: payload.counts.queued, tone: "gray" as const },
    { label: "failed 7d", value: payload.counts.failed_7d, tone: "red" as const }
  ].filter((count) => count.value > 0)

  return (
    <div className="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
      <StatusPill tone={repository.polling_enabled ? "green" : "gray"}>{repository.polling_enabled ? "polling enabled" : "polling paused"}</StatusPill>
      <span>{payload.credential_status.label}</span>
      <span className="text-gray-300 dark:text-gray-600">·</span>
      <span>
        {t('repository.agent_prefix')} {repository.agent_provider_label || `user default (${repository.effective_agent_provider_label})`}
      </span>
      {nonzeroCounts.map((count) => (
        <StatusPill key={count.label} tone={count.tone}>{count.value} {count.label}</StatusPill>
      ))}
    </div>
  )
}

function RepositoryDetailsCard({ payload, prefix }: { payload: RepositoryDetailPayload; prefix: string }) {
  const { t } = useT("settings")
  const repository = payload.repository

  return (
    <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
      <h2 className="font-semibold text-gray-900 dark:text-gray-100">
        {t('repository.details')}
      </h2>
      <dl className="mt-3 space-y-3">
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            {t('repository.working_repo')}
          </dt>
          <dd className="mt-0.5 font-mono text-gray-700 dark:text-gray-300">{repository.slug}</dd>
        </div>
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            {t('repository.working_branch')}
          </dt>
          <dd className="mt-0.5 font-mono text-gray-700 dark:text-gray-300">{repository.default_branch}</dd>
        </div>
        {repository.upstream_slug ? (
          <div>
            <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t('repository.upstream_repo')}
            </dt>
            <dd className="mt-0.5 font-mono text-gray-700 dark:text-gray-300">{repository.upstream_slug}{repository.upstream_default_branch ? `:${repository.upstream_default_branch}` : ""}</dd>
          </div>
        ) : null}
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            {t('repository.trigger_label')}
          </dt>
          <dd className="mt-0.5"><code className="rounded bg-gray-100 px-1 dark:bg-gray-800">{repository.trigger_label}</code></dd>
        </div>
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            {t('repository.epic_dependency_policy')}
          </dt>
          <dd className="mt-0.5 text-gray-700 dark:text-gray-300">
            {repository.epic_dependency_policy === "nonlinear" ? t('repository.epic_dependency_policy_nonlinear') : t('repository.epic_dependency_policy_linear')}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            {t('repository.syrus_owner')}
          </dt>
          <dd className="mt-0.5 text-gray-700 dark:text-gray-300">
            {repository.owner_user.profile_path ? (
              <Link className="text-blue-600 hover:underline dark:text-blue-400" to={withRoutePrefix(repository.owner_user.profile_path, prefix)}>{repository.owner_user.display_name}</Link>
            ) : (
              repository.owner_user.display_name || repository.owner_user.email_address
            )}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            {t('repository.added')}
          </dt>
          <dd className="mt-0.5 text-gray-700 dark:text-gray-300"><RelativeTimestamp value={repository.created_at} /></dd>
        </div>
        {repository.github_rate_limit ? (
          <div>
            <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t('repository.github_quota')}
            </dt>
            <dd className="mt-0.5 text-gray-700 dark:text-gray-300"><strong>{repository.github_rate_limit.remaining.toLocaleString()}</strong> / {repository.github_rate_limit.limit.toLocaleString()} ({repository.github_rate_limit.resource})</dd>
          </div>
        ) : null}
        {payload.credential_status.mode === "app" && payload.credential_status.installation_account ? (
          <div>
            <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t('repository.credential')}
            </dt>
            <dd className="mt-0.5 text-gray-700 dark:text-gray-300">
              {t('repository.syrus_app_via', { account: payload.credential_status.installation_account })}
            </dd>
          </div>
        ) : null}
      </dl>
    </section>
  )
}

function Actions({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const search = queryKey[3]
  const [moreOpen, setMoreOpen] = useState(false)
  const moreMenuRef = useDismissiblePopup<HTMLDivElement>(moreOpen, () => setMoreOpen(false))
  const retry = payload.retry_failed_jobs
  const poll = useMutation({
    mutationFn: () => pollRepositoryDetail(appendSearch(payload.paths.app_poll_repository_path, search), payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const retryFailed = useMutation({
    mutationFn: () => retryFailedRepositoryJobs(appendSearch(payload.paths.app_retry_failed_jobs_repository_path, search), payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const archive = useMutation({
    mutationFn: () => archiveRepositoryFromPath(payload.paths.app_archive_repository_path),
    onSuccess: (updated) => {
      queryClient.setQueryData(["repositories"], updated)
      navigate(withRoutePrefix(payload.paths.repositories_path, prefix))
    }
  })
  const runInsight = useMutation({
    mutationFn: () => runInsightAnalysis(payload.paths.app_run_insight_analysis_repository_path!),
    onSuccess: (updated) => {
      if ("repository" in updated && "tabs" in updated) {
        queryClient.setQueryData(queryKey, updated)
      }
      onNotice((updated as { message?: string | null }).message || "Insight analysis started.")
    }
  })
  const disabled = poll.isPending || retryFailed.isPending || archive.isPending

  async function archiveRepository() {
    onNotice(null)
    setMoreOpen(false)
    if (await confirm({ message: t("repositories.confirm_archive", { slug: payload.repository.slug }), destructive: true })) {
      archive.mutate()
    }
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        {payload.simple_mode ? null : <Link className={buttonClass("green")} to={withRoutePrefix(payload.paths.new_job_path, prefix)}>{t('repository.new_job')}</Link>}
        <button className={buttonClass("blue")} disabled={disabled} onClick={() => { onNotice(null); poll.mutate() }} type="button">{t('repository.poll_now')}</button>
        {retry.count > 0 ? (
          <button className={buttonClass("amber")} disabled={disabled || retry.provider_circuit.open} onClick={() => { onNotice(null); retryFailed.mutate() }} type="button">Retry {retry.count} failed with {retry.agent_provider_label}</button>
        ) : null}
        {payload.agent_insights_enabled && payload.paths.app_run_insight_analysis_repository_path ? (
          payload.active_insight_job ? (
            <Link className={buttonClass("gray")} to={withRoutePrefix(payload.active_insight_job.job_path, prefix)}>
              Insight analysis running
            </Link>
          ) : (
            <button
              className={buttonClass("gray")}
              disabled={disabled || runInsight.isPending}
              onClick={() => { onNotice(null); runInsight.mutate() }}
              type="button"
            >
              {runInsight.isPending ? "Starting…" : "Run insight analysis"}
            </button>
          )
        ) : null}
        {payload.agent_insights_enabled && payload.insight_schedule_config ? (
          <InsightScheduleBadge config={payload.insight_schedule_config} />
        ) : null}
        {payload.agent_insights_enabled && payload.paths.repository_insights_path ? (
          <Link className={buttonClass("gray")} to={withRoutePrefix(payload.paths.repository_insights_path, prefix)}>
            View insights
          </Link>
        ) : null}
        <div className="relative" ref={moreMenuRef}>
          <button
            aria-controls="repository-actions-menu"
            aria-expanded={moreOpen}
            aria-haspopup="menu"
            className={buttonClass("gray")}
            onClick={() => setMoreOpen((open) => !open)}
            type="button"
          >
            {t('repository.more')}
          </button>
          {moreOpen ? (
            <div className="absolute left-0 z-20 mt-2 min-w-40 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-1 text-sm shadow-lg" id="repository-actions-menu">
              <Link className="block rounded px-3 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800" onClick={() => setMoreOpen(false)} to={withRoutePrefix(payload.paths.edit_repository_path, prefix)}>Edit</Link>
              <button className="block w-full rounded px-3 py-2 text-left text-amber-800 dark:text-amber-200 hover:bg-amber-50 dark:hover:bg-amber-950/50 disabled:text-gray-300 dark:disabled:text-gray-600" disabled={disabled} onClick={archiveRepository} type="button">{t('repository.archive')}</button>
            </div>
          ) : null}
        </div>
      </div>
      {retry.provider_circuit.open ? (
        <PanelMessage tone="warning">
          {retry.agent_provider_label} retries are paused: {retry.provider_circuit.reason || "provider appears degraded"}.
        </PanelMessage>
      ) : null}
      {poll.isError ? <PanelMessage tone="error">{errorMessage(poll.error, "Repository poll failed.")}</PanelMessage> : null}
      {retryFailed.isError ? <PanelMessage tone="error">{errorMessage(retryFailed.error, "Retry failed jobs command failed.")}</PanelMessage> : null}
      {archive.isError ? <PanelMessage tone="error">{errorMessage(archive.error, "Archive failed.")}</PanelMessage> : null}
      {runInsight.isError ? <PanelMessage tone="error">{errorMessage(runInsight.error, "Failed to start insight analysis.")}</PanelMessage> : null}
      {dialog}
    </>
  )
}

function FlakyTestsPanel({ payload }: { payload: RepositoryDetailPayload }) {
  const { t } = useT("settings")
  const flakyPath = payload.paths.app_flaky_tests_path
  const { data, isPending, isError } = useQuery({
    queryKey: ["repositories", String(payload.repository.id), "flaky_tests"],
    queryFn: () => fetchRepositoryFlakyTests(flakyPath),
    enabled: !!flakyPath
  })

  if (isPending) return null
  if (isError) return null
  if (!data || !data.tests || data.tests.length === 0) return null

  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
        {t("repository.flaky_tests_title")}
      </h2>
      <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="bg-gray-50 text-left text-xs uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{t("repository.flaky_col_test")}</th>
              <th className="hidden px-4 py-2 sm:table-cell">{t("repository.flaky_col_suite")}</th>
              <th className="px-4 py-2">{t("repository.flaky_col_rate")}</th>
              <th className="hidden px-4 py-2 sm:table-cell">{t("repository.flaky_col_avg_duration")}</th>
              <th className="hidden px-4 py-2 sm:table-cell">{t("repository.flaky_col_last_seen")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
            {data.tests.map((test) => <FlakyTestRow key={`${test.suite_name}::${test.name}`} test={test} />)}
          </tbody>
        </table>
        <p className="border-t border-gray-100 px-4 py-2 text-xs text-gray-400 dark:border-gray-800 dark:text-gray-500">
          {t("repository.flaky_tests_lookback", { count: data.lookback })}
        </p>
      </div>
    </section>
  )
}

function FlakyTestRow({ test }: { test: RepositoryFlakyTest }) {
  const pct = `${(test.flakiness_score * 100).toFixed(0)}%`

  return (
    <tr className="text-gray-700 dark:text-gray-300">
      <td className="max-w-xs truncate px-4 py-2" title={test.name}>{test.name}</td>
      <td className="hidden max-w-[12rem] truncate px-4 py-2 text-gray-500 dark:text-gray-400 sm:table-cell" title={test.suite_name}>{test.suite_name}</td>
      <td className="whitespace-nowrap px-4 py-2">
        <span className="inline-flex items-center gap-1 rounded border border-amber-300 bg-amber-50 px-1.5 py-0.5 text-xs font-medium text-amber-700 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300">
          {pct}
          <span className="font-normal opacity-75">{test.failed_count}/{test.total_count}</span>
        </span>
      </td>
      <td className="hidden whitespace-nowrap px-4 py-2 text-gray-500 dark:text-gray-400 sm:table-cell">
        {test.avg_duration_ms != null ? formatTestDuration(test.avg_duration_ms) : "—"}
      </td>
      <td className="hidden whitespace-nowrap px-4 py-2 text-gray-500 dark:text-gray-400 sm:table-cell">
        {test.last_seen_at ? <RelativeTimestamp value={test.last_seen_at} /> : "—"}
      </td>
    </tr>
  )
}

function CredentialNotice({ payload }: { payload: RepositoryDetailPayload }) {
  const { t } = useT("settings")
  const status = payload.credential_status
  if (status.mode === "app") return null

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-700 dark:text-gray-300">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <span className="font-medium">
            {t('repository.connection')}
          </span>
          {" "}{t('repository.pat_fallback')}
          <span className="ml-1">{status.github_app_registered ? "Install the GitHub App for this repository owner to use app credentials here." : "Register the GitHub App to prefer app credentials over PAT fallback."}</span>
          {status.previous_installation_removed ? (
            <span className="ml-1">
              {t('repository.installation_removed')}
            </span>
          ) : null}
        </div>
        {status.install_url ? <a className={buttonClass("gray")} href={status.install_url} rel="noopener" target="_blank">{t('repository.install_app')}</a> : null}
        {status.register_path ? <a className={buttonClass("gray")} href={status.register_path}>{t('repository.register_app')}</a> : null}
      </div>
      {status.missing_github_ids ? (
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
          {t('repository.missing_github_ids')}
        </p>
      ) : null}
    </section>
  )
}

function NeedsTriageJobs({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const search = queryKey[3]
  const release = useMutation({
    mutationFn: (jobId: number) => releaseNeedsTriageRepositoryJob(appendSearch(payload.paths.app_release_needs_triage_job_repository_path, search), jobId, payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  if (!payload.can_release_triage_jobs) return null

  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
        {t('repository.needs_triage')}
      </h2>
      <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {payload.needs_triage_jobs.length > 0 ? (
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">
                  {t('repository.col_job')}
                </th>
                <th className="hidden px-4 py-2 sm:table-cell">
                  {t('repository.col_created')}
                </th>
                <th className="px-4 py-2 text-right">
                  {t('repository.col_action')}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
              {payload.needs_triage_jobs.map((job) => (
                <tr key={job.id}>
                  <td className="px-4 py-3">
                    <SourceLink job={job} prefix={prefix} />
                    <Link className="ml-1 text-gray-700 dark:text-gray-300 hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.issue_title || `JOB-${job.id}`}</Link>
                    {job.owner_user ? (
                      <div className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                        {t('repository.owner_prefix')} {job.owner_user.display_name || job.owner_user.email_address}
                      </div>
                    ) : null}
                  </td>
                  <td className="hidden px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell"><RelativeTimestamp value={job.created_at} /></td>
                  <td className="px-4 py-3 text-right">
                    <button className={buttonClass("blue")} disabled={release.isPending} onClick={() => { onNotice(null); release.mutate(job.id) }} type="button">
                      {t('repository.release_for_triage')}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="p-4 text-sm text-gray-600 dark:text-gray-400">
            {t('repository.no_triage_jobs')}
          </p>
        )}
      </div>
      {release.isError ? <PanelMessage tone="error">{errorMessage(release.error, "Unable to release job for triage.")}</PanelMessage> : null}
    </section>
  )
}

function RecentJobs({ payload, prefix, setupStatus }: { payload: RepositoryDetailPayload; prefix: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  const { t } = useT("settings")
  if (payload.jobs.length === 0) {
    if (payload.simple_mode) return null

    return (
      <section>
        <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
          {t('repository.recent_jobs')}
        </h2>
        <OnboardingEmptyState
          fallbackActionPath={payload.paths.new_job_path}
          fallbackActionText="Create direct job"
          fallbackDescription={`No jobs have run for this repository. Create a direct job now, or label a GitHub issue with ${payload.repository.trigger_label} for polling.`}
          fallbackTitle="No jobs yet"
          prefix={prefix}
          setupStatus={setupStatus}
        />
      </section>
    )
  }

  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
        {t('repository.recent_jobs')}
      </h2>
      <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">
                {t('repository.col_state')}
              </th>
              <th className="px-4 py-2">
                {t('repository.col_issue')}
              </th>
              <th className="hidden px-4 py-2 sm:table-cell">
                {t('repository.col_runs')}
              </th>
              <th className="hidden px-4 py-2 sm:table-cell">
                {t('repository.col_last')}
              </th>
              <th className="hidden px-4 py-2 sm:table-cell"><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
            {payload.jobs.map((job) => <JobRow job={job} key={job.id} prefix={prefix} />)}
          </tbody>
        </table>
      </div>
      <Pagination payload={payload} prefix={prefix} />
    </section>
  )
}

function JobRow({ job, prefix }: { job: RepositoryDetailJob; prefix: string }) {
  const { t } = useT("settings")
  return (
    <tr>
      <td className="px-4 py-3 align-top">
        <StateStatusPill state={job.state} />
        {job.priority !== "medium" ? <span className="ml-1"><TonePill tone="gray">{job.priority}</TonePill></span> : null}
      </td>
      <td className="px-4 py-3">
        <SourceLink job={job} prefix={prefix} />
        <ProviderAvailabilityWarning availability={job.provider_availability} className="ml-1 inline-flex align-[-0.125em]" />
        {job.issue_title ? <Link className="ml-1 text-gray-700 dark:text-gray-300 hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.issue_title}</Link> : null}
        {job.pr_number && job.pr_url ? <a className="ml-1 text-xs text-indigo-700 underline hover:no-underline" href={job.pr_url} rel="noopener" target="_blank">PR #{job.pr_number}</a> : null}
        {job.external_pr_number && job.external_pr_url ? <a className="ml-1 text-xs text-violet-700 underline hover:no-underline" href={job.external_pr_url} rel="noopener" target="_blank">PR #{job.external_pr_number}</a> : null}
        {job.current_step_caption ? <div className="mt-0.5 text-xs italic text-gray-500 dark:text-gray-400">{job.current_step_caption}</div> : null}
        <RepositoryRetryState job={job} />
        <div className="mt-1 flex items-center gap-1.5 text-xs text-gray-400 dark:text-gray-500 sm:hidden">
          <span>{job.runs_count} {job.runs_count === 1 ? "run" : "runs"}</span>
          <span>·</span>
          <span><RelativeTimestamp value={job.updated_at} /></span>
        </div>
      </td>
      <td className="hidden px-4 py-3 text-gray-600 dark:text-gray-400 sm:table-cell">{job.runs_count}</td>
      <td className="hidden px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell"><RelativeTimestamp value={job.updated_at} /></td>
      <td className="hidden px-4 py-3 text-right sm:table-cell">
        <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(job.job_path, prefix)}>{t('repository.view')}</Link>
      </td>
    </tr>
  )
}

function RepositoryRetryState({ job }: { job: RepositoryDetailJob }) {
  const { t } = useT("settings")
  const retry = job.retry_state
  if (!retry || retry.state_label === "No failure") return null

  const tone = retry.auto_retry_exhausted ? "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950/40 border-red-200 dark:border-red-800" : retry.provider_circuit_open ? "text-amber-800 dark:text-amber-200 bg-amber-50 dark:bg-amber-950/40 border-amber-200 dark:border-amber-800" : "text-gray-700 dark:text-gray-300 bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700"
  return (
    <div className={`mt-1 inline-flex flex-wrap items-center gap-1.5 rounded border px-2 py-1 text-xs ${tone}`}>
      <span className="font-medium">{retry.state_label}</span>
      <span>{retry.classification_label}</span>
      <span>
        {t('repository.retries_left', { count: retry.retry_budget_remaining })}
      </span>
      {retry.next_auto_retry_at ? (
        <span>
          {t('repository.retry_next', { time: formatRelativeDate(new Date(retry.next_auto_retry_at)) })}
        </span>
      ) : null}
    </div>
  )
}

function SourceLink({ job, prefix }: { job: { source: RepositoryDetailJob["source"] }; prefix: string }) {
  const { t } = useT("settings")
  if (!job.source.path) return <span className="text-gray-600 dark:text-gray-400">{job.source.label}</span>
  if (!job.source.external) {
    return (
      <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(job.source.path, prefix)}>
        {job.source.label}
      </Link>
    )
  }

  return (
    <a className="text-blue-600 dark:text-blue-400 underline hover:no-underline" href={job.source.path} rel="noopener" target="_blank">
      {job.source.label}
    </a>
  )
}

function InsightScheduleBadge({ config }: { config: InsightScheduleConfigRecord }) {
  if (config.enabled) {
    return (
      <span className="inline-flex items-center rounded border border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40 px-2 py-1 text-xs text-emerald-700 dark:text-emerald-300">
        Auto: on (min {config.min_jobs_since_last_run} / max {config.max_jobs_since_last_run})
      </span>
    )
  }
  return (
    <span className="inline-flex items-center rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 px-2 py-1 text-xs text-gray-500 dark:text-gray-400">
      Auto: off
    </span>
  )
}

function Pagination({ payload, prefix }: { payload: RepositoryDetailPayload; prefix: string }) {
  const { t } = useT("settings")
  const pagination = payload.pagination
  if (pagination.total_pages <= 1) return null

  return (
    <div className="mt-4 flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>
        {t('repository.showing', { first: pagination.first_item, last: pagination.last_item, total: pagination.total_jobs })}
      </span>
      <div className="flex gap-2">
        {pagination.previous_path ? (
          <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>
            {t('repository.previous')}
          </Link>
        ) : (
          <span className={disabledPaginationClass()}>
            {t('repository.previous')}
          </span>
        )}
        {pagination.next_path ? (
          <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>
            {t('repository.next')}
          </Link>
        ) : (
          <span className={disabledPaginationClass()}>
            {t('repository.next')}
          </span>
        )}
      </div>
    </div>
  )
}

function paginationLinkClass() {
  return "rounded border border-gray-300 dark:border-gray-600 px-3 py-1 hover:bg-gray-50 dark:hover:bg-gray-800"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 dark:border-gray-700 px-3 py-1 text-gray-300 dark:text-gray-600"
}

function pageSearch(search: string) {
  const params = new URLSearchParams(search)
  const page = params.get("page")
  return page ? `?${new URLSearchParams({ page }).toString()}` : ""
}

function formatTestDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`
  const minutes = Math.floor(ms / 60000)
  const seconds = Math.round((ms % 60000) / 1000)
  return `${minutes}m ${seconds}s`
}
