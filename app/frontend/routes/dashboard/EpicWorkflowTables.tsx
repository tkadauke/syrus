import { epicApparentState, SortableColumnHeader, TimestampCell, useMediaQuery, EpicCommitsBehindBadge, EpicProgressBar, EpicStuckBadge, NeutralStatePill, OwnerBadge, RepositorySlugLink, workflowLabel } from "./components"
import { formatRelativeDate } from "../../lib/relativeTime"
import { bulkButtonClass, columnAriaSort, compactText, epicDateValue, humanizeOption, withRoutePrefix, workflowDateValue } from "./helpers"
import type { DashboardSortState } from "./helpers"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { Checkbox } from "../../components/Checkbox"
import { DataTable } from "../../components/ui"
import { useOrderedColumns } from "./useOrderedColumns"
import { NoticeToast } from "../../components/NoticeToast"
import { StatusPill } from "../../components/StatusPill"
import { bulkDashboardEpics, type DashboardBulkEpicAction, type DashboardEpicItem, type DashboardWorkflowItem } from "../../api/dashboard"
import { errorMessage } from "../../lib/errorMessage"


// Dashboard epic + workflow tables extracted from Dashboard.tsx: EpicsTable and
// WorkflowsTable with their bulk actions, mobile lists, and per-row cells.
// Entry points rendered by the table view. Depends only on leaf modules.

// Unlike jobs (whose required set varies with landing-queue/blocked-folder
// smart folders), epics and workflows always require the same columns --
// see User::DASHBOARD_REQUIRED_COLUMNS plus epicTableColumns' unconditional
// checkbox prepend -- so these stay static here rather than threading
// `controls` down from Dashboard.tsx just for this.
const EPIC_REQUIRED_COLUMNS = [ "checkbox", "epic" ]
const WORKFLOW_REQUIRED_COLUMNS = [ "workflow", "job" ]

