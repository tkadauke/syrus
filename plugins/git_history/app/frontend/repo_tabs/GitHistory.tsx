import { useInfiniteQuery } from "@tanstack/react-query"
import { Link, useParams } from "react-router-dom"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { TonePill } from "@app/components/StatusPill"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { fetchGitHistory, type GitHistoryCommit, type GitHistoryOrigin } from "../api/gitHistory"

export function GitHistory() {
  const { t } = useT("git_history")
  const { repositoryId } = useParams<{ repositoryId: string }>()
  usePageTitle(t("title"))

  const history = useInfiniteQuery({
    queryKey: ["repositories", repositoryId, "git_history"],
    queryFn: ({ pageParam }) => fetchGitHistory(repositoryId as string, pageParam),
    initialPageParam: null as string | null,
    getNextPageParam: (lastPage) => (lastPage.has_more ? lastPage.next_cursor : undefined),
    enabled: Boolean(repositoryId)
  })

  if (history.isPending) {
    return <main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("loading")}</main>
  }

  if (history.isError) {
    return (
      <main aria-label={t("aria_label")} className="p-6">
        <p className="text-sm text-red-700 dark:text-red-300">{t("error")}</p>
      </main>
    )
  }

  const pages = history.data.pages
  const available = pages[0]?.available ?? false
  const commits = pages.flatMap((page) => page.commits)

  return (
    <main aria-label={t("aria_label")} className="mx-auto max-w-5xl space-y-5 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase tracking-wide text-terracotta-600 dark:text-terracotta-400">{t("eyebrow")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("title")}</h1>
      </header>

      {!available ? (
        <EmptyPanel label={t("unavailable")} />
      ) : commits.length === 0 ? (
        <EmptyPanel label={t("empty")} />
      ) : (
        <>
          <ul className="divide-y divide-gray-200 rounded border border-gray-200 bg-white dark:divide-gray-800 dark:border-gray-700 dark:bg-gray-900">
            {commits.map((commit) => <CommitRow commit={commit} key={commit.sha} />)}
          </ul>

          {history.hasNextPage ? (
            <div className="flex justify-center">
              <button
                className="rounded border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900"
                disabled={history.isFetchingNextPage}
                onClick={() => void history.fetchNextPage()}
                type="button"
              >
                {history.isFetchingNextPage ? t("loading_more") : t("load_more")}
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

function CommitRow({ commit }: { commit: GitHistoryCommit }) {
  return (
    <li className="flex flex-col gap-2 p-4 sm:flex-row sm:items-start sm:justify-between">
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <ClassificationPill commit={commit} />
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{commit.subject}</span>
        </div>
        <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <span className="font-mono">{commit.short_sha}</span>
          <RelativeTimestamp value={commit.authored_at} />
          <CommitAttribution commit={commit} />
        </div>
      </div>
    </li>
  )
}

function ClassificationPill({ commit }: { commit: GitHistoryCommit }) {
  const { t } = useT("git_history")

  if (commit.classification === "syrus_landed") return <TonePill tone="green">{t("classification.syrus_landed")}</TonePill>
  if (commit.classification === "external_pr") return <TonePill tone="blue">{t("classification.external_pr")}</TonePill>
  return <TonePill tone="gray">{t("classification.external_push")}</TonePill>
}

function CommitAttribution({ commit }: { commit: GitHistoryCommit }) {
  const { t } = useT("git_history")

  if (commit.classification === "syrus_landed") {
    return (
      <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
        {commit.job ? (
          <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/jobs/${commit.job.id}`}>{commit.job.slug}</Link>
        ) : null}
        {commit.epic ? (
          <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/epics/${commit.epic.id}`}>{commit.epic.slug}</Link>
        ) : null}
        {commit.user ? <span>{t("attribution.by", { name: commit.user.display_name })}</span> : null}
        <OriginLink origin={commit.origin} />
      </span>
    )
  }

  if (commit.classification === "external_pr") {
    return (
      <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
        {commit.pr_url ? (
          <a className="text-blue-600 hover:underline dark:text-blue-400" href={commit.pr_url} rel="noopener noreferrer" target="_blank">
            {t("attribution.pr", { number: commit.pr_number })}
          </a>
        ) : (
          <span>{t("attribution.pr", { number: commit.pr_number })}</span>
        )}
        {commit.github_author ? <span>{t("attribution.opened_by", { name: commit.github_author })}</span> : null}
      </span>
    )
  }

  return <span>{t("attribution.pushed_by", { name: commit.author?.name || t("attribution.unknown_author") })}</span>
}

function OriginLink({ origin }: { origin: GitHistoryOrigin | undefined }) {
  const { t } = useT("git_history")

  if (!origin) return null

  if (origin.type === "chat") {
    if (!origin.chat_session_id) return <span>{t("origin.chat")}</span>
    return (
      <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/chats/${origin.chat_session_id}`}>
        {origin.chat_title || t("origin.chat")}
      </Link>
    )
  }

  if (origin.type === "cron") {
    return <span>{t("origin.cron", { name: origin.scheduled_task.name })}</span>
  }

  if (origin.type === "github_issue") {
    if (!origin.issue_url) return null

    return (
      <a className="text-blue-600 hover:underline dark:text-blue-400" href={origin.issue_url} rel="noopener noreferrer" target="_blank">
        {t("origin.issue", { number: origin.issue_number })}
      </a>
    )
  }

  return null
}

export default GitHistory
