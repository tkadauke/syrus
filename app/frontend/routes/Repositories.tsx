import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading } from "../components/Heading"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import {
  fetchRepositories,
  unarchiveRepository,
  type RepositoriesPayload,
  type RepositoryRow
} from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"
import { linkFromSearch } from "../components/filterBar/helpers"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { FilterBar } from "../components/FilterBar"
import { useMediaQuery } from "./dashboard/components"
import { ColumnVisibilityMenu } from "../components/ColumnVisibilityMenu"
import { buttonClasses, DataTable, PanelMessage, Text, TonePill, type PillTone } from "../components/ui"

type ColumnKey =
  | "github_owner"
  | "open_jobs"
  | "last_activity"
  | "health"
  | "agent"
  | "polling_status"
  | "last_poll"
  | "trigger_label"
  | "default_branch"
  | "syrus_owner"
  | "upstream_slug"

type ColumnConfig = {
  key: ColumnKey
  labelKey: string
  defaultVisible: boolean
}

const COLUMN_CONFIG: ColumnConfig[] = [
  { key: "github_owner", labelKey: "repositories.col_github_owner", defaultVisible: true },
  { key: "open_jobs", labelKey: "repositories.col_open_jobs", defaultVisible: true },
  { key: "last_activity", labelKey: "repositories.col_last_activity", defaultVisible: true },
  { key: "health", labelKey: "repositories.col_health", defaultVisible: true },
  { key: "agent", labelKey: "repositories.col_agent", defaultVisible: true },
  { key: "polling_status", labelKey: "repositories.col_polling", defaultVisible: false },
  { key: "last_poll", labelKey: "repositories.col_last_poll", defaultVisible: false },
  { key: "trigger_label", labelKey: "repositories.col_trigger_label", defaultVisible: false },
  { key: "default_branch", labelKey: "repositories.col_default_branch", defaultVisible: false },
  { key: "syrus_owner", labelKey: "repositories.syrus_owner", defaultVisible: false },
  { key: "upstream_slug", labelKey: "repositories.col_upstream_slug", defaultVisible: false }
]

const DEFAULT_VISIBLE_COLUMNS: ColumnKey[] = COLUMN_CONFIG.filter((column) => column.defaultVisible).map((column) => column.key)
const VISIBLE_COLUMNS_STORAGE_KEY = "syrus.repositories.visible_columns"
const COLUMN_KEYS = new Set<string>(COLUMN_CONFIG.map((column) => column.key))

// A column key maps to the sort key backing it when that column is
// sortable. Columns absent from this map render a non-interactive header.
const SORT_KEY_BY_COLUMN: Partial<Record<ColumnKey, SortColumn>> = {
  open_jobs: "open_jobs_count",
  last_activity: "last_job_activity_at"
}

function readVisibleColumns(): ColumnKey[] {
  try {
    const raw = window.localStorage.getItem(VISIBLE_COLUMNS_STORAGE_KEY)
    if (!raw) return DEFAULT_VISIBLE_COLUMNS

    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return DEFAULT_VISIBLE_COLUMNS

    const filtered = parsed.filter((key): key is ColumnKey => typeof key === "string" && COLUMN_KEYS.has(key))
    return filtered.length > 0 || parsed.length === 0 ? filtered : DEFAULT_VISIBLE_COLUMNS
  } catch {
    return DEFAULT_VISIBLE_COLUMNS
  }
}

function writeVisibleColumns(columns: ColumnKey[]): void {
  try {
    window.localStorage.setItem(VISIBLE_COLUMNS_STORAGE_KEY, JSON.stringify(columns))
  } catch {
    // localStorage can be unavailable in private or restricted browser contexts.
  }
}

type SortColumn = "slug" | "open_jobs_count" | "last_job_activity_at"
type SortDirection = "ascending" | "descending"
type SortState = { column: SortColumn; direction: SortDirection }

const DEFAULT_SORT: SortState = { column: "slug", direction: "ascending" }

function toggleSort(current: SortState, column: SortColumn): SortState {
  if (current.column !== column) return { column, direction: "ascending" }
  return { column, direction: current.direction === "ascending" ? "descending" : "ascending" }
}

