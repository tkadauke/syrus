import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { StatusPill as StateStatusPill, TonePill } from "../components/StatusPill"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import {
  archiveRepositoryFromPath,
  bulkRepositoryIssues,
  closeRepositoryIssue,
  commentRepositoryIssue,
  delegateRepositoryIssue,
  fetchRepositoryDetail,
  fetchRepositoryIssues,
  pollRepositoryDetail,
  releaseNeedsTriageRepositoryJob,
  retryFailedRepositoryJobs,
  type RepositoryDetailJob,
  type RepositoryDetailPayload,
  type RepositoryIssue,
  type RepositoryIssuesPayload
} from "../api/repositories"

type IssueCommand =
  | { kind: "close"; issueNumber: number }
  | { kind: "delegate"; issueNumber: number }
  | { kind: "bulk"; bulkAction: "close" | "delegate"; issueNumbers: number[] }
  | { kind: "comment"; issueNumber: number; commentBody: string }

export function RepositoryDetailRoute() {
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

  return (
    <main aria-label="Repository" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {tab !== "github_issues" ? (
        <>
          {detail.isPending ? <PanelMessage>Loading repository...</PanelMessage> : null}
          {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, "Unable to load repository.")}</PanelMessage> : null}
          {detail.isSuccess ? <RepositoryDetail activeTab={tab} payload={detail.data} prefix={prefix} queryKey={detailQueryKey} /> : null}
        </>
      ) : (
        <>
          {issues.isPending ? <PanelMessage>Loading GitHub issues...</PanelMessage> : null}
          {issues.isError ? <PanelMessage tone="error">{errorMessage(issues.error, "Unable to load GitHub issues.")}</PanelMessage> : null}
          {issues.isSuccess ? <RepositoryIssues payload={issues.data} prefix={prefix} /> : null}
        </>
      )}
    </main>
  )
}

type RepositoryDetailQueryKey = readonly ["repositories", string, "detail", string]

function repositoryDetailQueryKey(id: string | number, search: string): RepositoryDetailQueryKey {
  return ["repositories", String(id), "detail", search] as const
}

function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

function RepositoryDetail({ activeTab, payload, prefix, queryKey }: { activeTab: "overview" | "github_issues"; payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey }) {
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
      <RepositorySummary payload={payload} />
      <Actions payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
      <NeedsTriageJobs payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
      <CredentialNotice payload={payload} />
      <RecentJobs payload={payload} prefix={prefix} setupStatus={setupStatus} />
    </>
  )
}

