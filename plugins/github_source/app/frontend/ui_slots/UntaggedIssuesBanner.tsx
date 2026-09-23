import { useState } from "react"
import { Link } from "react-router-dom"
import { CloseIcon } from "@app/components/CloseIcon"
import { Notice } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { withRoutePrefix } from "@app/routes/dashboard/helpers"

type UntaggedIssueRepository = {
  id: number
  slug: string
  count: number
  issues_path: string
}

type UntaggedIssues = {
  total: number
  repositories: UntaggedIssueRepository[]
}

const UNTAGGED_ISSUES_DISMISSAL_KEY = "syrus.github_source.untagged_issues_banner_dismissed"

function evidenceToken(untaggedIssues: UntaggedIssues): string {
  return `${untaggedIssues.total}:${untaggedIssues.repositories.map((repo) => `${repo.id}:${repo.count}`).join(",")}`
}

function readDismissal(): string | null {
  try {
    return window.sessionStorage.getItem(UNTAGGED_ISSUES_DISMISSAL_KEY)
  } catch {
    return null
  }
}

function writeDismissal(token: string): void {
  try {
    window.sessionStorage.setItem(UNTAGGED_ISSUES_DISMISSAL_KEY, token)
  } catch {
    // sessionStorage can be unavailable in private or restricted browser contexts.
  }
}

export default function UntaggedIssuesBanner({ className = "", prefix = "", untagged_issues }: { className?: string; prefix?: string; untagged_issues?: UntaggedIssues }) {
  const { t } = useT("github_source")
  const [dismissedToken, setDismissedToken] = useState<string | null>(() => readDismissal())

  if (!untagged_issues || untagged_issues.total === 0 || untagged_issues.repositories.length === 0) return null

  const token = evidenceToken(untagged_issues)
  if (dismissedToken === token) return null

  return (
    <Notice className={className} contentClassName="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between" role="status" tone="warning">
      <div className="min-w-0">
        <span>
          {t("dashboard.untagged_issues_summary", { count: untagged_issues.total })}{" "}
          {t("dashboard.untagged_issues_repo_count", { count: untagged_issues.repositories.length })}
        </span>
        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
          {untagged_issues.repositories.map((repo, index) => (
            <span key={repo.id}>
              {index > 0 ? ", " : null}
              <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(repo.issues_path, prefix)}>
                {repo.slug} ({repo.count})
              </Link>
            </span>
          ))}
        </div>
      </div>
      <button
        aria-label={t("dashboard.untagged_issues_dismiss")}
        className="shrink-0 text-warning hover:text-warning-text"
        onClick={() => {
          setDismissedToken(token)
          writeDismissal(token)
        }}
        type="button"
      >
        <CloseIcon />
      </button>
    </Notice>
  )
}
