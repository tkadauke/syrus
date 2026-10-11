import { type RepositoryDetailQueryKey, appendSearch, buttonClass, repositoryDetailPageSearch, repositoryDetailQueryKey } from "./repositoryDetail/shared"
import { PanelMessage } from "../components/PanelMessage"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading, SectionHeading } from "../components/Heading"
import { DataTable, DescriptionList, Metric, Surface } from "../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "../components/dataTable"
import { ChevronIcon } from "../components/ChevronIcon"
import { DismissButton } from "../components/DismissButton"
import { Checkbox } from "../components/Checkbox"
import { Button } from "../components/Button"
import { PluginUiSlot } from "../pluginUiSlots"
import { formatRelativeDate } from "../lib/relativeTime"
import { DeliveryTracksSection } from "./repositoryDetail/DeliveryTracks"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { NoticeToast } from "../components/NoticeToast"
import { ProviderAvailabilityWarning, ProviderFailoverNotice } from "../components/ProviderAvailabilityWarning"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { RepositoryPageShell } from "../components/RepositoryPageShell"
import { usePageGutterRestoreClassName } from "../components/ui/Page"
import { StatusPill as StateStatusPill, TonePill, type PillTone } from "../components/StatusPill"
import { CoverageSparkline } from "../components/CoverageSparkline"
import { PreviewPanel } from "../components/PreviewPanel"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { fetchRepositoryDetail, pollRepositoryDetail, releaseNeedsTriageRepositoryJob, retryFailedRepositoryJobs, runInsightAnalysis, runRepositoryRecommendation, type InsightScheduleConfigRecord, type RepositoryCognitiveDebtQueueItem, type RepositoryDetailJob, type RepositoryDetailPayload, type RepositoryFeatureRecommendation } from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"

const MERGE_TRAIN_FAILURE_RUNGS = [
  { value: "restart", labelKey: "repository.syrus_yml_merge_train_rung_restart" },
  { value: "keep_assembly", labelKey: "repository.syrus_yml_merge_train_rung_keep_assembly" }
] as const

export function RepositoryDetailRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const tab = "overview" as const
  const search = repositoryDetailPageSearch(location.search)
  const prefix = routePrefix(location.pathname)
  const detailQueryKey = repositoryDetailQueryKey(id, search)
  const detail = useQuery({
    queryKey: detailQueryKey,
    queryFn: () => fetchRepositoryDetail(id, search),
    enabled: id.length > 0
  })
  usePageTitle(detail.data?.repository.slug)

  return <RepositoryDetail activeTab={tab} detail={detail} prefix={prefix} queryKey={detailQueryKey} />
}

function RepositoryDetail({ activeTab, detail, prefix, queryKey }: { activeTab: "overview"; detail: { data?: RepositoryDetailPayload; isPending: boolean; isError: boolean; error: unknown }; prefix: string; queryKey: RepositoryDetailQueryKey }) {
  const { t } = useT("settings")
  const setupStatus = useSetupStatus()
  const payload = detail.data
  const [notice, setNotice] = useState<string | null>(payload?.message || null)

  return (
    <RepositoryPageShell
      activeTab={activeTab}
      ariaLabel={t('repository.aria_repository')}
      heading={payload ? (
        <PageHeading mono>
          <a className="hover:underline" href={payload.repository.github_url} rel="noopener" target="_blank">{payload.repository.slug}</a>
        </PageHeading>
      ) : null}
      prefix={prefix}
      tabs={payload?.tabs ?? []}
      tipBanner={payload ? <RecommendedActions payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} /> : undefined}
    >
      {detail.isPending ? (
        <PanelMessage>
          {t('repository.loading')}
        </PanelMessage>
      ) : null}
      {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, t("repository.error_load"))}</PanelMessage> : null}
      {payload ? (
        <>
          <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
          <div className="grid gap-6 lg:grid-cols-[62%_38%]">
            <div className="space-y-6">
              <RepositorySummary payload={payload} />
              <CognitiveDebtSection payload={payload} prefix={prefix} />
              <Actions payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
              <NeedsTriageJobs payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
              {payload.delivery ? <DeliveryTracksSection delivery={payload.delivery} prefix={prefix} /> : null}
              <PluginUiSlot panels={payload.ui_panels} props={{ repository: payload.repository }} />
              <RecentJobs payload={payload} prefix={prefix} setupStatus={setupStatus} />
            </div>
            <div className="space-y-6">
              <RepositoryDetailsCard payload={payload} prefix={prefix} />
              <SyrusYmlCard payload={payload} />
              <PreviewPanel
                canStart={!payload.repository.archived}
                initialPreview={payload.preview}
                queryKeyPrefix="repository"
                entityId={payload.repository.id}
                previewPath={payload.paths.app_preview_path}
                previewLogsPath={payload.paths.app_preview_logs_path}
                queryKey={queryKey}
                repositoryId={payload.repository.id}
              />
              <CoverageSparkline repositoryId={payload.repository.id} />
              <CredentialNotice payload={payload} />
            </div>
          </div>
        </>
      ) : null}
    </RepositoryPageShell>
  )
}