function RepositoryIssues({ payload, prefix }: { payload: RepositoryIssuesPayload; prefix: string }) {
  const queryClient = useQueryClient()
  const setupStatus = useSetupStatus()
  const queryKey = ["repositories", String(payload.repository.id), "issues", payload.state] as const
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [selected, setSelected] = useState<number[]>([])
  const [commentingOn, setCommentingOn] = useState<RepositoryIssue | null>(null)
  const [commentBody, setCommentBody] = useState("")
  const command = useMutation({
    mutationFn: (action: IssueCommand) => {
      switch (action.kind) {
        case "close":
          return closeRepositoryIssue(payload.paths.app_close_issue_path, { issueNumber: action.issueNumber, state: payload.state })
        case "delegate":
          return delegateRepositoryIssue(payload.paths.app_delegate_issue_path, { issueNumber: action.issueNumber, state: payload.state })
        case "comment":
          return commentRepositoryIssue(payload.paths.app_comment_issue_path, { issueNumber: action.issueNumber, commentBody: action.commentBody, state: payload.state })
        case "bulk":
          return bulkRepositoryIssues(payload.paths.app_bulk_issues_path, { issueNumbers: action.issueNumbers, bulkAction: action.bulkAction, state: payload.state })
      }
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
      setSelected([])
      setCommentingOn(null)
      setCommentBody("")
    }
  })

  function toggleIssue(number: number) {
    setSelected((current) => current.includes(number) ? current.filter((value) => value !== number) : [...current, number])
  }

  function submitComment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!commentingOn) return
    command.mutate({ kind: "comment", issueNumber: commentingOn.number, commentBody })
  }

  return (
    <>
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <a className="hover:underline" href={payload.repository.github_url} rel="noopener" target="_blank">{payload.repository.slug}</a>
        </h1>
      </header>

      <RepositoryTabs active="github_issues" prefix={prefix} tabs={payload.tabs} />

      <div className="flex flex-wrap gap-x-5 gap-y-1 text-sm text-gray-600 dark:text-gray-400">
        <span>Trigger label: <code className="rounded bg-gray-100 dark:bg-gray-800 px-1">{payload.repository.trigger_label}</code></span>
        <span>Showing: <StatusPill tone={payload.state === "open" ? "green" : "gray"}>{payload.state}</StatusPill></span>
        <span><strong>{payload.issue_count}</strong> {payload.issue_count === 1 ? "issue" : "issues"}</span>
        {payload.repository.github_rate_limit ? (
          <span>
            GitHub quota: <strong>{payload.repository.github_rate_limit.remaining.toLocaleString()}</strong> / {payload.repository.github_rate_limit.limit.toLocaleString()} ({payload.repository.github_rate_limit.resource})
          </span>
        ) : null}
        <a className="text-blue-600 dark:text-blue-400 hover:underline" href={payload.paths.github_issues_path} rel="noopener" target="_blank">View on GitHub</a>
      </div>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {payload.error_message ? <PanelMessage tone="error">{payload.error_message}</PanelMessage> : null}
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "GitHub issue command failed.")}</PanelMessage> : null}

      <div className="flex items-center justify-between gap-3">
        <div className="flex gap-1">
          <Link className={stateFilterClass(payload.state === "open")} to={withRoutePrefix(payload.state_paths.open, prefix)}>Open</Link>
          <Link className={stateFilterClass(payload.state === "closed")} to={withRoutePrefix(payload.state_paths.closed, prefix)}>Closed</Link>
        </div>
        {payload.issues.length > 0 ? (
          <div className="flex flex-wrap justify-end gap-2">
            {payload.state === "open" ? (
              <button
                className="rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 px-3 py-1.5 text-sm font-medium text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-950/60 disabled:opacity-50"
                disabled={selected.length === 0 || command.isPending}
                onClick={() => command.mutate({ kind: "bulk", bulkAction: "close", issueNumbers: selected })}
                type="button"
              >
                Close selected
              </button>
            ) : null}
            <button
              className="rounded border border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-950/40 px-3 py-1.5 text-sm font-medium text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-950/60 disabled:opacity-50"
              disabled={selected.length === 0 || command.isPending}
              onClick={() => command.mutate({ kind: "bulk", bulkAction: "delegate", issueNumbers: selected })}
              type="button"
            >
              Delegate selected
            </button>
          </div>
        ) : null}
      </div>

      {payload.issues.length > 0 ? (
        <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="w-10 px-4 py-2"><span className="sr-only">Select</span></th>
                <th className="px-4 py-2">Issue</th>
                <th className="w-36 px-4 py-2 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
              {payload.issues.map((issue) => (
                <RepositoryIssueRow
                  commandPending={command.isPending}
                  issue={issue}
                  key={issue.number}
                  onClose={() => command.mutate({ kind: "close", issueNumber: issue.number })}
                  onComment={() => {
                    setCommentingOn(issue)
                    setCommentBody("")
                  }}
                  onDelegate={() => command.mutate({ kind: "delegate", issueNumber: issue.number })}
                  onToggle={() => toggleIssue(issue.number)}
                  selected={selected.includes(issue.number)}
                  state={payload.state}
                />
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <OnboardingEmptyState
          fallbackActionPath={payload.state === "open" ? payload.paths.github_issues_path : payload.state_paths.open}
          fallbackActionText={payload.state === "open" ? "View GitHub issues" : "Show open issues"}
          fallbackDescription={payload.state === "open" ? `No open issues are available to delegate. Create or label an issue with ${payload.repository.trigger_label}, or use a direct job for first-run work.` : "No closed issues are available in this repository view."}
          fallbackTitle={`No ${payload.state} issues found`}
          prefix={prefix}
          setupStatus={setupStatus}
        />
      )}

      {commentingOn ? (
        <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">Comment on <span className="font-mono text-sm font-normal text-gray-600 dark:text-gray-400">#{commentingOn.number}</span></h2>
          <form className="mt-3 space-y-3" onSubmit={submitComment}>
            <textarea
              className="w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500"
              onChange={(event) => setCommentBody(event.target.value)}
              rows={5}
              value={commentBody}
            />
            <div className="flex justify-end gap-2">
              <button className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800" onClick={() => setCommentingOn(null)} type="button">Cancel</button>
              <button className={buttonClass("blue")} disabled={command.isPending} type="submit">Post comment</button>
            </div>
          </form>
        </section>
      ) : null}
    </>
  )
}

function RepositoryIssueRow({
  commandPending,
  issue,
  onClose,
  onComment,
  onDelegate,
  onToggle,
  selected,
  state
}: {
  commandPending: boolean
  issue: RepositoryIssue
  onClose: () => void
  onComment: () => void
  onDelegate: () => void
  onToggle: () => void
  selected: boolean
  state: "open" | "closed"
}) {
  return (
    <tr>
      <td className="px-4 py-3 align-top">
        <input aria-label={`Select issue #${issue.number}`} checked={selected} className="rounded border-gray-300 dark:border-gray-600 text-blue-600 dark:text-blue-400 focus:ring-blue-500" onChange={onToggle} type="checkbox" />
      </td>
      <td className="px-4 py-3 align-top">
        <div className="flex flex-wrap items-baseline gap-2">
          <a className="font-mono text-gray-500 dark:text-gray-400 hover:underline" href={issue.html_url} rel="noopener" target="_blank">#{issue.number}</a>
          {issue.labels.map((label) => <IssueLabel color={label.color} key={label.name} name={label.name} />)}
          <a className="font-medium text-gray-900 dark:text-gray-100 hover:underline" href={issue.html_url} rel="noopener" target="_blank">{issue.title}</a>
        </div>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{issue.user_login ? `${issue.user_login} · ` : ""}{issue.created_at ? formatRelative(issue.created_at) : ""}</div>
        {issue.body_excerpt ? <p className="mt-1 line-clamp-2 text-xs text-gray-400 dark:text-gray-500">{issue.body_excerpt}</p> : null}
      </td>
      <td className="px-4 py-3 align-top">
        <div className="flex flex-col items-stretch gap-1.5">
          <button className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700" disabled={commandPending} onClick={onComment} type="button">Comment</button>
          {state === "open" ? <button className="rounded bg-amber-50 dark:bg-amber-950/40 px-2 py-1 text-xs font-medium text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-950/60" disabled={commandPending} onClick={onClose} type="button">Close</button> : null}
          {issue.delegated ? (
            <span className="rounded border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 px-2 py-1 text-center text-xs font-medium text-green-700 dark:text-green-300">Delegated</span>
          ) : (
            <button className="rounded bg-blue-50 dark:bg-blue-950/40 px-2 py-1 text-xs font-medium text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-950/60" disabled={commandPending} onClick={onDelegate} type="button">Delegate</button>
          )}
        </div>
      </td>
    </tr>
  )
}

function IssueLabel({ color, name }: { color: string; name: string }) {
  const safeColor = color.match(/^[0-9a-fA-F]{6}$/) ? color : "6b7280"
  return (
    <span
      className="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium"
      style={{
        backgroundColor: `#${safeColor}22`,
        border: `1px solid #${safeColor}44`,
        color: `#${safeColor}`
      }}
    >
      {name}
    </span>
  )
}


function RepositorySummary({ payload }: { payload: RepositoryDetailPayload }) {
  const location = useLocation()
  const repository = payload.repository
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const nonzeroCounts = [
    { label: "running", value: payload.counts.running, tone: "blue" as const },
    { label: "queued", value: payload.counts.queued, tone: "gray" as const },
    { label: "failed 7d", value: payload.counts.failed_7d, tone: "red" as const }
  ].filter((count) => count.value > 0)

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
        <StatusPill tone={repository.polling_enabled ? "green" : "gray"}>{repository.polling_enabled ? "polling enabled" : "polling paused"}</StatusPill>
        <span>{payload.credential_status.label}</span>
        <span className="text-gray-300 dark:text-gray-600">·</span>
        <span>Agent: {repository.agent_provider_label || `user default (${repository.effective_agent_provider_label})`}</span>
        {nonzeroCounts.map((count) => (
          <StatusPill key={count.label} tone={count.tone}>{count.value} {count.label}</StatusPill>
        ))}
      </div>
      <details className="text-sm text-gray-600 dark:text-gray-400">
        <summary className="cursor-pointer select-none text-gray-500 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-100">Repository details</summary>
        <dl className="mt-3 grid gap-x-6 gap-y-2 sm:grid-cols-2 lg:grid-cols-3">
          <div><dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Working repo</dt><dd className="font-mono text-gray-700 dark:text-gray-300">{repository.slug}</dd></div>
          <div><dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Working branch</dt><dd className="font-mono text-gray-700 dark:text-gray-300">{repository.default_branch}</dd></div>
          {repository.upstream_slug ? (
            <div>
              <dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Upstream repo</dt>
              <dd className="font-mono text-gray-700 dark:text-gray-300">{repository.upstream_slug}{repository.upstream_default_branch ? `:${repository.upstream_default_branch}` : ""}</dd>
            </div>
          ) : null}
          <div><dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Trigger label</dt><dd><code className="rounded bg-gray-100 dark:bg-gray-800 px-1">{repository.trigger_label}</code></dd></div>
          <div>
            <dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Syrus owner</dt>
            <dd>
              {repository.owner_user.profile_path ? (
                <Link className="text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(repository.owner_user.profile_path, prefix)}>{repository.owner_user.display_name}</Link>
              ) : (
                repository.owner_user.display_name || repository.owner_user.email_address
              )}
            </dd>
          </div>
          <div><dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Added</dt><dd>{formatDate(repository.created_at)}</dd></div>
          {repository.github_rate_limit ? (
            <div><dt className="text-xs uppercase text-gray-400 dark:text-gray-500">GitHub quota</dt><dd><strong>{repository.github_rate_limit.remaining.toLocaleString()}</strong> / {repository.github_rate_limit.limit.toLocaleString()} ({repository.github_rate_limit.resource})</dd></div>
          ) : null}
          {payload.credential_status.mode === "app" && payload.credential_status.installation_account ? (
            <div><dt className="text-xs uppercase text-gray-400 dark:text-gray-500">Credential</dt><dd>Syrus App via {payload.credential_status.installation_account}</dd></div>
          ) : null}
        </dl>
      </details>
    </section>
  )
}

