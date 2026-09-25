import { AdminFiltersLayout } from "@app/components/AdminFiltersLayout"
import { PanelMessage } from "@app/components/PanelMessage"
import { TonePill } from "@app/components/StatusPill"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { FilterBar } from "@app/components/FilterBar"
import { SmartFolderNavigation, type SmartFolderNavFolder } from "@app/components/SmartFolderNavigation"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom"
import { useT } from "@app/hooks/useT"
import { Checkbox } from "@app/components/Checkbox"
import { NoticeToast } from "@app/components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "@app/components/OnboardingEmptyState"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { Button } from "@app/components/Button"
import { DataTable, type DataTableSortDirection } from "@app/components/ui/DataTable"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "@app/components/dataTable"
import {
  bulkRepositoryIssues,
  closeRepositoryIssue,
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

type IssueSort = RepositoryIssuesPayload["sort"]

const ISSUE_COLUMNS_STORAGE_KEY = "syrus.github_source.repository_issues.visible_columns"
const ISSUE_SORT_COLUMNS = new Set([ "number", "title", "state", "author", "created_at", "delegated" ])

function resolveSort(searchParams: URLSearchParams): IssueSort {
  const column = searchParams.get("sort")
  const direction = searchParams.get("direction")
  return {
    column: column && ISSUE_SORT_COLUMNS.has(column) ? column : "created_at",
    direction: direction === "asc" || direction === "desc" ? direction : "desc"
  }
}

function sortLink(pathname: string, search: string, sort: IssueSort, column: string) {
  const params = new URLSearchParams(search)
  const nextDirection = sort.column === column && sort.direction === "asc" ? "desc" : "asc"
  params.set("sort", column)
  params.set("direction", nextDirection)
  return `${pathname}?${params.toString()}`
}

export function RepositoryIssues({ isRefreshing, onRefresh, payload, prefix }: { isRefreshing: boolean; onRefresh: () => void; payload: RepositoryIssuesPayload; prefix: string }) {
  const { t } = useT("github_source")
  const { t: tNav } = useT("nav")
  const queryClient = useQueryClient()
  const location = useLocation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const setupStatus = useSetupStatus()
  const filterParam = searchParams.get("q") || ""
  const sort = payload.sort
  const queryKey = ["repositories", String(payload.repository.id), "issues", payload.folder, filterParam, sort.column, sort.direction] as const
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [selected, setSelected] = useState<number[]>([])
  const allSelected = payload.issues.length > 0 && selected.length === payload.issues.length
  const canBulkClose = payload.folder !== "closed"

  useEffect(() => {
    setSelected([])
  }, [payload.folder, payload.query])

  const command = useMutation({
    mutationFn: (action: IssueCommand) => {
      const folder = payload.folder
      switch (action.kind) {
        case "close":
          return closeRepositoryIssue(payload.paths.app_close_issue_path, { issueNumber: action.issueNumber, folder, filterParam, sort })
        case "delegate":
          return delegateRepositoryIssue(payload.paths.app_delegate_issue_path, { issueNumber: action.issueNumber, folder, filterParam, sort })
        case "bulk":
          return bulkRepositoryIssues(payload.paths.app_bulk_issues_path, { issueNumbers: action.issueNumbers, bulkAction: action.bulkAction, folder, filterParam, sort })
      }
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
      setSelected([])
    }
  })
  const columns = useMemo(() => buildIssueColumns({
    allSelected,
    commandPending: command.isPending,
    onClose: (issue) => command.mutate({ kind: "close", issueNumber: issue.number }),
    onDelegate: (issue) => command.mutate({ kind: "delegate", issueNumber: issue.number }),
    onToggle: toggleIssue,
    onToggleAll: toggleAll,
    selected,
    t
  }), [ allSelected, command.isPending, selected, t ])
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: ISSUE_COLUMNS_STORAGE_KEY })

  function toggleIssue(number: number) {
    setSelected((current) => current.includes(number) ? current.filter((value) => value !== number) : [...current, number])
  }

  function toggleAll() {
    setSelected((current) => current.length === payload.issues.length ? [] : payload.issues.map((issue) => issue.number))
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

            <div className="flex justify-end">
              <DataTableColumnMenu
                columns={columns}
                downLabel={t("repository.column_down")}
                menuId="repository-issues-columns-menu"
                moveDownLabel={(title) => t("repository.column_move_down", { title })}
                moveUpLabel={(title) => t("repository.column_move_up", { title })}
                onChange={preferences.onChange}
                order={preferences.order}
                triggerAriaLabel={t("repository.columns")}
                upLabel={t("repository.column_up")}
                visibleLabel={t("repository.visible_columns")}
              />
            </div>

            <DataTable.Root wrapperClassName="mt-3">
              <DataTable.Header>
                <DataTableColumnHeaderRow
                  columns={columns}
                  onReorder={preferences.onChange}
                  onSort={(column) => navigate(sortLink(location.pathname, location.search, sort, column))}
                  order={preferences.order}
                  sortColumn={sort.column}
                  sortDirection={sortDirection(sort)}
                />
              </DataTable.Header>
              <DataTable.Body>
                {payload.issues.map((issue) => (
                  <DataTable.Row key={issue.number}>
                    <DataTableColumnCells columns={columns} order={preferences.order} row={issue} />
                  </DataTable.Row>
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

    </>
  )
}

function emptyStateActionPath(payload: RepositoryIssuesPayload) {
  return payload.folder === "open" ? payload.paths.github_issues_path : payload.folder_paths.open
}

function buildIssueColumns({
  allSelected,
  commandPending,
  onClose,
  onDelegate,
  onToggle,
  onToggleAll,
  selected,
  t
}: {
  allSelected: boolean
  commandPending: boolean
  onClose: (issue: RepositoryIssue) => void
  onDelegate: (issue: RepositoryIssue) => void
  onToggle: (number: number) => void
  onToggleAll: () => void
  selected: number[]
  t: (key: string, options?: Record<string, unknown>) => string
}): DataTableColumnDef<RepositoryIssue>[] {
  return [
    {
      key: "select",
      label: t("repository.col_select"),
      required: true,
      renderHeader: () => <Checkbox aria-label={t("repository.select_all")} checked={allSelected} onChange={onToggleAll} />,
      renderCell: (issue) => (
        <Checkbox aria-label={t("repository.select_issue", { number: issue.number })} checked={selected.includes(issue.number)} onChange={() => onToggle(issue.number)} />
      ),
      headClassName: "w-10 px-3",
      cellClassName: "w-10 px-3 align-top"
    },
    {
      key: "issue",
      label: t("repository.col_issue"),
      required: true,
      sortKey: "title",
      renderCell: (issue) => (
        <>
          <div className="flex flex-wrap items-baseline gap-2">
            <a className="font-mono text-gray-500 hover:underline dark:text-gray-400" href={issue.html_url} rel="noopener" target="_blank">#{issue.number}</a>
            {issue.labels.map((label) => <IssueLabel color={label.color} key={label.name} name={label.name} />)}
            <a className="font-medium text-gray-900 hover:underline dark:text-gray-100" href={issue.html_url} rel="noopener" target="_blank">{issue.title}</a>
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
            <span>{issue.user_login ? `${issue.user_login} · ` : ""}{issue.created_at ? <RelativeTimestamp value={issue.created_at} /> : ""}</span>
            {issue.linked_pull_request ? (
              <a className="font-medium text-brand hover:underline dark:text-brand-emphasis" href={issue.linked_pull_request.url} rel="noopener" target="_blank">
                {t("repository.linked_pull_request", { number: issue.linked_pull_request.number })}
              </a>
            ) : null}
          </div>
          {issue.body_excerpt ? <p className="mt-1 line-clamp-2 text-xs text-gray-400 dark:text-gray-500">{issue.body_excerpt}</p> : null}
        </>
      ),
      cellClassName: "align-top"
    },
    {
      key: "number",
      label: t("repository.col_number"),
      sortKey: "number",
      responsiveClassName: "hidden md:table-cell",
      cellClassName: "font-mono text-gray-500 dark:text-gray-400",
      renderCell: (issue) => `#${issue.number}`
    },
    {
      key: "state",
      label: t("repository.col_state"),
      sortKey: "state",
      responsiveClassName: "hidden sm:table-cell",
      renderCell: (issue) => issue.state
    },
    {
      key: "status",
      label: t("repository.col_status"),
      sortKey: "delegated",
      renderCell: (issue) => issue.delegated ? <TonePill tone="green">{t("repository.delegated")}</TonePill> : <TonePill tone="gray">{t("repository.not_delegated")}</TonePill>,
      cellClassName: "align-top"
    },
    {
      key: "author",
      label: t("repository.col_author"),
      sortKey: "author",
      responsiveClassName: "hidden lg:table-cell",
      cellClassName: "text-gray-600 dark:text-gray-400",
      renderCell: (issue) => issue.user_login || "-"
    },
    {
      key: "created",
      label: t("repository.col_created"),
      sortKey: "created_at",
      responsiveClassName: "hidden lg:table-cell",
      cellClassName: "text-gray-500 dark:text-gray-400",
      renderCell: (issue) => issue.created_at ? <RelativeTimestamp value={issue.created_at} /> : "-"
    },
    {
      key: "actions",
      label: t("repository.col_actions"),
      required: true,
      pin: "end",
      align: "right",
      renderCell: (issue) => (
        <div className="flex flex-wrap justify-end gap-1.5">
          {issue.state === "open" ? (
            <Button disabled={commandPending} onClick={() => onClose(issue)} size="sm" variant="secondary">
              {t("repository.close")}
            </Button>
          ) : null}
          {issue.delegated ? null : (
            <Button disabled={commandPending} onClick={() => onDelegate(issue)} size="sm" variant="primary">
              {t("repository.delegate")}
            </Button>
          )}
        </div>
      ),
      cellClassName: "align-top"
    }
  ]
}

function sortDirection(sort: IssueSort): DataTableSortDirection {
  return sort.direction === "asc" ? "ascending" : "descending"
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
  const sort = resolveSort(searchParams)

  const issues = useQuery({
    queryKey: ["repositories", repositoryId, "issues", folder, filterParam, sort.column, sort.direction],
    queryFn: () => fetchRepositoryIssues(repositoryId, folder, filterParam, sort),
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
