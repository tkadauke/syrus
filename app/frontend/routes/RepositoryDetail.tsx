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
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { StatusPill as StateStatusPill, TonePill } from "../components/StatusPill"
import { CoverageSparkline } from "../components/CoverageSparkline"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { archiveRepositoryFromPath, fetchRepositoryDetail, fetchRepositoryIssues, pollRepositoryDetail, releaseNeedsTriageRepositoryJob, retryFailedRepositoryJobs, type RepositoryDetailJob, type RepositoryDetailPayload } from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"

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
          <RecentJobs payload={payload} prefix={prefix} setupStatus={setupStatus} />
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
  const disabled = poll.isPending || retryFailed.isPending || archive.isPending

  function archiveRepository() {
    onNotice(null)
    setMoreOpen(false)
    if (window.confirm(`Archive ${payload.repository.slug}? Polling stops; existing jobs are unaffected.`)) {
      archive.mutate()
    }
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <Link className={buttonClass("green")} to={withRoutePrefix(payload.paths.new_job_path, prefix)}>{t('repository.new_job')}</Link>
        <button className={buttonClass("blue")} disabled={disabled} onClick={() => { onNotice(null); poll.mutate() }} type="button">{t('repository.poll_now')}</button>
        {retry.count > 0 ? (
          <button className={buttonClass("amber")} disabled={disabled || retry.provider_circuit.open} onClick={() => { onNotice(null); retryFailed.mutate() }} type="button">Retry {retry.count} failed with {retry.agent_provider_label}</button>
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

