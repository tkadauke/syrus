import { useMediaQuery } from "./dashboard/components"
import { DashboardKanban } from "./dashboard/KanbanBoard"
import { JobsDashboardTable } from "./dashboard/JobsTable"
import { EpicsTable, SimpleFeaturesTable, WorkflowsTable } from "./dashboard/EpicWorkflowTables"
import { dashboardEmptyState, dashboardLinkFromSearch, dashboardVisibleColumns, epicTableColumns, pageLink, sortValue, sortableColumnFor, subjectLabel, uniqueValue, withRoutePrefix } from "./dashboard/helpers"
import type { DashboardSortState } from "./dashboard/helpers"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useBackendOutage } from "../hooks/useBackendUpdate"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { ApiError } from "../api/client"
import { DashboardSmartFolderNav, smartFolderIdFromSearch } from "../components/DashboardSmartFolderNav"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { CloseIcon } from "../components/CloseIcon"
import { TonePill } from "../components/StatusPill"
import { FilterBar } from "../components/FilterBar"
import { SyrusTour } from "../components/SyrusTour"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { useTour } from "../hooks/useTour"
import { dashboardApiSearch, dashboardChromeSearch, fetchDashboardChrome, fetchDashboardRows, fetchEpicsGraph, fetchJobsGraph, mergeDashboardPayload, recordDashboardFilterUsage, requestDashboardMainBranchRepair, updateDashboardPreferences, type DashboardHealthBlockedRepository, type DashboardEpicItem, type DashboardJobItem, type DashboardPayload, type DashboardSubject, type DashboardWorkflowItem } from "../api/dashboard"
import { TopoDepGraph } from "../components/TopoDepGraph"
import { errorMessage } from "../lib/errorMessage"

export function DashboardRoute() {
  const { t } = useT("dashboard")
  usePageTitle(t("title"))
  const location = useLocation()
  const search = dashboardApiSearch(location.pathname, location.search)
  const chromeSearch = dashboardChromeSearch(location.pathname, location.search)
  const dashboardChrome = useQuery({
    queryKey: ["dashboard", "chrome", chromeSearch],
    queryFn: ({ signal }) => fetchDashboardChrome(chromeSearch, { signal }),
    placeholderData: (previousData) => previousData
  })
  const dashboardRows = useQuery({
    queryKey: ["dashboard", "rows", search],
    queryFn: ({ signal }) => fetchDashboardRows(search, { signal }),
    placeholderData: (previousData) => previousData
  })
  const payload = useMemo(() => {
    if (!dashboardChrome.data || !dashboardRows.data) return null

    return mergeDashboardPayload(dashboardChrome.data, dashboardRows.data, { rowsCurrentForSearch: !dashboardRows.isPlaceholderData })
  }, [dashboardChrome.data, dashboardRows.data, dashboardRows.isPlaceholderData])

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
    <main aria-label={t("title")} className="mx-auto max-w-[96rem] space-y-5 px-0 py-4 sm:p-6">
      <header className="flex flex-wrap items-center gap-3 px-4 sm:px-0">
        <h1 className="flex-1 text-3xl font-semibold text-gray-900 dark:text-white">{payload.simple_mode ? t("simple_title") : t("title")}</h1>
        {isDesktop && !payload.simple_mode ? <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={true} isDesktop={isDesktop} /> : null}
        <DashboardCreateActions payload={payload} prefix={prefix} />
      </header>
      <ReadinessPanel className="mx-4 sm:mx-0" prefix={prefix} readiness={readiness} />
      <RepositoryHealthBanners className="mx-4 sm:mx-0" prefix={prefix} repositories={payload.health_blocked_repositories ?? payload.broken_repositories ?? []} />

      {isDesktop ? (
        <>
          {payload.simple_mode ? null : <DesktopDashboardControls pathname={pathname} payload={payload} search={search} />}
          <DashboardContent pathname={pathname} payload={payload} prefix={prefix} search={search} />
        </>
      ) : (
        <>
          {payload.simple_mode ? null : <MobileDashboardControls pathname={pathname} payload={payload} prefix={prefix} search={search} />}
          <DashboardContent pathname={pathname} payload={payload} prefix={prefix} search={search} />
        </>
      )}
      <DashboardTour />
    </main>
  )
}

