import { EpicProgressBar, EpicStuckBadge, ExternalMetadataLink, ExternalPrBadge, NeutralStatePill, OwnerBadge, PendingJobTitle, RepositorySlugLink, WorkflowBadges, workflowLabel } from "./components"
import { StartBlockedReasonPill } from "../../components/StartBlockedReasonPill"
import { TonePill } from "../../components/StatusPill"
import { PrHoverCard } from "../../components/PrHoverCard"
import { dashboardEmptyState, subjectLabel, withRoutePrefix } from "./helpers"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { DragEvent } from "react"
import { useEffect, useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { CopyableSlug } from "../../components/CopyableSlug"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { OnboardingEmptyState, useSetupStatus } from "../../components/OnboardingEmptyState"
import { NoticeToast } from "../../components/NoticeToast"
import { fetchDashboardRows, updateDashboardEpicState, type DashboardEpicItem, type DashboardItem, type DashboardLane, type DashboardPayload, type DashboardSubject } from "../../api/dashboard"
import { errorMessage } from "../../lib/errorMessage"


// Dashboard kanban board extracted from Dashboard.tsx: DashboardKanban and its
// lanes/cards with drag-to-move-lane behavior. Entry point rendered by the
// dashboard content area. Depends only on leaf modules and shared UI imports.

const KANBAN_CARDS_PER_PAGE = 20

export function DashboardKanban({ payload, prefix, rowsSearch, setupStatus }: { payload: DashboardPayload; prefix: string; rowsSearch: string; setupStatus: ReturnType<typeof useSetupStatus> }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [draggedEpic, setDraggedEpic] = useState<DashboardEpicItem | null>(null)
  const [dragOverLane, setDragOverLane] = useState<string | null>(null)
  const [optimisticLanes, setOptimisticLanes] = useState(payload.lanes ?? [])
  const [notice, setNotice] = useState<string | null>(null)
  const loadLane = useMutation({
    mutationFn: ({ lane }: { lane: DashboardLane }) => fetchDashboardRows(kanbanLaneSearch(rowsSearch, lane.key, lane.next_offset ?? lane.items.length)),
    onSuccess: (rows, { lane }) => {
      const fetchedLane = rows.lanes.find((candidate) => candidate.key === lane.key)
      if (!fetchedLane) return
      setOptimisticLanes((lanes) => mergeLoadedLane(lanes, fetchedLane))
    }
  })
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
              onLoadMore={() => loadLane.mutate({ lane })}
              prefix={prefix}
              serverLoadError={loadLane.isError && loadLane.variables?.lane.key === lane.key ? errorMessage(loadLane.error, t("load_error")) : null}
              serverLoadPending={loadLane.isPending && loadLane.variables?.lane.key === lane.key}
              subject={payload.subject}
            />
          ))}
        </div>
      </div>
    </>
  )
}