function RepositorySummary({ payload }: { payload: RepositoryDetailPayload }) {
  const { t } = useT("settings")
  const repository = payload.repository
  const pollIssueErrors = repository.poll_issue_errors ?? []
  const nonzeroCounts = [
    { label: t("repository.count_running"), value: payload.counts.running, tone: "blue" as const },
    { label: t("repository.count_queued"), value: payload.counts.queued, tone: "gray" as const },
    { label: t("repository.count_failed_7d"), value: payload.counts.failed_7d, tone: "red" as const }
  ].filter((count) => count.value > 0)

  return (
    <div className="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
      <TonePill tone={repository.polling_enabled ? "green" : "gray"}>{repository.polling_enabled ? t("repository.polling_enabled") : t("repository.polling_paused")}</TonePill>
      {pollIssueErrors.length > 0 ? (
        <TonePill tone="amber">{t("repository.poll_quarantined", { count: pollIssueErrors.length })}</TonePill>
      ) : null}
      <span>{payload.credential_status.label}</span>
      <span className="text-gray-300 dark:text-gray-600">·</span>
      <span>
        {t('repository.agent_prefix')} {repository.agent_provider_label || t("repository.user_default_agent", { provider: repository.effective_agent_provider_label })}
      </span>
      {nonzeroCounts.map((count) => (
        <TonePill key={count.label} tone={count.tone}>{count.value} {count.label}</TonePill>
      ))}
    </div>
  )
}

function CognitiveDebtSection({ payload, prefix }: { payload: RepositoryDetailPayload; prefix: string }) {
  const { t } = useT("settings")
  const debt = payload.cognitive_debt
  if (!debt) return null

  const summary = debt.summary

  return (
    <Surface aria-label={t("repository.cognitive_debt_aria")} className="text-sm" role="region">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <SectionHeading>
            {t("repository.cognitive_debt")}
          </SectionHeading>
          <p className="mt-1 max-w-3xl text-xs leading-5 text-text-secondary">
            {debt.proxy_notice || t("repository.cognitive_debt_proxy_notice")}
          </p>
          {debt.projection_notice ? (
            <p className="mt-1 max-w-3xl text-xs leading-5 text-warning-text">
              {debt.projection_notice}
            </p>
          ) : null}
        </div>
        <Metric.Group className="w-full lg:w-[24rem] lg:shrink-0" columns={2} data-testid="cognitive-debt-metrics">
          <Metric.Card label={t("repository.cognitive_coverage")} value={formatPercent(summary.cognitive_coverage_pct)} />
          <Metric.Card label={t("repository.cognitive_covered")} value={summary.covered_count.toLocaleString()} />
          <Metric.Card label={t("repository.cognitive_stale")} tone={summary.stale_count > 0 ? "warning" : "neutral"} value={summary.stale_count.toLocaleString()} />
          <Metric.Card label={t("repository.cognitive_blind")} tone={summary.blind_count > 0 ? "danger" : "neutral"} value={summary.blind_count.toLocaleString()} />
        </Metric.Group>
      </div>

      {debt.empty ? (
        <Surface className="mt-4 text-text-secondary" padding="sm" variant="subtle">
          {t("repository.cognitive_debt_empty")}
        </Surface>
      ) : (
        <>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <CognitiveDebtRollupList title={t("repository.cognitive_subsystems")} rows={debt.subsystems.slice(0, 4)} />
            <CognitiveDebtRollupList title={t("repository.cognitive_files")} rows={debt.files.slice(0, 4)} />
          </div>
          <div className="mt-4">
            <h3 className="text-xs font-semibold uppercase tracking-wide text-text-muted">
              {t("repository.cognitive_review_queue")}
            </h3>
            {debt.review_queue.length > 0 ? (
              <div className="mt-2 divide-y divide-border rounded-[var(--radius-panel)] border border-border">
                {debt.review_queue.map((item) => (
                  <CognitiveDebtQueueRow item={item} key={item.path} prefix={prefix} />
                ))}
              </div>
            ) : (
              <Surface className="mt-2 text-text-secondary" padding="sm" variant="subtle">
                {t("repository.cognitive_queue_empty")}
              </Surface>
            )}
          </div>
        </>
      )}
    </Surface>
  )
}

