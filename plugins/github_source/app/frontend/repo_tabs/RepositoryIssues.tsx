import { AdminFiltersLayout } from "@app/components/AdminFiltersLayout"
import { PanelMessage } from "@app/components/PanelMessage"
import { TonePill } from "@app/components/StatusPill"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { FilterBar } from "@app/components/FilterBar"
import { SmartFolderNavigation, type SmartFolderNavFolder } from "@app/components/SmartFolderNavigation"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useEffect, useMemo, useState } from "react"
import { useLocation, useParams, useSearchParams } from "react-router-dom"
import { useT } from "@app/hooks/useT"
import { Checkbox } from "@app/components/Checkbox"
import { NoticeToast } from "@app/components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "@app/components/OnboardingEmptyState"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { Button } from "@app/components/Button"
import { DataTable } from "@app/components/ui/DataTable"
import {
  bulkRepositoryIssues,
  closeRepositoryIssue,
  commentRepositoryIssue,
  delegateRepositoryIssue,
  fetchRepositoryIssues,
  ISSUE_FOLDERS,
  type IssueFolder,
  type RepositoryIssue,
  type RepositoryIssuesPayload
} from "../api/issues"
import { errorMessage } from "@app/lib/errorMessage"


// Repository GitHub-issues tab extracted from RepositoryDetail.tsx: the issue
// list (RepositoryIssues), its rows, and the issue label chip. Entry point
// rendered for the github_issues tab. Depends only on leaf/shared modules.
//
// The folder nav renders through the standard SmartFolderNavigation
// component (not the DB-backed AdminSmartFolderNav wrapper): GitHub issues
// have no local table to persist a SmartFolder row against, so the four
// folders are synthetic rows shaped to SmartFolderNavFolder rather than
// real persisted records. Counts come straight from the open/closed
// fetches list_all_issues already auto-paginates through.

type IssueCommand =
  | { kind: "close"; issueNumber: number }
  | { kind: "delegate"; issueNumber: number }
  | { kind: "bulk"; bulkAction: "close" | "delegate"; issueNumbers: number[] }
  | { kind: "comment"; issueNumber: number; commentBody: string }

function resolveFolder(searchParams: URLSearchParams): IssueFolder {
  const folder = searchParams.get("folder")
  if (folder && (ISSUE_FOLDERS as string[]).includes(folder)) return folder as IssueFolder

  return searchParams.get("state") === "closed" ? "closed" : "open"
}

function folderLink(pathname: string, search: string, folder: IssueFolder) {
  const params = new URLSearchParams(search)
  params.set("folder", folder)
  params.delete("state")
  return `${pathname}?${params.toString()}`
}

