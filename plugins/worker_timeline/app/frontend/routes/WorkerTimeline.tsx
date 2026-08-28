import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { FilterBar } from "@app/components/FilterBar"
import { fetchWorkerTimelineMacro, fetchWorkerTimelineWorkflow, type WorkerTimelineMacroPayload } from "../api/workerTimeline"
import { TimelineLanes } from "../components/TimelineLanes"
import { WorkflowWaterfall } from "../components/WorkflowWaterfall"

export function WorkerTimelineRoute() {
  const location = useLocation()
  if (location.pathname.endsWith("/workflow")) return <WorkerTimelineWorkflowDetail />

  return <WorkerTimelineMacroView />
}

export function WorkerTimelineMacroView() {
  const { t } = useT("worker_timeline")
  usePageTitle(t("heading"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)

  const macro = useQuery({
    queryKey: [ "worker_timeline", "macro", location.search ],
    queryFn: () => fetchWorkerTimelineMacro(location.search),
    placeholderData: keepPreviousData
  })

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

      <FilterBar filter={macro.data?.filter ?? null} filterSchema={macro.data?.filter_schema ?? []} pathname={location.pathname} search={location.search} />

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

  const detail = useQuery({
    enabled: Boolean(workflowId),
    queryKey: [ "worker_timeline", "workflow", workflowId ],
    queryFn: () => fetchWorkerTimelineWorkflow(workflowId as string)
  })

  return (
    <main aria-label={t("detail_aria")} className="mx-auto max-w-5xl space-y-4 p-6">
      <Link className="text-sm text-blue-700 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix("/worker_timeline", prefix)}>
        {t("back_to_timeline")}
      </Link>
      <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("detail_heading")}</h1>

      {!workflowId ? <p className="text-sm text-gray-600 dark:text-gray-400">{t("detail_placeholder_no_workflow")}</p> : null}
      {detail.isPending && workflowId ? <p className="text-sm text-gray-600 dark:text-gray-400">{t("loading")}</p> : null}
      {detail.isError ? <p className="text-sm text-red-700 dark:text-red-300">{errorMessage(detail.error, t("error_loading"))}</p> : null}
      {detail.data ? <WorkflowWaterfall payload={detail.data} /> : null}
    </main>
  )
}

export default WorkerTimelineRoute
