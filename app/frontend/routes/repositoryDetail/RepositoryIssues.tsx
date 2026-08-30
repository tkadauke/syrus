import { PanelMessage, StatusPill, stateFilterClass, buttonClass } from "./shared"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { withRoutePrefix } from "../../lib/routing"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { Checkbox } from "../../components/Checkbox"
import { NoticeToast } from "../../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../../components/OnboardingEmptyState"
import { RepositoryTabs } from "../../components/RepositoryTabs"
import { Button } from "../../components/Button"
import { bulkRepositoryIssues, closeRepositoryIssue, commentRepositoryIssue, delegateRepositoryIssue, type RepositoryIssue, type RepositoryIssuesPayload } from "../../api/repositories"
import { errorMessage } from "../../lib/errorMessage"


// Repository GitHub-issues tab extracted from RepositoryDetail.tsx: the issue
// list (RepositoryIssues), its rows, and the issue label chip. Entry point
// rendered for the github_issues tab. Depends only on leaf/shared modules.

type IssueCommand =
  | { kind: "close"; issueNumber: number }
  | { kind: "delegate"; issueNumber: number }
  | { kind: "bulk"; bulkAction: "close" | "delegate"; issueNumbers: number[] }
  | { kind: "comment"; issueNumber: number; commentBody: string }

export function RepositoryIssues({ isRefreshing, onRefresh, payload, prefix }: { isRefreshing: boolean; onRefresh: () => void; payload: RepositoryIssuesPayload; prefix: string }) {
  const { t } = useT("settings")
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
        <span>
          {t('repository.trigger_label_prefix')} <code className="rounded bg-gray-100 dark:bg-gray-800 px-1">{payload.repository.trigger_label}</code>
        </span>
        <span>
          {t('repository.showing_prefix')} <StatusPill tone={payload.state === "open" ? "green" : "gray"}>{payload.state}</StatusPill>
        </span>
        <span><strong>{payload.issue_count}</strong> {payload.issue_count === 1 ? "issue" : "issues"}</span>
        {payload.repository.github_rate_limit ? (
          <span>
            {t('repository.github_quota_prefix')} <strong>{payload.repository.github_rate_limit.remaining.toLocaleString()}</strong> / {payload.repository.github_rate_limit.limit.toLocaleString()} ({payload.repository.github_rate_limit.resource})
          </span>
        ) : null}
        <a className="text-brand hover:underline dark:text-brand-emphasis" href={payload.paths.github_issues_path} rel="noopener" target="_blank">{t('repository.view_on_github')}</a>
      </div>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {payload.error_message ? <PanelMessage tone="error">{payload.error_message}</PanelMessage> : null}
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "GitHub issue command failed.")}</PanelMessage> : null}

      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <div className="flex gap-1">
            <Link className={stateFilterClass(payload.state === "open")} to={withRoutePrefix(payload.state_paths.open, prefix)}>{t('repository.state_open')}</Link>
            <Link className={stateFilterClass(payload.state === "closed")} to={withRoutePrefix(payload.state_paths.closed, prefix)}>{t('repository.state_closed')}</Link>
          </div>
          <Button
            className="disabled:text-gray-400 dark:disabled:text-gray-500"
            disabled={isRefreshing}
            onClick={onRefresh}
            variant="secondary"
          >
            {isRefreshing ? t('repository.refreshing') : t('repository.refresh')}
          </Button>
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
                {t('repository.close_selected')}
              </button>
            ) : null}
            <button
              className="rounded border border-brand/30 bg-brand/10 px-3 py-1.5 text-sm font-medium text-brand hover:bg-brand/20 disabled:opacity-50"
              disabled={selected.length === 0 || command.isPending}
              onClick={() => command.mutate({ kind: "bulk", bulkAction: "delegate", issueNumbers: selected })}
              type="button"
            >
              {t('repository.delegate_selected')}
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
                <th className="px-4 py-2">
                  {t('repository.col_issue')}
                </th>
                <th className="w-36 px-4 py-2 text-right">
                  {t('repository.col_actions')}
                </th>
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
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">
            {t('repository.comment_on')} <span className="font-mono text-sm font-normal text-gray-600 dark:text-gray-400">#{commentingOn.number}</span>
          </h2>
          <form className="mt-3 space-y-3" onSubmit={submitComment}>
            <textarea
              className="w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-brand"
              onChange={(event) => setCommentBody(event.target.value)}
              rows={5}
              value={commentBody}
            />
            <div className="flex justify-end gap-2">
              <Button onClick={() => setCommentingOn(null)} variant="secondary">{t('repository.cancel')}</Button>
              <button className={buttonClass("blue")} disabled={command.isPending} type="submit">{t('repository.post_comment')}</button>
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
  const { t } = useT("settings")
  return (
    <tr>
      <td className="px-4 py-3 align-top">
        <Checkbox aria-label={`Select issue #${issue.number}`} checked={selected} onChange={onToggle} />
      </td>
      <td className="px-4 py-3 align-top">
        <div className="flex flex-wrap items-baseline gap-2">
          <a className="font-mono text-gray-500 dark:text-gray-400 hover:underline" href={issue.html_url} rel="noopener" target="_blank">#{issue.number}</a>
          {issue.labels.map((label) => <IssueLabel color={label.color} key={label.name} name={label.name} />)}
          <a className="font-medium text-gray-900 dark:text-gray-100 hover:underline" href={issue.html_url} rel="noopener" target="_blank">{issue.title}</a>
        </div>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{issue.user_login ? `${issue.user_login} · ` : ""}{issue.created_at ? <RelativeTimestamp value={issue.created_at} /> : ""}</div>
        {issue.body_excerpt ? <p className="mt-1 line-clamp-2 text-xs text-gray-400 dark:text-gray-500">{issue.body_excerpt}</p> : null}
      </td>
      <td className="px-4 py-3 align-top">
        <div className="flex flex-col items-stretch gap-1.5">
          <button className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700" disabled={commandPending} onClick={onComment} type="button">
            {t('repository.comment')}
          </button>
          {state === "open" ? <button className="rounded bg-amber-50 dark:bg-amber-950/40 px-2 py-1 text-xs font-medium text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-950/60" disabled={commandPending} onClick={onClose} type="button">
            {t('repository.close')}
          </button> : null}
          {issue.delegated ? (
            <span className="rounded border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 px-2 py-1 text-center text-xs font-medium text-green-700 dark:text-green-300">{t('repository.delegated')}</span>
          ) : (
            <button className="rounded bg-brand/10 px-2 py-1 text-xs font-medium text-brand hover:bg-brand/20" disabled={commandPending} onClick={onDelegate} type="button">{t('repository.delegate')}</button>
          )}
        </div>
      </td>
    </tr>
  )
}

function IssueLabel({ color, name }: { color: string; name: string }) {
  const { t } = useT("settings")
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
