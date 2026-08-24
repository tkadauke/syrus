import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { useT } from "@app/hooks/useT"
import { useInfiniteQuery } from "@tanstack/react-query"
import { useEffect, useRef } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import {
  fetchGitHistory,
  type GitHistoryCommit,
  type GitHistoryExternalPrCommit,
  type GitHistoryExternalPushCommit,
  type GitHistoryOrigin,
  type GitHistorySyrusLandedCommit
} from "../api/gitHistory"

export function GitHistory() {
  const { t } = useT("git_history")
  const params = useParams()
  const location = useLocation()
  const repositoryId = params.repositoryId || ""
  const prefix = routePrefix(location.pathname)
  const sentinelRef = useRef<HTMLDivElement>(null)

  const history = useInfiniteQuery({
    queryKey: ["repositories", repositoryId, "git_history"],
    queryFn: ({ pageParam }: { pageParam: string | null }) => fetchGitHistory(repositoryId, pageParam),
    initialPageParam: null as string | null,
    getNextPageParam: (lastPage) => (lastPage.has_more ? lastPage.next_cursor : undefined),
    enabled: repositoryId.length > 0
  })

  const hasNextPage = history.hasNextPage
  const isFetchingNextPage = history.isFetchingNextPage
  const fetchNextPage = history.fetchNextPage

  useEffect(() => {
    const sentinel = sentinelRef.current
    if (!sentinel || !hasNextPage || isFetchingNextPage) return

    const observer = new IntersectionObserver((entries) => {
      if (entries[0]?.isIntersecting) void fetchNextPage()
    }, { rootMargin: "200px" })

    observer.observe(sentinel)
    return () => observer.disconnect()
  }, [hasNextPage, isFetchingNextPage, fetchNextPage])

  if (history.isPending) {
    return <main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("common:loading")}</main>
  }

  if (history.isError) {
    return (
      <main className="p-6" aria-label={t("aria_label")}>
        <p className="text-sm text-red-700 dark:text-red-300">{t("unable_to_load")}</p>
      </main>
    )
  }

  const pages = history.data?.pages ?? []
  const available = pages[0]?.available ?? false
  const commits = pages.flatMap((page) => page.commits)

  return (
    <main aria-label={t("aria_label")} className="mx-auto max-w-4xl space-y-4 p-6">
      <header>
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("eyebrow")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("title")}</h1>
      </header>

      {!available ? (
        <EmptyPanel label={t("unavailable")} />
      ) : commits.length === 0 ? (
        <EmptyPanel label={t("empty")} />
      ) : (
        <>
          <ol className="space-y-2">
            {commits.map((commit) => (
              <CommitRow commit={commit} key={commit.sha} prefix={prefix} />
            ))}
          </ol>

          {hasNextPage ? (
            <div className="flex justify-center py-2" ref={sentinelRef}>
              <button
                className="rounded border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900"
                disabled={isFetchingNextPage}
                onClick={() => void fetchNextPage()}
                type="button"
              >
                {isFetchingNextPage ? t("loading_more") : t("load_more")}
              </button>
            </div>
          ) : null}
        </>
      )}
    </main>
  )
}

function EmptyPanel({ label }: { label: string }) {
  return (
    <p className="rounded border border-gray-200 bg-white p-4 text-sm text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">
      {label}
    </p>
  )
}

function CommitRow({ commit, prefix }: { commit: GitHistoryCommit; prefix: string }) {
  return (
    <li className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900" data-testid="git-history-commit">
      <div className="flex flex-wrap items-center gap-2">
        <ClassificationBadge classification={commit.classification} />
        <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{commit.short_sha}</span>
        <RelativeTimestamp className="text-xs text-gray-500 dark:text-gray-400" value={commit.authored_at} />
      </div>
      <p className="mt-1 truncate text-sm text-gray-900 dark:text-gray-100" title={commit.subject}>{commit.subject}</p>
      <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-gray-600 dark:text-gray-400">
        {commit.classification === "syrus_landed" ? <SyrusLandedMeta commit={commit} prefix={prefix} /> : null}
        {commit.classification === "external_pr" ? <ExternalPrMeta commit={commit} /> : null}
        {commit.classification === "external_push" ? <ExternalPushMeta commit={commit} /> : null}
      </div>
    </li>
  )
}

