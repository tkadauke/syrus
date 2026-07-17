import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { DragEvent, ReactNode } from "react"
import { Children, useEffect, useMemo, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { useT } from "../hooks/useT"
import { useBackendOutage } from "../hooks/useBackendUpdate"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { ApiError } from "../api/client"
import { CopyableSlug } from "../components/CopyableSlug"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { DashboardSmartFolderNav } from "../components/DashboardSmartFolderNav"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { NoticeToast } from "../components/NoticeToast"
import { CloseIcon } from "../components/CloseIcon"
import { StatusPill, TonePill } from "../components/StatusPill"
import { FilterBar } from "../components/FilterBar"
import { workflowSlug } from "../lib/slugs"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { bulkDashboardEpics, bulkDashboardJobs, dashboardApiSearch, fetchDashboardChrome, fetchDashboardRows, mergeDashboardPayload, recordDashboardFilterUsage, updateDashboardEpicState, updateDashboardPreferences, type DashboardHealthBlockedRepository, type DashboardBulkEpicAction, type DashboardBulkJobAction, type DashboardEpicItem, type DashboardItem, type DashboardJobItem, type DashboardLandingQueueEntry, type DashboardLane, type DashboardPayload, type DashboardRepository, type DashboardSubject, type DashboardWorkflowItem } from "../api/dashboard"
import type { LandingQueueBlockerJob } from "../api/jobs"

const KANBAN_CARDS_PER_PAGE = 20

export function DashboardRoute() {
  const location = useLocation()
  const search = dashboardApiSearch(location.pathname, location.search)
  const dashboardChrome = useQuery({
    queryKey: ["dashboard", "chrome", search],
    queryFn: ({ signal }) => fetchDashboardChrome(search, { signal }),
    placeholderData: (previousData) => previousData
  })
  const dashboardRows = useQuery({
    queryKey: ["dashboard", "rows", search],
    queryFn: ({ signal }) => fetchDashboardRows(search, { signal }),
    placeholderData: (previousData) => previousData
  })
  const payload = useMemo(() => {
    if (!dashboardChrome.data || !dashboardRows.data) return null

    return mergeDashboardPayload(dashboardChrome.data, dashboardRows.data)
  }, [dashboardChrome.data, dashboardRows.data])

  const { t } = useT("dashboard")
  if (!payload && (dashboardChrome.isPending || dashboardRows.isPending)) return <main aria-label={t("title")} className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("loading")}</main>
  if (dashboardChrome.isError) return <DashboardError error={dashboardChrome.error} />
  if (dashboardRows.isError) return <DashboardError error={dashboardRows.error} />
  if (!payload) return <main aria-label={t("title")} className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("loading")}</main>

  return <DashboardView pathname={location.pathname} search={location.search} payload={payload} />
}