function Actions({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
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
        <Link className={buttonClass("green")} to={withRoutePrefix(payload.paths.new_job_path, prefix)}>New job</Link>
        <button className={buttonClass("blue")} disabled={disabled} onClick={() => { onNotice(null); poll.mutate() }} type="button">Poll now</button>
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
            More
          </button>
          {moreOpen ? (
            <div className="absolute left-0 z-20 mt-2 min-w-40 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-1 text-sm shadow-lg" id="repository-actions-menu">
              <Link className="block rounded px-3 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800" onClick={() => setMoreOpen(false)} to={withRoutePrefix(payload.paths.edit_repository_path, prefix)}>Edit</Link>
              <button className="block w-full rounded px-3 py-2 text-left text-amber-800 dark:text-amber-200 hover:bg-amber-50 dark:hover:bg-amber-950/50 disabled:text-gray-300 dark:disabled:text-gray-600" disabled={disabled} onClick={archiveRepository} type="button">Archive</button>
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
  const status = payload.credential_status
  if (status.mode === "app") return null

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-700 dark:text-gray-300">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <span className="font-medium">Connection:</span> PAT fallback because this repository has no active App installation.
          <span className="ml-1">{status.github_app_registered ? "Install the GitHub App for this repository owner to use app credentials here." : "Register the GitHub App to prefer app credentials over PAT fallback."}</span>
          {status.previous_installation_removed ? <span className="ml-1">Previous installation was removed.</span> : null}
        </div>
        {status.install_url ? <a className={buttonClass("gray")} href={status.install_url} rel="noopener" target="_blank">Install Syrus App</a> : null}
        {status.register_path ? <a className={buttonClass("gray")} href={status.register_path}>Register Syrus App</a> : null}
      </div>
      {status.missing_github_ids ? <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">GitHub numeric IDs are missing; edit this repository and select it from the GitHub-backed picker to generate a one-click install link.</p> : null}
    </section>
  )
}

function NeedsTriageJobs({ payload, prefix, queryKey, onNotice }: { payload: RepositoryDetailPayload; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
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
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">Needs triage</h2>
      <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {payload.needs_triage_jobs.length > 0 ? (
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">Job</th>
                <th className="hidden px-4 py-2 sm:table-cell">Created</th>
                <th className="px-4 py-2 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
              {payload.needs_triage_jobs.map((job) => (
                <tr key={job.id}>
                  <td className="px-4 py-3">
                    <SourceLink job={job} prefix={prefix} />
                    <Link className="ml-1 text-gray-700 dark:text-gray-300 hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.issue_title || `JOB-${job.id}`}</Link>
                    {job.owner_user ? <div className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">Owner: {job.owner_user.display_name || job.owner_user.email_address}</div> : null}
                  </td>
                  <td className="hidden px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell">{formatRelative(job.created_at)}</td>
                  <td className="px-4 py-3 text-right">
                    <button className={buttonClass("blue")} disabled={release.isPending} onClick={() => { onNotice(null); release.mutate(job.id) }} type="button">Release for triage</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="p-4 text-sm text-gray-600 dark:text-gray-400">No jobs are waiting for triage release.</p>
        )}
      </div>
      {release.isError ? <PanelMessage tone="error">{errorMessage(release.error, "Unable to release job for triage.")}</PanelMessage> : null}
    </section>
  )
}

function RecentJobs({ payload, prefix, setupStatus }: { payload: RepositoryDetailPayload; prefix: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  if (payload.jobs.length === 0) {
    return (
      <section>
        <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">Recent jobs</h2>
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
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">Recent jobs</h2>
      <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">State</th>
              <th className="px-4 py-2">Issue</th>
              <th className="hidden px-4 py-2 sm:table-cell">Runs</th>
              <th className="hidden px-4 py-2 sm:table-cell">Last</th>
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
          <span>{formatRelative(job.updated_at)}</span>
        </div>
      </td>
      <td className="hidden px-4 py-3 text-gray-600 dark:text-gray-400 sm:table-cell">{job.runs_count}</td>
      <td className="hidden px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell">{formatRelative(job.updated_at)}</td>
      <td className="hidden px-4 py-3 text-right sm:table-cell"><Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(job.job_path, prefix)}>View</Link></td>
    </tr>
  )
}

function RepositoryRetryState({ job }: { job: RepositoryDetailJob }) {
  const retry = job.retry_state
  if (!retry || retry.state_label === "No failure") return null

  const tone = retry.auto_retry_exhausted ? "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950/40 border-red-200 dark:border-red-800" : retry.provider_circuit_open ? "text-amber-800 dark:text-amber-200 bg-amber-50 dark:bg-amber-950/40 border-amber-200 dark:border-amber-800" : "text-gray-700 dark:text-gray-300 bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700"
  return (
    <div className={`mt-1 inline-flex flex-wrap items-center gap-1.5 rounded border px-2 py-1 text-xs ${tone}`}>
      <span className="font-medium">{retry.state_label}</span>
      <span>{retry.classification_label}</span>
      <span>{retry.retry_budget_remaining} retries left</span>
      {retry.next_auto_retry_at ? <span>next {formatRelative(retry.next_auto_retry_at)}</span> : null}
    </div>
  )
}

function SourceLink({ job, prefix }: { job: { source: RepositoryDetailJob["source"] }; prefix: string }) {
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
  const pagination = payload.pagination
  if (pagination.total_pages <= 1) return null

  return (
    <div className="mt-4 flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>Showing {pagination.first_item}-{pagination.last_item} of {pagination.total_jobs}</span>
      <div className="flex gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>Previous</Link> : <span className={disabledPaginationClass()}>Previous</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>Next</Link> : <span className={disabledPaginationClass()}>Next</span>}
      </div>
    </div>
  )
}

function StatusPill({ children, tone }: { children: ReactNode; tone: "green" | "gray" | "blue" | "red" | "amber" }) {
  return <TonePill tone={tone}>{children}</TonePill>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "warning" }) {
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400",
    warning: "border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function buttonClass(tone: "green" | "blue" | "amber" | "gray", extra = "") {
  const colors = {
    amber: "bg-amber-600 text-white hover:bg-amber-500 dark:hover:bg-amber-500",
    blue: "bg-blue-600 text-white hover:bg-blue-500 dark:hover:bg-blue-500",
    gray: "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700",
    green: "bg-emerald-600 text-white hover:bg-emerald-500 dark:hover:bg-emerald-500"
  }
  return `rounded px-3 py-1.5 text-sm font-medium ${colors[tone]} ${extra}`.trim()
}

function paginationLinkClass() {
  return "rounded border border-gray-300 dark:border-gray-600 px-3 py-1 hover:bg-gray-50 dark:hover:bg-gray-800"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 dark:border-gray-700 px-3 py-1 text-gray-300 dark:text-gray-600"
}

function stateFilterClass(active: boolean) {
  return `rounded border px-3 py-1.5 text-sm font-medium ${active ? "border-blue-600 bg-blue-600 text-white" : "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"}`
}

function pageSearch(search: string) {
  const params = new URLSearchParams(search)
  const page = params.get("page")
  return page ? `?${new URLSearchParams({ page }).toString()}` : ""
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function formatRelative(value: string) {
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000))
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
