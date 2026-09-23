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
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  visibleColumns as visibleDataTableColumns,
  type DataTableColumnDef
} from "../components/dataTable"
import { buttonClasses, DataTable, Page, PanelMessage, Text, TonePill, usePageGutterRestoreClassName, type PillTone } from "../components/ui"
import { classes } from "../components/ui/classes"

const VISIBLE_COLUMNS_STORAGE_KEY = "syrus.repositories.visible_columns"

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

// The shared configurable-column model for the Repositories table: required
// Repository/Actions columns pinned at each end (never hidden, never
// draggable) with the optional columns in between selectable/reorderable
// through DataTableColumnMenu (picker) and DataTableColumnHeaderRow (header
// drag). Built fresh per render -- cheap, and matches how the primitive's own
// integration test composes it -- rather than memoized, so it always reflects
// the latest translations/callbacks.
function buildRepositoryColumns({
  t,
  prefix,
  onUnarchive,
  unarchivePending
}: {
  t: (key: string, opts?: Record<string, unknown>) => string
  prefix: string
  onUnarchive: (repository: RepositoryRow) => void
  unarchivePending: boolean
}): DataTableColumnDef<RepositoryRow>[] {
  return [
    {
      key: "repository",
      label: t("repositories.col_repository"),
      required: true,
      sortKey: "slug",
      renderCell: (repository) => (
        <div className="flex items-center gap-2">
          <Link className="font-mono text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(repository.repository_path, prefix)}>{repository.slug}</Link>
          {repository.archived ? <TonePill tone="gray">{t("repositories.archived_badge")}</TonePill> : null}
        </div>
      )
    },
    {
      key: "github_owner",
      label: t("repositories.col_github_owner"),
      cellClassName: "font-mono text-xs text-text-secondary",
      renderCell: (repository) => repository.owner
    },
    {
      key: "open_jobs",
      label: t("repositories.col_open_jobs"),
      sortKey: "open_jobs_count",
      renderCell: (repository) => repository.open_jobs_count
    },
    {
      key: "last_activity",
      label: t("repositories.col_last_activity"),
      sortKey: "last_job_activity_at",
      renderCell: (repository) => <RelativeTimestamp value={repository.last_job_activity_at} />
    },
    {
      key: "health",
      label: t("repositories.col_health"),
      renderCell: (repository) => <RepositoryHealthPill health={repository.main_health} />
    },
    {
      key: "agent",
      label: t("repositories.col_agent"),
      renderCell: (repository) => repository.agent_provider_label
    },
    {
      key: "polling_status",
      label: t("repositories.col_polling"),
      defaultVisible: false,
      renderCell: (repository) => <PollingPill enabled={repository.polling_enabled} />
    },
    {
      key: "last_poll",
      label: t("repositories.col_last_poll"),
      defaultVisible: false,
      renderCell: (repository) => <LastPoll repository={repository} />
    },
    {
      key: "trigger_label",
      label: t("repositories.col_trigger_label"),
      defaultVisible: false,
      renderCell: (repository) => <code className="rounded bg-surface-subtle px-1 text-xs">{repository.trigger_label}</code>
    },
    {
      key: "default_branch",
      label: t("repositories.col_default_branch"),
      defaultVisible: false,
      cellClassName: "font-mono text-xs text-text-secondary",
      renderCell: (repository) => repository.default_branch
    },
    {
      key: "syrus_owner",
      label: t("repositories.syrus_owner"),
      defaultVisible: false,
      cellClassName: "text-xs text-text-secondary",
      renderCell: (repository) => repository.owner_user.email_address
    },
    {
      key: "upstream_slug",
      label: t("repositories.col_upstream_slug"),
      defaultVisible: false,
      cellClassName: "font-mono text-xs text-text-secondary",
      renderCell: (repository) => repository.upstream_slug ? `${repository.upstream_slug}${repository.upstream_default_branch ? `:${repository.upstream_default_branch}` : ""}` : "-"
    },
    {
      key: "actions",
      label: t("repositories.col_actions"),
      required: true,
      pin: "end",
      align: "right",
      renderHeader: () => <span className="sr-only">{t("repositories.col_actions")}</span>,
      renderCell: (repository) => repository.archived ? (
        <button
          className="text-brand dark:text-brand-emphasis underline hover:no-underline disabled:text-gray-300 dark:disabled:text-gray-600"
          disabled={unarchivePending}
          onClick={() => onUnarchive(repository)}
          type="button"
        >
          {t('repositories.unarchive')}
        </button>
      ) : null
    }
  ]
}

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
    <Page.Root aria-label={t("aria_repositories")} gutter="responsive" size="wide">
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
    </Page.Root>
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
  const [sortState, setSortState] = useState<SortState>(DEFAULT_SORT)
  const marginGutterRestore = usePageGutterRestoreClassName("margin")

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

  const columns = buildRepositoryColumns({
    onUnarchive: (repository) => unarchive.mutate(repository.id),
    prefix,
    t,
    unarchivePending: unarchive.isPending
  })
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: VISIBLE_COLUMNS_STORAGE_KEY })

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
      <Page.Header className="items-center gap-3">
        <PageHeading>
          {t('repositories.heading')}
        </PageHeading>
        <Link className={buttonClasses("primary")} to={withRoutePrefix(payload.new_repository_path, prefix)}>{t('repositories.add')}</Link>
      </Page.Header>

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
            <details className={classes("group rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900", marginGutterRestore)}>
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
          <div className={classes("flex flex-wrap items-start justify-between gap-3", marginGutterRestore)}>
            <RepositoryFilterBar payload={payload} pathname={pathname} search={search} />
            <DataTableColumnMenu
              columns={columns}
              downLabel={t("repositories.column_down")}
              menuId="repositories-columns-menu"
              moveDownLabel={(title) => t("repositories.column_move_down", { title })}
              moveUpLabel={(title) => t("repositories.column_move_up", { title })}
              onChange={preferences.onChange}
              order={preferences.order}
              triggerAriaLabel={t("repositories.columns")}
              triggerClassName="h-[var(--control-height-md)] w-[var(--control-height-md)]"
              triggerSize="icon"
              upLabel={t("repositories.column_up")}
              visibleLabel={t("repositories.visible_columns")}
            />
          </div>

          <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
            <RepositoryDataTable
              columns={columns}
              emptyMessage={emptyStateMessage(t, activeFolder)}
              onReorder={preferences.onChange}
              onSort={toggleSortColumn}
              order={preferences.order}
              repositories={combinedRepositories}
              sortState={sortState}
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
  columns,
  repositories,
  order,
  onReorder,
  sortState,
  onSort,
  emptyMessage
}: {
  columns: DataTableColumnDef<RepositoryRow>[]
  repositories: RepositoryRow[]
  order: string[] | null | undefined
  onReorder: (nextOrder: string[]) => void
  sortState: SortState
  onSort: (column: SortColumn) => void
  emptyMessage: string
}) {
  const colSpan = visibleDataTableColumns({ columns, order }).length

  return (
    <DataTable.Root>
      <DataTable.Header>
        <DataTableColumnHeaderRow
          columns={columns}
          onReorder={onReorder}
          onSort={(key) => onSort(key as SortColumn)}
          order={order}
          sortColumn={sortState.column}
          sortDirection={sortState.direction}
        />
      </DataTable.Header>
      <DataTable.Body>
        {repositories.length === 0 ? (
          <DataTable.Empty colSpan={colSpan}>{emptyMessage}</DataTable.Empty>
        ) : (
          repositories.map((repository) => (
            <DataTable.Row key={repository.id}>
              <DataTableColumnCells columns={columns} order={order} row={repository} />
            </DataTable.Row>
          ))
        )}
      </DataTable.Body>
    </DataTable.Root>
  )
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