export function EpicsTable({ columns, items, onReorderColumns, prefix, reorderPending, sortState }: { columns: string[]; items: DashboardEpicItem[]; onReorderColumns?: (nextOrder: string[]) => void; prefix: string; reorderPending?: boolean; sortState: DashboardSortState }) {
  const { t } = useT("dashboard")
  const [selectedIds, setSelectedIds] = useState<Set<number>>(() => new Set())
  const visibleIds = useMemo(() => items.map((item) => item.id), [items])
  const selectedArray = useMemo(() => Array.from(selectedIds), [selectedIds])
  const allSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedIds.has(id))
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { dragOverKey, dragProps, draggable, orderedColumns } = useOrderedColumns({
    columns,
    onReorderColumns,
    reorderPending,
    requiredColumns: EPIC_REQUIRED_COLUMNS
  })

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
        <DataTable.Root>
          <DataTable.Header>
              <DataTable.Row>
                {orderedColumns.map((column) => (
                  <DataTable.HeadCell
                    aria-sort={columnAriaSort("epic", column, sortState)}
                    checkbox={column === "checkbox"}
                    className={dragOverKey === column ? "outline outline-2 -outline-offset-2 outline-brand" : undefined}
                    key={column}
                    {...(draggable(column) ? dragProps(column) : {})}
                  >
                    {column === "checkbox" ? <Checkbox aria-label={t("select_all_epics")} checked={allSelected} onChange={toggleAll} /> : <SortableColumnHeader column={column} sortState={sortState} subject="epic" />}
                  </DataTable.HeadCell>
                ))}
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
              {items.map((epic) => (
                <DataTable.Row key={epic.id}>
                  {orderedColumns.map((column) => <EpicCell column={column} epic={epic} key={column} onToggleOne={toggleOne} prefix={prefix} selected={selectedIds.has(epic.id)} />)}
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
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
  const showProgress = epicProgressVisible(epic)
  return (
    <article aria-label={`${epic.display_number} ${epic.title}`} className={`grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 overflow-hidden px-4 pt-3 text-gray-700 dark:text-gray-200 ${showProgress ? "" : "pb-3"}`}>
      <Checkbox aria-label={t("select_item", { title: epic.title })} checked={selected} className="mt-1" onChange={() => onToggleOne(epic.id)} />
      <div className="min-w-0 pb-3">
        <div className="mb-1 flex flex-wrap gap-1">
          <NeutralStatePill state={epicApparentState(epic)} />
          <EpicStuckBadge stuck={epic.stuck} />
          <EpicCommitsBehindBadge commits={epic.max_commits_behind_base} />
        </div>
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <SlugHoverCard id={epic.id} kind="epic">
            <span className="font-mono text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{epic.display_number}</span>
          </SlugHoverCard>
          <Link aria-label={`${epic.display_number} ${epic.title}`} className="rounded-sm text-sm font-semibold leading-snug text-brand underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" to={withRoutePrefix(epic.paths.epic_path, prefix)}>{epic.title}</Link>
        </div>
        {compactText(epic.description) ? <p className="mt-1 line-clamp-2 text-sm leading-snug text-gray-500 dark:text-gray-400">{compactText(epic.description)}</p> : null}
        <div className="mt-1 flex flex-wrap gap-x-2 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <RepositorySlugLink prefix={prefix} repository={epic.repository} />
          <OwnerBadge badge={epic.owner_badge} />
        </div>
      </div>
      {showProgress ? (
        <div className="col-span-2 -mx-4">
          <EpicProgressBar epic={epic} fullWidth />
        </div>
      ) : null}
    </article>
  )
}

function EpicCell({ epic, column, selected, onToggleOne, prefix }: { epic: DashboardEpicItem; column: string; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  const { t } = useT("dashboard")
  if (column === "checkbox") {
    return <DataTable.Cell className="align-top"><Checkbox aria-label={t("select_item", { title: epic.title })} checked={selected} onChange={() => onToggleOne(epic.id)} /></DataTable.Cell>
  }
  if (column === "epic") {
    return (
      <DataTable.Cell className="max-w-md">
        <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(epic.paths.epic_path, prefix)}>{epic.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">
          <SlugHoverCard id={epic.id} kind="epic">{epic.display_number}</SlugHoverCard>
        </div>
      </DataTable.Cell>
    )
  }
  if (column === "state") {
    const showProgress = epicProgressVisible(epic)
    return (
      <DataTable.Cell className={showProgress ? "relative pb-5 align-top" : "align-top"}>
        <div className="flex flex-wrap gap-1">
          <NeutralStatePill state={epicApparentState(epic)} />
          <EpicStuckBadge stuck={epic.stuck} />
          <EpicCommitsBehindBadge commits={epic.max_commits_behind_base} />
        </div>
        {showProgress ? (
          <div className="absolute inset-x-0 bottom-0">
            <EpicProgressBar epic={epic} fullWidth />
          </div>
        ) : null}
      </DataTable.Cell>
    )
  }
  if (column === "owner") return <DataTable.Cell className="text-xs text-gray-600 dark:text-gray-300"><OwnerBadge badge={epic.owner_badge} /></DataTable.Cell>
  if (column === "repository") {
    return <DataTable.Cell><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-brand hover:underline dark:text-gray-300" prefix={prefix} repository={epic.repository} /></DataTable.Cell>
  }
  if (column === "updated") return <TimestampCell value={epic.updated_at} />
  if (column === "number") return <TextCell mono value={String(epic.number)} />
  if (column === "auto_approve_mode") return <TextCell value={humanizeOption(epic.auto_approve_mode)} />
  if (column === "child_job_count") return <TextCell value={String(epic.jobs_count)} />
  if (column === "open_child_count") return <TextCell value={String(epic.open_child_count ?? 0)} />
  if (column === "blocked_child_count") return <TextCell value={String(epic.blocked_child_count ?? 0)} />
  if (column === "dependency_count") return <TextCell value={String(epic.dependency_count ?? 0)} />
  if (column === "child_progress_percent") return <TextCell value={`${epic.child_progress_percent ?? 0}%`} />

  return <TimestampCell value={epicDateValue(epic, column)} />
}

function epicProgressVisible(epic: DashboardEpicItem) {
  return epic.state === "in_progress" && epic.jobs_count > 0
}

export function WorkflowsTable({ columns, items, onReorderColumns, prefix, reorderPending, sortState }: { columns: string[]; items: DashboardWorkflowItem[]; onReorderColumns?: (nextOrder: string[]) => void; prefix: string; reorderPending?: boolean; sortState: DashboardSortState }) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { dragOverKey, dragProps, draggable, orderedColumns } = useOrderedColumns({
    columns,
    onReorderColumns,
    reorderPending,
    requiredColumns: WORKFLOW_REQUIRED_COLUMNS
  })

  if (!isDesktop) return <MobileWorkflowsList items={items} prefix={prefix} />

  return (
    <DataTable.Root>
      <DataTable.Header>
          <DataTable.Row>
            {orderedColumns.map((column) => (
              <DataTable.HeadCell
                aria-sort={columnAriaSort("workflow", column, sortState)}
                className={dragOverKey === column ? "outline outline-2 -outline-offset-2 outline-brand" : undefined}
                key={column}
                {...(draggable(column) ? dragProps(column) : {})}
              >
                <SortableColumnHeader column={column} sortState={sortState} subject="workflow" />
              </DataTable.HeadCell>
            ))}
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {items.map((workflow) => (
            <DataTable.Row key={workflow.id}>
              {orderedColumns.map((column) => <WorkflowCell column={column} key={column} prefix={prefix} workflow={workflow} />)}
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
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
    <Link aria-label={`${slug} ${workflow.job.title}`} className="grid grid-cols-[7.25rem_minmax(0,1fr)] gap-3 px-4 py-3 text-gray-700 hover:bg-gray-50 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:text-gray-200 dark:hover:bg-gray-800 dark:hover:text-white" to={withRoutePrefix(workflow.path, prefix)}>
      <div className="pt-1">
        <StatusPill state={workflow.state} />
      </div>
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span className="font-mono text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{slug}</span>
          <span className="text-sm font-semibold leading-snug text-brand underline">{workflow.job.title}</span>
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
      <DataTable.Cell className="font-medium">
        <Link className="text-brand hover:underline" to={withRoutePrefix(workflow.path, prefix)}>{workflowLabel(workflow)}</Link>
      </DataTable.Cell>
    )
  }
  if (column === "state") return <DataTable.Cell><StatusPill state={workflow.state} /></DataTable.Cell>
  if (column === "job") {
    return (
      <DataTable.Cell className="max-w-md">
        <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(workflow.job.path, prefix)}>{workflow.job.title}</Link>
        <div className="mt-1 flex flex-wrap gap-1 text-xs text-gray-500 dark:text-gray-400">
          <RepositorySlugLink prefix={prefix} repository={workflow.job.repository} />
          <OwnerBadge badge={workflow.job.owner_badge} />
        </div>
      </DataTable.Cell>
    )
  }
  if (column === "trigger") return <DataTable.Cell className="text-gray-700 dark:text-gray-200">{workflow.trigger_kind}</DataTable.Cell>
  if (column === "agent") return <DataTable.Cell className="text-gray-700 dark:text-gray-200">{workflow.agent_provider}</DataTable.Cell>
  if (column === "trigger_kind") return <TextCell value={humanizeOption(workflow.trigger_kind)} />
  if (column === "agent_provider") return <TextCell value={humanizeOption(workflow.agent_provider)} />
  if (column === "failure_reason") return <TextCell value={workflow.failure_reason ? humanizeOption(workflow.failure_reason) : null} />
  if (column === "run_count") return <TextCell value={String(workflow.run_count ?? 0)} />
  if (column === "worker_hostname") return <TextCell mono value={workflow.worker_hostname} />
  if (column === "worker_storage_key") return <TextCell mono value={workflow.worker_storage_key} />
  if (column === "started") return <TimestampCell value={workflow.started_at || workflow.created_at} />
  if (column === "finished") return <TimestampCell value={workflow.finished_at} />

  return <TimestampCell value={workflowDateValue(workflow, column)} />
}

function TextCell({ value, mono = false }: { value: string | null | undefined; mono?: boolean }) {
  return <DataTable.Cell className={`max-w-56 truncate text-xs text-gray-700 dark:text-gray-200 ${mono ? "font-mono" : ""}`} title={value || undefined}>{value || "-"}</DataTable.Cell>
}
