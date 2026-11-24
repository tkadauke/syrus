import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link } from "react-router-dom"
import { postJson } from "../../../../../app/frontend/api/client"
import { buttonClasses } from "../../../../../app/frontend/components/Button"
import { CloseIcon } from "../../../../../app/frontend/components/CloseIcon"
import { Notice } from "../../../../../app/frontend/components/ui"
import { useT } from "../../../../../app/frontend/hooks/useT"
import { withRoutePrefix } from "../../../../../app/frontend/lib/routing"

export type DashboardHealthBlockedRepository = {
  id: number
  slug: string
  main_health: string
  ci_health: string
  grader_health: string
  landing_paused: boolean
  main_branch_repair_blocks_work: boolean
  repository_path: string
  repair_path: string
  main_branch_repair: DashboardMainBranchRepairStatus
}

export type DashboardRepairJob = {
  id: number
  slug: string
  state: string
  title: string
  job_path: string
}

export type DashboardMainBranchRepairStatus = {
  enabled: boolean
  failed_open_jobs_count: number
  max_open_failed_jobs: number
  blocked_reason: string | null
  can_request: boolean
  can_spawn: boolean
  blocking_job: DashboardRepairJob | null
  failed_jobs: DashboardRepairJob[]
}

const HEALTH_BANNER_DISMISSALS_KEY = "syrus.health_banner_dismissals"

function healthBannerEvidenceToken(repo: DashboardHealthBlockedRepository): string {
  return `${repo.ci_health}:${repo.grader_health}`
}

function readHealthBannerDismissals(): Record<string, string> {
  try {
    const raw = window.localStorage.getItem(HEALTH_BANNER_DISMISSALS_KEY)
    const value = raw ? JSON.parse(raw) : {}
    return typeof value === "object" && value !== null && !Array.isArray(value) ? value : {}
  } catch {
    return {}
  }
}

function writeHealthBannerDismissals(dismissals: Record<string, string>): void {
  try {
    window.localStorage.setItem(HEALTH_BANNER_DISMISSALS_KEY, JSON.stringify(dismissals))
  } catch {
    // localStorage can be unavailable in private or restricted browser contexts.
  }
}

function RepositoryHealthBanners({
  className = "",
  prefix,
  repositories
}: {
  className?: string
  prefix: string
  repositories: DashboardHealthBlockedRepository[]
}) {
  const { t } = useT("main_branch_health")
  const queryClient = useQueryClient()
  const [dismissals, setDismissals] = useState<Record<string, string>>(() => readHealthBannerDismissals())
  const requestRepair = useMutation({
    mutationFn: requestMainBranchRepair,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard", "chrome"] })
    }
  })
  const visible = repositories.filter((repo) => dismissals[repo.id] !== healthBannerEvidenceToken(repo))

  if (visible.length === 0) return null

  return (
    <div className={`${className} space-y-2`}>
      {visible.map((repo) => {
        const repair = repo.main_branch_repair
        const blockingJob = repair?.blocking_job
        const failedJobs = repair?.failed_jobs ?? []
        const isStartingRepair = requestRepair.isPending && requestRepair.variables === repo.repair_path
        const repairError =
          requestRepair.isError && requestRepair.variables === repo.repair_path
            ? requestRepair.error instanceof Error
              ? requestRepair.error.message
              : t("banner.broken_main_repair_start_failed")
            : null

        return (
          <Notice
            className="px-4 py-3"
            contentClassName="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
            key={repo.id}
            role="alert"
            tone="danger"
          >
            <div className="min-w-0">
              <span>
                <span className="font-mono font-medium">{repo.slug}</span>
                {" — "}
                {t(
                  repo.main_health === "inconclusive"
                    ? "banner.main_health_inconclusive_banner_not_held"
                    : repo.landing_paused && repo.main_branch_repair_blocks_work
                      ? "banner.broken_main_banner"
                      : "banner.broken_main_banner_not_held"
                )}
              </span>
              {repair ? (
                <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
                  {blockingJob ? (
                    <span>
                      {t(
                        repair.blocked_reason === "active"
                          ? "banner.broken_main_repair_active"
                          : repair.blocked_reason === "landing"
                            ? "banner.broken_main_repair_landing"
                            : "banner.broken_main_repair_waiting"
                      )}{" "}
                      <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(blockingJob.job_path, prefix)}>
                        {blockingJob.slug}
                      </Link>
                    </span>
                  ) : null}
                  {failedJobs.length > 0 ? (
                    <span>
                      {t("banner.broken_main_repair_failed_jobs")}{" "}
                      {failedJobs.map((job, index) => (
                        <span key={job.id}>
                          {index > 0 ? ", " : null}
                          <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(job.job_path, prefix)}>
                            {job.slug}
                          </Link>
                        </span>
                      ))}
                    </span>
                  ) : null}
                  {repair.blocked_reason === "waiting_for_health_signals" ? <span>{t("banner.broken_main_repair_waiting_for_signals")}</span> : null}
                  {repair.blocked_reason === "failed_open_cap" ? <span>{t("banner.broken_main_repair_cap")}</span> : null}
                  {repairError ? <span className="font-medium">{repairError}</span> : null}
                </div>
              ) : null}
            </div>
            <div className="flex shrink-0 items-center gap-2">
              {repair?.can_request ? (
                <button
                  className={buttonClasses("secondary", "sm", "disabled:cursor-not-allowed disabled:opacity-60")}
                  disabled={isStartingRepair}
                  onClick={() => requestRepair.mutate(repo.repair_path)}
                  type="button"
                >
                  {isStartingRepair ? t("banner.broken_main_repair_starting") : t("banner.broken_main_repair_start")}
                </button>
              ) : null}
              <Link className={buttonClasses("secondary", "sm")} to={withRoutePrefix(repo.repository_path, prefix)}>
                {t("banner.broken_main_view_details")}
              </Link>
              <button
                aria-label={t("banner.broken_main_dismiss")}
                className="text-danger hover:text-danger-text"
                onClick={() =>
                  setDismissals((prev) => {
                    const next = { ...prev, [repo.id]: healthBannerEvidenceToken(repo) }
                    writeHealthBannerDismissals(next)
                    return next
                  })
                }
                type="button"
              >
                <CloseIcon />
              </button>
            </div>
          </Notice>
        )
      })}
    </div>
  )
}

function requestMainBranchRepair(path: string) {
  return postJson<{ message?: string }>(path, {})
}

// Dashboard banner slot ("dashboard.banner"): the server ships the blocked
// repositories as panel props, so core never learns what main-branch health is.
export default function HealthBanners({
  className,
  prefix,
  repositories
}: {
  className?: string
  prefix?: string
  repositories?: DashboardHealthBlockedRepository[]
}) {
  return <RepositoryHealthBanners className={className} prefix={prefix ?? ""} repositories={repositories ?? []} />
}
