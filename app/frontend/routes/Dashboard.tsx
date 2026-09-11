import { useMediaQuery } from "./dashboard/components"
import { DashboardKanban } from "./dashboard/KanbanBoard"
import { JobsDashboardTable, SimpleJobsTable } from "./dashboard/JobsTable"
import { EpicsTable, SimpleFeaturesTable, WorkflowsTable } from "./dashboard/EpicWorkflowTables"
import { dashboardEmptyState, dashboardLinkFromSearch, dashboardVisibleColumns, epicTableColumns, pageLink, sortValue, sortableColumnFor, subjectLabel, uniqueValue, withRoutePrefix } from "./dashboard/helpers"
import type { DashboardSortState } from "./dashboard/helpers"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useBackendOutage } from "../hooks/useBackendUpdate"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { ApiError } from "../api/client"
import { Button, buttonClasses } from "../components/Button"
import { Checkbox } from "../components/Checkbox"
import { DashboardSmartFolderNav, smartFolderIdFromSearch } from "../components/DashboardSmartFolderNav"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import { CloseIcon } from "../components/CloseIcon"
import { PageHeading } from "../components/Heading"
import { TonePill } from "../components/StatusPill"
import { FilterBar } from "../components/FilterBar"
import { Notice, Page, Section, Surface, Text } from "../components/ui"
import { SyrusTour } from "../components/SyrusTour"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { useTour } from "../hooks/useTour"
import { dashboardApiSearch, dashboardChromeSearch, dashboardSubjectFromPath, fetchDashboardChromeWithMeta, fetchDashboardRowsWithMeta, fetchEpicsGraph, fetchJobsGraph, mergeDashboardPayload, recordDashboardFilterUsage, requestDashboardMainBranchRepair, updateDashboardPreferences, type DashboardHealthBlockedRepository, type DashboardEpicItem, type DashboardJobItem, type DashboardPayload, type DashboardSubject, type DashboardUntaggedIssues, type DashboardWorkflowItem } from "../api/dashboard"
import type { JsonResponseMeta } from "../api/client"
import { TopoDepGraph } from "../components/TopoDepGraph"
import { errorMessage } from "../lib/errorMessage"
import { apiRequestTrace, browserTraceId, recordBrowserTrace, type BrowserTraceSpan } from "../lib/performanceTrace"

export function DashboardRoute() {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  usePageTitle(t("title"))
  const location = useLocation()
  const search = dashboardApiSearch(location.pathname, location.search)
  const chromeSearch = dashboardChromeSearch(location.pathname, location.search)
  const traceKey = `${location.pathname}?${search}`
  const activeTrace = useRef<{ key: string; traceId: string; startedAt: number } | null>(null)
  const reportedTraceKey = useRef<string | null>(null)
  const chromeMeta = useRef<JsonResponseMeta | null>(null)
  const rowsMeta = useRef<JsonResponseMeta | null>(null)
  if (activeTrace.current?.key !== traceKey) {
    activeTrace.current = { key: traceKey, traceId: browserTraceId("dashboard"), startedAt: performance.now() }
    chromeMeta.current = null
    rowsMeta.current = null
  }
  const dashboardChrome = useQuery({
    queryKey: ["dashboard", "chrome", chromeSearch],
    queryFn: async ({ signal }) => {
      const response = await fetchDashboardChromeWithMeta(chromeSearch, { signal })
      chromeMeta.current = response.meta
      return response.data
    },
    placeholderData: (previousData) => previousData
  })
  const dashboardRows = useQuery({
    queryKey: ["dashboard", "rows", search],
    queryFn: async ({ signal }) => {
      const response = await fetchDashboardRowsWithMeta(search, { signal })
      rowsMeta.current = response.meta
      return response.data
    },
    placeholderData: (previousData) => previousData
  })
  const payload = useMemo(() => {
    if (!dashboardChrome.data || !dashboardRows.data) return null

    return mergeDashboardPayload(dashboardChrome.data, dashboardRows.data, { rowsCurrentForSearch: !dashboardRows.isPlaceholderData })
  }, [dashboardChrome.data, dashboardRows.data, dashboardRows.isPlaceholderData])
  useEffect(() => {
    if (!payload || payload.rows_current_for_search === false) return
    const bootstrap = queryClient.getQueryData<BootstrapPayload>(["bootstrap"]) ?? readInitialBootstrap()
    const loggingEnabled = bootstrap?.feature_flags?.performance_logging === true
    if (!loggingEnabled) return
    const trace = activeTrace.current
    if (!trace || trace.key !== traceKey || reportedTraceKey.current === traceKey) return

    reportedTraceKey.current = traceKey
    recordDashboardBrowserTrace({
      traceId: trace.traceId,
      tracePath: dashboardTracePath(location.pathname, location.search),
      startedAt: trace.startedAt,
      payload,
      chromeMeta: chromeMeta.current,
      rowsMeta: rowsMeta.current,
      loggingEnabled
    })
  }, [dashboardChrome.data, dashboardRows.data, payload, queryClient, traceKey])

  if (!payload && (dashboardChrome.isPending || dashboardRows.isPending)) return <Page.Root aria-label={t("title")}><Text muted>{t("loading")}</Text></Page.Root>
  if (dashboardChrome.isError) return <DashboardError error={dashboardChrome.error} />
  if (dashboardRows.isError) return <DashboardError error={dashboardRows.error} />
  if (!payload) return <Page.Root aria-label={t("title")}><Text muted>{t("loading")}</Text></Page.Root>

  return <DashboardView pathname={location.pathname} search={location.search} payload={payload} />
}