function DashboardView({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const initialBootstrap = readInitialBootstrap()
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: initialBootstrap != null,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const readiness = bootstrap.data?.setup_status?.readiness
  const { t } = useT("dashboard")

  return (
    <main aria-label={t("title")} className="mx-auto max-w-[96rem] space-y-5 p-6">
      <header className="flex flex-wrap items-center gap-3">
        <h1 className="flex-1 text-3xl font-semibold text-gray-900 dark:text-white">{t("title")}</h1>
        {isDesktop ? <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={true} /> : null}
        <DashboardCreateActions payload={payload} prefix={prefix} />
      </header>
      <ReadinessPanel prefix={prefix} readiness={readiness} />
      <RepositoryHealthBanners prefix={prefix} repositories={payload.health_blocked_repositories ?? payload.broken_repositories ?? []} />

      {isDesktop ? (
        <>
          <DesktopDashboardControls pathname={pathname} payload={payload} search={search} />
          <DashboardContent pathname={pathname} payload={payload} prefix={prefix} search={search} />
        </>
      ) : (
        <>
          <MobileDashboardControls pathname={pathname} payload={payload} prefix={prefix} search={search} />
          <DashboardContent pathname={pathname} payload={payload} prefix={prefix} search={search} />
        </>
      )}
    </main>
  )
}

export function ReadinessPanel({ prefix, readiness }: { prefix: string; readiness?: NonNullable<NonNullable<BootstrapPayload["setup_status"]>["readiness"]> }) {
  const { t } = useT("dashboard")
  // While the desktop shell's backend update has the containers down,
  // readiness checks fail because the backend is deliberately unreachable —
  // showing them would read as "credentials gone". The sidebar's notice
  // explains what's happening; the warnings return the moment the update
  // ends. During the image-pull half of an update the old backend still
  // serves, so outage stays false and the panel behaves normally.
  const backendOutage = useBackendOutage()
  if (backendOutage) return null
  if (!readiness || readiness.status === "ok") return null

  const failingChecks = readiness.checks.filter((check) => check.status !== "ok")
  if (failingChecks.length === 0) return null

  return (
    <section aria-label={t("system_readiness")} className="rounded border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950/40">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-amber-950 dark:text-amber-100">{t("readiness_title")}</h2>
          <p className="mt-1 text-sm text-amber-900 dark:text-amber-200">{t("readiness_description")}</p>
        </div>
        <Link className="rounded border border-amber-300 bg-white px-3 py-1.5 text-sm font-medium text-amber-900 hover:bg-amber-100 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100 dark:hover:bg-amber-900" to={`${prefix}/credentials`}>
          {t("open_settings")}
        </Link>
      </div>
      <div className="mt-3 grid gap-2 lg:grid-cols-2">
        {failingChecks.map((check) => (
          <div className="rounded border border-amber-200 bg-white p-3 dark:border-amber-900 dark:bg-gray-950" key={check.key}>
            <div className="flex items-center gap-2">
              <TonePill tone={check.status === "error" ? "red" : "amber"}>{check.status}</TonePill>
              <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{check.label}</h3>
              {check.optional ? <span className="text-xs text-gray-500 dark:text-gray-400">{t("optional")}</span> : null}
            </div>
            <p className="mt-2 text-sm text-gray-700 dark:text-gray-200">{check.message}</p>
            {check.remediation ? <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">{check.remediation}</p> : null}
          </div>
        ))}
      </div>
    </section>
  )
}

function RepositoryHealthBanners({ prefix, repositories }: { prefix: string; repositories: DashboardHealthBlockedRepository[] }) {
  const { t } = useT("dashboard")
  const [dismissed, setDismissed] = useState<Set<number>>(() => new Set())
  const visible = repositories.filter((repo) => !dismissed.has(repo.id))

  if (visible.length === 0) return null

  return (
    <div className="space-y-2">
      {visible.map((repo) => (
        <div className="flex items-center justify-between gap-3 rounded border border-red-200 bg-red-50 px-4 py-3 text-sm dark:border-red-900 dark:bg-red-950/40" key={repo.id} role="alert">
          <span className="text-red-800 dark:text-red-200">
            <span className="font-mono font-medium">{repo.slug}</span>
            {" — "}{t(repo.main_health === "inconclusive"
              ? (repo.landing_paused ? "main_health_inconclusive_banner" : "main_health_inconclusive_banner_not_held")
              : (repo.landing_paused ? "broken_main_banner" : "broken_main_banner_not_held")
            )}
          </span>
          <div className="flex shrink-0 items-center gap-2">
            <Link
              className="rounded border border-red-300 bg-white px-2 py-1 text-xs font-medium text-red-800 hover:bg-red-50 dark:border-red-800 dark:bg-red-950 dark:text-red-200 dark:hover:bg-red-900"
              to={withRoutePrefix(repo.repository_path, prefix)}
            >
              {t("broken_main_view_details")}
            </Link>
            <button
              aria-label={t("broken_main_dismiss")}
              className="text-red-500 hover:text-red-700 dark:text-red-400 dark:hover:text-red-200"
              onClick={() => setDismissed((prev) => new Set([...prev, repo.id]))}
              type="button"
            >
              <CloseIcon />
            </button>
          </div>
        </div>
      ))}
    </div>
  )
}

function DesktopDashboardControls({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  return (
    <div className="flex min-w-0 flex-col gap-3 lg:flex-row lg:items-center">
      <div className="min-w-0 flex-1">
        <DashboardFilterBar pathname={pathname} search={search} payload={payload} />
      </div>
      <OwnershipControls pathname={pathname} search={search} payload={payload} />
    </div>
  )
}

function MobileDashboardControls({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  const { t } = useT("dashboard")
  return (
    <div className="space-y-3">
      <div aria-label={t("controls_label")} className="flex items-center justify-between gap-3 pb-1" role="group">
        <div className="min-w-0 flex-1 overflow-x-auto">
          <SubjectTabs className="inline-flex w-max flex-nowrap overflow-hidden rounded border border-gray-300 bg-white text-sm dark:border-gray-700 dark:bg-gray-900" payload={payload} prefix={prefix} />
        </div>
        <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={false} />
      </div>
      <details className="group rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium text-gray-700 dark:text-gray-200">
          <span>{t("folders_and_filters")}</span>
          <span className="text-gray-400 group-open:hidden dark:text-gray-500">{t("show")}</span>
          <span className="hidden text-gray-400 group-open:inline dark:text-gray-500">{t("hide")}</span>
        </summary>
        <div className="space-y-4 border-t border-gray-200 p-4 dark:border-gray-700">
          <OwnershipControls pathname={pathname} search={search} payload={payload} />
          <DashboardFilterBar pathname={pathname} search={search} payload={payload} />
          <DashboardSmartFolderNav payload={payload} prefix={prefix} search={search} />
        </div>
      </details>
    </div>
  )
}

function OwnershipControls({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  const { t } = useT("dashboard")
  const navigate = useNavigate()
  if (payload.subject === "epic" || payload.subject === "job") return null
  if (payload.ownership.team_user_count <= 1) return null

  function scopeLink(scope: string) {
    return dashboardLinkFromSearch(pathname, search, {
      ownership_scope: scope === "mine" ? null : scope,
      owner_id: scope === "user" ? payload.ownership.owner_id : null,
      page: null
    })
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <nav aria-label={t("ownership_scope_label")} className="inline-flex overflow-hidden rounded border border-gray-300 bg-white text-sm dark:border-gray-700 dark:bg-gray-900">
        {payload.controls.ownership_scopes.map((scope) => (
          <Link
            className={`px-3 py-1.5 font-medium ${payload.ownership.scope === scope.value ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-950" : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"}`}
            key={scope.value}
            to={scopeLink(scope.value)}
          >
            {scope.label}
          </Link>
        ))}
      </nav>
      {payload.ownership.scope === "user" ? (
        <label className="sr-only" htmlFor="dashboard-owner-filter">{t("owner_filter_label")}</label>
      ) : null}
      {payload.ownership.scope === "user" ? (
        <select
          className="h-9 rounded border border-gray-300 bg-white px-2 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          id="dashboard-owner-filter"
          onChange={(event) => navigate(dashboardLinkFromSearch(pathname, search, { ownership_scope: "user", owner_id: event.target.value, page: null }))}
          value={payload.ownership.owner_id ?? ""}
        >
          {payload.controls.owners.map((owner) => <option key={owner.id} value={owner.id}>{owner.label}</option>)}
        </select>
      ) : null}
    </div>
  )
}

function DashboardContent({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  const setupStatus = useSetupStatus()

  return (
    <section className="min-w-0 space-y-4">
      <DashboardTable payload={payload} prefix={prefix} setupStatus={setupStatus} />
      {payload.view === "list" ? <Pagination pathname={pathname} search={search} payload={payload} /> : null}
    </section>
  )
}

function useMediaQuery(query: string, defaultMatches: boolean) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches

    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const updateMatches = () => setMatches(media.matches)
    updateMatches()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", updateMatches)
      return () => media.removeEventListener("change", updateMatches)
    }

    media.addListener(updateMatches)
    return () => media.removeListener(updateMatches)
  }, [query])

  return matches
}

function DashboardCreateActions({ payload, prefix }: { payload: DashboardPayload; prefix: string }) {
  const { t } = useT("dashboard")
  return (
    <div className="flex flex-wrap gap-2">
      <Link className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500" to={withRoutePrefix(payload.paths.new_epic_path, prefix)}>{t("new_epic")}</Link>
      <Link className="rounded bg-green-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-green-500" to={withRoutePrefix(payload.paths.new_job_path, prefix)}>{t("new_job")}</Link>
    </div>
  )
}

function SubjectTabs({ payload, prefix, className = "inline-flex w-max overflow-hidden rounded border border-gray-300 bg-white text-sm dark:border-gray-700 dark:bg-gray-900" }: { payload: DashboardPayload; prefix: string; className?: string }) {
  const { t } = useT("dashboard")
  const subjects: Array<{ key: DashboardSubject; label: string; path: string }> = [
    { key: "epic", label: t("tab_epics"), path: "/dashboard/epics" },
    { key: "job", label: t("tab_jobs"), path: "/dashboard/jobs" },
    { key: "workflow", label: t("tab_workflows"), path: "/dashboard/workflows" }
  ]

  return (
    <nav aria-label={t("subjects")} className={className}>
      {subjects.map((subject) => (
        <Link
          className={`px-3 py-1.5 font-medium ${payload.subject === subject.key ? "bg-blue-50 text-blue-700 ring-1 ring-inset ring-blue-600 dark:bg-blue-950 dark:text-blue-200 dark:ring-blue-500" : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"}`}
          key={subject.key}
          to={withRoutePrefix(subject.path, prefix)}
        >
          {subject.label}
        </Link>
      ))}
    </nav>
  )
}

function DashboardToolbar({ payload, pathname, search, showConfiguration = true }: { payload: DashboardPayload; pathname: string; search: string; showConfiguration?: boolean }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [columnsOpen, setColumnsOpen] = useState(false)
  const [lanesOpen, setLanesOpen] = useState(false)
  const columnsMenuRef = useDismissiblePopup<HTMLDivElement>(columnsOpen, () => setColumnsOpen(false))
  const lanesMenuRef = useDismissiblePopup<HTMLDivElement>(lanesOpen, () => setLanesOpen(false))
  const updatePreferences = useMutation({
    mutationFn: updateDashboardPreferences,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })

  function updateLane(lane: string, checked: boolean) {
    const current = payload.preferences.kanban_lanes
    const next = checked ? [ ...current, lane ].filter(uniqueValue) : current.filter((value) => value !== lane)
    updatePreferences.mutate({
      subject: payload.subject,
      kanban_lanes: next
    })
  }

  function updateColumn(column: string, checked: boolean) {
    const optionalColumns = payload.controls.columns.optional.map((option) => option.key)
    const next = optionalColumns.filter((candidate) => {
      if (candidate === column) return checked
      return payload.preferences.visible_columns.includes(candidate)
    })
    updatePreferences.mutate({
      subject: payload.subject,
      visible_columns: next
    })
  }

  return (
    <div className="shrink-0">
      <div className="flex flex-wrap items-center justify-end gap-3">
        <nav aria-label={t("view_label")} className="inline-flex overflow-hidden rounded border border-gray-300 bg-white text-sm dark:border-gray-700 dark:bg-gray-900">
          {payload.controls.views.map((view) => (
            <Link
              className={`px-3 py-1.5 capitalize ${payload.view === view ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-950" : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"}`}
              key={view}
              onClick={() =>
                updatePreferences.mutate({
                  subject: payload.subject,
                  active_smart_folder_id: payload.active_smart_folder_id,
                  view
                })
              }
              to={dashboardLinkFromSearch(pathname, search, { view, page: null })}
            >
              {view}
            </Link>
          ))}
        </nav>
        {showConfiguration && payload.view === "list" ? (
          <div className="relative" ref={columnsMenuRef}>
            <button
              aria-label={t("columns")}
              aria-controls="dashboard-columns-menu"
              aria-expanded={columnsOpen}
              aria-haspopup="menu"
              className="inline-flex h-9 w-9 items-center justify-center rounded border border-gray-300 bg-white text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
              onClick={() => setColumnsOpen((open) => !open)}
              type="button"
            >
              <ColumnsIcon />
            </button>
            {columnsOpen ? (
              <div className="absolute right-0 z-20 mt-2 w-64 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900" id="dashboard-columns-menu" role="menu">
                <fieldset className="space-y-2">
                  <legend className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("visible_columns")}</legend>
                  {payload.controls.columns.optional.map((column) => (
                    <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-200" key={column.key}>
                      <input
                        checked={payload.preferences.visible_columns.includes(column.key)}
                        disabled={updatePreferences.isPending}
                        onChange={(event) => updateColumn(column.key, event.target.checked)}
                        type="checkbox"
                      />
                      <span>{column.title}</span>
                    </label>
                  ))}
                </fieldset>
              </div>
            ) : null}
          </div>
        ) : null}
        {showConfiguration && payload.view === "kanban" ? (
          <div className="relative" ref={lanesMenuRef}>
            <button
              aria-label={t("kanban_lanes")}
              aria-controls="dashboard-kanban-lanes-menu"
              aria-expanded={lanesOpen}
              aria-haspopup="menu"
              className="inline-flex h-9 w-9 items-center justify-center rounded border border-gray-300 bg-white text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
              onClick={() => setLanesOpen((open) => !open)}
              type="button"
            >
              <ColumnsIcon />
            </button>
            {lanesOpen ? (
              <div className="absolute right-0 z-20 mt-2 w-64 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900" id="dashboard-kanban-lanes-menu" role="menu">
                <fieldset className="space-y-2">
                  <legend className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("kanban_lanes")}</legend>
                  {payload.controls.kanban_lanes.map((lane) => (
                    <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-200" key={lane.key}>
                      <input
                        checked={payload.preferences.kanban_lanes.includes(lane.key)}
                        disabled={updatePreferences.isPending}
                        onChange={(event) => updateLane(lane.key, event.target.checked)}
                        type="checkbox"
                      />
                      <span>{lane.title}</span>
                    </label>
                  ))}
                </fieldset>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
      {updatePreferences.isError ? <p className="mt-1 text-right text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(updatePreferences.error, t("preferences_error"))}</p> : null}
    </div>
  )
}

function ColumnsIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path d="M7 4v16M17 4v16M5 5h14M5 12h14M5 19h14" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
  )
}

function DashboardFilterBar({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  const activeFolder = payload.smart_folders.find((folder) => folder.id === payload.active_smart_folder_id)
  const keepSmartFolderOnFilter = activeFolder?.kind === "user_defined"

  return (
    <FilterBar
      buildLink={(path, currentSearch, updates) => {
        const nextUpdates = { ...updates }
        if (nextUpdates.smart_folder_id != null && !keepSmartFolderOnFilter) nextUpdates.smart_folder_id = null

        return dashboardLinkFromSearch(path, currentSearch, nextUpdates)
      }}
      filter={payload.filter}
      filterSchema={payload.controls.filter_schema}
      legacyFilterKeys={legacyFilterKeys}
      onFilterApplied={(tree) => {
        void recordDashboardFilterUsage({ subject: payload.subject, filter: tree as Record<string, unknown> }).catch(() => {})
      }}
      pathname={pathname}
      search={search}
      suggestionSearch={{ surface: "dashboard", subject: payload.subject }}
      suggestions={payload.controls.filter_suggestions}
    />
  )
}

const legacyFilterKeys = ["state", "repository_id", "kind", "trigger_kind", "job_id", "attention", "tag_ids", "pr", "age"]

function DashboardTable({ payload, prefix, setupStatus }: { payload: DashboardPayload; prefix: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const updateSort = useMutation({
    mutationFn: updateDashboardPreferences,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const storedSortColumn = sortValue(payload.preferences.sort, "column")
  const storedSortDirection = sortValue(payload.preferences.sort, "direction")
  const queueSortOutsideLanding = payload.subject === "job" && storedSortColumn === "landing_queue_position" && !payload.landing_queue.visible
  const effectiveSortColumn = queueSortOutsideLanding ? "created_at" : storedSortColumn
  const effectiveSortDirection = queueSortOutsideLanding ? "desc" : storedSortDirection
  const [queueSortResetRequested, setQueueSortResetRequested] = useState(false)

  useEffect(() => {
    if (!queueSortOutsideLanding) {
      if (queueSortResetRequested) setQueueSortResetRequested(false)
      return
    }
    if (queueSortResetRequested || updateSort.isPending) return

    setQueueSortResetRequested(true)
    updateSort.mutate({
      subject: payload.subject,
      active_smart_folder_id: payload.active_smart_folder_id,
      sort_column: "created_at",
      sort_direction: "desc"
    })
  }, [payload.active_smart_folder_id, payload.subject, queueSortOutsideLanding, queueSortResetRequested, updateSort])

  const sortState: DashboardSortState = {
    column: effectiveSortColumn || payload.controls.sort_columns[0] || "title",
    direction: effectiveSortDirection || "desc",
    pending: updateSort.isPending,
    sortableColumns: payload.controls.sort_columns,
    onSort: (column) => {
      const sortColumn = sortableColumnFor(payload.subject, column)
      if (!sortColumn || !payload.controls.sort_columns.includes(sortColumn)) return

      const currentColumn = effectiveSortColumn || payload.controls.sort_columns[0] || "title"
      const currentDirection = effectiveSortDirection || "desc"
      const nextDirection = currentColumn === sortColumn && currentDirection === "asc" ? "desc" : "asc"
      updateSort.mutate({
        subject: payload.subject,
        active_smart_folder_id: payload.active_smart_folder_id,
        sort_column: sortColumn,
        sort_direction: nextDirection
      })
    }
  }

  if (payload.view === "kanban") return <DashboardKanban payload={payload} prefix={prefix} setupStatus={setupStatus} />

  if ((payload.items ?? []).length === 0) {
    if (payload.total === 0 && payload.counts[`${payload.subject}s` as keyof DashboardPayload["counts"]] === 0) {
      const emptyState = dashboardEmptyState(payload, t)
      return (
        <OnboardingEmptyState
          fallbackActionPath={emptyState.actionPath}
          fallbackActionText={emptyState.actionText}
          fallbackDescription={emptyState.description}
          fallbackTitle={emptyState.title}
          prefix={prefix}
          setupStatus={setupStatus}
        />
      )
    }

    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">{t("no_match", { subject: subjectLabel(payload.subject, 2) })}</div>
  }

  const columns = dashboardVisibleColumns(payload)
  const items = payload.items ?? []
  if (payload.subject === "job") return <JobsDashboardTable columns={columns} items={items.filter((item): item is DashboardJobItem => item.type === "job")} landingQueueEntries={payload.landing_queue.entries ?? []} prefix={prefix} sortState={sortState} t={t} />
  if (payload.subject === "workflow") return <WorkflowsTable columns={columns} items={items.filter((item): item is DashboardWorkflowItem => item.type === "workflow")} prefix={prefix} sortState={sortState} />

  return <EpicsTable columns={epicTableColumns(columns)} items={items.filter((item): item is DashboardEpicItem => item.type === "epic")} prefix={prefix} sortState={sortState} />
}

function DashboardKanban({ payload, prefix, setupStatus }: { payload: DashboardPayload; prefix: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [draggedEpic, setDraggedEpic] = useState<DashboardEpicItem | null>(null)
  const [dragOverLane, setDragOverLane] = useState<string | null>(null)
  const [optimisticLanes, setOptimisticLanes] = useState(payload.lanes ?? [])
  const [notice, setNotice] = useState<string | null>(null)
  const moveEpic = useMutation({
    mutationFn: ({ epic, targetState }: { epic: DashboardEpicItem; sourceState: string; targetState: string }) => updateDashboardEpicState(epic.paths.app_state_path, targetState),
    onSuccess: (updated) => {
      setNotice(updated.message || t("epic_updated"))
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    },
    onError: (_error, { epic, sourceState }) => {
      setOptimisticLanes((lanes) => moveEpicBetweenLanes(lanes, epic, sourceState))
    }
  })

  useEffect(() => {
    setOptimisticLanes(payload.lanes ?? [])
  }, [payload.lanes])

  if ((payload.lanes ?? []).length === 0) {
    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">{t("no_lanes")}</div>
  }

  if (payload.total === 0 && payload.counts[`${payload.subject}s` as keyof DashboardPayload["counts"]] === 0) {
    const emptyState = dashboardEmptyState(payload, t)
    return (
      <OnboardingEmptyState
        fallbackActionPath={emptyState.actionPath}
        fallbackActionText={emptyState.actionText}
        fallbackDescription={emptyState.description}
        fallbackTitle={emptyState.title}
        prefix={prefix}
        setupStatus={setupStatus}
      />
    )
  }

  function startDrag(epic: DashboardEpicItem, event: DragEvent<HTMLElement>) {
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", String(epic.id))
    setDraggedEpic(epic)
    setNotice(null)
  }

  function clearDrag() {
    setDraggedEpic(null)
    setDragOverLane(null)
  }

  function dragOverLaneFor(lane: DashboardLane, event: DragEvent<HTMLElement>) {
    if (!draggedEpic) return
    if (!canMoveEpicToLane(draggedEpic, lane.key)) {
      setDragOverLane(null)
      return
    }

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    setDragOverLane(lane.key)
  }

  function dropOnLane(lane: DashboardLane, event: DragEvent<HTMLElement>) {
    if (!draggedEpic || !canMoveEpicToLane(draggedEpic, lane.key)) {
      clearDrag()
      return
    }

    event.preventDefault()
    const sourceState = draggedEpic.state
    setOptimisticLanes((lanes) => moveEpicBetweenLanes(lanes, draggedEpic, lane.key))
    moveEpic.mutate({ epic: draggedEpic, sourceState, targetState: lane.key })
    clearDrag()
  }

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {moveEpic.isError ? <div className="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200" role="alert">{errorMessage(moveEpic.error, t("epic_move_error"))}</div> : null}
      <div className="select-none overflow-x-auto pb-2">
        <div className="grid min-w-[56rem] gap-3" style={{ gridTemplateColumns: `repeat(${(payload.lanes ?? []).length}, minmax(14rem, 1fr))` }}>
          {optimisticLanes.map((lane) => (
            <KanbanLane
              draggingOver={dragOverLane === lane.key}
              key={lane.key}
              lane={lane}
              onDragEnd={clearDrag}
              onDragOver={(event) => dragOverLaneFor(lane, event)}
              onDragStart={startDrag}
              onDrop={(event) => dropOnLane(lane, event)}
              prefix={prefix}
              subject={payload.subject}
            />
          ))}
        </div>
      </div>
    </>
  )
}

function dashboardEmptyFallbackPath(payload: DashboardPayload) {
  return payload.subject === "epic" ? payload.paths.new_epic_path : payload.paths.new_job_path
}

function dashboardEmptyState(payload: DashboardPayload, t: (key: string, opts?: Record<string, unknown>) => string) {
  const subject = subjectLabel(payload.subject, 2)
  if (payload.setup && !payload.setup.complete) {
    const setupDescription = payload.setup.next_step === "credentials"
      ? t("setup_credentials_description")
      : t("setup_description")

    return {
      title: t("empty_title", { subject: capitalizeLabel(subject) }),
      description: setupDescription,
      actionPath: payload.setup.paths.setup_path,
      actionText: t("open_setup")
    }
  }

  return {
    title: t("empty_title", { subject: capitalizeLabel(subject) }),
    description: t("empty_description", { subject }),
    actionPath: dashboardEmptyFallbackPath(payload),
    actionText: payload.subject === "epic" ? t("create_epic") : t("create_direct_job")
  }
}

function capitalizeLabel(value: string) {
  return value.charAt(0).toUpperCase() + value.slice(1)
}

function KanbanLane({
  draggingOver,
  lane,
  onDragEnd,
  onDragOver,
  onDragStart,
  onDrop,
  prefix,
  subject
}: {
  draggingOver: boolean
  lane: DashboardLane
  onDragEnd: () => void
  onDragOver: (event: DragEvent<HTMLElement>) => void
  onDragStart: (epic: DashboardEpicItem, event: DragEvent<HTMLElement>) => void
  onDrop: (event: DragEvent<HTMLElement>) => void
  prefix: string
  subject: DashboardSubject
}) {
  const { t } = useT("dashboard")
  const itemSignature = lane.items.map((item) => `${item.type}-${item.id}`).join(",")
  const [visibleCount, setVisibleCount] = useState(KANBAN_CARDS_PER_PAGE)
  const visibleItems = lane.items.slice(0, visibleCount)
  const hiddenCount = lane.items.length - visibleItems.length

  useEffect(() => {
    setVisibleCount(KANBAN_CARDS_PER_PAGE)
  }, [lane.key, itemSignature])

  return (
    <section
      aria-label={t("lane_label", { title: lane.title })}
      className={`min-h-64 rounded border bg-gray-50 dark:bg-gray-950 ${draggingOver ? "border-blue-400 ring-2 ring-blue-100 dark:border-blue-500 dark:ring-blue-900" : "border-gray-200 dark:border-gray-700"}`}
      onDragOver={onDragOver}
      onDrop={onDrop}
    >
      <header className="flex items-center justify-between border-b border-gray-200 px-3 py-2 dark:border-gray-700">
        <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{lane.title}</h3>
        <span className="rounded bg-white px-2 py-0.5 text-xs text-gray-500 ring-1 ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-700">{lane.count}</span>
      </header>
      <div className="space-y-2 p-2">
        {lane.items.length === 0 ? <p className="px-1 py-2 text-sm text-gray-400 dark:text-gray-500">{t("no_items_in_lane", { subject: subjectLabel(subject, 2) })}</p> : null}
        {visibleItems.map((item) => (
          <KanbanCard
            item={item}
            key={`${item.type}-${item.id}`}
            onDragEnd={onDragEnd}
            onDragStart={onDragStart}
            prefix={prefix}
          />
        ))}
        {hiddenCount > 0 ? (
          <button
            aria-label={t("load_more_lane", { lane: lane.title })}
            className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
            onClick={() => setVisibleCount((count) => count + KANBAN_CARDS_PER_PAGE)}
            type="button"
          >
            {t("load_more")}
          </button>
        ) : null}
      </div>
    </section>
  )
}

function KanbanCard({ item, onDragEnd, onDragStart, prefix }: { item: DashboardItem; onDragEnd: () => void; onDragStart: (epic: DashboardEpicItem, event: DragEvent<HTMLElement>) => void; prefix: string }) {
  if (item.type === "job") {
    return (
      <article className={`rounded border p-3 shadow-sm ${item.needs_attention ? "border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/30" : "border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900"}`}>
        <div className="flex items-start justify-between gap-1">
          <Link className="text-sm font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.paths.job_path, prefix)}><PendingJobTitle pending={Boolean(item.title_pending)} title={item.title} /></Link>
          {item.needs_attention ? <span aria-label="Needs attention" className="mt-0.5 shrink-0 rounded bg-amber-200 px-1 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-800 dark:text-amber-200">!</span> : null}
        </div>
        <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500 dark:text-gray-400">
          <WorkflowBadges state={item.summary_state} triggerAriaPrefix="Active workflow trigger" triggerKind={item.active_workflow_trigger_kind} />
          <RepositorySlugLink className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-500 hover:text-blue-700 hover:underline dark:bg-gray-800 dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={item.repository} />
          <OwnerBadge badge={item.owner_badge} />
          {item.pr_number ? <ExternalMetadataLink className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-500 hover:text-blue-700 hover:underline dark:bg-gray-800 dark:text-gray-300 dark:hover:text-blue-300" href={item.pr_url}>PR #{item.pr_number}</ExternalMetadataLink> : null}
        </div>
      </article>
    )
  }

  if (item.type === "workflow") {
    const slug = workflowLabel(item)
    return (
      <article className="rounded border border-gray-200 bg-white p-3 shadow-sm dark:border-gray-700 dark:bg-gray-900">
        <Link className="text-sm font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.path, prefix)}>{slug}</Link>
        <Link className="mt-1 block text-sm text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.job.path, prefix)}><PendingJobTitle pending={Boolean(item.job.title_pending)} title={item.job.title} /></Link>
        <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500 dark:text-gray-400">
          <WorkflowBadges state={item.state} triggerAriaPrefix="Workflow trigger" triggerKind={item.trigger_kind} />
          <OwnerBadge badge={item.job.owner_badge} />
        </div>
      </article>
    )
  }

  return (
    <article
      aria-label={`${item.display_number} ${item.title}`}
      className="cursor-grab overflow-hidden rounded border border-gray-200 bg-white shadow-sm active:cursor-grabbing dark:border-gray-700 dark:bg-gray-900"
      draggable
      onDragEnd={onDragEnd}
      onDragStart={(event) => onDragStart(item, event)}
    >
      <div className="p-3">
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <SlugHoverCard id={item.id} kind="epic">
            <CopyableSlug className="text-xs font-semibold uppercase" slug={item.display_number} />
          </SlugHoverCard>
          <Link className="text-sm font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.paths.epic_path, prefix)}>{item.title}</Link>
        </div>
        <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500 dark:text-gray-400">
          <NeutralStatePill state={item.state} />
          <EpicStuckBadge stuck={item.stuck} />
          <OwnerBadge badge={item.owner_badge} />
          <RepositorySlugLink className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-500 hover:text-blue-700 hover:underline dark:bg-gray-800 dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={item.repository} />
        </div>
      </div>
      <EpicProgressBar epic={item} fullWidth />
    </article>
  )
}

function canMoveEpicToLane(epic: DashboardEpicItem, targetState: string) {
  if (targetState === epic.state) return false
  if (epic.state === "ready" && targetState === "backlog") return true
  if (epic.state === "ready" && targetState === "in_progress") return true
  if (epic.state === "in_progress" && targetState === "ready") return true
  if (epic.state === "in_progress" && targetState === "done") return epic.all_jobs_closed
  if (epic.state === "backlog" && targetState === "ready") return epic.jobs_count > 0
  return false
}

function moveEpicBetweenLanes(lanes: DashboardLane[], epic: DashboardEpicItem, targetState: string) {
  let movedEpic: DashboardEpicItem | null = null
  let removedFromLaneKey: string | null = null
  const withoutEpic = lanes.map((lane) => {
    const items = lane.items.filter((item) => {
      const isDraggedEpic = item.type === "epic" && item.id === epic.id
      if (isDraggedEpic) {
        movedEpic = { ...item, state: targetState }
        removedFromLaneKey = lane.key
      }
      return !isDraggedEpic
    })
    const count = lane.key === removedFromLaneKey ? Math.max(0, lane.count - 1) : lane.count

    return { ...lane, count, items }
  })

  const optimisticEpic = movedEpic || { ...epic, state: targetState }

  return withoutEpic.map((lane) => {
    if (lane.key !== targetState) return lane

    return {
      ...lane,
      count: lane.count + 1,
      items: [optimisticEpic, ...lane.items]
    }
  })
}

type DashboardSortState = {
  column: string
  direction: string
  pending: boolean
  sortableColumns: string[]
  onSort: (column: string) => void
}

function JobsDashboardTable({ items, columns, landingQueueEntries, prefix, sortState, t }: { items: DashboardJobItem[]; columns: string[]; landingQueueEntries: DashboardLandingQueueEntry[]; prefix: string; sortState: DashboardSortState; t: (key: string, opts?: Record<string, unknown>) => string }) {
  const [selectedIds, setSelectedIds] = useState<Set<number>>(() => new Set())
  const visibleIds = useMemo(() => items.map((item) => item.id), [items])
  const selectedArray = useMemo(() => Array.from(selectedIds), [selectedIds])
  const allSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedIds.has(id))

  useEffect(() => {
    setSelectedIds((current) => {
      const visible = new Set(visibleIds)
      const next = new Set(Array.from(current).filter((id) => visible.has(id)))
      return next.size === current.size ? current : next
    })
  }, [visibleIds])

  function toggleAll() {
    setSelectedIds((current) => {
      if (allSelected) return new Set()
      return new Set([ ...Array.from(current), ...visibleIds ])
    })
  }

  function toggleOne(id: number) {
    setSelectedIds((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <div className="space-y-3">
      <BulkJobActions selectedIds={selectedArray} onClear={() => setSelectedIds(new Set())} />
      <JobsTable
        allSelected={allSelected}
        columns={columns}
        items={items}
        landingQueueEntries={landingQueueEntries}
        onToggleAll={toggleAll}
        onToggleOne={toggleOne}
        prefix={prefix}
        selectedIds={selectedIds}
        sortState={sortState}
        t={t}
      />
    </div>
  )
}

function BulkJobActions({ selectedIds, onClear }: { selectedIds: number[]; onClear: () => void }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const action = useMutation({
    mutationFn: (bulkAction: DashboardBulkJobAction) => bulkDashboardJobs({ job_ids: selectedIds, bulk_action: bulkAction }),
    onSuccess: (payload) => {
      setNotice(payload.message)
      onClear()
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const disabled = selectedIds.length === 0 || action.isPending

  function run(bulkAction: DashboardBulkJobAction) {
    setNotice(null)
    if (bulkAction === "close" && !window.confirm(t(selectedIds.length === 1 ? "close_confirm_one" : "close_confirm_other", { count: selectedIds.length }))) return
    action.mutate(bulkAction)
  }

  if (selectedIds.length === 0) {
    return <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
  }

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900">
      <div>
        <span className="font-medium text-gray-900 dark:text-gray-100">{t("selected_count", { count: selectedIds.length })}</span>
        <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
        {action.isError ? <span className="ml-3 text-red-700 dark:text-red-300" role="alert">{errorMessage(action.error, t("bulk_action_error"))}</span> : null}
      </div>
      <div className="flex flex-wrap gap-2">
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("retry")} type="button">{t("retry")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("claim")} type="button">{t("claim")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("release_claim")} type="button">{t("release")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("approve")} type="button">{t("approve")}</button>
        <button className={bulkButtonClass(disabled, "danger")} disabled={disabled} onClick={() => run("close")} type="button">{t("close_action")}</button>
      </div>
    </div>
  )
}

// Group key for the landing-queue delineation: one key per *landing unit*.
// An Epic lands atomically (a merge-train), so all its jobs share a key; an
// epicless job lands on its own, so each gets its own key (a "single-job
// epic"). Sorted by queue position, the separators then trace the relative
// order of lands within a repository.
export function epicGroupKey(job: DashboardJobItem) {
  return job.epic ? `epic-${job.epic.id}` : `job-${job.id}`
}

// True when this row begins a new landing unit relative to the previous row,
// but only at epic group boundaries — consecutive standalone (epicless) jobs
// are the same kind of landing unit and do not get a separator between them.
// Only meaningful when the list is ordered by queue position.
export function startsNewEpicGroup(items: DashboardJobItem[], index: number, enabled: boolean) {
  if (!enabled || index === 0) return false
  const currentKey = epicGroupKey(items[index])
  const prevKey = epicGroupKey(items[index - 1])
  if (currentKey === prevKey) return false
  return currentKey.startsWith("epic-") || prevKey.startsWith("epic-")
}

function JobsTable({
  items,
  columns,
  landingQueueEntries,
  selectedIds,
  allSelected,
  onToggleAll,
  onToggleOne,
  prefix,
  sortState,
  t
}: {
  items: DashboardJobItem[]
  columns: string[]
  landingQueueEntries: DashboardLandingQueueEntry[]
  selectedIds: Set<number>
  allSelected: boolean
  onToggleAll: () => void
  onToggleOne: (id: number) => void
  prefix: string
  sortState: DashboardSortState
  t: (key: string, opts?: Record<string, unknown>) => string
}) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  // Only group by Epic when the rows are actually in queue order — in any
  // other sort the Epics aren't contiguous, so a separator would mislead.
  const groupByEpic = sortState.column === "landing_queue_position"
  const landingQueueGroups = useMemo(() => groupByLandingQueueEntry(items, landingQueueEntries, t), [items, landingQueueEntries, t])
  const [expandedBlockerGroups, setExpandedBlockerGroups] = useState<Set<string>>(() => new Set())

  useEffect(() => {
    setExpandedBlockerGroups((current) => {
      const visibleKeys = new Set(landingQueueGroups.map((group) => group.key))
      const next = new Set(Array.from(current).filter((key) => visibleKeys.has(key)))
      return next.size === current.size ? current : next
    })
  }, [landingQueueGroups])

  function toggleBlockerGroup(key: string) {
    setExpandedBlockerGroups((current) => {
      const next = new Set(current)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  if (!isDesktop) return <MobileJobsList groupByEpic={groupByEpic} items={items} onToggleOne={onToggleOne} prefix={prefix} selectedIds={selectedIds} />

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            {columns.map((column) => (
              <th aria-sort={columnAriaSort("job", column, sortState)} className={column === "checkbox" ? "w-10 px-4 py-2" : "px-4 py-2"} key={column}>
                {column === "checkbox" ? <input aria-label={t("select_all_jobs")} checked={allSelected} onChange={onToggleAll} type="checkbox" /> : <SortableColumnHeader column={column} sortState={sortState} subject="job" />}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {groupByEpic ? (
            landingQueueGroups.map((group, index) => (
              <LandingQueueJobGroup
                columns={columns}
                expanded={expandedBlockerGroups.has(group.key)}
                group={group}
                key={group.key}
                onToggleBlockers={toggleBlockerGroup}
                onToggleOne={onToggleOne}
                prefix={prefix}
                selectedIds={selectedIds}
                topSeparator={index > 0 && (group.key.startsWith("epic:") || landingQueueGroups[index - 1].key.startsWith("epic:"))}
              />
            ))
          ) : (
            items.map((job, index) => (
              <tr className={startsNewEpicGroup(items, index, groupByEpic) ? "border-t-4 border-gray-300 dark:border-gray-600" : undefined} key={job.id}>
                {columns.map((column) => <JobCell column={column} job={job} key={column} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} />)}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  )
}

type LandingQueueApprovedRow = {
  kind: "approved"
  id: number
  job: DashboardJobItem
}

type LandingQueueBlockerRow = {
  kind: "blocker"
  id: number
  job: LandingQueueBlockerJob
  attribution: string | null
}

type LandingQueueDisplayRow = LandingQueueApprovedRow | LandingQueueBlockerRow

type LandingQueueDisplayGroup = {
  key: string
  jobs: DashboardJobItem[]
  blockerJobs: LandingQueueBlockerRow[]
  rows: LandingQueueDisplayRow[]
}

function LandingQueueJobGroup({
  columns,
  expanded,
  group,
  onToggleBlockers,
  onToggleOne,
  prefix,
  selectedIds,
  topSeparator
}: {
  columns: string[]
  expanded: boolean
  group: LandingQueueDisplayGroup
  onToggleBlockers: (key: string) => void
  onToggleOne: (id: number) => void
  prefix: string
  selectedIds: Set<number>
  topSeparator: boolean
}) {
  const { t } = useT("dashboard")
  const blockerCount = group.blockerJobs.length
  const rows = expanded ? group.rows : group.rows.filter((row) => row.kind === "approved")

  return (
    <>
      {blockerCount > 0 ? (
        <tr className={topSeparator ? "border-t-4 border-gray-300 dark:border-gray-600" : undefined}>
          <td className="bg-gray-50 px-4 py-2 dark:bg-gray-950/40" colSpan={columns.length}>
            <button
              aria-expanded={expanded}
              className="inline-flex items-center gap-2 rounded px-1 py-0.5 text-xs font-semibold text-gray-600 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-gray-300 dark:hover:text-gray-100"
              onClick={() => onToggleBlockers(group.key)}
              type="button"
            >
              <span aria-hidden="true">{expanded ? "▼" : "▶"}</span>
              <span>{t(blockerCount === 1 ? "blocker_one" : "blocker_other", { count: blockerCount })}</span>
            </button>
          </td>
        </tr>
      ) : null}
      {rows.map((row, index) => {
        const separatorClass = blockerCount === 0 && topSeparator && index === 0 ? "border-t-4 border-gray-300 dark:border-gray-600" : undefined
        if (row.kind === "blocker") {
          return (
            <tr className={`bg-gray-50/70 text-gray-500 dark:bg-gray-950/30 dark:text-gray-400${separatorClass ? ` ${separatorClass}` : ""}`} key={`blocker-${group.key}-${row.id}`}>
              {columns.map((column) => <LandingQueueBlockerCell column={column} job={row.job} attribution={row.attribution} key={column} prefix={prefix} />)}
            </tr>
          )
        }

        return (
          <tr className={separatorClass} key={row.job.id}>
            {columns.map((column) => <JobCell column={column} job={row.job} key={column} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(row.job.id)} />)}
          </tr>
        )
      })}
    </>
  )
}

function LandingQueueBlockerCell({ job, column, attribution, prefix }: { job: LandingQueueBlockerJob; column: string; attribution: string | null; prefix: string }) {
  if (column === "checkbox") return <td className="px-4 py-3 align-top" />
  if (column === "landing_queue_position") return <td className="px-4 py-3" />
  if (column === "landing_queue_blocked_reason") return <td className="px-4 py-3" />
  if (column === "issue" || column === "title") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(job.job_path, prefix)}>{job.title}</Link>
        <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
          <span>JOB-{job.id}</span>
          {job.pr_number && job.pr_path ? <ExternalMetadataLink href={job.pr_path}>PR #{job.pr_number}</ExternalMetadataLink> : null}
          {attribution ? <span className="rounded border border-gray-200 px-1.5 py-0.5 text-[11px] text-gray-500 dark:border-gray-700 dark:text-gray-400">{attribution}</span> : null}
        </div>
      </td>
    )
  }
  if (column === "state") {
    return (
      <td className="px-4 py-3">
        <NeutralStatePill state={job.state} />
      </td>
    )
  }

  return <td className="px-4 py-3 text-gray-400 dark:text-gray-500">-</td>
}

function groupByLandingQueueEntry(items: DashboardJobItem[], entries: DashboardLandingQueueEntry[], t: (key: string, opts?: Record<string, unknown>) => string) {
  const entriesByKey = new Map(entries.map((entry) => [entry.key, entry]))
  const groups: LandingQueueDisplayGroup[] = []
  const groupsByKey = new Map<string, LandingQueueDisplayGroup>()

  items.forEach((job) => {
    const key = job.landing_queue_entry_key || epicGroupKey(job)
    let group = groupsByKey.get(key)
    if (!group) {
      group = { key, jobs: [], blockerJobs: [], rows: [] }
      groupsByKey.set(key, group)
      groups.push(group)
    }
    group.jobs.push(job)
  })

  groups.forEach((group) => {
    const entry = entriesByKey.get(group.key)
    group.blockerJobs = (entry?.blocker_jobs ?? []).map((job) => ({
      kind: "blocker",
      id: job.id,
      job,
      attribution: blockerAttribution(job, group.key, t)
    }))
    const approvedRows: LandingQueueApprovedRow[] = group.jobs.map((job) => ({ kind: "approved", id: job.id, job }))
    group.rows = topologicalLandingQueueRows([ ...approvedRows, ...group.blockerJobs ], entry)
  })

  return groups
}

function topologicalLandingQueueRows(rows: LandingQueueDisplayRow[], entry?: DashboardLandingQueueEntry) {
  if (!entry) return rows

  const byId = new Map(rows.map((row) => [row.id, row]))
  const originalIndex = new Map(rows.map((row, index) => [row.id, index]))
  const incoming = new Map<number, Set<number>>()
  const outgoing = new Map<number, Set<number>>()

  rows.forEach((row) => {
    incoming.set(row.id, new Set())
    outgoing.set(row.id, new Set())
  })
  entry.dependency_edges.forEach((edge) => {
    if (!byId.has(edge.from_job_id) || !byId.has(edge.to_job_id)) return
    outgoing.get(edge.from_job_id)?.add(edge.to_job_id)
    incoming.get(edge.to_job_id)?.add(edge.from_job_id)
  })

  const ready = rows.filter((row) => incoming.get(row.id)?.size === 0)
  sortLandingQueueRows(ready, originalIndex)
  const ordered: LandingQueueDisplayRow[] = []

  while (ready.length > 0) {
    const row = ready.shift()
    if (!row) break
    ordered.push(row)

    const dependents = Array.from(outgoing.get(row.id) ?? [])
      .map((id) => byId.get(id))
      .filter((dependent): dependent is LandingQueueDisplayRow => dependent != null)
    sortLandingQueueRows(dependents, originalIndex)
    dependents.forEach((dependent) => {
      incoming.get(dependent.id)?.delete(row.id)
      if (incoming.get(dependent.id)?.size === 0) {
        ready.push(dependent)
        sortLandingQueueRows(ready, originalIndex)
      }
    })
  }

  const orderedIds = new Set(ordered.map((row) => row.id))
  return [ ...ordered, ...rows.filter((row) => !orderedIds.has(row.id)) ]
}

function sortLandingQueueRows(rows: LandingQueueDisplayRow[], originalIndex: Map<number, number>) {
  rows.sort((left, right) => (originalIndex.get(left.id) ?? 0) - (originalIndex.get(right.id) ?? 0))
}

function blockerAttribution(job: LandingQueueBlockerJob, groupKey: string, t: (key: string, opts?: Record<string, unknown>) => string) {
  if (job.epic_title) return t("epic_attribution", { title: job.epic_title })
  if (job.epic_id != null) return t("epic_attribution_by_id", { id: job.epic_id })
  if (Object.prototype.hasOwnProperty.call(job, "epic_id") && job.epic_id == null) return t("standalone")
  if (groupKey.startsWith("job:") && groupKey !== `job:${job.id}`) return t("standalone")
  return null
}

function MobileJobsList({ items, selectedIds, onToggleOne, prefix, groupByEpic }: { items: DashboardJobItem[]; selectedIds: Set<number>; onToggleOne: (id: number) => void; prefix: string; groupByEpic: boolean }) {
  return (
    <div className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="divide-y divide-gray-100 dark:divide-gray-800">
        {items.map((job, index) => <MobileJobRow job={job} key={job.id} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} topSeparator={startsNewEpicGroup(items, index, groupByEpic)} />)}
      </div>
    </div>
  )
}

function MobileJobRow({ job, selected, onToggleOne, prefix, topSeparator = false }: { job: DashboardJobItem; selected: boolean; onToggleOne: (id: number) => void; prefix: string; topSeparator?: boolean }) {
  const { t } = useT("dashboard")
  const approvalLabel = job.approved_at ? t("approved") : t("not_approved")

  return (
    <article aria-label={job.title} className={`grid grid-cols-[auto_minmax(0,1fr)] gap-3 px-4 py-3${topSeparator ? " border-t-4 border-gray-300 dark:border-gray-600" : ""}`}>
      <input aria-label={t("select_item", { title: job.title })} checked={selected} className="mt-1" onChange={() => onToggleOne(job.id)} type="checkbox" />
      <div className="min-w-0 text-gray-700 dark:text-gray-200">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <WorkflowBadges state={job.summary_state} triggerAriaPrefix="Active workflow trigger" triggerKind={job.active_workflow_trigger_kind} />
          {job.total_cost_usd == null ? null : <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{formatCurrency(job.total_cost_usd, 2)}</span>}
          <RepositorySlugLink prefix={prefix} repository={job.repository} />
          <OwnerBadge badge={job.owner_badge} />
        </div>
        <div className="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <Link aria-label={job.title} className="rounded-sm text-sm font-semibold leading-snug text-blue-600 underline focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-blue-300" to={withRoutePrefix(job.paths.job_path, prefix)}><PendingJobTitle pending={Boolean(job.title_pending)} title={job.title} /></Link>
          {job.kind !== "issue" ? <span className="text-xs text-gray-500 dark:text-gray-400">{humanizeOption(job.kind)}</span> : null}
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <JobSlugMetadata job={job} prefix={prefix} />
          {job.pr_number ? <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink> : null}
          {job.source_chat ? <JobSourceChatLink job={job} prefix={prefix} /> : null}
          {job.claimed_by_user && !job.claimed_by_current_user ? <DashboardOwnerLabel job={job} prefix={prefix} quiet /> : null}
          <span>{approvalLabel}</span>
          {job.owner_badge ? <OwnerBadge badge={job.owner_badge} /> : null}
          <span>{job.workflows_count} {pluralize(job.workflows_count, "workflow")}</span>
          <span>{formatDate(job.started_at || job.created_at)}</span>
        </MetadataLine>
        {job.tags.length > 0 ? (
          <div className="mt-1 flex flex-wrap gap-1">
            {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-500 dark:bg-gray-800 dark:text-gray-300" key={tag.id}>{tag.name}</span>)}
          </div>
        ) : null}
      </div>
    </article>
  )
}

function JobCell({ job, column, selected, onToggleOne, prefix }: { job: DashboardJobItem; column: string; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  const { t } = useT("dashboard")
  if (column === "checkbox") {
    return <td className="px-4 py-3 align-top"><input aria-label={t("select_item", { title: job.title })} checked={selected} onChange={() => onToggleOne(job.id)} type="checkbox" /></td>
  }
  if (column === "issue" || column === "title") {
    return (
      <td className="max-w-md px-4 py-3">
        <div className="flex items-center gap-1.5">
          <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(job.paths.job_path, prefix)}><PendingJobTitle pending={Boolean(job.title_pending)} title={job.title} /></Link>
          {job.needs_attention ? <span aria-label="Needs attention" className="shrink-0 rounded bg-amber-200 px-1 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-800 dark:text-amber-200">!</span> : null}
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <JobSlugMetadata job={job} prefix={prefix} />
          {job.pr_number ? <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink> : null}
          {job.source_chat ? <JobSourceChatLink job={job} prefix={prefix} /> : null}
          {job.owner_badge ? <OwnerBadge badge={job.owner_badge} /> : null}
          {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5 dark:bg-gray-800 dark:text-gray-300" key={tag.id}>{tag.name}</span>)}
          {job.retry_state && job.retry_state.state_label !== "No failure" ? <RetryStateInline job={job} /> : null}
        </MetadataLine>
      </td>
    )
  }
  if (column === "state") {
    return (
      <td className="px-4 py-3">
        <NeutralStatePill state={job.state} />
      </td>
    )
  }
  if (column === "landing_queue_position") {
    return <td className="px-4 py-3 font-mono text-xs font-semibold text-gray-600 dark:text-gray-300">{job.landing_queue_position ? `#${job.landing_queue_position}` : "-"}</td>
  }
  if (column === "landing_queue_blocked_reason") {
    return <td className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{job.landing_queue_blocked_reason ?? "-"}</td>
  }
  if (column === "repository") {
    return <td className="px-4 py-3"><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-blue-700 hover:underline dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={job.repository} /></td>
  }
  if (column === "owner") return <td className="px-4 py-3"><DashboardOwnerLabel job={job} prefix={prefix} /></td>
  if (column === "latest") return <LatestWorkflowCell job={job} />
  if (column === "workflows_count") return <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{job.workflows_count}</td>

  return <TimestampCell value={jobDateValue(job, column)} />
}

function DashboardOwnerLabel({ job, prefix, quiet = false }: { job: DashboardJobItem; prefix: string; quiet?: boolean }) {
  const { t } = useT("dashboard")
  const owner = job.claimed_by_user
  if (!owner) return quiet ? null : <span className="text-xs text-gray-400 dark:text-gray-500">{t("unclaimed")}</span>
  if (job.claimed_by_current_user) return quiet ? null : <span className="sr-only">{t("claimed_by_you")}</span>

  return (
    <Link className="text-xs font-medium text-gray-600 hover:text-blue-700 hover:underline dark:text-gray-300 dark:hover:text-blue-300" to={withRoutePrefix(owner.profile_path, prefix)}>
      {owner.display_name}
    </Link>
  )
}

function LatestWorkflowCell({ job }: { job: DashboardJobItem }) {
  if (job.latest_workflow_id == null) {
    return <td className="px-4 py-3" />
  }

  if (!job.latest_workflow_trigger_kind) {
    return <td className="px-4 py-3"><StatusPill state={job.latest_workflow_state} /></td>
  }

  return (
    <td aria-label={`Latest workflow: ${job.latest_workflow_trigger_kind} ${job.latest_workflow_state}`} className="px-4 py-3">
      <div className="flex flex-col items-start gap-1.5">
        <WorkflowBadges state={job.latest_workflow_state} triggerAriaPrefix="Latest workflow trigger" triggerKind={job.latest_workflow_trigger_kind} />
        <RetryStateInline job={job} />
      </div>
    </td>
  )
}

function JobSlugMetadata({ job, prefix }: { job: DashboardJobItem; prefix: string }) {
  if (job.epic) {
    return (
      <span className="inline-flex items-center">
        <SlugHoverCard id={job.epic.id} kind="epic">
          <Link className="text-gray-500 hover:text-blue-700 hover:underline dark:text-gray-400 dark:hover:text-blue-300" to={withRoutePrefix(job.epic.path, prefix)}>{job.epic.display_number}</Link>
        </SlugHoverCard>
        <span>/</span>
        <SlugHoverCard id={job.id} kind="job">
          <CopyableSlug slug={`JOB-${job.id}`} />
        </SlugHoverCard>
      </span>
    )
  }

  return <IssueMetadata job={job} />
}

function WorkflowBadges({ state, triggerAriaPrefix, triggerKind }: { state: string; triggerAriaPrefix: string; triggerKind: string | null }) {
  return (
    <span className="inline-flex flex-wrap items-center gap-1">
      {triggerKind ? <WorkflowTriggerPill ariaPrefix={triggerAriaPrefix} triggerKind={triggerKind} /> : null}
      <StatusPill state={state} />
    </span>
  )
}

function PendingJobTitle({ pending, title }: { pending: boolean; title: string }) {
  const { t } = useT("dashboard")
  if (!pending) return <>{title}</>

  return (
    <span className="inline-flex min-w-0 items-center gap-1 italic text-gray-500 dark:text-gray-400">
      <span aria-hidden="true" className="inline-block h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-gray-300 border-t-gray-500 dark:border-gray-700 dark:border-t-gray-300" />
      <span>{t("generating_title")}</span>
    </span>
  )
}

function WorkflowTriggerPill({ ariaPrefix, triggerKind }: { ariaPrefix: string; triggerKind: string }) {
  const className = workflowTriggerClassName(triggerKind)

  return (
    <span aria-label={`${ariaPrefix}: ${triggerKind}`} className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ${className}`} data-status-pill="true">
      <span>{triggerKind.replaceAll("_", " ")}</span>
    </span>
  )
}

function workflowTriggerClassName(triggerKind: string) {
  if (triggerKind === "chat_feedback") {
    return "bg-indigo-100 text-indigo-700 ring-indigo-200 dark:bg-indigo-950/50 dark:text-indigo-200 dark:ring-indigo-800"
  }

  return "bg-gray-100 text-gray-700 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700"
}

function IssueMetadata({ job }: { job: DashboardJobItem }) {
  if (!job.issue_number) return <CopyableSlug slug={`JOB-${job.id}`} />

  const label = `#${job.issue_number}`

  return <ExternalMetadataLink href={job.issue_url}>{label}</ExternalMetadataLink>
}

function MetadataLine({ children, className }: { children: ReactNode; className: string }) {
  const items = Children.toArray(children)
  return (
    <div className={className}>
      {items.map((item, index) => (
        <span className="inline-flex items-center gap-x-1.5" key={index}>
          {index > 0 ? <span aria-hidden="true" className="select-none">·</span> : null}
          {item}
        </span>
      ))}
    </div>
  )
}

function JobSourceChatLink({ job, prefix }: { job: DashboardJobItem; prefix: string }) {
  const { t } = useT("dashboard")
  if (!job.source_chat) return null

  return (
    <Link className="text-gray-500 hover:text-blue-700 hover:underline dark:text-gray-400 dark:hover:text-blue-300" to={withRoutePrefix(job.source_chat.path, prefix)}>
      {t("chat_link")}
    </Link>
  )
}

function RetryStateInline({ job }: { job: DashboardJobItem }) {
  const retry = job.retry_state
  if (!retry || retry.state_label === "No failure") return null

  const details = [
    retry.classification_label,
    retry.retryable ? "retryable" : "not retryable",
    `${retry.retry_budget_remaining} left`,
    retry.next_auto_retry_at ? `next ${formatDate(retry.next_auto_retry_at)}` : null,
    retry.provider_circuit_open ? "provider circuit open" : null
  ].filter(Boolean).join(" · ")

  const tone = retry.auto_retry_exhausted ? "red" : retry.provider_circuit_open ? "amber" : "gray"

  return <TonePill title={details} tone={tone}>{retry.state_label}</TonePill>
}

function ExternalMetadataLink({ children, className = "text-gray-500 hover:text-blue-700 hover:underline dark:text-gray-400 dark:hover:text-blue-300", href }: { children: ReactNode; className?: string; href: string | null }) {
  if (!href) return <span className={className}>{children}</span>

  return <a className={className} href={href} rel="noopener noreferrer" target="_blank">{children}</a>
}

function RepositorySlugLink({ className = "font-mono text-xs text-gray-500 hover:text-blue-700 hover:underline dark:text-gray-400 dark:hover:text-blue-300", prefix, repository }: { className?: string; prefix: string; repository: DashboardRepository }) {
  return <Link className={className} to={withRoutePrefix(repository.repository_path, prefix)}>{repository.slug}</Link>
}

function EpicsTable({ items, columns, prefix, sortState }: { items: DashboardEpicItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
  const { t } = useT("dashboard")
  const [selectedIds, setSelectedIds] = useState<Set<number>>(() => new Set())
  const visibleIds = useMemo(() => items.map((item) => item.id), [items])
  const selectedArray = useMemo(() => Array.from(selectedIds), [selectedIds])
  const allSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedIds.has(id))
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  useEffect(() => {
    setSelectedIds((current) => {
      const visible = new Set(visibleIds)
      const next = new Set(Array.from(current).filter((id) => visible.has(id)))
      return next.size === current.size ? current : next
    })
  }, [visibleIds])

  function toggleAll() {
    setSelectedIds((current) => {
      if (allSelected) return new Set()
      return new Set([ ...Array.from(current), ...visibleIds ])
    })
  }

  function toggleOne(id: number) {
    setSelectedIds((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <div className="space-y-3">
      <BulkEpicActions selectedIds={selectedArray} onClear={() => setSelectedIds(new Set())} />
      {isDesktop ? (
        <div className="overflow-x-auto rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
              <tr>
                {columns.map((column) => (
                  <th aria-sort={columnAriaSort("epic", column, sortState)} className={column === "checkbox" ? "w-10 px-4 py-2" : "px-4 py-2"} key={column}>
                    {column === "checkbox" ? <input aria-label={t("select_all_epics")} checked={allSelected} onChange={toggleAll} type="checkbox" /> : <SortableColumnHeader column={column} sortState={sortState} subject="epic" />}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {items.map((epic) => (
                <tr key={epic.id}>
                  {columns.map((column) => <EpicCell column={column} epic={epic} key={column} onToggleOne={toggleOne} prefix={prefix} selected={selectedIds.has(epic.id)} />)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <MobileEpicsList items={items} onToggleOne={toggleOne} prefix={prefix} selectedIds={selectedIds} />
      )}
    </div>
  )
}

function BulkEpicActions({ selectedIds, onClear }: { selectedIds: number[]; onClear: () => void }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const action = useMutation({
    mutationFn: (bulkAction: DashboardBulkEpicAction) => bulkDashboardEpics({ epic_ids: selectedIds, bulk_action: bulkAction }),
    onSuccess: (payload) => {
      setNotice(payload.message)
      onClear()
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const disabled = selectedIds.length === 0 || action.isPending

  function run(bulkAction: DashboardBulkEpicAction) {
    setNotice(null)
    action.mutate(bulkAction)
  }

  if (selectedIds.length === 0) {
    return <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
  }

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900">
      <div>
        <span className="font-medium text-gray-900 dark:text-gray-100">{t("selected_count", { count: selectedIds.length })}</span>
        <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
        {action.isError ? <span className="ml-3 text-red-700 dark:text-red-300" role="alert">{errorMessage(action.error, t("bulk_action_error"))}</span> : null}
      </div>
      <div className="flex flex-wrap gap-2">
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("start")} type="button">{t("move_to_in_progress")}</button>
      </div>
    </div>
  )
}

function MobileEpicsList({ items, selectedIds, onToggleOne, prefix }: { items: DashboardEpicItem[]; selectedIds: Set<number>; onToggleOne: (id: number) => void; prefix: string }) {
  return (
    <div className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="divide-y divide-gray-100 dark:divide-gray-800">
        {items.map((epic) => <MobileEpicRow epic={epic} key={epic.id} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(epic.id)} />)}
      </div>
    </div>
  )
}

function MobileEpicRow({ epic, selected, onToggleOne, prefix }: { epic: DashboardEpicItem; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  const { t } = useT("dashboard")
  return (
    <article aria-label={`${epic.display_number} ${epic.title}`} className="grid grid-cols-[auto_minmax(0,1fr)] gap-3 px-4 py-3 text-gray-700 dark:text-gray-200">
      <input aria-label={t("select_item", { title: epic.title })} checked={selected} className="mt-1" onChange={() => onToggleOne(epic.id)} type="checkbox" />
      <div className="min-w-0">
        <div className="mb-1">
          <NeutralStatePill state={epic.state} />
          <EpicStuckBadge stuck={epic.stuck} />
          <EpicProgressBar epic={epic} />
        </div>
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <SlugHoverCard id={epic.id} kind="epic">
            <span className="font-mono text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{epic.display_number}</span>
          </SlugHoverCard>
          <Link aria-label={`${epic.display_number} ${epic.title}`} className="rounded-sm text-sm font-semibold leading-snug text-blue-600 underline focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-blue-300" to={withRoutePrefix(epic.paths.epic_path, prefix)}>{epic.title}</Link>
        </div>
        {compactText(epic.description) ? <p className="mt-1 line-clamp-2 text-sm leading-snug text-gray-500 dark:text-gray-400">{compactText(epic.description)}</p> : null}
        <div className="mt-1 flex flex-wrap gap-x-2 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <RepositorySlugLink prefix={prefix} repository={epic.repository} />
          <OwnerBadge badge={epic.owner_badge} />
        </div>
      </div>
    </article>
  )
}

function EpicCell({ epic, column, selected, onToggleOne, prefix }: { epic: DashboardEpicItem; column: string; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  const { t } = useT("dashboard")
  if (column === "checkbox") {
    return <td className="px-4 py-3 align-top"><input aria-label={t("select_item", { title: epic.title })} checked={selected} onChange={() => onToggleOne(epic.id)} type="checkbox" /></td>
  }
  if (column === "epic") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(epic.paths.epic_path, prefix)}>{epic.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">
          <SlugHoverCard id={epic.id} kind="epic">{epic.display_number}</SlugHoverCard>
        </div>
      </td>
    )
  }
  if (column === "state") {
    return (
      <td className="px-4 py-3">
        <div className="flex flex-wrap gap-1">
          <NeutralStatePill state={epic.state} />
          <EpicStuckBadge stuck={epic.stuck} />
          <EpicProgressBar epic={epic} />
        </div>
      </td>
    )
  }
  if (column === "owner") return <td className="px-4 py-3 text-xs text-gray-600 dark:text-gray-300"><OwnerBadge badge={epic.owner_badge} /></td>
  if (column === "repository") {
    return <td className="px-4 py-3"><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-blue-700 hover:underline dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={epic.repository} /></td>
  }
  if (column === "updated") return <TimestampCell value={epic.updated_at} />

  return <TimestampCell value={epicDateValue(epic, column)} />
}

function WorkflowsTable({ items, columns, prefix, sortState }: { items: DashboardWorkflowItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  if (!isDesktop) return <MobileWorkflowsList items={items} prefix={prefix} />

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            {columns.map((column) => <th aria-sort={columnAriaSort("workflow", column, sortState)} className="px-4 py-2" key={column}><SortableColumnHeader column={column} sortState={sortState} subject="workflow" /></th>)}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {items.map((workflow) => (
            <tr key={workflow.id}>
              {columns.map((column) => <WorkflowCell column={column} key={column} prefix={prefix} workflow={workflow} />)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const EPIC_PROGRESS_SEGMENTS = [
  { state: "merged", barColor: "bg-emerald-700" },
  { state: "approved", barColor: "bg-green-500" },
  { state: "implemented", barColor: "bg-cyan-500" },
  { state: "blocked_by_epic", barColor: "bg-amber-400" },
]

export function EpicProgressBar({ epic, fullWidth = false }: { epic: DashboardEpicItem; fullWidth?: boolean }) {
  const { t } = useT("dashboard")
  if (epic.state !== "in_progress" || epic.jobs_count === 0) return null

  const segments = EPIC_PROGRESS_SEGMENTS.map(({ state, barColor }) => {
    const count = epic.job_state_counts[state] ?? 0
    return { state, barColor, count, percent: (count / epic.jobs_count) * 100 }
  })

  const titleText = segments
    .filter(s => s.count > 0)
    .map(s => `${s.count} ${humanizeOption(s.state)}`)
    .join(", ") || undefined

  return (
    <div
      aria-label={t("epic_progress_label")}
      className={fullWidth ? "flex h-1.5 w-full bg-gray-200 dark:bg-gray-700" : "flex h-1.5 w-20 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700"}
      role="progressbar"
      title={titleText}
    >
      {segments.map(({ state, barColor, percent }) =>
        percent > 0 ? <div className={`h-1.5 transition-[width] ${barColor}`} key={state} style={{ width: `${percent}%` }} /> : null
      )}
    </div>
  )
}

function EpicStuckBadge({ stuck }: { stuck: boolean }) {
  const { t } = useT("dashboard")
  if (!stuck) return null

  return (
    <span
      aria-label={t("needs_attention")}
      className="inline-flex items-center rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-950/60 dark:text-amber-200 dark:ring-amber-800"
      title={t("needs_attention_title")}
    >
      {t("needs_attention")}
    </span>
  )
}

function MobileWorkflowsList({ items, prefix }: { items: DashboardWorkflowItem[]; prefix: string }) {
  return (
    <div className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="divide-y divide-gray-100 dark:divide-gray-800">
        {items.map((workflow) => <MobileWorkflowRow key={workflow.id} prefix={prefix} workflow={workflow} />)}
      </div>
    </div>
  )
}

function MobileWorkflowRow({ workflow, prefix }: { prefix: string; workflow: DashboardWorkflowItem }) {
  const { t } = useT("dashboard")
  const startedAt = workflow.started_at || workflow.created_at
  const finishedAt = workflow.finished_at || workflow.cleaned_up_at
  const slug = workflowLabel(workflow)

  return (
    <Link aria-label={`${slug} ${workflow.job.title}`} className="grid grid-cols-[7.25rem_minmax(0,1fr)] gap-3 px-4 py-3 text-gray-700 hover:bg-gray-50 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-gray-200 dark:hover:bg-gray-800 dark:hover:text-white" to={withRoutePrefix(workflow.path, prefix)}>
      <div className="pt-1">
        <StatusPill state={workflow.state} />
      </div>
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span className="font-mono text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{slug}</span>
          <span className="text-sm font-semibold leading-snug text-blue-600 underline dark:text-blue-300">{workflow.job.title}</span>
        </div>
        <div className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">{workflow.job.repository.slug}</div>
        <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <span>{workflow.trigger_kind}</span>
          <span>{workflow.agent_provider}</span>
          <OwnerBadge badge={workflow.job.owner_badge} />
          {startedAt ? <span>{t("started_at", { date: formatDate(startedAt) })}</span> : null}
          {finishedAt ? <span>{t("finished_at", { date: formatDate(finishedAt) })}</span> : null}
        </div>
      </div>
    </Link>
  )
}

function SortableColumnHeader({ subject, column, sortState }: { subject: DashboardSubject; column: string; sortState: DashboardSortState }) {
  const { t } = useT("dashboard")
  const label = dashboardColumnLabel(subject, column, t)
  const sortColumn = sortableColumnFor(subject, column)
  if (!sortColumn || !sortState.sortableColumns.includes(sortColumn)) return <span>{label}</span>

  const active = sortState.column === sortColumn
  const nextDirection = active && sortState.direction === "asc" ? "desc" : "asc"
  const directionLabel = nextDirection === "asc" ? t("ascending") : t("descending")

  return (
    <button
      aria-label={t("sort_by", { label, direction: directionLabel.toLowerCase() })}
      className={`inline-flex items-center gap-1 text-left font-semibold uppercase ${active ? "text-gray-900 dark:text-gray-100" : "text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"}`}
      disabled={sortState.pending}
      onClick={() => sortState.onSort(column)}
      type="button"
    >
      <span>{label}</span>
      {active ? <span aria-hidden="true" className="text-[11px] leading-none text-gray-700 dark:text-gray-300">{sortState.direction === "asc" ? "↑" : "↓"}</span> : null}
    </button>
  )
}

function WorkflowCell({ workflow, column, prefix }: { workflow: DashboardWorkflowItem; column: string; prefix: string }) {
  if (column === "workflow" || column === "title") {
    return (
      <td className="px-4 py-3 font-medium">
        <Link className="text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(workflow.path, prefix)}>{workflowLabel(workflow)}</Link>
      </td>
    )
  }
  if (column === "state") return <td className="px-4 py-3"><StatusPill state={workflow.state} /></td>
  if (column === "job") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(workflow.job.path, prefix)}>{workflow.job.title}</Link>
        <div className="mt-1 flex flex-wrap gap-1 text-xs text-gray-500 dark:text-gray-400">
          <RepositorySlugLink prefix={prefix} repository={workflow.job.repository} />
          <OwnerBadge badge={workflow.job.owner_badge} />
        </div>
      </td>
    )
  }
  if (column === "trigger") return <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{workflow.trigger_kind}</td>
  if (column === "agent") return <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{workflow.agent_provider}</td>
  if (column === "started") return <TimestampCell value={workflow.started_at || workflow.created_at} />
  if (column === "finished") return <TimestampCell value={workflow.finished_at} />

  return <TimestampCell value={workflowDateValue(workflow, column)} />
}

function TimestampCell({ value }: { value: string | null }) {
  return (
    <td className="px-4 py-3 text-gray-500 dark:text-gray-400">
      <RelativeTimestamp value={value} />
    </td>
  )
}

function workflowLabel(workflow: Pick<DashboardWorkflowItem, "id" | "slug">) {
  return workflow.slug || workflowSlug(workflow.id)
}

function Pagination({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  const { t } = useT("dashboard")
  if (payload.total_pages <= 1) return null

  const firstItem = (payload.page - 1) * payload.per_page + 1
  const lastItem = Math.min(payload.page * payload.per_page, payload.total)

  return (
    <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-300">
      <span>{t("showing_pagination", { first: firstItem, last: lastItem, total: payload.total })}</span>
      <div className="flex gap-2">
        {payload.page > 1 ? (
          <Link className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800" to={pageLink(pathname, search, payload.page - 1)}>{t("previous")}</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600">{t("previous")}</span>
        )}
        {payload.page < payload.total_pages ? (
          <Link className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800" to={pageLink(pathname, search, payload.page + 1)}>{t("next")}</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600">{t("next")}</span>
        )}
      </div>
    </div>
  )
}

function NeutralStatePill({ state }: { state: string }) {
  return <span className="inline-flex whitespace-nowrap rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium capitalize text-gray-700 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700">{state.replace(/_/g, " ")}</span>
}

function OwnerBadge({ badge, fallback = null }: { badge: { label: string; kind: string } | null; fallback?: string | null }) {
  if (!badge && !fallback) return null

  const label = badge?.label || fallback
  const className = badge?.kind === "claimable"
    ? "rounded bg-amber-50 px-1.5 py-0.5 text-xs text-amber-700 ring-1 ring-amber-200 dark:bg-amber-950 dark:text-amber-200 dark:ring-amber-800"
    : "rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-600 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:ring-gray-700"

  return <span className={className}>{label}</span>
}

function compactText(value: string) {
  return value.replace(/\s+/g, " ").trim()
}

function formatCurrency(value: number, digits = 4) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value)
}

function pluralize(count: number, singular: string) {
  return count === 1 ? singular : `${singular}s`
}

function DashboardError({ error }: { error: Error }) {
  const { t } = useT("dashboard")
  return (
    <main aria-label={t("title")} className="p-6">
      <p className="text-sm text-red-700 dark:text-red-300">{error instanceof ApiError ? error.message : t("load_error")}</p>
    </main>
  )
}

function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

function dashboardLinkFromSearch(path: string, search: string, updates: Record<string, string | number | null | undefined>) {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) {
      params.delete(key)
    } else {
      params.set(key, String(value))
    }
  }

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function pageLink(pathname: string, search: string, page: number) {
  const params = new URLSearchParams(search)
  params.set("page", String(page))
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

function bulkButtonClass(disabled: boolean, tone: "default" | "danger" = "default") {
  if (disabled) return "rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600"
  if (tone === "danger") return "rounded border border-red-300 px-3 py-1 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"

  return "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-white dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
}

function epicTableColumns(columns: string[]) {
  return [ "checkbox", ...columns.filter((column) => column !== "checkbox") ]
}

function uniqueValue(value: string, index: number, values: string[]) {
  return values.indexOf(value) === index
}

function subjectLabel(subject: DashboardSubject, count: number) {
  const label = subject === "job" ? "job" : subject
  return count === 1 ? label : `${label}s`
}

function sortValue(sort: Record<string, string>, key: string) {
  return sort[key]
}

function sortableColumnFor(subject: DashboardSubject, column: string) {
  const aliases: Record<DashboardSubject, Record<string, string>> = {
    epic: {
      epic: "title",
      title: "title",
      updated: "updated_at"
    },
    job: {
      issue: "title",
      title: "title",
      started: "started_at"
    },
    workflow: {
      workflow: "title",
      title: "title",
      started: "started_at",
      finished: "finished_at"
    }
  }

  return aliases[subject][column] || column
}

function columnAriaSort(subject: DashboardSubject, column: string, sortState: DashboardSortState) {
  const sortColumn = sortableColumnFor(subject, column)
  if (!sortColumn || sortState.column !== sortColumn) return undefined

  return sortState.direction === "asc" ? "ascending" : "descending"
}

function dashboardColumnLabel(subject: DashboardSubject, column: string, t: (key: string, opts?: Record<string, unknown>) => string) {
  // The workflow table uses "title" column key but displays it as "Workflow"
  const i18nKey = subject === "workflow" && column === "title" ? "workflow_title" : column
  return t(`column_label.${i18nKey}`, { defaultValue: humanizeOption(column) })
}

function dashboardVisibleColumns(payload: DashboardPayload) {
  const allowed = new Set([
    ...payload.controls.columns.required.map((column) => column.key),
    ...payload.controls.columns.optional.map((column) => column.key)
  ])
  const normalized = [
    ...payload.controls.columns.required.map((column) => column.key),
    ...payload.preferences.visible_columns.map((column) => normalizeDashboardColumn(payload.subject, column))
  ]

  return normalized.filter((column, index, columns) => allowed.has(column) && columns.indexOf(column) === index)
}

function normalizeDashboardColumn(subject: DashboardSubject, column: string) {
  if (subject === "job" && column === "title") return "issue"
  if (subject === "workflow" && column === "title") return "workflow"

  return column
}

function jobDateValue(job: DashboardJobItem, column: string) {
  const values: Record<string, string | null> = {
    started: job.started_at,
    created_at: job.created_at,
    updated_at: job.updated_at,
    started_at: job.started_at,
    finished_at: job.finished_at,
    approved_at: job.approved_at,
    dependencies_overridden_at: job.dependencies_overridden_at,
    last_feedback_addressed_at: job.last_feedback_addressed_at,
    last_seen_comment_at: job.last_seen_comment_at,
    pr_mergeable_checked_at: job.pr_mergeable_checked_at
  }

  return values[column] || null
}

function epicDateValue(epic: DashboardEpicItem, column: string) {
  const values: Record<string, string | null> = {
    created_at: epic.created_at,
    updated_at: epic.updated_at,
    done_at: epic.done_at,
    archived_at: epic.archived_at
  }

  return values[column] || null
}

function workflowDateValue(workflow: DashboardWorkflowItem, column: string) {
  const values: Record<string, string | null> = {
    created_at: workflow.created_at,
    updated_at: workflow.updated_at,
    started_at: workflow.started_at,
    finished_at: workflow.finished_at,
    cleaned_up_at: workflow.cleaned_up_at
  }

  return values[column] || null
}

function humanizeOption(value: string) {
  return value.replace(/_/g, " ").replace(/^\w/, (match) => match.toUpperCase())
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}

function formatDate(value: string | null) {
  if (!value) return "-"

  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function RelativeTimestamp({ value }: { value: string | null }) {
  if (!value) return <>-</>

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <>-</>

  return (
    <time dateTime={value} title={formatDate(value)}>
      {formatRelativeDate(date)}
    </time>
  )
}

function formatRelativeDate(date: Date) {
  const seconds = Math.round((date.getTime() - Date.now()) / 1000)
  const absSeconds = Math.abs(seconds)
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
    ["second", 1]
  ]

  const [unit, divisor] = units.find(([, unitSeconds]) => absSeconds >= unitSeconds) || ["second", 1]
  const value = Math.round(seconds / divisor)

  return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(value, unit)
}
