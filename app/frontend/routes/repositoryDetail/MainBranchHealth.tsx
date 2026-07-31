import { appendSearch, buttonClass, PanelMessage, StatusPill, type RepositoryDetailQueryKey } from "./shared"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { withRoutePrefix } from "../../lib/routing"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { resumeRepositoryLanding, runMainBranchGraders, repairMainBranch, checkCiNow, type RepositoryDetailPayload, type RepositoryHealthCheckRecord, type RepositoryHealthHistory } from "../../api/repositories"
import { errorMessage } from "../../lib/errorMessage"
import { useConfirm } from "../../hooks/useConfirm"


// Repository main-branch health section extracted from RepositoryDetail.tsx:
// the health section (MainBranchHealthSection), health badge, failing-checks
// list, health-history table/rows, and the healthTone helper. Entry point
// rendered on the overview tab. Depends only on leaf/shared modules.

function healthTone(health: string): HealthTone {
  if (health === "healthy") return "green"
  if (health === "broken") return "red"
  if (health === "inconclusive") return "amber"
  return "gray"
}

type HealthTone = "green" | "red" | "gray" | "amber"

export function MainBranchHealthSection({ history, payload, prefix, queryKey, onNotice }: { history: RepositoryHealthHistory; payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const repository = payload.repository
  const shaUrl = history.last_health_checked_sha
    ? `https://github.com/${repository.slug}/commit/${history.last_health_checked_sha}`
    : null
  const search = queryKey[3]
  const graders = useMutation({
    mutationFn: () => runMainBranchGraders(appendSearch(payload.paths.app_run_main_branch_graders_repository_path, search), payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const ciCheck = useMutation({
    mutationFn: () => checkCiNow(appendSearch(payload.paths.app_check_ci_now_repository_path, search), payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const repair = useMutation({
    mutationFn: () => repairMainBranch(appendSearch(payload.paths.app_repair_main_branch_repository_path, search), payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const resumeWork = useMutation({
    mutationFn: () => resumeRepositoryLanding(payload.paths.app_resume_landing_repository_path, payload.pagination.page),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const canResume = repository.main_branch_health_enabled && repository.landing_paused && repository.main_health === "broken"

  async function confirmResume() {
    if (!await confirm({ message: t("repository.resume_landing_confirm") })) return
    onNotice(null)
    resumeWork.mutate()
  }

  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
        {t("repository.main_branch_health")}
      </h2>
      <div className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <div className="flex flex-wrap items-center gap-4">
          <HealthBadge label={t("repository.health_ci")} health={history.ci_health} />
          <HealthBadge label={t("repository.health_graders")} health={history.grader_health} />
          {shaUrl && history.last_health_checked_sha ? (
            <div className="text-xs text-gray-500 dark:text-gray-400 self-center">
              {t("repository.health_checked_sha")}{" "}
              <a className="font-mono hover:underline text-blue-600 dark:text-blue-400" href={shaUrl} rel="noopener" target="_blank">
                {history.last_health_checked_sha.slice(0, 7)}
              </a>
            </div>
          ) : null}
          <button
            className={buttonClass("gray")}
            disabled={graders.isPending}
            onClick={() => { onNotice(null); graders.mutate() }}
            type="button"
          >
            {t("repository.run_graders_now")}
          </button>
          {history.ci_health !== "not_configured" ? (
            <button
              className={buttonClass("gray")}
              disabled={ciCheck.isPending}
              onClick={() => { onNotice(null); ciCheck.mutate() }}
              type="button"
            >
              {t("repository.check_ci_now")}
            </button>
          ) : null}
          {history.main_branch_repair.can_request ? (
            <button
              className={buttonClass("gray")}
              disabled={repair.isPending}
              onClick={() => { onNotice(null); repair.mutate() }}
              type="button"
            >
              {repair.isPending ? t("repository.health_repair_starting") : t("repository.health_repair_start")}
            </button>
          ) : null}
        </div>
        <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
          {repository.main_branch_health_enabled ? null : <span>{t("repository.health_enforcement_disabled")}</span>}
          <span>{repository.main_branch_repair_enabled ? t("repository.health_auto_repair_enabled") : t("repository.health_auto_repair_disabled")}</span>
          {repository.main_branch_repair_auto_approve ? <span>{t("repository.health_auto_repair_approval_enabled")}</span> : null}
        </div>
        {history.main_branch_repair.blocked_reason === "failed_open_cap" ? (
          <div className="space-y-2 rounded border border-amber-200 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/40 p-3 text-sm text-amber-900 dark:text-amber-100">
            {t("repository.health_repair_failed_cap", {
              count: history.main_branch_repair.failed_open_jobs_count,
              max: history.main_branch_repair.max_open_failed_jobs
            })}
            {history.main_branch_repair.failed_jobs.length > 0 ? (
              <div className="flex flex-wrap gap-x-2 gap-y-1">
                <span>{t("repository.health_repair_failed_jobs")}</span>
                {history.main_branch_repair.failed_jobs.map((job) => (
                  <a className="font-medium text-blue-600 dark:text-blue-400 hover:underline" href={job.job_path} key={job.id}>
                    {job.slug}
                  </a>
                ))}
              </div>
            ) : null}
          </div>
        ) : history.main_branch_repair.blocking_job ? (
          <div className="rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 text-sm text-gray-600 dark:text-gray-300">
            {t(
              history.main_branch_repair.blocked_reason === "active" ? "repository.health_repair_active" : history.main_branch_repair.blocked_reason === "landing" ? "repository.health_repair_landing" : "repository.health_repair_waiting",
              { slug: history.main_branch_repair.blocking_job.slug }
            )}{" "}
            <a className="font-medium text-blue-600 dark:text-blue-400 hover:underline" href={history.main_branch_repair.blocking_job.job_path}>
              {history.main_branch_repair.blocking_job.title}
            </a>
          </div>
        ) : history.main_branch_repair.blocked_reason === "waiting_for_health_signals" ? (
          <div className="rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 text-sm text-gray-600 dark:text-gray-300">
            {t("repository.health_repair_waiting_for_signals")}
          </div>
        ) : null}
        {canResume ? (
          <div className="flex flex-col gap-3 rounded border border-amber-200 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/40 p-3 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-sm text-amber-900 dark:text-amber-100">
              {t("repository.resume_landing_warning")}
            </p>
            <button
              className="rounded border border-amber-300 dark:border-amber-600 bg-white dark:bg-amber-950 px-3 py-1.5 text-sm font-medium text-amber-900 dark:text-amber-100 hover:bg-amber-100 dark:hover:bg-amber-900 disabled:cursor-not-allowed disabled:opacity-50"
              disabled={resumeWork.isPending}
              onClick={confirmResume}
              type="button"
            >
              {t("repository.resume_landing_anyway")}
            </button>
          </div>
        ) : null}
        {resumeWork.isError ? (
          <PanelMessage tone="error">{errorMessage(resumeWork.error, "Unable to resume work.")}</PanelMessage>
        ) : null}
        {history.ci_health === "broken" && history.records.length > 0 ? (
          <FailingChecks checks={history.records[0].ci_failed_checks} />
        ) : null}
        <HealthHistoryTable records={history.records} prefix={prefix} t={t} />
        {graders.isError ? <PanelMessage tone="error">{errorMessage(graders.error, "Run graders command failed.")}</PanelMessage> : null}
        {ciCheck.isError ? <PanelMessage tone="error">{errorMessage(ciCheck.error, "Check CI command failed.")}</PanelMessage> : null}
        {repair.isError ? <PanelMessage tone="error">{errorMessage(repair.error, "Repair command failed.")}</PanelMessage> : null}
      </div>
      {dialog}
    </section>
  )
}

function HealthBadge({ label, health }: { label: string; health: string }) {
  const { t } = useT("settings")
  const tone = healthTone(health)
  return (
    <div className="flex items-center gap-2">
      <span className="text-sm font-medium text-gray-700 dark:text-gray-300">{label}</span>
      <StatusPill tone={tone}>{healthLabel(health, t)}</StatusPill>
    </div>
  )
}

function healthLabel(health: string, t: (key: string) => string) {
  if (health === "healthy") return t("repository.health_healthy")
  if (health === "broken") return t("repository.health_broken")
  if (health === "inconclusive") return t("repository.health_inconclusive")
  if (health === "not_configured") return t("repository.health_not_configured")
  return t("repository.health_unknown")
}

function FailingChecks({ checks }: { checks: Array<{ name: string; url: string }> }) {
  if (checks.length === 0) return null
  return (
    <ul className="space-y-1 text-sm">
      {checks.map((check) => (
        <li key={check.name} className="flex items-center gap-1.5 text-red-700 dark:text-red-300">
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-red-500 shrink-0" />
          {check.url ? (
            <a className="hover:underline" href={check.url} rel="noopener" target="_blank">{check.name}</a>
          ) : (
            <span>{check.name}</span>
          )}
        </li>
      ))}
    </ul>
  )
}

function HealthHistoryTable({ records, prefix, t }: { records: RepositoryHealthCheckRecord[]; prefix: string; t: (key: string) => string }) {
  if (records.length === 0) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">{t("repository.health_no_history")}</p>
  }

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.health_history_heading")}</h3>
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-3 py-2">{t("repository.health_col_time")}</th>
              <th className="px-3 py-2">{t("repository.health_col_sha")}</th>
              <th className="px-3 py-2">{t("repository.health_col_ci")}</th>
              <th className="px-3 py-2">{t("repository.health_col_graders")}</th>
              <th className="px-3 py-2">{t("repository.health_col_failures")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {records.map((record) => (
              <HealthHistoryRow key={record.id} prefix={prefix} record={record} t={t} />
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function HealthHistoryRow({ prefix, record, t }: { prefix: string; record: RepositoryHealthCheckRecord; t: (key: string) => string }) {
  const failureNames = [
    ...record.ci_failed_checks.map((c) => c.name),
    ...record.grader_failed_names
  ]
  const graderPill = <StatusPill tone={healthTone(record.grader_health)}>{healthLabel(record.grader_health, t)}</StatusPill>
  return (
    <tr>
      <td className="px-3 py-2 text-gray-500 dark:text-gray-400 whitespace-nowrap"><RelativeTimestamp value={record.checked_at} /></td>
      <td className="px-3 py-2">
        <a className="font-mono text-xs text-blue-600 dark:text-blue-400 hover:underline" href={record.sha_url} rel="noopener" target="_blank">
          {record.sha}
        </a>
      </td>
      <td className="px-3 py-2"><StatusPill tone={healthTone(record.ci_health)}>{healthLabel(record.ci_health, t)}</StatusPill></td>
      <td className="px-3 py-2">
        <div className="flex flex-wrap items-center gap-1.5">
          {record.workflow_path ? (
            <Link to={withRoutePrefix(record.workflow_path, prefix)}>{graderPill}</Link>
          ) : graderPill}
          <HealthSourceBadge source={record.source} t={t} />
        </div>
      </td>
      <td className="px-3 py-2 text-xs text-gray-600 dark:text-gray-400">
        {failureNames.length > 0 ? failureNames.join(", ") : null}
      </td>
    </tr>
  )
}

function HealthSourceBadge({ source, t }: { source: string; t: (key: string) => string }) {
  const isQuorum = source === "concern_quorum"
  const label = healthSourceLabel(source, t)
  return (
    <span
      className={[
        "inline-flex items-center rounded border px-1.5 py-0.5 text-[11px] font-medium uppercase leading-none",
        isQuorum
          ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
          : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"
      ].join(" ")}
      data-source={source}
    >
      {label}
    </span>
  )
}

function healthSourceLabel(source: string, t: (key: string) => string) {
  const key = `repository.health_source_${source}`
  const label = t(key)
  return label === key ? source : label
}