function recordDashboardBrowserTrace({ chromeMeta, loggingEnabled, payload, rowsMeta, startedAt, traceId, tracePath }: { chromeMeta: JsonResponseMeta | null; loggingEnabled: boolean; payload: DashboardPayload; rowsMeta: JsonResponseMeta | null; startedAt: number; traceId: string; tracePath: string }) {
  const totalDuration = Math.max(0, performance.now() - startedAt)
  const apiRequests = [
    apiRequestTrace("dashboard.chrome", sanitizedDashboardRequestMeta(chromeMeta)),
    apiRequestTrace("dashboard.rows", sanitizedDashboardRequestMeta(rowsMeta))
  ].filter((request): request is NonNullable<typeof request> => request != null)
  const apiDuration = apiRequests.reduce((sum, request) => sum + request.duration_ms, 0)
  recordBrowserTrace({
    trace_id: traceId,
    name: "dashboard.route",
    path: tracePath,
    duration_ms: totalDuration,
    visibility_state: document.visibilityState || "unknown",
    metadata: {
      subject: payload.subject,
      view: payload.view,
      page: payload.page,
      rows_count: payload.items?.length ?? 0,
      total: payload.total,
      total_estimated: payload.total_estimated === true,
      smart_folder_id: payload.active_smart_folder_id
    },
    api_requests: apiRequests,
    spans: dashboardTraceSpans({ apiRequests, apiDuration, totalDuration })
  }, { enabled: loggingEnabled })
}

function dashboardTraceSpans({ apiDuration, apiRequests, totalDuration }: { apiDuration: number; apiRequests: Array<{ name: string; duration_ms: number }>; totalDuration: number }): BrowserTraceSpan[] {
  const spans: BrowserTraceSpan[] = apiRequests.map((request) => ({
    name: `api.${request.name}`,
    duration_ms: request.duration_ms
  }))
  spans.push({
    name: "frontend.after_api",
    duration_ms: Math.max(0, Math.round((totalDuration - apiDuration) * 10) / 10),
    metadata: { api_request_count: apiRequests.length }
  })
  return spans
}