export function RepositoryIssues({ isRefreshing, onRefresh, payload, prefix }: { isRefreshing: boolean; onRefresh: () => void; payload: RepositoryIssuesPayload; prefix: string }) {
  const { t } = useT("github_source")
  const { t: tNav } = useT("nav")
  const queryClient = useQueryClient()
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const setupStatus = useSetupStatus()
  const filterParam = searchParams.get("q") || ""
  const queryKey = ["repositories", String(payload.repository.id), "issues", payload.folder, filterParam] as const
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [selected, setSelected] = useState<number[]>([])
  const [commentingOn, setCommentingOn] = useState<RepositoryIssue | null>(null)
  const [commentBody, setCommentBody] = useState("")

  useEffect(() => {
    setSelected([])
    setCommentingOn(null)
  }, [payload.folder, payload.query])

  const command = useMutation({
    mutationFn: (action: IssueCommand) => {
      const folder = payload.folder
      switch (action.kind) {
        case "close":
          return closeRepositoryIssue(payload.paths.app_close_issue_path, { issueNumber: action.issueNumber, folder, filterParam })
        case "delegate":
          return delegateRepositoryIssue(payload.paths.app_delegate_issue_path, { issueNumber: action.issueNumber, folder, filterParam })
        case "comment":
          return commentRepositoryIssue(payload.paths.app_comment_issue_path, { issueNumber: action.issueNumber, commentBody: action.commentBody, folder, filterParam })
        case "bulk":
          return bulkRepositoryIssues(payload.paths.app_bulk_issues_path, { issueNumbers: action.issueNumbers, bulkAction: action.bulkAction, folder, filterParam })
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

  function toggleAll() {
    setSelected((current) => current.length === payload.issues.length ? [] : payload.issues.map((issue) => issue.number))
  }

  function submitComment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!commentingOn) return
    command.mutate({ kind: "comment", issueNumber: commentingOn.number, commentBody })
  }

  const folders: SmartFolderNavFolder[] = useMemo(() => ISSUE_FOLDERS.map((folder, index) => ({
    id: index + 1,
    name: t(`repository.folder_${folder}`),
    kind: "builtin",
    visibility: "default",
    position: index,
    count: payload.folder_counts[folder],
    active: payload.folder === folder,
    path: folderLink(location.pathname, location.search, folder)
  })), [t, payload.folder, payload.folder_counts, location.pathname, location.search])

  const allSelected = payload.issues.length > 0 && selected.length === payload.issues.length
  const canBulkClose = payload.folder !== "closed"

  return (
    <>
      <div className="flex flex-wrap gap-x-5 gap-y-1 text-sm text-gray-600 dark:text-gray-400">
        <span>
          {t('repository.trigger_label_prefix')} <code className="rounded bg-gray-100 dark:bg-gray-800 px-1">{payload.repository.trigger_label}</code>
        </span>
        {payload.repository.github_rate_limit ? (
          <span>
            {t('repository.github_quota_prefix')} <strong>{payload.repository.github_rate_limit.remaining.toLocaleString()}</strong> / {payload.repository.github_rate_limit.limit.toLocaleString()} ({payload.repository.github_rate_limit.resource})
          </span>
        ) : null}
        <a className="text-brand hover:underline dark:text-brand-emphasis" href={payload.paths.github_issues_path} rel="noopener" target="_blank">{t('repository.view_on_github')}</a>
        <Button
          className="disabled:text-gray-400 dark:disabled:text-gray-500"
          disabled={isRefreshing}
          onClick={onRefresh}
          size="sm"
          variant="secondary"
        >
          {isRefreshing ? t('repository.refreshing') : t('repository.refresh')}
        </Button>
      </div>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {payload.error_message ? <PanelMessage tone="error">{payload.error_message}</PanelMessage> : null}
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, t("repository.command_failed"))}</PanelMessage> : null}

      <AdminFiltersLayout
        filterBar={
          <FilterBar
            filter={payload.filter}
            filterSchema={payload.filter_schema}
            pathname={location.pathname}
            search={location.search}
          />
        }
        smartFolders={
          <SmartFolderNavigation
            actionLabel={() => ""}
            ariaLabel={t("repository.folders_aria")}
            emptySavedMessage={tNav("smart_folder.no_saved_folders")}
            folders={folders}
            getDisplayName={(folder) => folder.name}
            heading={t("repository.folders_heading")}
            moreLabel={tNav("smart_folder.more")}
            prefix={prefix}
            savedAriaLabel={`${t("repository.folders_aria")} saved`}
            savedHeading={tNav("smart_folder.saved")}
          />
        }
      >
        <div className="flex items-center justify-between gap-4">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t(`repository.folder_${payload.folder}`)}</h2>
          <span className="text-sm text-gray-500 dark:text-gray-400">{t("repository.issue_count", { count: payload.issue_count })}</span>
        </div>

        {payload.issues.length > 0 ? (
          <>
            {selected.length > 0 ? (
              <div className="flex flex-wrap items-center gap-2 rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 px-3 py-2 text-sm text-gray-700 dark:text-gray-300">
                <span>{t("repository.selected_count", { count: selected.length })}</span>
                {canBulkClose ? (
                  <Button
                    disabled={command.isPending}
                    onClick={() => command.mutate({ kind: "bulk", bulkAction: "close", issueNumbers: selected })}
                    size="sm"
                    variant="danger"
                  >
                    {t('repository.close_selected')}
                  </Button>
                ) : null}
                <Button
                  disabled={command.isPending}
                  onClick={() => command.mutate({ kind: "bulk", bulkAction: "delegate", issueNumbers: selected })}
                  size="sm"
                  variant="primary"
                >
                  {t('repository.delegate_selected')}
                </Button>
              </div>
            ) : null}

            <DataTable.Root wrapperClassName="mt-3">
              <DataTable.Header>
                <DataTable.Row>
                  <DataTable.HeadCell checkbox>
                    <Checkbox aria-label={t("repository.select_all")} checked={allSelected} onChange={toggleAll} />
                  </DataTable.HeadCell>
                  <DataTable.HeadCell>{t('repository.col_issue')}</DataTable.HeadCell>
                  <DataTable.HeadCell>{t('repository.col_status')}</DataTable.HeadCell>
                  <DataTable.HeadCell align="right">{t('repository.col_actions')}</DataTable.HeadCell>
                </DataTable.Row>
              </DataTable.Header>
              <DataTable.Body>
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
                  />
                ))}
              </DataTable.Body>
            </DataTable.Root>
          </>
        ) : (
          <OnboardingEmptyState
            fallbackActionPath={emptyStateActionPath(payload)}
            fallbackActionText={t(`repository.empty_${payload.folder}_action`)}
            fallbackDescription={t(`repository.empty_${payload.folder}_description`, { label: payload.repository.trigger_label })}
            fallbackTitle={t("repository.empty_title", { folder: t(`repository.folder_${payload.folder}`) })}
            prefix={prefix}
            setupStatus={setupStatus}
          />
        )}
      </AdminFiltersLayout>

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
              <Button disabled={command.isPending} type="submit" variant="primary">{t('repository.post_comment')}</Button>
            </div>
          </form>
        </section>
      ) : null}
    </>
  )
}

