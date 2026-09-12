import { type RepositoryDetailQueryKey, appendSearch, buttonClass, PanelMessage, StatusPill } from "./repositoryDetail/shared"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading, SectionHeading } from "../components/Heading"
import { DataTable, DescriptionList } from "../components/ui"
import { ChevronIcon } from "../components/ChevronIcon"
import { DismissButton } from "../components/DismissButton"
import { PluginUiSlot } from "../pluginUiSlots"
import { formatRelativeDate } from "../lib/relativeTime"
import { MainBranchHealthSection } from "./repositoryDetail/MainBranchHealth"
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
import { StatusPill as StateStatusPill, TonePill } from "../components/StatusPill"
import { CoverageSparkline } from "../components/CoverageSparkline"
import { PreviewPanel } from "../components/PreviewPanel"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { archiveRepositoryFromPath, fetchRepositoryDetail, pollRepositoryDetail, releaseNeedsTriageRepositoryJob, retryFailedRepositoryJobs, runInsightAnalysis, runRepositoryRecommendation, type InsightScheduleConfigRecord, type RepositoryDetailJob, type RepositoryDetailPayload, type RepositoryFeatureRecommendation } from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"
import { useConfirm } from "../hooks/useConfirm"

export function RepositoryDetailRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const tab = "overview" as const
  const search = pageSearch(location.search)
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

function repositoryDetailQueryKey(id: string | number, search: string): RepositoryDetailQueryKey {
  return ["repositories", String(id), "detail", search] as const
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
              <Actions payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
              <NeedsTriageJobs payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
              {payload.health_history ? <MainBranchHealthSection history={payload.health_history} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} /> : null}
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
  const nonzeroCounts = [
    { label: t("repository.count_running"), value: payload.counts.running, tone: "blue" as const },
    { label: t("repository.count_queued"), value: payload.counts.queued, tone: "gray" as const },
    { label: t("repository.count_failed_7d"), value: payload.counts.failed_7d, tone: "red" as const }
  ].filter((count) => count.value > 0)

  return (
    <div className="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
      <StatusPill tone={repository.polling_enabled ? "green" : "gray"}>{repository.polling_enabled ? t("repository.polling_enabled") : t("repository.polling_paused")}</StatusPill>
      <span>{payload.credential_status.label}</span>
      <span className="text-gray-300 dark:text-gray-600">·</span>
      <span>
        {t('repository.agent_prefix')} {repository.agent_provider_label || t("repository.user_default_agent", { provider: repository.effective_agent_provider_label })}
      </span>
      {nonzeroCounts.map((count) => (
        <StatusPill key={count.label} tone={count.tone}>{count.value} {count.label}</StatusPill>
      ))}
    </div>
  )
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
    onSuccess: (updated) => {
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
    blue: "border-blue-200 bg-blue-50 text-blue-900 dark:border-blue-800 dark:bg-blue-950/40 dark:text-blue-100",
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
    [t("repository.syrus_yml_review_plan"), summary.review_plan_enabled ? t("repository.syrus_yml_enabled") : t("repository.syrus_yml_disabled")],
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
    </section>
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
      onNotice((updated as { message?: string | null }).message || t("repository.insight_started"))
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
          <button className={buttonClass("amber")} disabled={disabled || retry.provider_circuit.open} onClick={() => { onNotice(null); retryFailed.mutate() }} type="button">{t("repository.retry_failed_with", { count: retry.count, provider: retry.agent_provider_label })}</button>
        ) : null}
        {payload.agent_insights_enabled && payload.paths.app_run_insight_analysis_repository_path ? (
          payload.active_insight_job ? (
            <Link className={buttonClass("gray")} to={withRoutePrefix(payload.active_insight_job.job_path, prefix)}>
              {t("repository.insight_running")}
            </Link>
          ) : (
            <button
              className={buttonClass("gray")}
              disabled={disabled || runInsight.isPending}
              onClick={() => { onNotice(null); runInsight.mutate() }}
              type="button"
            >
              {runInsight.isPending ? t("repository.insight_starting") : t("repository.run_insight")}
            </button>
          )
        ) : null}
        {payload.agent_insights_enabled && payload.insight_schedule_config ? (
          <InsightScheduleBadge config={payload.insight_schedule_config} />
        ) : null}
        {payload.agent_insights_enabled && payload.paths.repository_insights_path ? (
          <Link className={buttonClass("gray")} to={withRoutePrefix(payload.paths.repository_insights_path, prefix)}>
            {t("repository.view_insights")}
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
              <Link className="block rounded px-3 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800" onClick={() => setMoreOpen(false)} to={withRoutePrefix(payload.paths.new_repository_skill_job_path, prefix)}>{t('repository.launch_skill')}</Link>
              <Link className="block rounded px-3 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800" onClick={() => setMoreOpen(false)} to={withRoutePrefix(payload.paths.edit_repository_path, prefix)}>{t("repository.edit")}</Link>
              <button className="block w-full rounded px-3 py-2 text-left text-amber-800 dark:text-amber-200 hover:bg-amber-50 dark:hover:bg-amber-950/50 disabled:text-gray-300 dark:disabled:text-gray-600" disabled={disabled} onClick={archiveRepository} type="button">{t('repository.archive')}</button>
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
      {archive.isError ? <PanelMessage tone="error">{errorMessage(archive.error, t("repository.archive_failed"))}</PanelMessage> : null}
      {runInsight.isError ? <PanelMessage tone="error">{errorMessage(runInsight.error, t("repository.insight_start_failed"))}</PanelMessage> : null}
      {dialog}
    </>
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
      <SectionHeading className="mb-3">
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
          <p className="rounded border border-gray-200 bg-white p-4 text-sm text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
            {t('repository.no_triage_jobs')}
          </p>
        )}
      </div>
      {release.isError ? <PanelMessage tone="error">{errorMessage(release.error, t("repository.release_triage_failed"))}</PanelMessage> : null}
    </section>
  )
}