function KanbanLane({
  draggingOver,
  lane,
  onDragEnd,
  onDragOver,
  onDragStart,
  onDrop,
  onLoadMore,
  prefix,
  serverLoadError,
  serverLoadPending,
  subject
}: {
  draggingOver: boolean
  lane: DashboardLane
  onDragEnd: () => void
  onDragOver: (event: DragEvent<HTMLElement>) => void
  onDragStart: (epic: DashboardEpicItem, event: DragEvent<HTMLElement>) => void
  onDrop: (event: DragEvent<HTMLElement>) => void
  onLoadMore: () => void
  prefix: string
  serverLoadError: string | null
  serverLoadPending: boolean
  subject: DashboardSubject
}) {
  const { t } = useT("dashboard")
  const [visibleCount, setVisibleCount] = useState(KANBAN_CARDS_PER_PAGE)
  const visibleItems = lane.items.slice(0, visibleCount)
  const hiddenCount = lane.items.length - visibleItems.length
  const serverHasMore = Boolean(lane.has_more)
  const canLoadMore = hiddenCount > 0 || serverHasMore

  useEffect(() => {
    setVisibleCount(KANBAN_CARDS_PER_PAGE)
  }, [lane.key])

  function loadMore() {
    if (hiddenCount > 0) {
      setVisibleCount((count) => count + KANBAN_CARDS_PER_PAGE)
      return
    }

    setVisibleCount((count) => count + KANBAN_CARDS_PER_PAGE)
    onLoadMore()
  }

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
        {serverLoadError ? <div className="rounded border border-red-200 bg-red-50 p-2 text-xs text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200" role="alert">{serverLoadError}</div> : null}
        {canLoadMore ? (
          <button
            aria-label={t("load_more_lane", { lane: lane.title })}
            className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
            disabled={serverLoadPending}
            onClick={loadMore}
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
  const { t } = useT("dashboard")
  if (item.type === "job") {
    return (
      <article className={`rounded border p-3 shadow-sm ${item.priority === "urgent" ? "border-red-200 bg-red-50 dark:border-red-900 dark:bg-red-950/40" : item.needs_attention ? "border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/30" : "border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900"}`}>
        <div className="flex items-start justify-between gap-1">
          <Link className="line-clamp-2 text-sm font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.paths.job_path, prefix)}><PendingJobTitle pending={Boolean(item.title_pending)} title={item.title} /></Link>
          {item.needs_attention ? <span aria-label={t("needs_attention_aria")} className="mt-0.5 shrink-0 rounded bg-amber-200 px-1 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-800 dark:text-amber-200">!</span> : null}
        </div>
        <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500 dark:text-gray-400">
          <WorkflowBadges state={item.summary_state} triggerAriaPrefix="Active workflow trigger" triggerKind={item.active_workflow_trigger_kind} />
          {item.state === "queued" && item.start_blocked_reason ? (
            <StartBlockedReasonPill count={item.start_blocked_count} details={item.start_blocked_details} nextCheckAt={item.start_blocked_next_check_at} reason={item.start_blocked_reason} startBlockedAt={item.start_blocked_at} />
          ) : null}
          <RepositorySlugLink className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-500 hover:text-blue-700 hover:underline dark:bg-gray-800 dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={item.repository} />
          <OwnerBadge badge={item.owner_badge} />
          {item.pr_number ? (
            <PrHoverCard jobId={item.id} prNumber={item.pr_number} prUrl={item.pr_url ?? ""}>
              <ExternalMetadataLink className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-500 hover:text-blue-700 hover:underline dark:bg-gray-800 dark:text-gray-300 dark:hover:text-blue-300" href={item.pr_url}>PR #{item.pr_number}</ExternalMetadataLink>
            </PrHoverCard>
          ) : null}
          <ExternalPrBadge external={item.pr_is_external} />
        </div>
      </article>
    )
  }

  if (item.type === "workflow") {
    const slug = workflowLabel(item)
    return (
      <article className="rounded border border-gray-200 bg-white p-3 shadow-sm dark:border-gray-700 dark:bg-gray-900">
        <Link className="text-sm font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.path, prefix)}>{slug}</Link>
        <Link className="mt-1 line-clamp-2 block text-sm text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(item.job.path, prefix)}><PendingJobTitle pending={Boolean(item.job.title_pending)} title={item.job.title} /></Link>
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
      className="cursor-grab rounded border border-gray-200 bg-white shadow-sm active:cursor-grabbing dark:border-gray-700 dark:bg-gray-900"
      draggable
      onDragEnd={onDragEnd}
      onDragStart={(event) => onDragStart(item, event)}
    >
      <div className="p-3">
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <SlugHoverCard id={item.id} kind="epic">
            <CopyableSlug className="text-xs font-semibold uppercase" slug={item.display_number} />
          </SlugHoverCard>
          <Link className="line-clamp-2 text-sm font-medium text-blue-600 hover:underline dark:text-blue-300" draggable={false} to={withRoutePrefix(item.paths.epic_path, prefix)}>{item.title}</Link>
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

function kanbanLaneSearch(search: string, lane: string, offset: number) {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search)
  params.set("kanban_lane", lane)
  params.set("kanban_offset", String(Math.max(0, offset)))
  const next = params.toString()
  return next ? `?${next}` : ""
}

function mergeLoadedLane(lanes: DashboardLane[], fetchedLane: DashboardLane) {
  return lanes.map((lane) => {
    if (lane.key !== fetchedLane.key) return lane

    const existingKeys = new Set(lane.items.map((item) => `${item.type}-${item.id}`))
    const appendedItems = fetchedLane.items.filter((item) => !existingKeys.has(`${item.type}-${item.id}`))

    return {
      ...lane,
      ...fetchedLane,
      items: [...lane.items, ...appendedItems],
      loaded_count: (lane.items.length + appendedItems.length)
    }
  })
}
