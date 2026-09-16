import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { FilterBar } from "@app/components/FilterBar"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { SlugHoverCard } from "@app/components/SlugHoverCard"
import { Notice, Page, PageDescription, PageHeader, PageHeading, Section, SectionHeading, Text } from "@app/components/pluginUi"
import { fetchWorkerTimelineMacro, fetchWorkerTimelineWorkflow, recordWorkerTimelineFilterUsage, type WorkerTimelineMacroPayload } from "../api/workerTimeline"
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
    <Page aria-label={t("aria_page")} size="wide">
      <PageHeader className="border-b border-border pb-4">
        <Text className="font-medium uppercase" size="xs" tone="muted">{t("eyebrow")}</Text>
        <PageHeading>{t("heading")}</PageHeading>
        <PageDescription>{t("description")}</PageDescription>
      </PageHeader>

      <FilterBar
        filter={macro.data?.filter ?? null}
        filterSchema={macro.data?.filter_schema ?? []}
        onFilterApplied={(tree) => {
          void recordWorkerTimelineFilterUsage({ filter: tree as Record<string, unknown> }).catch(() => {})
        }}
        pathname={location.pathname}
        search={location.search}
        suggestionSearch={{ surface: "worker_timeline", subject: "worker_timeline" }}
      />

      {macro.isPending ? <Notice>{t("loading")}</Notice> : null}
      {macro.isError ? <Notice tone="error">{errorMessage(macro.error, t("error_loading"))}</Notice> : null}
      {macro.data ? <TimelineLanes onSelectWorkflow={handleSelectWorkflow} payload={macro.data} /> : null}

      {macro.data ? <PendingList pending={macro.data.pending} prefix={prefix} /> : null}
    </Page>
  )
}

function PendingList({
  pending,
  prefix
}: {
  pending: WorkerTimelineMacroPayload["pending"]
  prefix: string
}) {
  const { t } = useT("worker_timeline")
  if (pending.length === 0) return null

  return (
    <Section aria-label={t("pending_aria")}>
      <SectionHeading>{t("pending_heading")}</SectionHeading>
      <ul className="mt-2 divide-y divide-border text-sm">
        {pending.map((entry) => {
          const label = pendingLabelParts(entry)

          return (
            <li className="flex items-center justify-between gap-3 py-2" key={entry.workflow_id}>
              <span className="flex min-w-0 items-center gap-1.5">
                <SlugHoverCard id={entry.job_id} kind="job">
                  <CopyableSlug className="text-xs" slug={label.jobSlug} />
                </SlugHoverCard>
                <span className="text-gray-400 dark:text-gray-500" aria-hidden="true">·</span>
                <Link className="truncate text-left text-brand underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(`/worker_timeline/workflow?id=${entry.workflow_id}`, prefix)}>
                  {label.triggerKind}
                </Link>
              </span>
              <Text as="span" size="xs" tone="muted">
                {entry.blocked.available ? t("blocked_reason_line", { reason: entry.blocked.blocked_reason }) : t("no_blocker_data")}
              </Text>
            </li>
          )
        })}
      </ul>
    </Section>
  )
}

function pendingLabelParts(entry: WorkerTimelineMacroPayload["pending"][number]) {
  const [jobSlug, triggerKind] = entry.label.split(" · ")

  return {
    jobSlug: jobSlug || `JOB-${entry.job_id}`,
    triggerKind: triggerKind || entry.label
  }
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
    <Page aria-label={t("detail_aria")}>
      <Link className="text-sm text-brand dark:text-brand-emphasis underline hover:no-underline" to={withRoutePrefix("/worker_timeline", prefix)}>
        {t("back_to_timeline")}
      </Link>
      <PageHeading>{t("detail_heading")}</PageHeading>

      {!workflowId ? <Notice>{t("detail_placeholder_no_workflow")}</Notice> : null}
      {detail.isPending && workflowId ? <Notice>{t("loading")}</Notice> : null}
      {detail.isError ? <Notice tone="error">{errorMessage(detail.error, t("error_loading"))}</Notice> : null}
      {detail.data ? <WorkflowWaterfall payload={detail.data} prefix={prefix} /> : null}
    </Page>
  )
}

export default WorkerTimelineRoute