function emptyStateActionPath(payload: RepositoryIssuesPayload) {
  return payload.folder === "open" ? payload.paths.github_issues_path : payload.folder_paths.open
}

function RepositoryIssueRow({
  commandPending,
  issue,
  onClose,
  onComment,
  onDelegate,
  onToggle,
  selected
}: {
  commandPending: boolean
  issue: RepositoryIssue
  onClose: () => void
  onComment: () => void
  onDelegate: () => void
  onToggle: () => void
  selected: boolean
}) {
  const { t } = useT("github_source")
  return (
    <DataTable.Row>
      <DataTable.Cell checkbox className="align-top">
        <Checkbox aria-label={t("repository.select_issue", { number: issue.number })} checked={selected} onChange={onToggle} />
      </DataTable.Cell>
      <DataTable.Cell className="align-top">
        <div className="flex flex-wrap items-baseline gap-2">
          <a className="font-mono text-gray-500 dark:text-gray-400 hover:underline" href={issue.html_url} rel="noopener" target="_blank">#{issue.number}</a>
          {issue.labels.map((label) => <IssueLabel color={label.color} key={label.name} name={label.name} />)}
          <a className="font-medium text-gray-900 dark:text-gray-100 hover:underline" href={issue.html_url} rel="noopener" target="_blank">{issue.title}</a>
        </div>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{issue.user_login ? `${issue.user_login} · ` : ""}{issue.created_at ? <RelativeTimestamp value={issue.created_at} /> : ""}</div>
        {issue.body_excerpt ? <p className="mt-1 line-clamp-2 text-xs text-gray-400 dark:text-gray-500">{issue.body_excerpt}</p> : null}
      </DataTable.Cell>
      <DataTable.Cell className="align-top">
        {issue.delegated ? (
          <TonePill tone="green">{t('repository.delegated')}</TonePill>
        ) : (
          <TonePill tone="gray">{t('repository.not_delegated')}</TonePill>
        )}
      </DataTable.Cell>
      <DataTable.Cell align="right" className="align-top">
        <div className="flex flex-wrap justify-end gap-1.5">
          <Button disabled={commandPending} onClick={onComment} size="sm" variant="secondary">
            {t('repository.comment')}
          </Button>
          {issue.state === "open" ? (
            <Button disabled={commandPending} onClick={onClose} size="sm" variant="secondary">
              {t('repository.close')}
            </Button>
          ) : null}
          {issue.delegated ? null : (
            <Button disabled={commandPending} onClick={onDelegate} size="sm" variant="primary">
              {t('repository.delegate')}
            </Button>
          )}
        </div>
      </DataTable.Cell>
    </DataTable.Row>
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

// Rendered by PluginRepoPageTabRoute, which passes no props: the repository
// comes from the URL and the issue list is fetched here rather than being
// threaded through the core repository payload.
export default function RepositoryIssuesTab() {
  const { t } = useT("github_source")
  const params = useParams()
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const repositoryId = params.repositoryId || ""
  const folder = resolveFolder(searchParams)
  const filterParam = searchParams.get("q") || ""

  const issues = useQuery({
    queryKey: ["repositories", repositoryId, "issues", folder, filterParam],
    queryFn: () => fetchRepositoryIssues(repositoryId, folder, filterParam),
    enabled: repositoryId.length > 0
  })
  const payload = issues.data

  return (
    <RepositoryPageShell
      activeTab="github_source.issues"
      heading={payload ? (
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <a className="hover:underline" href={payload.repository.github_url} rel="noopener" target="_blank">{payload.repository.slug}</a>
        </h1>
      ) : null}
      prefix={prefix}
      tabs={payload?.tabs ?? []}
    >
      {issues.isPending ? <PanelMessage>{t("repository.loading_issues")}</PanelMessage> : null}
      {!issues.isPending && (issues.isError || !payload) ? <PanelMessage tone="error">{t("repository.load_error")}</PanelMessage> : null}
      {payload ? (
        <RepositoryIssues
          isRefreshing={issues.isFetching}
          onRefresh={() => issues.refetch()}
          payload={payload}
          prefix={prefix}
        />
      ) : null}
    </RepositoryPageShell>
  )
}