function CognitiveDebtRollupList({ title, rows }: { title: string; rows: NonNullable<RepositoryDetailPayload["cognitive_debt"]>["files"] }) {
  return (
    <div>
      <h3 className="text-xs font-semibold uppercase tracking-wide text-text-muted">{title}</h3>
      <div className="mt-2 space-y-1">
        {rows.map((row) => (
          <div className="flex items-center justify-between gap-3 rounded-[var(--radius-control)] border border-border px-2 py-1.5 text-xs" key={row.key}>
            <span className="min-w-0 truncate font-mono text-text-primary">{row.key}</span>
            <span className="shrink-0 text-text-secondary">{formatPercent(row.cognitive_coverage_pct)}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

function CognitiveDebtQueueRow({ item, prefix }: { item: RepositoryCognitiveDebtQueueItem; prefix: string }) {
  const { t } = useT("settings")
  const coverage = item.rollup.cognitive_coverage_pct
  return (
    <div className="flex flex-col gap-2 px-3 py-3 sm:flex-row sm:items-start sm:justify-between">
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <a className="font-mono text-sm text-brand hover:underline dark:text-brand-emphasis" href={item.source.github_url} rel="noopener" target="_blank">
            {item.path}
          </a>
          <TonePill tone={cognitiveStateTone(item.coverage_state)}>{cognitiveStateLabel(item.coverage_state, t)}</TonePill>
          {item.explanations.map((explanation) => (
            <TonePill key={explanation} tone={explanationTone(explanation)}>
              {explanationLabel(explanation, t)}
            </TonePill>
          ))}
        </div>
        <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-text-secondary">
          <span>{t("repository.cognitive_risk_score", { score: item.risk_score.toFixed(1) })}</span>
          <span>{t("repository.cognitive_file_coverage", { pct: formatPercent(coverage) })}</span>
          <span>{t("repository.cognitive_file_blind", { count: item.rollup.blind_count })}</span>
          {item.signals.test_coverage_pct == null ? null : (
            <span>{t("repository.cognitive_test_coverage", { pct: formatPercent(item.signals.test_coverage_pct) })}</span>
          )}
        </div>
      </div>
      {item.source.review_path ? (
        <Link className={`${buttonClass("gray")} shrink-0`} to={withRoutePrefix(item.source.review_path, prefix)}>
          {t("repository.cognitive_open_review")}
        </Link>
      ) : null}
    </div>
  )
}

function formatPercent(value: number | null | undefined) {
  return value == null ? "n/a" : `${value.toFixed(1)}%`
}

function cognitiveStateTone(state: string): PillTone {
  if (state === "covered") return "green"
  if (state === "stale") return "amber"
  return "red"
}

function explanationTone(explanation: string): PillTone {
  if (explanation.includes("blind") || explanation.includes("untested") || explanation.includes("unhealthy")) return "red"
  if (explanation.includes("stale") || explanation.includes("churn") || explanation.includes("coverage")) return "amber"
  return "gray"
}

function cognitiveStateLabel(state: string, t: ReturnType<typeof useT>["t"]) {
  const labels: Record<string, string> = {
    covered: t("repository.cognitive_state_covered"),
    stale: t("repository.cognitive_state_stale"),
    blind: t("repository.cognitive_state_blind")
  }
  return labels[state] || state
}

function explanationLabel(explanation: string, t: ReturnType<typeof useT>["t"]) {
  const labels: Record<string, string> = {
    blind: t("repository.cognitive_chip_blind"),
    stale: t("repository.cognitive_chip_stale"),
    "partially blind": t("repository.cognitive_chip_partially_blind"),
    "partially stale": t("repository.cognitive_chip_partially_stale"),
    covered: t("repository.cognitive_chip_covered"),
    "high churn": t("repository.cognitive_chip_high_churn"),
    untested: t("repository.cognitive_chip_untested"),
    "low test coverage": t("repository.cognitive_chip_low_test_coverage"),
    "high complexity": t("repository.cognitive_chip_high_complexity"),
    "unhealthy target": t("repository.cognitive_chip_unhealthy_target"),
    "old blind code": t("repository.cognitive_chip_old_blind_code"),
    "recent reliability signal": t("repository.cognitive_chip_recent_reliability_signal"),
    "unprojected review evidence": t("repository.cognitive_chip_unprojected_review_evidence")
  }
  return labels[explanation] || explanation
}

export function RecommendedActions({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const search = queryKey[3]
  const [dismissed, setDismissed] = useState<Set<string>>(() => readDismissedRecommendations(payload.repository.id))
  const [currentIndex, setCurrentIndex] = useState(0)
  const recommendationAction = useMutation({
    mutationFn: (recommendation: RepositoryFeatureRecommendation) => runRepositoryRecommendation(appendSearch(recommendation.cta.path, search), payload.pagination.page),
    onSuccess: (updated, recommendation) => {
      dismiss(recommendation)
      if ("repository" in updated && "tabs" in updated) {
        queryClient.setQueryData(queryKey, updated)
        onNotice(updated.message || null)
      } else {
        onNotice(updated.message || t("repository.recommendation_job_created"))
        navigate(withRoutePrefix(updated.redirect_to, prefix))
      }
    }
  })

  const recommendations = (payload.recommended_actions || []).filter((recommendation) => !dismissed.has(recommendation.dismissal_key))
  const activeIndex = Math.min(currentIndex, Math.max(recommendations.length - 1, 0))
  const recommendation = recommendations[activeIndex]
  const hasMultiple = recommendations.length > 1

  useEffect(() => {
    if (currentIndex >= recommendations.length) {
      setCurrentIndex(Math.max(recommendations.length - 1, 0))
    }
  }, [currentIndex, recommendations.length])

  if (recommendations.length === 0) return null

  function dismiss(recommendation: RepositoryFeatureRecommendation) {
    const next = new Set(dismissed)
    next.add(recommendation.dismissal_key)
    setDismissed(next)
    writeDismissedRecommendations(payload.repository.id, next)
    if (activeIndex >= recommendations.length - 1) {
      setCurrentIndex(Math.max(recommendations.length - 2, 0))
    }
  }

  return (
    <section aria-label={t("repository.recommended_actions")} className="space-y-2">
      <div className={`rounded border px-3 py-2 text-sm ${recommendationToneClass(recommendation.tone)}`} key={recommendation.id}>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium">{recommendation.title}</span>
              <span className="text-xs opacity-75">{recommendation.category}</span>
              <span className="text-xs opacity-75">{t("repository.tip_position", { index: activeIndex + 1, count: recommendations.length })}</span>
            </div>
            <p className="mt-0.5 text-xs leading-5 opacity-90">{recommendation.body}</p>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {hasMultiple ? (
              <div className="flex items-center gap-1">
                <button
                  aria-label={t("repository.previous_tip")}
                  className="inline-flex h-7 w-7 items-center justify-center rounded border border-current/20 hover:bg-black/5 disabled:opacity-40 dark:hover:bg-white/10"
                  disabled={recommendationAction.isPending}
                  onClick={() => setCurrentIndex((index) => (index - 1 + recommendations.length) % recommendations.length)}
                  type="button"
                >
                  <ChevronIcon className="h-4 w-4 rotate-180" />
                </button>
                <button
                  aria-label={t("repository.next_tip")}
                  className="inline-flex h-7 w-7 items-center justify-center rounded border border-current/20 hover:bg-black/5 disabled:opacity-40 dark:hover:bg-white/10"
                  disabled={recommendationAction.isPending}
                  onClick={() => setCurrentIndex((index) => (index + 1) % recommendations.length)}
                  type="button"
                >
                  <ChevronIcon className="h-4 w-4" />
                </button>
              </div>
            ) : null}
            {recommendation.cta.kind === "link" ? (
              <Link className={buttonClass("gray")} to={withRoutePrefix(recommendation.cta.path, prefix)}>{recommendation.cta.label}</Link>
            ) : (
              <button
                className={buttonClass(recommendation.cta.kind === "job" ? "blue" : "green")}
                disabled={recommendationAction.isPending}
                onClick={() => { onNotice(null); recommendationAction.mutate(recommendation) }}
                type="button"
              >
                {recommendationAction.isPending ? t("repository.working") : recommendation.cta.label}
              </button>
            )}
            <DismissButton label={t("repository.dismiss_recommendation", { title: recommendation.title })} onClick={() => dismiss(recommendation)} />
          </div>
        </div>
      </div>
      {recommendationAction.isError ? <PanelMessage tone="error">{errorMessage(recommendationAction.error, t("repository.recommendation_action_failed"))}</PanelMessage> : null}
    </section>
  )
}

function recommendationToneClass(tone: RepositoryFeatureRecommendation["tone"]) {
  const classes = {
    amber: "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100",
    blue: "border-info-border bg-info-surface text-info-text",
    green: "border-emerald-200 bg-emerald-50 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-100",
    gray: "border-gray-200 bg-white text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return classes[tone]
}

function dismissedRecommendationStorageKey(repositoryId: number) {
  return `syrus:repository:${repositoryId}:dismissed-recommendations`
}

function readDismissedRecommendations(repositoryId: number) {
  if (typeof window === "undefined") return new Set<string>()
  try {
    return new Set<string>(JSON.parse(window.localStorage.getItem(dismissedRecommendationStorageKey(repositoryId)) || "[]"))
  } catch (_error) {
    return new Set<string>()
  }
}

function writeDismissedRecommendations(repositoryId: number, dismissed: Set<string>) {
  if (typeof window === "undefined") return
  window.localStorage.setItem(dismissedRecommendationStorageKey(repositoryId), JSON.stringify([...dismissed]))
}

function RepositoryDetailsCard({ payload, prefix }: { payload: RepositoryDetailPayload; prefix: string }) {
  const { t } = useT("settings")
  const repository = payload.repository
  const pollIssueErrors = repository.poll_issue_errors ?? []

  return (
    <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900" aria-label={t('repository.details')}>
      <SectionHeading>
        {t('repository.details')}
      </SectionHeading>
      <DescriptionList.Root className="mt-3" density="compact">
        <DescriptionList.Item descriptionClassName="font-mono text-gray-700 dark:text-gray-300" label={t('repository.working_repo')}>
          {repository.slug}
        </DescriptionList.Item>
        <DescriptionList.Item descriptionClassName="font-mono text-gray-700 dark:text-gray-300" label={t('repository.working_branch')}>
          {repository.default_branch}
        </DescriptionList.Item>
        {repository.upstream_slug ? (
          <DescriptionList.Item descriptionClassName="font-mono text-gray-700 dark:text-gray-300" label={t('repository.upstream_repo')}>
            {repository.upstream_slug}{repository.upstream_default_branch ? `:${repository.upstream_default_branch}` : ""}
          </DescriptionList.Item>
        ) : null}
        <DescriptionList.Item label={t('repository.trigger_label')}>
          <code className="rounded bg-gray-100 px-1 dark:bg-gray-800">{repository.trigger_label}</code>
        </DescriptionList.Item>
        <DescriptionList.Item descriptionClassName="text-gray-700 dark:text-gray-300" label={t('repository.syrus_owner')}>
          {repository.owner_user.profile_path ? (
            <Link className="text-brand hover:underline dark:text-brand-emphasis" to={withRoutePrefix(repository.owner_user.profile_path, prefix)}>{repository.owner_user.display_name}</Link>
          ) : (
            repository.owner_user.display_name || repository.owner_user.email_address
          )}
        </DescriptionList.Item>
        <DescriptionList.Item descriptionClassName="text-gray-700 dark:text-gray-300" label={t('repository.added')}>
          <RelativeTimestamp value={repository.created_at} />
        </DescriptionList.Item>
        {repository.github_rate_limit ? (
          <DescriptionList.Item descriptionClassName="text-gray-700 dark:text-gray-300" label={t('repository.github_quota')}>
            <strong>{repository.github_rate_limit.remaining.toLocaleString()}</strong> / {repository.github_rate_limit.limit.toLocaleString()} ({repository.github_rate_limit.resource})
          </DescriptionList.Item>
        ) : null}
        {pollIssueErrors.length > 0 ? (
          <DescriptionList.Item descriptionClassName="space-y-1 text-gray-700 dark:text-gray-300" label={t('repository.poll_issue_errors')}>
            {pollIssueErrors.map((error) => (
              <div key={`${error.issue_number}-${error.recorded_at}`} className="font-mono text-xs text-amber-700 dark:text-amber-300" title={error.error_message}>
                #{error.issue_number}: {error.error_message}
              </div>
            ))}
          </DescriptionList.Item>
        ) : null}
        {payload.credential_status.mode === "app" && payload.credential_status.installation_account ? (
          <DescriptionList.Item descriptionClassName="text-gray-700 dark:text-gray-300" label={t('repository.credential')}>
            {t('repository.syrus_app_via', { account: payload.credential_status.installation_account })}
          </DescriptionList.Item>
        ) : null}
      </DescriptionList.Root>
    </section>
  )
}

function SyrusYmlCard({ payload }: { payload: RepositoryDetailPayload }) {
  const { t } = useT("settings")
  const summary = payload.syrus_yml
  if (!summary) return null

  const rows = summary.present ? [
    [t("repository.syrus_yml_prepare"), String(summary.prepare_commands_count)],
    [t("repository.syrus_yml_graders"), t("repository.syrus_yml_graders_value", { count: summary.graders_count, required: summary.required_graders_count })],
    [t("repository.syrus_yml_formatters"), formatterModeLabel(summary.formatter_mode, t)],
    [t("repository.syrus_yml_generated"), String(summary.generated_steps_count)],
    [t("repository.syrus_yml_visual_review"), visualReviewModeLabel(summary.visual_review_mode, t)],
    [t("repository.syrus_yml_adversarial_review"), summary.adversarial_review_rounds == null ? t("repository.syrus_yml_not_configured") : t("repository.syrus_yml_rounds", { count: summary.adversarial_review_rounds })],
    [t("repository.syrus_yml_coverage"), summary.coverage_configured ? t("repository.syrus_yml_configured") : t("repository.syrus_yml_not_configured")],
    [t("repository.syrus_yml_delivery_tracks"), String(summary.delivery_tracks_count)]
  ] : [
    [t("repository.syrus_yml_status"), summary.note || t("repository.syrus_yml_unavailable")]
  ]

  return (
    <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900" aria-label={t("repository.syrus_yml_aria")}>
      <SectionHeading>
        .syrus.yml
      </SectionHeading>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {summary.present ? t("repository.syrus_yml_loaded", { source: summary.source }) : summary.note ? t("repository.syrus_yml_not_loaded_with_note", { note: summary.note }) : t("repository.syrus_yml_not_loaded")}
      </p>
      <DescriptionList.Root className="mt-3 sm:grid-cols-2" density="compact">
        {rows.map(([label, value]) => (
          <DescriptionList.Item descriptionClassName="text-gray-700 dark:text-gray-300" key={label} label={label}>
            {value}
          </DescriptionList.Item>
        ))}
      </DescriptionList.Root>
      {summary.present ? <MergeTrainFailurePolicySelector initialPolicy={summary.merge_train_failure_policy} /> : null}
    </section>
  )
}

function MergeTrainFailurePolicySelector({ initialPolicy }: { initialPolicy: string[] | null }) {
  const { t } = useT("settings")
  const [open, setOpen] = useState(false)
  const [policy, setPolicy] = useState<string[] | null>(initialPolicy)
  const popupRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const selected = policy ?? []
  const summary = selected.length > 0
    ? selected.join(" -> ")
    : t("repository.syrus_yml_merge_train_fallback")
  const yaml = selected.length > 0
    ? `merge_train:\n  failure_policy:\n${selected.map((rung) => `    - ${rung}`).join("\n")}`
    : t("repository.syrus_yml_merge_train_fallback_detail")

  function toggleRung(rung: string, checked: boolean) {
    const next = checked
      ? [ ...selected, rung ].filter((value, index, values) => values.indexOf(value) === index)
      : selected.filter((value) => value !== rung)
    setPolicy(next.length > 0 ? next : null)
  }

  function moveRung(rung: string, direction: -1 | 1) {
    const index = selected.indexOf(rung)
    const target = index + direction
    if (index < 0 || target < 0 || target >= selected.length) return

    const next = [ ...selected ]
    ;[next[index], next[target]] = [next[target], next[index]]
    setPolicy(next)
  }

  return (
    <div className="relative mt-4 border-t border-gray-200 pt-3 dark:border-gray-700" ref={popupRef}>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <p className="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
            {t("repository.syrus_yml_merge_train_failure_policy")}
          </p>
          <p className="mt-1 min-w-0 break-words font-mono text-sm text-gray-800 dark:text-gray-100">
            {summary}
          </p>
        </div>
        <Button
          aria-expanded={open}
          className="w-full justify-between sm:w-auto sm:min-w-40"
          onClick={() => setOpen((value) => !value)}
          variant="secondary"
        >
          <span className="truncate">{t("repository.syrus_yml_merge_train_button")}</span>
          <ChevronIcon className={`h-4 w-4 shrink-0 transition-transform ${open ? "rotate-90" : ""}`} />
        </Button>
      </div>

      {open ? (
        <div className="absolute right-0 z-20 mt-2 w-full max-w-[calc(100vw-2rem)] rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-950 sm:w-96">
          <div className="space-y-2">
            {MERGE_TRAIN_FAILURE_RUNGS.map((rung) => {
              const checked = selected.includes(rung.value)
              const index = selected.indexOf(rung.value)
              return (
                <div className="flex items-center gap-2 rounded border border-gray-200 p-2 dark:border-gray-800" key={rung.value}>
                  <Checkbox
                    checked={checked}
                    label={t(rung.labelKey)}
                    onChange={(event) => toggleRung(rung.value, event.target.checked)}
                  />
                  <div className="ml-auto flex shrink-0 items-center gap-1">
                    <button
                      aria-label={t("repository.syrus_yml_merge_train_move_up", { rung: t(rung.labelKey) })}
                      className="rounded border border-gray-300 px-2 py-1 text-xs text-gray-600 disabled:opacity-40 dark:border-gray-700 dark:text-gray-300"
                      disabled={!checked || index <= 0}
                      onClick={() => moveRung(rung.value, -1)}
                      type="button"
                    >
                      {t("repository.syrus_yml_merge_train_up")}
                    </button>
                    <button
                      aria-label={t("repository.syrus_yml_merge_train_move_down", { rung: t(rung.labelKey) })}
                      className="rounded border border-gray-300 px-2 py-1 text-xs text-gray-600 disabled:opacity-40 dark:border-gray-700 dark:text-gray-300"
                      disabled={!checked || index === selected.length - 1}
                      onClick={() => moveRung(rung.value, 1)}
                      type="button"
                    >
                      {t("repository.syrus_yml_merge_train_down")}
                    </button>
                  </div>
                </div>
              )
            })}
          </div>
          <div className="mt-3 rounded bg-gray-50 p-2 dark:bg-gray-900">
            <p className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("repository.syrus_yml_merge_train_yaml")}</p>
            <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-xs text-gray-700 dark:text-gray-200">{yaml}</pre>
          </div>
          <div className="mt-3 flex justify-end">
            <button
              className="text-sm text-gray-600 underline hover:no-underline dark:text-gray-300"
              onClick={() => setPolicy(null)}
              type="button"
            >
              {t("repository.syrus_yml_merge_train_clear")}
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

function formatterModeLabel(mode: string, t: ReturnType<typeof useT>["t"]) {
  const labels: Record<string, string> = {
    unavailable: t("repository.syrus_yml_unavailable_mode"),
    "not configured": t("repository.syrus_yml_not_configured"),
    disabled: t("repository.syrus_yml_disabled"),
    "plugin defaults": t("repository.syrus_yml_plugin_defaults"),
    explicit: t("repository.syrus_yml_explicit")
  }

  return labels[mode] || mode
}

function visualReviewModeLabel(mode: string, t: ReturnType<typeof useT>["t"]) {
  const labels: Record<string, string> = {
    unavailable: t("repository.syrus_yml_unavailable_mode"),
    "not configured": t("repository.syrus_yml_not_configured"),
    "instance default": t("repository.syrus_yml_instance_default"),
    enabled: t("repository.syrus_yml_enabled"),
    disabled: t("repository.syrus_yml_disabled")
  }

  return labels[mode] || mode
}

function Actions({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
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
  const runInsight = useMutation({
    mutationFn: () => runInsightAnalysis(payload.paths.app_run_insight_analysis_repository_path!),
    onSuccess: (updated) => {
      if ("repository" in updated && "tabs" in updated) {
        queryClient.setQueryData(queryKey, updated)
      }
      onNotice((updated as { message?: string | null }).message || t("repository.insight_started"))
    }
  })
  const disabled = poll.isPending || retryFailed.isPending

  function pollNow() {
    onNotice(null)
    setMoreOpen(false)
    poll.mutate()
  }

  function retryFailedJobs() {
    onNotice(null)
    setMoreOpen(false)
    retryFailed.mutate()
  }

  function startInsight() {
    onNotice(null)
    setMoreOpen(false)
    runInsight.mutate()
  }

  return (
    <>
      <div className="flex flex-wrap items-center justify-end gap-2">
        {payload.agent_insights_enabled && payload.insight_schedule_config ? (
          <InsightScheduleBadge config={payload.insight_schedule_config} />
        ) : null}
        {payload.can_edit ? (
          <Link className={buttonClass("gray")} to={withRoutePrefix(payload.paths.edit_repository_path, prefix)}>{t("repository.edit")}</Link>
        ) : null}
        <div className="relative" ref={moreMenuRef}>
          <button
            aria-controls="repository-actions-menu"
            aria-expanded={moreOpen}
            aria-haspopup="menu"
            aria-label={t('repository.more_actions')}
            className={buttonClass("gray")}
            onClick={() => setMoreOpen((open) => !open)}
            type="button"
          >
            ⋯
          </button>
          {moreOpen ? (
            <div className="absolute right-0 z-20 mt-2 min-w-48 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-1 text-sm shadow-lg" id="repository-actions-menu" role="menu">
              <Link className={menuItemClass()} onClick={() => setMoreOpen(false)} role="menuitem" to={withRoutePrefix(payload.paths.new_job_path, prefix)}>{t('repository.new_job')}</Link>
              <button className={menuItemClass()} disabled={disabled} onClick={pollNow} role="menuitem" type="button">{t('repository.poll_now')}</button>
              {retry.count > 0 ? (
                <button className={menuItemClass()} disabled={disabled || retry.provider_circuit.open} onClick={retryFailedJobs} role="menuitem" type="button">{t("repository.retry_failed_with", { count: retry.count, provider: retry.agent_provider_label })}</button>
              ) : null}
              <Link className={menuItemClass()} onClick={() => setMoreOpen(false)} role="menuitem" to={withRoutePrefix(payload.paths.new_repository_skill_job_path, prefix)}>{t('repository.launch_skill')}</Link>
              {payload.agent_insights_enabled && payload.paths.app_run_insight_analysis_repository_path ? (
                payload.active_insight_job ? (
                  <Link className={menuItemClass()} onClick={() => setMoreOpen(false)} role="menuitem" to={withRoutePrefix(payload.active_insight_job.job_path, prefix)}>
                    {t("repository.insight_running")}
                  </Link>
                ) : (
                  <button
                    className={menuItemClass()}
                    disabled={disabled || runInsight.isPending}
                    onClick={startInsight}
                    role="menuitem"
                    type="button"
                  >
                    {runInsight.isPending ? t("repository.insight_starting") : t("repository.run_insight")}
                  </button>
                )
              ) : null}
              {payload.agent_insights_enabled && payload.paths.repository_insights_path ? (
                <Link className={menuItemClass()} onClick={() => setMoreOpen(false)} role="menuitem" to={withRoutePrefix(payload.paths.repository_insights_path, prefix)}>
                  {t("repository.view_insights")}
                </Link>
              ) : null}
            </div>
          ) : null}
        </div>
      </div>
      {retry.provider_circuit.open ? (
        <PanelMessage tone="warning">
          {t("repository.retries_paused", { provider: retry.agent_provider_label, reason: retry.provider_circuit.reason || t("repository.provider_degraded") })}
        </PanelMessage>
      ) : null}
      {poll.isError ? <PanelMessage tone="error">{errorMessage(poll.error, t("repository.poll_failed"))}</PanelMessage> : null}
      {retryFailed.isError ? <PanelMessage tone="error">{errorMessage(retryFailed.error, t("repository.retry_failed_command_failed"))}</PanelMessage> : null}
      {runInsight.isError ? <PanelMessage tone="error">{errorMessage(runInsight.error, t("repository.insight_start_failed"))}</PanelMessage> : null}
    </>
  )
}

function menuItemClass(tone: "default" | "danger" = "default") {
  const colors = {
    danger: "text-amber-800 dark:text-amber-200 hover:bg-amber-50 dark:hover:bg-amber-950/50",
    default: "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
  }
  return `block w-full rounded px-3 py-2 text-left disabled:text-gray-300 dark:disabled:text-gray-600 ${colors[tone]}`
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
          <span className="ml-1">{status.github_app_registered ? t("repository.install_app_owner_hint") : t("repository.register_app_hint")}</span>
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

// Left off the shared column-config primitive on purpose: only one of its
// three columns (Created) is genuinely optional -- Job and Action are both
// the point of a triage queue -- and the list is bounded/small, so a
// picker/reorder menu would add controls without giving the operator
// anything worth decluttering.
function NeedsTriageJobs({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const search = queryKey[3]
  const contentGutter = useRepositoryContentGutterClassName()
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
      <SectionHeading className={`mb-3 ${contentGutter}`}>
        {t('repository.needs_triage')}
        {payload.needs_triage_count > payload.needs_triage_jobs.length ? (
          <span className="ml-2 text-xs font-normal text-gray-500 dark:text-gray-400">
            {t('repository.needs_triage_showing_limited', {
              shown: payload.needs_triage_jobs.length,
              total: payload.needs_triage_count
            })}
          </span>
        ) : null}
      </SectionHeading>
      <div>
        {payload.needs_triage_jobs.length > 0 ? (
          <DataTable.Root>
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>
                  {t('repository.col_job')}
                </DataTable.HeadCell>
                <DataTable.HeadCell className="hidden sm:table-cell">
                  {t('repository.col_created')}
                </DataTable.HeadCell>
                <DataTable.HeadCell align="right">
                  {t('repository.col_action')}
                </DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
              {payload.needs_triage_jobs.map((job) => (
                <DataTable.Row key={job.id}>
                  <DataTable.Cell>
                    <SourceLink job={job} prefix={prefix} />
                    <Link className="ml-1 text-gray-700 dark:text-gray-300 hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.issue_title || `JOB-${job.id}`}</Link>
                    {job.owner_user ? (
                      <div className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                        {t('repository.owner_prefix')} {job.owner_user.display_name || job.owner_user.email_address}
                      </div>
                    ) : null}
                  </DataTable.Cell>
                  <DataTable.Cell className="hidden text-gray-500 dark:text-gray-400 sm:table-cell"><RelativeTimestamp value={job.created_at} /></DataTable.Cell>
                  <DataTable.Cell align="right">
                    <button className={buttonClass("blue")} disabled={release.isPending} onClick={() => { onNotice(null); release.mutate(job.id) }} type="button">
                      {t('repository.release_for_triage')}
                    </button>
                  </DataTable.Cell>
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
        ) : (
          <Surface className="text-sm text-gray-600 dark:text-gray-400">
            {t('repository.no_triage_jobs')}
          </Surface>
        )}
      </div>
      {release.isError ? <PanelMessage tone="error">{errorMessage(release.error, t("repository.release_triage_failed"))}</PanelMessage> : null}
    </section>
  )
}

const RECENT_JOBS_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.repository_detail.jobs.visible_columns"

// State and Issue together are this table's row identity (status + what the
// job is about); the Issue cell's own inline link already opens the job, so
// there is no separate row-level affordance. Runs/Last activity are the only
// genuinely optional columns.
function buildRecentJobsColumns({ prefix, t }: { prefix: string; t: (key: string, options?: Record<string, unknown>) => string }): DataTableColumnDef<RepositoryDetailJob>[] {
  return [
    {
      key: "state",
      label: t('repository.col_state'),
      required: true,
      cellClassName: "align-top",
      renderCell: (job) => (
        <>
          <StateStatusPill state={job.state} />
          {job.priority !== "medium" ? <span className="ml-1"><TonePill tone="gray">{job.priority}</TonePill></span> : null}
        </>
      )
    },
    {
      key: "issue",
      label: t('repository.col_issue'),
      required: true,
      renderCell: (job) => (
        <>
          <SourceLink job={job} prefix={prefix} />
          <ProviderAvailabilityWarning availability={job.provider_availability} className="ml-1 inline-flex align-[-0.125em]" />
          {job.issue_title ? <Link className="ml-1 text-gray-700 dark:text-gray-300 hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.issue_title}</Link> : null}
          {job.pr_number && job.pr_url ? <a className="ml-1 text-xs text-indigo-700 underline hover:no-underline" href={job.pr_url} rel="noopener" target="_blank">{t("repository.pr_number", { number: job.pr_number })}</a> : null}
          {job.external_pr_number && job.external_pr_url ? <a className="ml-1 text-xs text-violet-700 underline hover:no-underline" href={job.external_pr_url} rel="noopener" target="_blank">{t("repository.pr_number", { number: job.external_pr_number })}</a> : null}
          <ProviderFailoverNotice failover={job.provider_failover} className="mt-1 flex w-fit" />
          {job.current_step_caption ? <div className="mt-0.5 text-xs italic text-gray-500 dark:text-gray-400">{job.current_step_caption}</div> : null}
          <RepositoryRetryState job={job} />
          <div className="mt-1 flex items-center gap-1.5 text-xs text-text-muted sm:hidden">
            <span>{t("repository.runs_count", { count: job.runs_count })}</span>
            <span>·</span>
            <span><RelativeTimestamp value={job.updated_at} /></span>
          </div>
        </>
      )
    },
    {
      key: "runs",
      label: t('repository.col_runs'),
      responsiveClassName: "hidden sm:table-cell",
      cellClassName: "text-text-secondary",
      renderCell: (job) => job.runs_count
    },
    {
      key: "last_activity",
      label: t('repository.col_last'),
      responsiveClassName: "hidden sm:table-cell",
      cellClassName: "text-text-muted",
      renderCell: (job) => <RelativeTimestamp value={job.updated_at} />
    }
  ]
}

function RecentJobs({ payload, prefix, setupStatus }: { payload: RepositoryDetailPayload; prefix: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  const { t } = useT("settings")
  const columns = buildRecentJobsColumns({ prefix, t })
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: RECENT_JOBS_VISIBLE_COLUMNS_STORAGE_KEY })
  const contentGutter = useRepositoryContentGutterClassName()

  if (payload.jobs.length === 0) {
    return (
      <section>
        <SectionHeading className={`mb-3 ${contentGutter}`}>
          {t('repository.recent_jobs')}
        </SectionHeading>
        <OnboardingEmptyState
          fallbackActionPath={payload.paths.new_job_path}
          fallbackActionText={t("repository.empty_jobs_action")}
          fallbackDescription={t("repository.empty_jobs_description", { label: payload.repository.trigger_label })}
          fallbackTitle={t("repository.empty_jobs_title")}
          prefix={prefix}
          setupStatus={setupStatus}
        />
      </section>
    )
  }

  return (
    <section>
      <div className={`mb-3 flex items-center justify-between gap-3 ${contentGutter}`}>
        <SectionHeading>
          {t('repository.recent_jobs')}
        </SectionHeading>
        <DataTableColumnMenu
          columns={columns}
          downLabel={t("repositories.column_down")}
          menuId="repository-detail-jobs-columns-menu"
          moveDownLabel={(title) => t("repositories.column_move_down", { title })}
          moveUpLabel={(title) => t("repositories.column_move_up", { title })}
          onChange={preferences.onChange}
          order={preferences.order}
          triggerAriaLabel={t("repositories.columns")}
          upLabel={t("repositories.column_up")}
          visibleLabel={t("repositories.visible_columns")}
        />
      </div>
      <DataTable.Root>
        <DataTable.Header>
          <DataTableColumnHeaderRow columns={columns} onReorder={preferences.onChange} order={preferences.order} />
        </DataTable.Header>
        <DataTable.Body>
          {payload.jobs.map((job) => (
            <DataTable.Row key={job.id}>
              <DataTableColumnCells columns={columns} order={preferences.order} row={job} />
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
      <Pagination payload={payload} prefix={prefix} />
    </section>
  )
}

function useRepositoryContentGutterClassName() {
  return usePageGutterRestoreClassName("padding")
}

function RepositoryRetryState({ job }: { job: RepositoryDetailJob }) {
  const { t } = useT("settings")
  const retry = job.retry_state
  if (!retry || retry.state_label === "No failure") return null

  const tone = retry.auto_retry_exhausted ? "border-danger-border bg-danger-surface text-danger-text" : retry.provider_circuit_open ? "border-warning-border bg-warning-surface text-warning-text" : "border-border bg-surface-subtle text-text-secondary"
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
  if (!job.source.path) return <span className="text-text-secondary">{job.source.label}</span>
  if (!job.source.external) {
    return (
      <Link className="text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(job.source.path, prefix)}>
        {job.source.label}
      </Link>
    )
  }

  return (
    <a className="text-brand underline hover:no-underline dark:text-brand-emphasis" href={job.source.path} rel="noopener" target="_blank">
      {job.source.label}
    </a>
  )
}

function InsightScheduleBadge({ config }: { config: InsightScheduleConfigRecord }) {
  if (config.enabled) {
    return (
      <TonePill tone="green">
        Auto: on (min {config.min_jobs_since_last_run} / max {config.max_jobs_since_last_run})
      </TonePill>
    )
  }
  return (
    <TonePill tone="gray">
      Auto: off
    </TonePill>
  )
}

function Pagination({ payload, prefix }: { payload: RepositoryDetailPayload; prefix: string }) {
  const { t } = useT("settings")
  const pagination = payload.pagination
  if (pagination.total_pages <= 1) return null

  return (
    <div className="mt-4 flex items-center justify-between text-sm text-text-secondary">
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