function ClassificationBadge({ classification }: { classification: GitHistoryCommit["classification"] }) {
  const { t } = useT("git_history")
  const classes = {
    syrus_landed: "bg-terracotta-50 text-terracotta-700 ring-terracotta-200 dark:bg-terracotta-950/50 dark:text-terracotta-200 dark:ring-terracotta-800",
    external_pr: "bg-blue-50 text-blue-700 ring-blue-200 dark:bg-blue-950/50 dark:text-blue-200 dark:ring-blue-800",
    external_push: "bg-gray-100 text-gray-700 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700"
  }[classification]

  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${classes}`}>
      {t(`classification_${classification}`)}
    </span>
  )
}

function SyrusLandedMeta({ commit, prefix }: { commit: GitHistorySyrusLandedCommit; prefix: string }) {
  const { t } = useT("git_history")

  return (
    <>
      <Link className="font-medium text-blue-700 underline hover:no-underline dark:text-blue-300" to={withRoutePrefix(`/jobs/${commit.job.id}`, prefix)}>
        {t("job_link", { id: commit.job.id })}
      </Link>
      {commit.epic ? (
        <Link className="text-blue-700 underline hover:no-underline dark:text-blue-300" to={withRoutePrefix(`/epics/${commit.epic.id}`, prefix)}>
          {t("epic_link", { id: commit.epic.id })}
        </Link>
      ) : null}
      {commit.user ? <span>{t("by_user", { name: commit.user.display_name })}</span> : null}
      <OriginMeta origin={commit.origin} prefix={prefix} />
    </>
  )
}

function OriginMeta({ origin, prefix }: { origin: GitHistoryOrigin; prefix: string }) {
  const { t } = useT("git_history")

  if (origin.type === "github_issue" && origin.issue_number != null) {
    return origin.issue_url ? (
      <a className="underline hover:no-underline" href={origin.issue_url} rel="noopener noreferrer" target="_blank">
        {t("issue_number", { number: origin.issue_number })}
      </a>
    ) : (
      <span>{t("issue_number", { number: origin.issue_number })}</span>
    )
  }

  if (origin.type === "cron") {
    return (
      <Link className="underline hover:no-underline" to={withRoutePrefix(`/scheduled_tasks/${origin.scheduled_task.id}`, prefix)}>
        {t("cron_label", { name: origin.scheduled_task.name })}
      </Link>
    )
  }

  if (origin.type === "chat" && origin.chat_session_id != null) {
    return (
      <Link className="underline hover:no-underline" to={withRoutePrefix(`/chats/${origin.chat_session_id}`, prefix)}>
        {t("chat_link")}
      </Link>
    )
  }

  return null
}

function ExternalPrMeta({ commit }: { commit: GitHistoryExternalPrCommit }) {
  const { t } = useT("git_history")

  return (
    <>
      {commit.pr_number != null ? (
        commit.pr_url ? (
          <a className="font-medium underline hover:no-underline" href={commit.pr_url} rel="noopener noreferrer" target="_blank">
            {t("pr_number", { number: commit.pr_number })}
          </a>
        ) : (
          <span className="font-medium">{t("pr_number", { number: commit.pr_number })}</span>
        )
      ) : null}
      {commit.github_author ? <span>{t("by_user", { name: commit.github_author })}</span> : null}
    </>
  )
}

function ExternalPushMeta({ commit }: { commit: GitHistoryExternalPushCommit }) {
  const { t } = useT("git_history")
  const name = commit.author.name || commit.author.email

  return name ? <span>{t("by_user", { name })}</span> : null
}

export default GitHistory