function sortedRepositories(repositories: RepositoryRow[], sortState: SortState): RepositoryRow[] {
  const factor = sortState.direction === "ascending" ? 1 : -1

  return [...repositories].sort((left, right) => {
    if (sortState.column === "slug") return left.slug.localeCompare(right.slug) * factor
    if (sortState.column === "open_jobs_count") return (left.open_jobs_count - right.open_jobs_count) * factor

    const leftTime = left.last_job_activity_at ? new Date(left.last_job_activity_at).getTime() : -Infinity
    const rightTime = right.last_job_activity_at ? new Date(right.last_job_activity_at).getTime() : -Infinity
    return (leftTime - rightTime) * factor
  })
}

const HEALTH_TONE: Record<string, PillTone> = {
  healthy: "green",
  broken: "red",
  inconclusive: "amber",
  unknown: "gray"
}

// Old flat dropdown param names the shared FilterBar's chip bar replaces --
// still accepted server-side for back-compat bookmarks, but FilterBar strips
// them from links it builds so a stale one never lingers alongside `q=`.
const REPOSITORY_LEGACY_FILTER_KEYS = ["slug", "github_owner", "health", "agent_provider", "has_open_jobs", "archived"]

export function RepositoriesIndex() {
  const { t } = useT("settings")
  usePageTitle(t("repositories.heading"))
  const location = useLocation()
  const repositories = useQuery({
    queryKey: ["repositories", location.search],
    queryFn: () => fetchRepositories(location.search),
    // Keeps the previously filtered table (and the mounted FilterBar/column
    // picker/select DOM nodes) on screen while a new filter's query is in
    // flight, instead of tearing the whole view down to "Loading
    // repositories..." and remounting it fresh on every filter change.
    placeholderData: keepPreviousData
  })
  const prefix = routePrefix(location.pathname)

  return (
    <main aria-label={t("aria_repositories")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {repositories.isPending ? (
        <PanelMessage>
          {t('repositories.loading')}
        </PanelMessage>
      ) : null}
      {repositories.isError ? <PanelMessage tone="error">{errorMessage(repositories.error, t("repositories.error_load"))}</PanelMessage> : null}
      {repositories.isSuccess ? (
        <RepositoriesView
          pathname={location.pathname}
          payload={repositories.data}
          prefix={prefix}
          search={location.search}
        />
      ) : null}
    </main>
  )
}

function RepositoriesView({ payload, prefix, pathname, search }: { payload: RepositoriesPayload; prefix: string; pathname: string; search: string }) {
  const { t } = useT("settings")
  const { t: tNav } = useT("nav")
  const queryClient = useQueryClient()
  const setupStatus = useSetupStatus()
  // Below the lg breakpoint the app sidebar's Repositories subnav collapses
  // into the drawer and isn't reachable, so this page falls back to an
  // in-page "Folders and filters" affordance -- the same pattern Dashboard,
  // Agent Activity, and Design Docs use to keep smart folders reachable on
  // narrow viewports.
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [visibleColumns, setVisibleColumns] = useState<ColumnKey[]>(() => readVisibleColumns())
  const columnOptions = useMemo(
    () => COLUMN_CONFIG.map((column) => ({ key: column.key, title: t(column.labelKey) })),
    [t]
  )
  const [sortState, setSortState] = useState<SortState>(DEFAULT_SORT)

  const unarchive = useMutation({
    mutationFn: (id: number) => unarchiveRepository(id),
    onSuccess: (updated) => {
      // The unarchive endpoint responds with the default (unfiltered)
      // repositories payload, not one scoped to whatever smart folder or
      // filters are currently active -- caching it directly under the
      // current search key would leave a stale/mismatched row visible
      // (e.g. the just-unarchived repo lingering in the Archived folder).
      // Invalidate instead so the active query refetches through the
      // normal filtered path.
      setNotice(updated.message || null)
      void queryClient.invalidateQueries({ queryKey: ["repositories"] })
    }
  })

  function updateVisibleColumns(next: string[]) {
    const filtered = next.filter((key): key is ColumnKey => COLUMN_KEYS.has(key))
    setVisibleColumns(filtered)
    writeVisibleColumns(filtered)
  }

  function toggleSortColumn(column: SortColumn) {
    setSortState((current) => toggleSort(current, column))
  }

  const combinedRepositories = useMemo(
    () => sortedRepositories([ ...payload.active_repositories, ...payload.archived_repositories ], sortState),
    [payload.active_repositories, payload.archived_repositories, sortState]
  )
  const activeSmartFolderId = smartFolderIdFromSearch(search) ?? payload.active_smart_folder_id
  const activeFolder = payload.smart_folders.find((folder) => folder.id === activeSmartFolderId)
  const filtersActive = search.length > 0
  const showOnboarding = !filtersActive && payload.active_repositories.length === 0 && payload.archived_repositories.length === 0

  return (
    <>
      <header className="flex items-center justify-between gap-3">
        <PageHeading>
          {t('repositories.heading')}
        </PageHeading>
        <Link className={buttonClasses("primary")} to={withRoutePrefix(payload.new_repository_path, prefix)}>{t('repositories.add')}</Link>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {unarchive.isError ? <PanelMessage tone="error">{errorMessage(unarchive.error, t("repositories.command_failed"))}</PanelMessage> : null}

      {showOnboarding ? (
        <OnboardingEmptyState
          fallbackActionPath={payload.new_repository_path}
          fallbackActionText={t("repositories.empty_action")}
          fallbackDescription={t("repositories.empty_description")}
          fallbackTitle={t("repositories.empty_title")}
          prefix={prefix}
          setupStatus={setupStatus}
        />
      ) : (
        <div className="min-w-0 space-y-4">
          {!isDesktop ? (
            <details className="group rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium">
                <span>{tNav("filters_layout.folders_and_filters")}</span>
                <Text as="span" className="group-open:hidden" muted variant="caption">{tNav("filters_layout.show")}</Text>
                <Text as="span" className="hidden group-open:inline" muted variant="caption">{tNav("filters_layout.hide")}</Text>
              </summary>
              <div className="border-t border-gray-200 p-4 dark:border-gray-700">
                <AdminSmartFolderNav
                  activeFolderId={activeSmartFolderId}
                  allowSaveWithoutActiveFolder
                  ariaLabel={tNav("sidebar_smart_folders_aria", { label: t("repositories.heading") })}
                  currentFilter={payload.filter}
                  folders={payload.smart_folders}
                  heading={t("repositories.smart_folders_heading")}
                  onMutationSuccess={() => {
                    void queryClient.invalidateQueries({ queryKey: ["repositories"] })
                  }}
                  prefix={prefix}
                  queryKey={["repositories"]}
                  subjectType="repository"
                />
              </div>
            </details>
          ) : null}
          <div className="flex flex-wrap items-start justify-between gap-3">
            <RepositoryFilterBar payload={payload} pathname={pathname} search={search} />
            <ColumnVisibilityMenu
              downLabel={t("repositories.column_down")}
              menuId="repositories-columns-menu"
              moveDownLabel={(title) => t("repositories.column_move_down", { title })}
              moveUpLabel={(title) => t("repositories.column_move_up", { title })}
              onChange={updateVisibleColumns}
              optionalColumns={columnOptions}
              triggerAriaLabel={t("repositories.columns")}
              triggerClassName="h-[var(--control-height-md)] w-[var(--control-height-md)]"
              triggerSize="icon"
              upLabel={t("repositories.column_up")}
              visibleColumns={visibleColumns}
              visibleLabel={t("repositories.visible_columns")}
            />
          </div>

          <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
            <RepositoryDataTable
              emptyMessage={emptyStateMessage(t, activeFolder)}
              onSort={toggleSortColumn}
              onUnarchive={(repository) => unarchive.mutate(repository.id)}
              prefix={prefix}
              repositories={combinedRepositories}
              sortState={sortState}
              unarchivePending={unarchive.isPending}
              visibleColumns={visibleColumns}
            />
          </section>
        </div>
      )}
    </>
  )
}

function emptyStateMessage(t: (key: string, options?: Record<string, unknown>) => string, activeFolder: AdminSmartFolder | undefined): string {
  if (!activeFolder || activeFolder.i18n_key === "repositories_all") return t("repositories.no_matches")
  if (activeFolder.i18n_key === "repositories_recent") return t("repositories.no_matches_recent")
  if (activeFolder.i18n_key === "repositories_archived") return t("repositories.no_matches_archived")
  if (activeFolder.kind === "user_defined") return t("repositories.no_matches_folder", { name: activeFolder.name })

  return t("repositories.no_matches")
}

function smartFolderIdFromSearch(search: string): number | null {
  const value = new URLSearchParams(search).get("smart_folder_id")
  if (!value) return null

  const id = Number(value)
  return Number.isInteger(id) ? id : null
}

// Uses the shared chip-bar FilterBar (the same component Dashboard, Admin
// Work Units, etc. use) instead of a bespoke set of dropdowns -- the backend
// now exposes a `filter_schema` and reads/writes the same `q=<base64-json>`
// wire format every other FilterBar-backed subject uses.
function RepositoryFilterBar({ payload, pathname, search }: { payload: RepositoriesPayload; pathname: string; search: string }) {
  const activeSmartFolderId = smartFolderIdFromSearch(search) ?? payload.active_smart_folder_id
  const activeFolder = payload.smart_folders.find((folder) => folder.id === activeSmartFolderId)
  // Editing the chip bar while a built-in folder (All/Recent/Archived) is
  // selected drops that folder's floor server-side (see
  // Repositories::Filter.smart_folder_floor), so keep the URL in sync by
  // dropping smart_folder_id too -- otherwise the sidebar would keep
  // highlighting a folder whose condition no longer applies. A user-defined
  // folder is the one case worth keeping selected while its own filter is
  // being edited (mirrors Dashboard's DashboardFilterBar).
  const keepSmartFolderOnFilter = activeFolder?.kind === "user_defined"

  return (
    <FilterBar
      buildLink={(path, currentSearch, updates) => {
        const nextUpdates = { ...updates }
        if (nextUpdates.smart_folder_id != null && !keepSmartFolderOnFilter) nextUpdates.smart_folder_id = null

        return linkFromSearch(path, currentSearch, nextUpdates)
      }}
      filter={payload.filter}
      filterSchema={payload.filter_schema}
      legacyFilterKeys={REPOSITORY_LEGACY_FILTER_KEYS}
      pathname={pathname}
      search={search}
    />
  )
}

function RepositoryDataTable({
  repositories,
  visibleColumns,
  sortState,
  onSort,
  onUnarchive,
  unarchivePending,
  emptyMessage,
  prefix
}: {
  repositories: RepositoryRow[]
  visibleColumns: ColumnKey[]
  sortState: SortState
  onSort: (column: SortColumn) => void
  onUnarchive: (repository: RepositoryRow) => void
  unarchivePending: boolean
  emptyMessage: string
  prefix: string
}) {
  const { t } = useT("settings")
  const columns = visibleColumns
    .map((key) => COLUMN_CONFIG.find((column) => column.key === key))
    .filter((column): column is ColumnConfig => column != null)

  return (
    <DataTable.Root>
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell onSort={() => onSort("slug")} sortDirection={sortState.column === "slug" ? sortState.direction : "none"}>
            {t("repositories.col_repository")}
          </DataTable.HeadCell>
          {columns.map((column) => {
            const sortColumn = SORT_KEY_BY_COLUMN[column.key]
            return (
              <DataTable.HeadCell
                key={column.key}
                onSort={sortColumn ? () => onSort(sortColumn) : undefined}
                sortDirection={sortColumn && sortState.column === sortColumn ? sortState.direction : "none"}
              >
                {t(column.labelKey)}
              </DataTable.HeadCell>
            )
          })}
          <DataTable.HeadCell><span className="sr-only">{t("repositories.col_actions")}</span></DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {repositories.length === 0 ? (
          <DataTable.Empty colSpan={columns.length + 2}>{emptyMessage}</DataTable.Empty>
        ) : (
          repositories.map((repository) => (
            <DataTable.Row key={repository.id}>
              <DataTable.Cell>
                <div className="flex items-center gap-2">
                  <Link className="font-mono text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(repository.repository_path, prefix)}>{repository.slug}</Link>
                  {repository.archived ? <TonePill tone="gray">{t("repositories.archived_badge")}</TonePill> : null}
                </div>
              </DataTable.Cell>
              {columns.map((column) => <RepositoryColumnCell column={column.key} key={column.key} repository={repository} />)}
              <DataTable.Cell className="text-right">
                {repository.archived ? (
                  <button
                    className="text-brand dark:text-brand-emphasis underline hover:no-underline disabled:text-gray-300 dark:disabled:text-gray-600"
                    disabled={unarchivePending}
                    onClick={() => onUnarchive(repository)}
                    type="button"
                  >
                    {t('repositories.unarchive')}
                  </button>
                ) : null}
              </DataTable.Cell>
            </DataTable.Row>
          ))
        )}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function RepositoryColumnCell({ repository, column }: { repository: RepositoryRow; column: ColumnKey }) {
  if (column === "github_owner") return <DataTable.Cell className="font-mono text-xs text-text-secondary">{repository.owner}</DataTable.Cell>
  if (column === "open_jobs") return <DataTable.Cell>{repository.open_jobs_count}</DataTable.Cell>
  if (column === "last_activity") return <DataTable.Cell><RelativeTimestamp value={repository.last_job_activity_at} /></DataTable.Cell>
  if (column === "health") return <DataTable.Cell><RepositoryHealthPill health={repository.main_health} /></DataTable.Cell>
  if (column === "agent") return <DataTable.Cell>{repository.agent_provider_label}</DataTable.Cell>
  if (column === "polling_status") return <DataTable.Cell><PollingPill enabled={repository.polling_enabled} /></DataTable.Cell>
  if (column === "last_poll") return <DataTable.Cell><LastPoll repository={repository} /></DataTable.Cell>
  if (column === "trigger_label") return <DataTable.Cell><code className="rounded bg-surface-subtle px-1 text-xs">{repository.trigger_label}</code></DataTable.Cell>
  if (column === "default_branch") return <DataTable.Cell className="font-mono text-xs text-text-secondary">{repository.default_branch}</DataTable.Cell>
  if (column === "syrus_owner") return <DataTable.Cell className="text-xs text-text-secondary">{repository.owner_user.email_address}</DataTable.Cell>
  if (column === "upstream_slug") {
    return (
      <DataTable.Cell className="font-mono text-xs text-text-secondary">
        {repository.upstream_slug ? `${repository.upstream_slug}${repository.upstream_default_branch ? `:${repository.upstream_default_branch}` : ""}` : "-"}
      </DataTable.Cell>
    )
  }

  return <DataTable.Cell />
}

function RepositoryHealthPill({ health }: { health: string }) {
  const { t } = useT("settings")
  const tone = HEALTH_TONE[health] ?? "gray"

  return <TonePill tone={tone}>{t(`repositories.health_${health}`, { defaultValue: health })}</TonePill>
}

function PollingPill({ enabled }: { enabled: boolean }) {
  const { t } = useT("settings")
  if (enabled) {
    return (
      <span className="inline-block rounded bg-green-100 dark:bg-green-950/40 px-2 py-0.5 text-xs text-green-700 dark:text-green-300">
        {t('repositories.polling_enabled')}
      </span>
    )
  }
  return (
    <span className="inline-block rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs text-gray-600 dark:text-gray-400">
      {t('repositories.polling_paused')}
    </span>
  )
}

function LastPoll({ repository }: { repository: RepositoryRow }) {
  const { t } = useT("settings")
  if (repository.last_poll_status === "failed") {
    return (
      <div>
        <span className="font-medium text-red-600 dark:text-red-300">
          {t('repositories.poll_failed')}
        </span>
        <span className="ml-1 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={repository.last_poll_started_at} /></span>
        {repository.last_poll_error ? <div className="mt-0.5 max-w-xs truncate font-mono text-xs text-red-500 dark:text-red-300" title={repository.last_poll_error}>{repository.last_poll_error}</div> : null}
      </div>
    )
  }

  if (repository.last_poll_status === "ok") {
    return (
      <div>
        <span className="text-green-700 dark:text-green-300">
          {t('repositories.poll_ok')}
        </span>
        <span className="ml-1 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={repository.last_poll_started_at} /></span>
      </div>
    )
  }

  return <span className="text-gray-400 dark:text-gray-500">-</span>
}