export function DashboardTour() {
  const { run, handleJoyrideCallback } = useTour("dashboard")
  const { t } = useT("tours")

  const steps = [
    {
      target: "[data-tour='dashboard-filter-bar']",
      title: t("dashboard.filter_chips_title"),
      content: t("dashboard.filter_chips_content"),
      placement: "bottom" as const,
      disableBeacon: true,
    },
    {
      target: "[data-tour='dashboard-view-switcher']",
      title: t("dashboard.view_switcher_title"),
      content: t("dashboard.view_switcher_content"),
      placement: "bottom-end" as const,
    },
    {
      target: "[data-tour='dashboard-create-actions']",
      title: t("dashboard.create_actions_title"),
      content: t("dashboard.create_actions_content"),
      placement: "bottom-end" as const,
    },
    {
      target: "[data-tour='dashboard-table']",
      title: t("dashboard.job_row_title"),
      content: t("dashboard.job_row_content"),
      placement: "top" as const,
    },
  ]

  return <SyrusTour run={run} steps={steps} onEvent={(data) => handleJoyrideCallback(data)} />
}

export function ReadinessPanel({ className = "", prefix, readiness }: { className?: string; prefix: string; readiness?: NonNullable<NonNullable<BootstrapPayload["setup_status"]>["readiness"]> }) {
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
    <section aria-label={t("system_readiness")} className={`${className} rounded border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950/40`}>
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

function RepositoryHealthBanners({ className = "", prefix, repositories }: { className?: string; prefix: string; repositories: DashboardHealthBlockedRepository[] }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [dismissed, setDismissed] = useState<Set<number>>(() => new Set())
  const requestRepair = useMutation({
    mutationFn: requestDashboardMainBranchRepair,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const visible = repositories.filter((repo) => !dismissed.has(repo.id))

  if (visible.length === 0) return null

  return (
    <div className={`${className} space-y-2`}>
      {visible.map((repo) => {
        const repair = repo.main_branch_repair
        const blockingJob = repair?.blocking_job
        const failedJobs = repair?.failed_jobs ?? []
        const isStartingRepair = requestRepair.isPending && requestRepair.variables === repo.repair_path
        const repairError = requestRepair.isError && requestRepair.variables === repo.repair_path
          ? (requestRepair.error instanceof Error ? requestRepair.error.message : t("broken_main_repair_start_failed"))
          : null

        return (
          <div className="flex flex-col gap-2 rounded border border-red-200 bg-red-50 px-4 py-3 text-sm dark:border-red-900 dark:bg-red-950/40 sm:flex-row sm:items-center sm:justify-between" key={repo.id} role="alert">
            <div className="min-w-0">
              <span className="text-red-800 dark:text-red-200">
                <span className="font-mono font-medium">{repo.slug}</span>
                {" — "}{t(repo.main_health === "inconclusive"
                  ? "main_health_inconclusive_banner_not_held"
                  : (repo.landing_paused ? "broken_main_banner" : "broken_main_banner_not_held")
                )}
              </span>
              {repair ? (
                <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-red-700 dark:text-red-200">
                  {blockingJob ? (
                    <span>
                      {t(repair.blocked_reason === "active" ? "broken_main_repair_active" : repair.blocked_reason === "landing" ? "broken_main_repair_landing" : "broken_main_repair_waiting")}{" "}
                      <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(blockingJob.job_path, prefix)}>
                        {blockingJob.slug}
                      </Link>
                    </span>
                  ) : null}
                  {failedJobs.length > 0 ? (
                    <span>
                      {t("broken_main_repair_failed_jobs")}{" "}
                      {failedJobs.map((job, index) => (
                        <span key={job.id}>
                          {index > 0 ? ", " : null}
                          <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(job.job_path, prefix)}>
                            {job.slug}
                          </Link>
                        </span>
                      ))}
                    </span>
                  ) : null}
                  {repair.blocked_reason === "waiting_for_health_signals" ? <span>{t("broken_main_repair_waiting_for_signals")}</span> : null}
                  {repair.blocked_reason === "failed_open_cap" ? <span>{t("broken_main_repair_cap")}</span> : null}
                  {repairError ? <span className="font-medium">{repairError}</span> : null}
                </div>
              ) : null}
            </div>
            <div className="flex shrink-0 items-center gap-2">
              {repair?.can_request ? (
                <button
                  className="rounded border border-red-300 bg-white px-2 py-1 text-xs font-medium text-red-800 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-60 dark:border-red-800 dark:bg-red-950 dark:text-red-200 dark:hover:bg-red-900"
                  disabled={isStartingRepair}
                  onClick={() => requestRepair.mutate(repo.repair_path)}
                  type="button"
                >
                  {isStartingRepair ? t("broken_main_repair_starting") : t("broken_main_repair_start")}
                </button>
              ) : null}
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
        )
      })}
    </div>
  )
}

function DesktopDashboardControls({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  return <div data-tour="dashboard-filter-bar"><DashboardFilterBar pathname={pathname} search={search} payload={payload} /></div>
}

function MobileDashboardControls({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  const { t } = useT("dashboard")
  return (
    <div className="space-y-3 px-4 sm:px-0">
      <div aria-label={t("controls_label")} className="flex items-center justify-between gap-3 pb-1" role="group">
        <div className="min-w-0 flex-1 overflow-x-auto">
          <SubjectTabs className="inline-flex w-max flex-nowrap overflow-hidden rounded border border-gray-300 bg-white text-sm dark:border-gray-700 dark:bg-gray-900" payload={payload} prefix={prefix} />
        </div>
        <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={false} isDesktop={false} />
      </div>
      <details className="group rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium text-gray-700 dark:text-gray-200">
          <span>{t("folders_and_filters")}</span>
          <span className="text-gray-400 group-open:hidden dark:text-gray-500">{t("show")}</span>
          <span className="hidden text-gray-400 group-open:inline dark:text-gray-500">{t("hide")}</span>
        </summary>
        <div className="space-y-4 border-t border-gray-200 p-4 dark:border-gray-700">
          <div data-tour="dashboard-filter-bar"><DashboardFilterBar pathname={pathname} search={search} payload={payload} /></div>
          <DashboardSmartFolderNav payload={payload} prefix={prefix} search={search} />
        </div>
      </details>
    </div>
  )
}

export function graphSearchWithSmartFolder(rawSearch: string, activeSfId: number | null): string {
  const params = new URLSearchParams(rawSearch.startsWith("?") ? rawSearch.slice(1) : rawSearch)
  if (!params.has("smart_folder_id") && !params.has("q") && activeSfId != null) {
    params.set("smart_folder_id", String(activeSfId))
  }
  const str = params.toString()
  return str ? `?${str}` : ""
}

export function DashboardContent({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  const setupStatus = useSetupStatus()
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { t } = useT("dashboard")

  if (payload.view === "dependencies") {
    if (!isDesktop) {
      return (
        <section className="min-w-0 space-y-4">
          <div className="mx-4 rounded border border-gray-200 bg-white p-6 text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400 sm:mx-0">{t("dependencies_mobile_unavailable")}</div>
        </section>
      )
    }
    const graphSearch = graphSearchWithSmartFolder(
      dashboardApiSearch(pathname, search),
      payload.active_smart_folder_id
    )
    return (
      <section className="min-w-0 space-y-4">
        <DashboardDependencyView payload={payload} graphSearch={graphSearch} />
      </section>
    )
  }

  return (
    <section className="min-w-0 space-y-4" data-tour="dashboard-table">
      <DashboardTable payload={payload} pathname={pathname} prefix={prefix} search={search} setupStatus={setupStatus} />
      {payload.view === "list" ? <Pagination pathname={pathname} search={search} payload={payload} /> : null}
    </section>
  )
}

export function DashboardDependencyView({ payload, graphSearch }: { payload: DashboardPayload; graphSearch: string }) {
  const { t } = useT("dashboard")
  const subject = payload.subject

  const graphQuery = useQuery({
    queryKey: ["dashboard", "graph", subject, graphSearch],
    queryFn: ({ signal }) =>
      subject === "job" ? fetchJobsGraph(graphSearch, { signal }) : fetchEpicsGraph(graphSearch, { signal }),
    enabled: subject === "job" || subject === "epic",
    placeholderData: (previousData) => previousData
  })

  if (subject === "workflow") return null

  if (graphQuery.isPending) {
    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">{t("loading")}</div>
  }

  if (graphQuery.isError) {
    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-red-700 dark:border-gray-700 dark:bg-gray-900 dark:text-red-300" role="alert">{t("load_error")}</div>
  }

  const { nodes, edges } = graphQuery.data ?? { nodes: [], edges: [] }

  if (nodes.length === 0) {
    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">{t("no_match", { subject: subjectLabel(subject, 2) })}</div>
  }

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white p-6 dark:border-gray-700 dark:bg-gray-900">
      {edges.length === 0 && (
        <p className="mb-3 text-sm text-gray-500 dark:text-gray-400">{t("no_dependency_edges")}</p>
      )}
      <TopoDepGraph nodes={nodes} edges={edges} />
    </div>
  )
}

function DashboardCreateActions({ payload, prefix }: { payload: DashboardPayload; prefix: string }) {
  const { t } = useT("dashboard")
  return (
    <div className="flex flex-wrap gap-2" data-tour="dashboard-create-actions">
      <Link className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500" to={withRoutePrefix(payload.paths.new_epic_path, prefix)}>{payload.simple_mode ? t("new_feature") : t("new_epic")}</Link>
      {payload.simple_mode ? null : <Link className="rounded bg-green-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-green-500" to={withRoutePrefix(payload.paths.new_job_path, prefix)}>{t("new_job")}</Link>}
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

export function DashboardToolbar({ payload, pathname, search, showConfiguration = true, isDesktop = true }: { payload: DashboardPayload; pathname: string; search: string; showConfiguration?: boolean; isDesktop?: boolean }) {
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
  const viewTabs = isDesktop ? payload.controls.views : payload.controls.views.filter((view) => view !== "dependencies")

  return (
    <div className="shrink-0">
      <div className="flex flex-wrap items-center justify-end gap-3">
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
        <nav aria-label={t("view_label")} className="inline-flex overflow-hidden rounded border border-gray-300 bg-white text-sm dark:border-gray-700 dark:bg-gray-900">
          {viewTabs.map((view) => (
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
  const activeSmartFolderId = smartFolderIdFromSearch(search) ?? payload.active_smart_folder_id
  const activeFolder = payload.smart_folders.find((folder) => folder.id === activeSmartFolderId)
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

const legacyFilterKeys = ["state", "repository_id", "kind", "trigger_kind", "job_id", "attention", "start_blocked", "tag_ids", "pr", "age"]

export function DashboardTable({ payload, pathname = "", prefix, search = "", setupStatus }: { payload: DashboardPayload; pathname?: string; prefix: string; search?: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
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
  const isOnLandingQueueFolder = payload.smart_folders.some(
    (f) => f.id === payload.active_smart_folder_id && f.attention_preset === "landing_queue"
  )
  const queueSortOutsideLanding = payload.subject === "job" && storedSortColumn === "landing_queue_position" && !isOnLandingQueueFolder
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

  if (payload.view === "kanban") return <DashboardKanban payload={payload} prefix={prefix} rowsSearch={dashboardApiSearch(pathname, search)} setupStatus={setupStatus} />

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

    return <div className="mx-4 rounded border border-gray-200 bg-white p-6 text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400 sm:mx-0">{t("no_match", { subject: subjectLabel(payload.subject, 2) })}</div>
  }

  const columns = dashboardVisibleColumns(payload)
  const items = payload.items ?? []
  if (payload.simple_mode) return <SimpleFeaturesTable items={items.filter((item): item is DashboardEpicItem => item.type === "epic")} prefix={prefix} />
  if (payload.subject === "job") return <JobsDashboardTable columns={columns} items={items.filter((item): item is DashboardJobItem => item.type === "job")} landingQueueEntries={payload.landing_queue.entries ?? []} prefix={prefix} sortState={sortState} t={t} />
  if (payload.subject === "workflow") return <WorkflowsTable columns={columns} items={items.filter((item): item is DashboardWorkflowItem => item.type === "workflow")} prefix={prefix} sortState={sortState} />

  return <EpicsTable columns={epicTableColumns(columns)} items={items.filter((item): item is DashboardEpicItem => item.type === "epic")} prefix={prefix} sortState={sortState} />
}

function Pagination({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  const { t } = useT("dashboard")
  if (payload.total_pages <= 1) return null

  const firstItem = (payload.page - 1) * payload.per_page + 1
  const lastItem = Math.min(payload.page * payload.per_page, payload.total)

  return (
    <div className="mx-4 flex items-center justify-between text-sm text-gray-600 dark:text-gray-300 sm:mx-0">
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

function DashboardError({ error }: { error: Error }) {
  const { t } = useT("dashboard")
  return (
    <main aria-label={t("title")} className="p-6">
      <p className="text-sm text-red-700 dark:text-red-300">{error instanceof ApiError ? error.message : t("load_error")}</p>
    </main>
  )
}
