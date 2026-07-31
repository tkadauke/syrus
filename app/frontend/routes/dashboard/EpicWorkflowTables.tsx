import { SortableColumnHeader, TimestampCell, useMediaQuery, EpicCommitsBehindBadge, EpicProgressBar, EpicStuckBadge, NeutralStatePill, OwnerBadge, RepositorySlugLink, workflowLabel } from "./components"
import { formatRelativeDate } from "../../lib/relativeTime"
import { bulkButtonClass, columnAriaSort, compactText, epicDateValue, withRoutePrefix, workflowDateValue } from "./helpers"
import type { DashboardSortState } from "./helpers"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { NoticeToast } from "../../components/NoticeToast"
import { StatusPill } from "../../components/StatusPill"
import { bulkDashboardEpics, type DashboardBulkEpicAction, type DashboardEpicItem, type DashboardWorkflowItem } from "../../api/dashboard"
import { errorMessage } from "../../lib/errorMessage"


// Dashboard epic + workflow tables extracted from Dashboard.tsx: EpicsTable and
// WorkflowsTable with their bulk actions, mobile lists, and per-row cells.
// Entry points rendered by the table view. Depends only on leaf modules.

export function SimpleFeaturesTable({ items, prefix }: { items: DashboardEpicItem[]; prefix: string }) {
  const { t } = useT("dashboard")

  return (
    <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <ul className="divide-y divide-gray-100 dark:divide-gray-800">
        {items.map((epic) => (
          <li key={epic.id}>
            <Link
              aria-label={`${epic.title} ${simpleStatusLabel(epic.simple_status, t)}`}
              className="grid gap-2 px-4 py-4 text-gray-700 hover:bg-gray-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-gray-200 dark:hover:bg-gray-800 md:grid-cols-[minmax(0,1fr)_auto_auto] md:items-center md:gap-4"
              to={withRoutePrefix(epic.paths.epic_path, prefix)}
            >
              <span className="min-w-0 break-words text-base font-semibold text-gray-900 dark:text-gray-100">{epic.title}</span>
              <span className="text-sm font-medium text-blue-700 dark:text-blue-300">{simpleStatusLabel(epic.simple_status, t)}</span>
              {epic.updated_at ? <span className="text-sm text-gray-500 dark:text-gray-400">{formatRelativeDate(new Date(epic.updated_at))}</span> : null}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}

function simpleStatusLabel(status: string | undefined, t: (key: string, opts?: Record<string, unknown>) => string) {
  return t(`simple_status.${status || "working_on_it"}`, { defaultValue: status || "Working on it" })
}

export function EpicsTable({ items, columns, prefix, sortState }: { items: DashboardEpicItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
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
        <div className="mb-1 flex flex-wrap gap-1">
          <NeutralStatePill state={epic.state} />
          <EpicStuckBadge stuck={epic.stuck} />
          <EpicProgressBar epic={epic} />
          <EpicCommitsBehindBadge commits={epic.max_commits_behind_base} />
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
          <EpicCommitsBehindBadge commits={epic.max_commits_behind_base} />
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

export function WorkflowsTable({ items, columns, prefix, sortState }: { items: DashboardWorkflowItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
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
          {startedAt ? <span>{t("started_at", { date: formatRelativeDate(new Date(startedAt)) })}</span> : null}
          {finishedAt ? <span>{t("finished_at", { date: formatRelativeDate(new Date(finishedAt)) })}</span> : null}
        </div>
      </div>
    </Link>
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