function dashboardTracePath(pathname: string, rawSearch: string): string {
  const params = sanitizedDashboardSearchParams(rawSearch)
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

function sanitizedDashboardRequestMeta(meta: JsonResponseMeta | null): JsonResponseMeta | null {
  if (!meta) return null
  const url = new URL(meta.path, window.location.origin)
  const query = sanitizedDashboardSearchParams(url.search)
  query.set("section", url.searchParams.get("section") || "rows")
  return { ...meta, path: `${url.pathname}?${query.toString()}` }
}

function sanitizedDashboardSearchParams(rawSearch: string): URLSearchParams {
  const source = new URLSearchParams(rawSearch.startsWith("?") ? rawSearch.slice(1) : rawSearch)
  const params = new URLSearchParams()
  for (const key of ["subject", "view", "smart_folder_id", "page", "scope", "ownership_scope"]) {
    const value = source.get(key)
    if (value != null) params.set(key, value)
  }
  return params
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
  const isLegacyEpicsView = payload.simple_mode && payload.subject === "epic"

  return (
    <Page.Root aria-label={t("title")} className="space-y-5 px-0 py-4 sm:p-6" size="wide">
      <Page.Header className="items-center gap-3 px-4 sm:px-0">
        <PageHeading className="flex-1">{isLegacyEpicsView ? t("legacy_epics_title") : payload.simple_mode ? t("simple_title") : t("title")}</PageHeading>
        {isDesktop && !payload.simple_mode ? <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={true} isDesktop={isDesktop} /> : null}
        <DashboardCreateActions payload={payload} prefix={prefix} />
      </Page.Header>
      {isLegacyEpicsView ? <LegacyEpicsBanner className="mx-4 sm:mx-0" /> : null}
      <ReadinessPanel className="mx-4 sm:mx-0" prefix={prefix} readiness={readiness} />
      <RepositoryHealthBanners className="mx-4 sm:mx-0" prefix={prefix} repositories={payload.health_blocked_repositories ?? payload.broken_repositories ?? []} />
      <UntaggedIssuesBanner className="mx-4 sm:mx-0" prefix={prefix} untaggedIssues={payload.untagged_issues} />

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
      <DashboardTour simpleMode={payload.simple_mode} />
    </Page.Root>
  )
}

export function DashboardTour({ simpleMode = false }: { simpleMode?: boolean }) {
  const { run, handleJoyrideCallback } = useTour("dashboard")
  const { t } = useT("tours")

  const steps = [
    ...(simpleMode
      ? []
      : [
          {
            target: "[data-tour='dashboard-filter-bar']",
            title: t("dashboard.filter_chips_title"),
            content: t("dashboard.filter_chips_content"),
            placement: "bottom" as const,
            disableBeacon: true,
          }
        ]),
    {
      target: "[data-tour='dashboard-view-switcher']",
      title: t("dashboard.view_switcher_title"),
      content: t("dashboard.view_switcher_content"),
      placement: "bottom-end" as const,
    },
    {
      target: "[data-tour='dashboard-create-actions']",
      title: simpleMode ? t("dashboard.create_actions_title_simple") : t("dashboard.create_actions_title"),
      content: simpleMode ? t("dashboard.create_actions_content_simple") : t("dashboard.create_actions_content"),
      placement: "bottom-end" as const,
    },
    {
      target: "[data-tour='dashboard-table']",
      title: simpleMode ? t("dashboard.job_row_title_simple") : t("dashboard.job_row_title"),
      content: simpleMode ? t("dashboard.job_row_content_simple") : t("dashboard.job_row_content"),
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
    <Section.Root aria-label={t("system_readiness")} className={className} tone="warning">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Text as="h2" tone="warning" variant="heading-sm">{t("readiness_title")}</Text>
          <Text className="mt-1" tone="warning">{t("readiness_description")}</Text>
        </div>
        <Link className={buttonClasses("secondary", "sm")} to={`${prefix}/credentials`}>
          {t("open_settings")}
        </Link>
      </div>
      <div className="mt-3 grid gap-2 lg:grid-cols-2">
        {failingChecks.map((check) => (
          <Surface padding="sm" variant="inset" key={check.key}>
            <div className="flex items-center gap-2">
              <TonePill tone={check.status === "error" ? "red" : "amber"}>{check.status}</TonePill>
              <Text as="h3" variant="heading-sm">{check.label}</Text>
              {check.optional ? <Text as="span" muted variant="caption">{t("optional")}</Text> : null}
            </div>
            <Text className="mt-2">{check.message}</Text>
            {check.remediation ? <Text className="mt-1" muted>{check.remediation}</Text> : null}
          </Surface>
        ))}
      </div>
    </Section.Root>
  )
}

const HEALTH_BANNER_DISMISSALS_KEY = "syrus.health_banner_dismissals"

function healthBannerEvidenceToken(repo: DashboardHealthBlockedRepository): string {
  return `${repo.ci_health}:${repo.grader_health}`
}

function readHealthBannerDismissals(): Record<string, string> {
  try {
    const raw = window.localStorage.getItem(HEALTH_BANNER_DISMISSALS_KEY)
    const value = raw ? JSON.parse(raw) : {}
    return typeof value === "object" && value !== null && !Array.isArray(value) ? value : {}
  } catch {
    return {}
  }
}

function writeHealthBannerDismissals(dismissals: Record<string, string>): void {
  try {
    window.localStorage.setItem(HEALTH_BANNER_DISMISSALS_KEY, JSON.stringify(dismissals))
  } catch {
    // localStorage can be unavailable in private or restricted browser contexts.
  }
}

export function RepositoryHealthBanners({ className = "", prefix, repositories }: { className?: string; prefix: string; repositories: DashboardHealthBlockedRepository[] }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [dismissals, setDismissals] = useState<Record<string, string>>(() => readHealthBannerDismissals())
  const requestRepair = useMutation({
    mutationFn: requestDashboardMainBranchRepair,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const visible = repositories.filter((repo) => dismissals[repo.id] !== healthBannerEvidenceToken(repo))

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
          <Notice className="px-4 py-3" contentClassName="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between" key={repo.id} role="alert" tone="danger">
            <div className="min-w-0">
              <span>
                <span className="font-mono font-medium">{repo.slug}</span>
                {" — "}{t(repo.main_health === "inconclusive"
                  ? "main_health_inconclusive_banner_not_held"
                  : (repo.landing_paused && repo.main_branch_repair_blocks_work ? "broken_main_banner" : "broken_main_banner_not_held")
                )}
              </span>
              {repair ? (
                <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
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
                  className={buttonClasses("secondary", "sm", "disabled:cursor-not-allowed disabled:opacity-60")}
                  disabled={isStartingRepair}
                  onClick={() => requestRepair.mutate(repo.repair_path)}
                  type="button"
                >
                  {isStartingRepair ? t("broken_main_repair_starting") : t("broken_main_repair_start")}
                </button>
              ) : null}
              <Link
                className={buttonClasses("secondary", "sm")}
                to={withRoutePrefix(repo.repository_path, prefix)}
              >
                {t("broken_main_view_details")}
              </Link>
              <button
                aria-label={t("broken_main_dismiss")}
                className="text-danger hover:text-danger-text"
                onClick={() => setDismissals((prev) => {
                  const next = { ...prev, [repo.id]: healthBannerEvidenceToken(repo) }
                  writeHealthBannerDismissals(next)
                  return next
                })}
                type="button"
              >
                <CloseIcon />
              </button>
            </div>
          </Notice>
        )
      })}
    </div>
  )
}

