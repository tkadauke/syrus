import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading } from "../components/Heading"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
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
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { Button, buttonClasses, Checkbox, DataTable, Input, PanelMessage, Select, Surface, Text, TonePill, type PillTone } from "../components/ui"

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

    const validKeys = new Set<string>(COLUMN_CONFIG.map((column) => column.key))
    const filtered = parsed.filter((key): key is ColumnKey => typeof key === "string" && validKeys.has(key))
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

const HEALTH_FILTER_VALUES = ["healthy", "broken", "inconclusive", "unknown"] as const

const HEALTH_TONE: Record<string, PillTone> = {
  healthy: "green",
  broken: "red",
  inconclusive: "amber",
  unknown: "gray"
}

function readRepositoryFilters(search: string) {
  const params = new URLSearchParams(search)
  return {
    slug: params.get("slug") ?? "",
    github_owner: params.get("github_owner") ?? "",
    health: params.get("health") ?? "",
    agent_provider: params.get("agent_provider") ?? "",
    has_open_jobs: params.get("has_open_jobs") === "true"
  }
}

function uniqueSorted(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean))).sort((left, right) => left.localeCompare(right))
}

function agentOptionsFrom(repositories: RepositoryRow[]): Array<{ value: string; label: string }> {
  const byValue = new Map<string, string>()
  repositories.forEach((repository) => {
    if (!repository.agent_provider) return
    if (!byValue.has(repository.agent_provider)) byValue.set(repository.agent_provider, repository.agent_provider_label)
  })
  return Array.from(byValue.entries())
    .map(([value, label]) => ({ value, label }))
    .sort((left, right) => left.label.localeCompare(right.label))
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
  // A separate, always-unfiltered fetch backing the owner/agent filter
  // dropdown option lists. Sourcing those options from `repositories.data`
  // instead would narrow them by whatever filters are already applied
  // (including the filter's own dimension), so picking a value could make
  // every other option -- and a way back to it -- disappear.
  const filterOptions = useQuery({
    queryKey: ["repositories", "filter-options"],
    queryFn: () => fetchRepositories(),
    staleTime: 60_000
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
          filterOptionsPayload={filterOptions.data ?? repositories.data}
          pathname={location.pathname}
          payload={repositories.data}
          prefix={prefix}
          search={location.search}
        />
      ) : null}
    </main>
  )
}

