import { useQuery } from "@tanstack/react-query"
import { useMemo } from "react"
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchWorkerTimelineFilters, fetchWorkerTimelineMacro, type WorkerTimelineMacroPayload } from "../api/workerTimeline"
import { FilterBar, type WorkerTimelineFilterValue } from "../components/FilterBar"
import { TimelineLanes } from "../components/TimelineLanes"

const ONE_HOUR_MS = 60 * 60 * 1000

export function WorkerTimelineRoute() {
  const location = useLocation()
  if (location.pathname.endsWith("/workflow")) return <WorkerTimelineWorkflowDetail />

  return <WorkerTimelineMacroView />
}

function toLocalInputValue(date: Date): string {
  const offset = date.getTimezoneOffset()
  const local = new Date(date.getTime() - offset * 60_000)
  return local.toISOString().slice(0, 16)
}

function filterValueFromSearchParams(searchParams: URLSearchParams): WorkerTimelineFilterValue {
  const now = new Date()
  const defaultFrom = new Date(now.getTime() - ONE_HOUR_MS)

  return {
    repositoryId: searchParams.get("repository_id") || "",
    epicId: searchParams.get("epic_id") || "",
    hostname: searchParams.get("hostname") || "",
    statuses: searchParams.getAll("status"),
    from: searchParams.get("from") || toLocalInputValue(defaultFrom),
    to: searchParams.get("to") || toLocalInputValue(now)
  }
}

function macroQueryString(value: WorkerTimelineFilterValue): string {
  const params = new URLSearchParams()
  if (value.repositoryId) params.set("repository_id", value.repositoryId)
  if (value.epicId) params.set("epic_id", value.epicId)
  if (value.hostname) params.set("hostname", value.hostname)
  value.statuses.forEach((status) => params.append("status", status))
  if (value.from) params.set("from", new Date(value.from).toISOString())
  if (value.to) params.set("to", new Date(value.to).toISOString())

  const search = params.toString()
  return search ? `?${search}` : ""
}

function searchParamsFromFilterValue(value: WorkerTimelineFilterValue): URLSearchParams {
  const params = new URLSearchParams()
  if (value.repositoryId) params.set("repository_id", value.repositoryId)
  if (value.epicId) params.set("epic_id", value.epicId)
  if (value.hostname) params.set("hostname", value.hostname)
  value.statuses.forEach((status) => params.append("status", status))
  if (value.from) params.set("from", value.from)
  if (value.to) params.set("to", value.to)
  return params
}

export function WorkerTimelineMacroView() {
  const { t } = useT("worker_timeline")
  usePageTitle(t("heading"))
  const location = useLocation()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const prefix = routePrefix(location.pathname)

  const filterValue = useMemo(() => filterValueFromSearchParams(searchParams), [ searchParams ])
  const macroSearch = useMemo(() => macroQueryString(filterValue), [ filterValue ])

  const filterOptions = useQuery({
    queryKey: [ "worker_timeline", "filters" ],
    queryFn: fetchWorkerTimelineFilters,
    staleTime: 60_000
  })

  const macro = useQuery({
    queryKey: [ "worker_timeline", "macro", macroSearch ],
    queryFn: () => fetchWorkerTimelineMacro(macroSearch)
  })

  function handleFilterChange(next: WorkerTimelineFilterValue) {
    setSearchParams(searchParamsFromFilterValue(next))
  }

  function handleSelectWorkflow(workflowId: number) {
    navigate(withRoutePrefix(`/worker_timeline/workflow?id=${workflowId}`, prefix))
  }

  return (
    <main aria-label={t("aria_page")} className="mx-auto max-w-[96rem] space-y-4 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("eyebrow")}</p>
        <h1 className="mt-1 text-3xl font-semibold text-gray-900 dark:text-gray-100">{t("heading")}</h1>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t("description")}</p>
      </header>

      <FilterBar onChange={handleFilterChange} options={filterOptions.data} value={filterValue} />

      {macro.isPending ? <p className="p-6 text-sm text-gray-600 dark:text-gray-400">{t("loading")}</p> : null}
      {macro.isError ? <p className="p-6 text-sm text-red-700 dark:text-red-300">{errorMessage(macro.error, t("error_loading"))}</p> : null}
      {macro.data ? <TimelineLanes onSelectWorkflow={handleSelectWorkflow} payload={macro.data} /> : null}

      {macro.data ? <PendingList onSelectWorkflow={handleSelectWorkflow} pending={macro.data.pending} /> : null}
    </main>
  )
}

function PendingList({
  pending,
  onSelectWorkflow
}: {
  pending: WorkerTimelineMacroPayload["pending"]
  onSelectWorkflow: (workflowId: number) => void
}) {
  const { t } = useT("worker_timeline")
  if (pending.length === 0) return null

  return (
    <section aria-label={t("pending_aria")} className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("pending_heading")}</h2>
      <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800 text-sm">
        {pending.map((entry) => (
          <li className="flex items-center justify-between gap-3 py-2" key={entry.workflow_id}>
            <button className="text-left text-blue-700 dark:text-blue-300 underline hover:no-underline" onClick={() => onSelectWorkflow(entry.workflow_id)} type="button">
              {entry.label}
            </button>
            <span className="text-xs text-gray-500 dark:text-gray-400">
              {entry.blocked.available ? t("blocked_reason_line", { reason: entry.blocked.blocked_reason }) : t("no_blocker_data")}
            </span>
          </li>
        ))}
      </ul>
    </section>
  )
}

function WorkerTimelineWorkflowDetail() {
  const { t } = useT("worker_timeline")
  usePageTitle(t("detail_heading"))
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const workflowId = searchParams.get("id")
  const prefix = routePrefix(location.pathname)

  return (
    <main aria-label={t("detail_aria")} className="mx-auto max-w-3xl space-y-4 p-6">
      <Link className="text-sm text-blue-700 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix("/worker_timeline", prefix)}>
        {t("back_to_timeline")}
      </Link>
      <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("detail_heading")}</h1>
      <p className="text-sm text-gray-600 dark:text-gray-400">
        {workflowId ? t("detail_placeholder_workflow", { id: workflowId }) : t("detail_placeholder_no_workflow")}
      </p>
      <p className="text-sm text-gray-600 dark:text-gray-400">{t("detail_placeholder_note")}</p>
    </main>
  )
}

export default WorkerTimelineRoute