const UNTAGGED_ISSUES_DISMISSAL_KEY = "syrus.untagged_issues_banner_dismissed"

function untaggedIssuesEvidenceToken(untaggedIssues: DashboardUntaggedIssues): string {
  return `${untaggedIssues.total}:${untaggedIssues.repositories.map((repo) => `${repo.id}:${repo.count}`).join(",")}`
}

function readUntaggedIssuesDismissal(): string | null {
  try {
    return window.sessionStorage.getItem(UNTAGGED_ISSUES_DISMISSAL_KEY)
  } catch {
    return null
  }
}

function writeUntaggedIssuesDismissal(token: string): void {
  try {
    window.sessionStorage.setItem(UNTAGGED_ISSUES_DISMISSAL_KEY, token)
  } catch {
    // sessionStorage can be unavailable in private or restricted browser contexts.
  }
}

export function LegacyEpicsBanner({ className = "" }: { className?: string }) {
  const { t } = useT("dashboard")

  return (
    <Notice className={className} role="status" tone="info">
      {t("legacy_epics_banner")}
    </Notice>
  )
}

export function UntaggedIssuesBanner({ className = "", prefix, untaggedIssues }: { className?: string; prefix: string; untaggedIssues?: DashboardUntaggedIssues }) {
  const { t } = useT("dashboard")
  const [dismissedToken, setDismissedToken] = useState<string | null>(() => readUntaggedIssuesDismissal())

  if (!untaggedIssues || untaggedIssues.total === 0 || untaggedIssues.repositories.length === 0) return null

  const token = untaggedIssuesEvidenceToken(untaggedIssues)
  if (dismissedToken === token) return null

  return (
    <Notice className={className} contentClassName="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between" role="status" tone="warning">
      <div className="min-w-0">
        <span>
          {t("untagged_issues_summary", { count: untaggedIssues.total })}{" "}
          {t("untagged_issues_repo_count", { count: untaggedIssues.repositories.length })}
        </span>
        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
          {untaggedIssues.repositories.map((repo, index) => (
            <span key={repo.id}>
              {index > 0 ? ", " : null}
              <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(repo.issues_path, prefix)}>
                {repo.slug} ({repo.count})
              </Link>
            </span>
          ))}
        </div>
      </div>
      <button
        aria-label={t("untagged_issues_dismiss")}
        className="shrink-0 text-warning hover:text-warning-text"
        onClick={() => {
          setDismissedToken(token)
          writeUntaggedIssuesDismissal(token)
        }}
        type="button"
      >
        <CloseIcon />
      </button>
    </Notice>
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
          <SubjectTabs className="inline-flex w-max flex-nowrap overflow-hidden rounded-[var(--radius-control)] border border-border bg-surface text-sm" pathname={pathname} payload={payload} prefix={prefix} />
        </div>
        <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={false} isDesktop={false} />
      </div>
      <details className="group rounded-[var(--radius-panel)] border border-border bg-surface text-text-primary">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium">
          <span>{t("folders_and_filters")}</span>
          <Text as="span" className="group-open:hidden" muted variant="caption">{t("show")}</Text>
          <Text as="span" className="hidden group-open:inline" muted variant="caption">{t("hide")}</Text>
        </summary>
        <div className="space-y-4 border-t border-border p-4">
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
          <Surface className="mx-4 sm:mx-0" padding="lg"><Text muted>{t("dependencies_mobile_unavailable")}</Text></Surface>
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
      {payload.view === "list" && payload.rows_current_for_search !== false ? <Pagination pathname={pathname} search={search} payload={payload} /> : null}
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
    return <Surface padding="lg"><Text muted>{t("loading")}</Text></Surface>
  }

  if (graphQuery.isError) {
    return <Notice role="alert" tone="danger">{t("load_error")}</Notice>
  }

  const { nodes, edges } = graphQuery.data ?? { nodes: [], edges: [] }

  if (nodes.length === 0) {
    return <Surface padding="lg"><Text muted>{t("no_match", { subject: subjectLabel(subject, 2) })}</Text></Surface>
  }

  return (
    <Surface className="overflow-x-auto" padding="lg">
      {edges.length === 0 && (
        <Text className="mb-3" muted>{t("no_dependency_edges")}</Text>
      )}
      <TopoDepGraph nodes={nodes} edges={edges} />
    </Surface>
  )
}