function RecentJobs({ payload, prefix, setupStatus }: { payload: RepositoryDetailPayload; prefix: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  const { t } = useT("settings")
  if (payload.jobs.length === 0) {
    if (payload.simple_mode) return null

    return (
      <section>
        <SectionHeading className="mb-3">
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
      <SectionHeading className="mb-3">
        {t('repository.recent_jobs')}
      </SectionHeading>
      <DataTable.Root>
        <DataTable.Header>
          <DataTable.Row>
              <DataTable.HeadCell>
                {t('repository.col_state')}
              </DataTable.HeadCell>
              <DataTable.HeadCell>
                {t('repository.col_issue')}
              </DataTable.HeadCell>
              <DataTable.HeadCell className="hidden sm:table-cell">
                {t('repository.col_runs')}
              </DataTable.HeadCell>
              <DataTable.HeadCell className="hidden sm:table-cell">
                {t('repository.col_last')}
              </DataTable.HeadCell>
              <DataTable.HeadCell className="hidden sm:table-cell"><span className="sr-only">{t("repository.col_actions")}</span></DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {payload.jobs.map((job) => <JobRow job={job} key={job.id} prefix={prefix} />)}
          </DataTable.Body>
        </DataTable.Root>
      <Pagination payload={payload} prefix={prefix} />
    </section>
  )
}

function JobRow({ job, prefix }: { job: RepositoryDetailJob; prefix: string }) {
  const { t } = useT("settings")
  return (
    <DataTable.Row>
      <DataTable.Cell className="align-top">
        <StateStatusPill state={job.state} />
        {job.priority !== "medium" ? <span className="ml-1"><TonePill tone="gray">{job.priority}</TonePill></span> : null}
      </DataTable.Cell>
      <DataTable.Cell>
        <SourceLink job={job} prefix={prefix} />
        <ProviderAvailabilityWarning availability={job.provider_availability} className="ml-1 inline-flex align-[-0.125em]" />
        {job.issue_title ? <Link className="ml-1 text-gray-700 dark:text-gray-300 hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.issue_title}</Link> : null}
        {job.pr_number && job.pr_url ? <a className="ml-1 text-xs text-indigo-700 underline hover:no-underline" href={job.pr_url} rel="noopener" target="_blank">{t("repository.pr_number", { number: job.pr_number })}</a> : null}
        {job.external_pr_number && job.external_pr_url ? <a className="ml-1 text-xs text-violet-700 underline hover:no-underline" href={job.external_pr_url} rel="noopener" target="_blank">{t("repository.pr_number", { number: job.external_pr_number })}</a> : null}
        <ProviderFailoverNotice failover={job.provider_failover} className="mt-1 flex w-fit" />
        {job.current_step_caption ? <div className="mt-0.5 text-xs italic text-gray-500 dark:text-gray-400">{job.current_step_caption}</div> : null}
        <RepositoryRetryState job={job} />
        <div className="mt-1 flex items-center gap-1.5 text-xs text-gray-400 dark:text-gray-500 sm:hidden">
          <span>{t("repository.runs_count", { count: job.runs_count })}</span>
          <span>·</span>
          <span><RelativeTimestamp value={job.updated_at} /></span>
        </div>
      </DataTable.Cell>
      <DataTable.Cell className="hidden text-gray-600 dark:text-gray-400 sm:table-cell">{job.runs_count}</DataTable.Cell>
      <DataTable.Cell className="hidden text-gray-500 dark:text-gray-400 sm:table-cell"><RelativeTimestamp value={job.updated_at} /></DataTable.Cell>
      <DataTable.Cell align="right" className="hidden sm:table-cell">
        <Link className="text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(job.job_path, prefix)}>{t('repository.view')}</Link>
      </DataTable.Cell>
    </DataTable.Row>
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
