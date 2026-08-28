import { useMemo } from "react"
import { useInfiniteQuery } from "@tanstack/react-query"
import { Link, useParams } from "react-router-dom"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { TonePill } from "@app/components/StatusPill"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { fetchGitHistory, type GitHistoryCommit, type GitHistoryOrigin } from "../api/gitHistory"
import { commitGroupKey, groupCommits, type CommitGroup, type EpicCommitGroup, type JobCommitGroup } from "./groupCommits"

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

  // Recomputed over the full accumulated commit list (not per-page) so a
  // Job's or Epic's commit group reassembles correctly even when "load
  // more" happened to land in the middle of it.
  const commits = useMemo(
    () => (history.data ? history.data.pages.flatMap((page) => page.commits) : []),
    [history.data]
  )
  const groups = useMemo(() => groupCommits(commits), [commits])

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

  const available = history.data.pages[0]?.available ?? false

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
            {groups.map((group) => <CommitGroupRow group={group} key={commitGroupKey(group)} />)}
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

function CommitGroupRow({ group }: { group: CommitGroup }) {
  if (group.kind === "epic") return <EpicGroupRow group={group} />
  if (group.kind === "job") return <JobGroupRow group={group} />
  return <ExternalCommitRow commit={group.commit} />
}

// An Epic group is anchored by its `epic_landed` (and any
// `epic_reconciliation`) commits -- the first one renders as the group's
// summary row, any further ones plus every member Job's own nested commit
// group render underneath, collapsed into one visual unit instead of a flat
// list of unrelated-looking rows.
function EpicGroupRow({ group }: { group: EpicCommitGroup }) {
  const [headline, ...restCommits] = group.commits
  const nestedJobGroups = group.jobGroups.filter((jobGroup) => jobGroup.commits.length > 0)
  if (!headline) return null

  return (
    <li className="border-l-4 border-terracotta-400 dark:border-terracotta-600">
      <details open>
        <summary className="cursor-pointer list-none [&::-webkit-details-marker]:hidden">
          <CommitContent commit={headline} emphasized />
        </summary>
        {restCommits.length > 0 || nestedJobGroups.length > 0 ? (
          <div className="divide-y divide-gray-100 border-t border-gray-100 bg-gray-50/60 pl-6 dark:divide-gray-800 dark:border-gray-800 dark:bg-gray-800/40">
            {restCommits.map((commit) => <CommitContent commit={commit} emphasized key={commit.sha} />)}
            {nestedJobGroups.map((jobGroup) => <NestedJobGroupRow group={jobGroup} key={`job-${jobGroup.job.id}`} />)}
          </div>
        ) : null}
      </details>
    </li>
  )
}

// A standalone Job group (no epic-landing anchor in view) at the top
// level of the list -- its own syrus_landed commits collapse underneath
// its most recent one instead of appearing as separate flat rows.
function JobGroupRow({ group }: { group: JobCommitGroup }) {
  const [headline, ...restCommits] = group.commits
  if (!headline) return null

  return (
    <li className="border-l-4 border-terracotta-400 dark:border-terracotta-600">
      <details open>
        <summary className="cursor-pointer list-none [&::-webkit-details-marker]:hidden">
          <CommitContent commit={headline} emphasized />
        </summary>
        {restCommits.length > 0 ? (
          <div className="divide-y divide-gray-100 border-t border-gray-100 bg-gray-50/60 pl-6 dark:divide-gray-800 dark:border-gray-800 dark:bg-gray-800/40">
            {restCommits.map((commit) => <CommitContent commit={commit} emphasized key={commit.sha} />)}
          </div>
        ) : null}
      </details>
    </li>
  )
}

// The same Job group shape, nested one level deeper inside its Epic group
// (a <div>, not a fresh <li> -- the Epic's <li> already owns the list item).
function NestedJobGroupRow({ group }: { group: JobCommitGroup }) {
  const [headline, ...restCommits] = group.commits
  if (!headline) return null

  return (
    <div className="border-l-2 border-terracotta-200 dark:border-terracotta-800">
      <details open>
        <summary className="cursor-pointer list-none [&::-webkit-details-marker]:hidden">
          <CommitContent commit={headline} emphasized />
        </summary>
        {restCommits.length > 0 ? (
          <div className="divide-y divide-gray-100 border-t border-gray-100 pl-6 dark:divide-gray-800 dark:border-gray-800">
            {restCommits.map((commit) => <CommitContent commit={commit} emphasized key={commit.sha} />)}
          </div>
        ) : null}
      </details>
    </div>
  )
}

// external_pr / external_push commits are never grouped -- rendered
// individually, de-emphasized relative to Syrus-attributed rows.
function ExternalCommitRow({ commit }: { commit: GitHistoryCommit }) {
  return (
    <li className="border-l-4 border-transparent bg-gray-50/40 dark:bg-gray-900/40">
      <CommitContent commit={commit} emphasized={false} />
    </li>
  )
}

function CommitContent({ commit, emphasized }: { commit: GitHistoryCommit; emphasized: boolean }) {
  return (
    <div className="flex flex-col gap-2 p-4 sm:flex-row sm:items-start sm:justify-between">
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <ClassificationPill commit={commit} />
          <span
            className={
              emphasized
                ? "truncate text-sm font-semibold text-gray-900 dark:text-gray-100"
                : "truncate text-sm font-normal text-gray-500 dark:text-gray-500"
            }
          >
            {commit.subject}
          </span>
        </div>
        <div
          className={`mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs ${
            emphasized ? "text-gray-500 dark:text-gray-400" : "text-gray-400 dark:text-gray-600"
          }`}
        >
          <span className="font-mono">{commit.short_sha}</span>
          <RelativeTimestamp value={commit.authored_at} />
          <CommitAttribution commit={commit} />
        </div>
      </div>
    </div>
  )
}

function ClassificationPill({ commit }: { commit: GitHistoryCommit }) {
  const { t } = useT("git_history")

  if (commit.classification === "syrus_landed") return <TonePill tone="green">{t("classification.syrus_landed")}</TonePill>
  if (commit.classification === "epic_landed") return <TonePill tone="green">{t("classification.epic_landed")}</TonePill>
  if (commit.classification === "epic_reconciliation") return <TonePill tone="amber">{t("classification.epic_reconciliation")}</TonePill>
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

  if (commit.classification === "epic_landed") {
    return (
      <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
        {commit.epic ? (
          <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/epics/${commit.epic.id}`}>{commit.epic.slug}</Link>
        ) : null}
        {(commit.jobs ?? []).map((job) => (
          <Link className="text-blue-600 hover:underline dark:text-blue-400" key={job.id} to={`/jobs/${job.id}`}>{job.slug}</Link>
        ))}
      </span>
    )
  }

  if (commit.classification === "epic_reconciliation") {
    return (
      <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
        {commit.epic ? (
          <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/epics/${commit.epic.id}`}>{commit.epic.slug}</Link>
        ) : null}
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