function RepositoriesView({ payload, filterOptionsPayload, prefix, pathname, search }: { payload: RepositoriesPayload; filterOptionsPayload: RepositoriesPayload; prefix: string; pathname: string; search: string }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const setupStatus = useSetupStatus()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [visibleColumns, setVisibleColumns] = useState<ColumnKey[]>(() => readVisibleColumns())
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

  function toggleColumn(column: ColumnKey, visible: boolean) {
    setVisibleColumns((current) => {
      const next = visible ? Array.from(new Set([...current, column])) : current.filter((key) => key !== column)
      writeVisibleColumns(next)
      return next
    })
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
          <div className="flex flex-wrap items-end justify-between gap-3">
            <RepositoryFilterBar optionsPayload={filterOptionsPayload} pathname={pathname} search={search} />
            <RepositoryColumnPicker onToggle={toggleColumn} visibleColumns={visibleColumns} />
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

function RepositoryFilterBar({ optionsPayload, pathname, search }: { optionsPayload: RepositoriesPayload; pathname: string; search: string }) {
  const { t } = useT("settings")
  const navigate = useNavigate()
  const filters = useMemo(() => readRepositoryFilters(search), [search])
  const [slugDraft, setSlugDraft] = useState(filters.slug)

  useEffect(() => {
    setSlugDraft(filters.slug)
  }, [filters.slug])

  useEffect(() => {
    if (slugDraft === filters.slug) return

    const timeout = window.setTimeout(() => {
      navigate(linkFromSearch(pathname, search, { slug: slugDraft || null }), { replace: true })
    }, 300)
    return () => window.clearTimeout(timeout)
    // Only the draft value should retrigger the debounce timer; re-running it
    // off filters.slug/search would cancel the pending navigation the moment
    // it fires (search changes as soon as this timeout calls navigate).
  }, [slugDraft])

  // Sourced from the always-unfiltered optionsPayload (see RepositoriesIndex)
  // so picking a value -- or narrowing via any other filter, including a
  // dropdown's own dimension -- never removes other choices from the list.
  const allRepositories = useMemo(() => [...optionsPayload.active_repositories, ...optionsPayload.archived_repositories], [optionsPayload])
  const ownerOptions = useMemo(
    () => uniqueSorted([...allRepositories.map((repository) => repository.owner), ...(filters.github_owner ? [filters.github_owner] : [])]),
    [allRepositories, filters.github_owner]
  )
  const agentOptions = useMemo(() => {
    const options = agentOptionsFrom(allRepositories)
    if (filters.agent_provider && !options.some((option) => option.value === filters.agent_provider)) {
      options.push({ value: filters.agent_provider, label: filters.agent_provider })
    }
    return options
  }, [allRepositories, filters.agent_provider])

  function updateParam(key: string, value: string | null) {
    navigate(linkFromSearch(pathname, search, { [key]: value }))
  }

  const hasFilters = Boolean(filters.slug || filters.github_owner || filters.health || filters.agent_provider || filters.has_open_jobs)

  return (
    <div className="flex flex-wrap items-end gap-3">
      <label className="flex flex-col gap-1 text-xs font-medium uppercase text-text-muted">
        {t("repositories.filter_search")}
        <Input
          className="w-56"
          onChange={(event) => setSlugDraft(event.target.value)}
          placeholder={t("repositories.filter_search_placeholder")}
          type="search"
          value={slugDraft}
        />
      </label>
      <label className="flex flex-col gap-1 text-xs font-medium uppercase text-text-muted">
        {t("repositories.filter_owner")}
        <Select className="w-40" fullWidth={false} onChange={(event) => updateParam("github_owner", event.target.value || null)} value={filters.github_owner}>
          <option value="">{t("repositories.filter_all")}</option>
          {ownerOptions.map((owner) => <option key={owner} value={owner}>{owner}</option>)}
        </Select>
      </label>
      <label className="flex flex-col gap-1 text-xs font-medium uppercase text-text-muted">
        {t("repositories.filter_health")}
        <Select className="w-40" fullWidth={false} onChange={(event) => updateParam("health", event.target.value || null)} value={filters.health}>
          <option value="">{t("repositories.filter_all")}</option>
          {HEALTH_FILTER_VALUES.map((value) => <option key={value} value={value}>{t(`repositories.health_${value}`)}</option>)}
        </Select>
      </label>
      <label className="flex flex-col gap-1 text-xs font-medium uppercase text-text-muted">
        {t("repositories.filter_agent")}
        <Select className="w-40" fullWidth={false} onChange={(event) => updateParam("agent_provider", event.target.value || null)} value={filters.agent_provider}>
          <option value="">{t("repositories.filter_all")}</option>
          {agentOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </Select>
      </label>
      <Checkbox
        checked={filters.has_open_jobs}
        label={t("repositories.filter_has_open_jobs")}
        onChange={(event) => updateParam("has_open_jobs", event.target.checked ? "true" : null)}
      />
      {hasFilters ? (
        <button className="text-sm text-text-muted underline hover:text-text-primary" onClick={() => navigate(pathname)} type="button">
          {t("repositories.filter_clear")}
        </button>
      ) : null}
    </div>
  )
}

function RepositoryColumnPicker({ visibleColumns, onToggle }: { visibleColumns: ColumnKey[]; onToggle: (column: ColumnKey, visible: boolean) => void }) {
  const { t } = useT("settings")
  const [open, setOpen] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))

  return (
    <div className="relative" ref={menuRef}>
      <Button
        aria-controls="repositories-columns-menu"
        aria-expanded={open}
        aria-haspopup="menu"
        onClick={() => setOpen((current) => !current)}
        size="sm"
        variant="secondary"
      >
        {t("repositories.columns")}
      </Button>
      {open ? (
        <Surface className="absolute right-0 z-20 mt-2 w-64 shadow-lg" id="repositories-columns-menu" padding="sm" role="menu">
          <fieldset className="space-y-2">
            <Text as="legend" muted variant="label">{t("repositories.visible_columns")}</Text>
            {COLUMN_CONFIG.map((column) => (
              <label className="flex items-center gap-2 text-sm text-text-primary" key={column.key}>
                <Checkbox
                  checked={visibleColumns.includes(column.key)}
                  onChange={(event) => onToggle(column.key, event.target.checked)}
                />
                <span>{t(column.labelKey)}</span>
              </label>
            ))}
          </fieldset>
        </Surface>
      ) : null}
    </div>
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
  const columns = COLUMN_CONFIG.filter((column) => visibleColumns.includes(column.key))

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