function DashboardCreateActions({ payload, prefix }: { payload: DashboardPayload; prefix: string }) {
  const { t } = useT("dashboard")
  return (
    <div className="flex flex-wrap gap-2" data-tour="dashboard-create-actions">
      <Link className={buttonClasses()} to={withRoutePrefix(payload.paths.new_epic_path, prefix)}>{payload.simple_mode ? t("new_feature") : t("new_epic")}</Link>
      {payload.simple_mode ? null : <Link className={buttonClasses("success")} to={withRoutePrefix(payload.paths.new_job_path, prefix)}>{t("new_job")}</Link>}
    </div>
  )
}

function SubjectTabs({ pathname, payload, prefix, className = "inline-flex w-max overflow-hidden rounded-[var(--radius-control)] border border-border bg-surface text-sm" }: { pathname: string; payload: DashboardPayload; prefix: string; className?: string }) {
  const { t } = useT("dashboard")
  const activeSubject = dashboardSubjectFromPath(pathname) ?? payload.subject
  const subjects: Array<{ key: DashboardSubject; label: string; path: string }> = [
    { key: "epic", label: t("tab_epics"), path: "/dashboard/epics" },
    { key: "job", label: t("tab_jobs"), path: "/dashboard/jobs" },
    { key: "workflow", label: t("tab_workflows"), path: "/dashboard/workflows" }
  ]

  return (
    <nav aria-label={t("subjects")} className={className}>
      {subjects.map((subject) => (
        <Link
          className={`px-3 py-1.5 font-medium ${activeSubject === subject.key ? "bg-brand/10 text-brand ring-1 ring-inset ring-brand dark:text-brand-emphasis" : "text-text-primary hover:bg-surface-raised"}`}
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
            <Button
              aria-label={t("columns")}
              aria-controls="dashboard-columns-menu"
              aria-expanded={columnsOpen}
              aria-haspopup="menu"
              className="h-9 w-9"
              onClick={() => setColumnsOpen((open) => !open)}
              size="sm"
              variant="secondary"
            >
              <ColumnsIcon />
            </Button>
            {columnsOpen ? (
              <Surface className="absolute right-0 z-20 mt-2 w-64 shadow-lg" id="dashboard-columns-menu" padding="sm" role="menu">
                <fieldset className="space-y-2">
                  <Text as="legend" muted variant="label">{t("visible_columns")}</Text>
                  {payload.controls.columns.optional.map((column) => (
                    <label className="flex items-center gap-2 text-sm text-text-primary" key={column.key}>
                      <Checkbox
                        checked={payload.preferences.visible_columns.includes(column.key)}
                        disabled={updatePreferences.isPending}
                        onChange={(event) => updateColumn(column.key, event.target.checked)}
                      />
                      <span>{column.title}</span>
                    </label>
                  ))}
                </fieldset>
              </Surface>
            ) : null}
          </div>
        ) : null}
        {showConfiguration && payload.view === "kanban" ? (
          <div className="relative" ref={lanesMenuRef}>
            <Button
              aria-label={t("kanban_lanes")}
              aria-controls="dashboard-kanban-lanes-menu"
              aria-expanded={lanesOpen}
              aria-haspopup="menu"
              className="h-9 w-9"
              onClick={() => setLanesOpen((open) => !open)}
              size="sm"
              variant="secondary"
            >
              <ColumnsIcon />
            </Button>
            {lanesOpen ? (
              <Surface className="absolute right-0 z-20 mt-2 w-64 shadow-lg" id="dashboard-kanban-lanes-menu" padding="sm" role="menu">
                <fieldset className="space-y-2">
                  <Text as="legend" muted variant="label">{t("kanban_lanes")}</Text>
                  {payload.controls.kanban_lanes.map((lane) => (
                    <label className="flex items-center gap-2 text-sm text-text-primary" key={lane.key}>
                      <Checkbox
                        checked={payload.preferences.kanban_lanes.includes(lane.key)}
                        disabled={updatePreferences.isPending}
                        onChange={(event) => updateLane(lane.key, event.target.checked)}
                      />
                      <span>{lane.title}</span>
                    </label>
                  ))}
                </fieldset>
              </Surface>
            ) : null}
          </div>
        ) : null}
        <nav aria-label={t("view_label")} className="inline-flex overflow-hidden rounded-[var(--radius-control)] border border-border bg-surface text-sm">
          {viewTabs.map((view) => (
            <Link
              className={`px-3 py-1.5 capitalize ${payload.view === view ? "bg-brand text-on-brand" : "text-text-primary hover:bg-surface-raised"}`}
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
      {updatePreferences.isError ? <Text as="p" className="mt-1 text-right" role="alert" tone="danger">{errorMessage(updatePreferences.error, t("preferences_error"))}</Text> : null}
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

  if (payload.rows_current_for_search === false) {
    return <Surface className="mx-4 sm:mx-0" padding="lg"><Text muted>{t("loading")}</Text></Surface>
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

    return <Surface className="mx-4 sm:mx-0" padding="lg"><Text muted>{t("no_match", { subject: subjectLabel(payload.subject, 2) })}</Text></Surface>
  }

  const columns = dashboardVisibleColumns(payload)
  const items = payload.items ?? []
  if (payload.simple_mode && payload.subject === "epic") return <SimpleFeaturesTable items={items.filter((item): item is DashboardEpicItem => item.type === "epic")} prefix={prefix} />
  if (payload.simple_mode) return <SimpleJobsTable items={items.filter((item): item is DashboardJobItem => item.type === "job")} />
  if (payload.subject === "job") {
    return (
      <JobsDashboardTable
        columns={columns}
        items={items.filter((item): item is DashboardJobItem => item.type === "job")}
        controls={payload.controls}
        landingQueueEntries={payload.landing_queue.entries ?? []}
        landingQueueStatus={payload.landing_queue.status ?? null}
        prefix={prefix}
        sortState={sortState}
        t={t}
      />
    )
  }
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
      <span>{payload.total_estimated ? t("showing_pagination_estimated", { first: firstItem, last: lastItem }) : t("showing_pagination", { first: firstItem, last: lastItem, total: payload.total })}</span>
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
