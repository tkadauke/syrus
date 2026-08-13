import { SortableColumnHeader, TimestampCell, useMediaQuery, ExternalMetadataLink, ExternalPrBadge, MetadataLine, NeutralStatePill, OwnerBadge, PendingJobTitle, RepositorySlugLink, WorkflowBadges } from "./components"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { formatRelativeDate } from "../../lib/relativeTime"
import { translateBlockedReason } from "../../lib/translateBlockedReason"
import { bulkButtonClass, columnAriaSort, formatCurrency, humanizeOption, jobDateValue, pluralize, withRoutePrefix } from "./helpers"
import type { DashboardSortState } from "./helpers"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { CopyableSlug } from "../../components/CopyableSlug"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { PrHoverCard } from "../../components/PrHoverCard"
import { NoticeToast } from "../../components/NoticeToast"
import { StartBlockedReasonPill } from "../../components/StartBlockedReasonPill"
import { ProviderAvailabilityWarning } from "../../components/ProviderAvailabilityWarning"
import { StatusPill, TonePill } from "../../components/StatusPill"
import { bulkDashboardJobs, unpauseDashboardJob, type DashboardBulkJobAction, type DashboardJobItem, type DashboardLandingQueueEntry } from "../../api/dashboard"
import type { LandingQueueBlockerJob } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { useConfirm } from "../../hooks/useConfirm"


// Dashboard jobs table extracted from Dashboard.tsx: JobsDashboardTable and its
// subtree — the desktop jobs table, the landing-queue grouping/topology, the
// per-job cells, and the mobile jobs list. Entry point rendered by the table
// view. Depends only on leaf modules and shared UI imports.

export function JobsDashboardTable({ items, columns, landingQueueEntries, prefix, sortState, t }: { items: DashboardJobItem[]; columns: string[]; landingQueueEntries: DashboardLandingQueueEntry[]; prefix: string; sortState: DashboardSortState; t: (key: string, opts?: Record<string, unknown>) => string }) {
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
  const { confirm, dialog } = useConfirm()
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

  async function run(bulkAction: DashboardBulkJobAction) {
    setNotice(null)
    if (bulkAction === "close" && !await confirm({ message: t(selectedIds.length === 1 ? "close_confirm_one" : "close_confirm_other", { count: selectedIds.length }), destructive: true })) return
    action.mutate(bulkAction)
  }

  if (selectedIds.length === 0) {
    return <>{dialog}<NoticeToast message={notice} onDismiss={() => setNotice(null)} /></>
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
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("pause")} type="button">{t("pause")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("unpause")} type="button">{t("unpause")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("claim")} type="button">{t("claim")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("release_claim")} type="button">{t("release")}</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("approve")} type="button">{t("approve")}</button>
        <button className={bulkButtonClass(disabled, "danger")} disabled={disabled} onClick={() => run("close")} type="button">{t("close_action")}</button>
      </div>
      {dialog}
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

  if (!isDesktop) {
    return (
      <MobileJobsList
        expandedBlockerGroups={expandedBlockerGroups}
        groupByEpic={groupByEpic}
        items={items}
        landingQueueGroups={landingQueueGroups}
        onToggleBlockers={toggleBlockerGroup}
        onToggleOne={onToggleOne}
        prefix={prefix}
        selectedIds={selectedIds}
      />
    )
  }

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            {columns.map((column) => (
              <th aria-sort={columnAriaSort("job", column, sortState)} className={column === "checkbox" ? "w-10 px-4 py-2" : "px-4 py-2"} key={column} title={column === "commits_behind_base" ? t("column_label.commits_behind_base_tooltip") : undefined}>
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
            items.map((job, index) => {
              const separatorClass = startsNewEpicGroup(items, index, groupByEpic) ? "border-t-4 border-gray-300 dark:border-gray-600" : ""
              const urgentClass = job.priority === "urgent" ? "bg-red-50 dark:bg-red-950/40" : ""
              return (
                <tr className={[separatorClass, urgentClass].filter(Boolean).join(" ") || undefined} key={job.id}>
                  {columns.map((column) => <JobCell column={column} job={job} key={column} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} />)}
                </tr>
              )
            })
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

        const urgentClass = row.job.priority === "urgent" ? "bg-red-50 dark:bg-red-950/40" : ""
        return (
          <tr className={[separatorClass, urgentClass].filter(Boolean).join(" ") || undefined} key={row.job.id}>
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
  if (column === "landing_queue_wait_reason") return <td className="px-4 py-3" />
  if (column === "issue" || column === "title") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(job.job_path, prefix)}>{job.title}</Link>
        <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
          <SlugHoverCard id={job.id} kind="job">
            <CopyableSlug slug={`JOB-${job.id}`} />
          </SlugHoverCard>
          {job.pr_number && job.pr_path ? (
              <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_path}>
                <ExternalMetadataLink href={job.pr_path}>PR #{job.pr_number}</ExternalMetadataLink>
              </PrHoverCard>
            ) : null}
          {job.pr_is_external ? <ExternalPrBadge external={job.pr_is_external} /> : null}
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
  if (column === "repository") {
    return <td className="px-4 py-3"><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-blue-700 hover:underline dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={job.repository} /></td>
  }
  if (column === "latest") {
    if (job.latest_workflow_id == null) return <td className="px-4 py-3" />
    return (
      <td aria-label={`Latest workflow: ${job.latest_workflow_trigger_kind ?? ""} ${job.latest_workflow_state ?? ""}`} className="px-4 py-3">
        <WorkflowBadges state={job.latest_workflow_state ?? ""} triggerAriaPrefix="Latest workflow trigger" triggerKind={job.latest_workflow_trigger_kind} />
      </td>
    )
  }
  if (column === "started" || column === "started_at") return <TimestampCell value={job.started_at} />
  if (column === "created_at") return <TimestampCell value={job.created_at} />
  if (column === "commits_behind_base") return <td className="px-4 py-3" />

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

function MobileJobsList({
  expandedBlockerGroups,
  groupByEpic,
  items,
  landingQueueGroups,
  onToggleBlockers,
  onToggleOne,
  prefix,
  selectedIds
}: {
  expandedBlockerGroups: Set<string>
  groupByEpic: boolean
  items: DashboardJobItem[]
  landingQueueGroups: LandingQueueDisplayGroup[]
  onToggleBlockers: (key: string) => void
  onToggleOne: (id: number) => void
  prefix: string
  selectedIds: Set<number>
}) {
  return (
    <div className="border-y border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900 sm:rounded sm:border">
      <div className="divide-y divide-gray-100 dark:divide-gray-800">
        {groupByEpic ? (
          landingQueueGroups.map((group, index) => (
            <MobileLandingQueueJobGroup
              expanded={expandedBlockerGroups.has(group.key)}
              group={group}
              key={group.key}
              onToggleBlockers={onToggleBlockers}
              onToggleOne={onToggleOne}
              prefix={prefix}
              selectedIds={selectedIds}
              topSeparator={index > 0 && (group.key.startsWith("epic:") || landingQueueGroups[index - 1].key.startsWith("epic:"))}
            />
          ))
        ) : (
          items.map((job, index) => <MobileJobRow job={job} key={job.id} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} topSeparator={startsNewEpicGroup(items, index, groupByEpic)} />)
        )}
      </div>
    </div>
  )
}

function MobileLandingQueueJobGroup({ expanded, group, onToggleBlockers, onToggleOne, prefix, selectedIds, topSeparator }: { expanded: boolean; group: LandingQueueDisplayGroup; onToggleBlockers: (key: string) => void; onToggleOne: (id: number) => void; prefix: string; selectedIds: Set<number>; topSeparator: boolean }) {
  const { t } = useT("dashboard")
  const blockerCount = group.blockerJobs.length
  const rows = expanded ? group.rows : group.rows.filter((row) => row.kind === "approved")

  return (
    <div className={topSeparator ? "border-t-4 border-gray-300 dark:border-gray-600" : undefined}>
      {blockerCount > 0 ? (
        <div className="bg-gray-50 px-4 py-2 dark:bg-gray-950/40">
          <button
            aria-expanded={expanded}
            className="inline-flex min-h-8 items-center gap-2 rounded px-1 py-0.5 text-xs font-semibold text-gray-600 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-gray-300 dark:hover:text-gray-100"
            onClick={() => onToggleBlockers(group.key)}
            type="button"
          >
            <span aria-hidden="true">{expanded ? "▼" : "▶"}</span>
            <span>{t(blockerCount === 1 ? "blocker_one" : "blocker_other", { count: blockerCount })}</span>
          </button>
        </div>
      ) : null}
      {rows.map((row) => row.kind === "blocker" ? (
        <MobileLandingQueueBlockerRow attribution={row.attribution} job={row.job} key={`blocker-${group.key}-${row.id}`} prefix={prefix} />
      ) : (
        <MobileJobRow job={row.job} key={row.job.id} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(row.job.id)} />
      ))}
    </div>
  )
}

function MobileLandingQueueBlockerRow({ attribution, job, prefix }: { attribution: string | null; job: LandingQueueBlockerJob; prefix: string }) {
  return (
    <article aria-label={job.title} className="grid grid-cols-[auto_minmax(0,1fr)] gap-3 bg-gray-50/70 px-4 py-3 text-gray-500 dark:bg-gray-950/30 dark:text-gray-400">
      <div aria-hidden="true" className="mt-1 h-4 w-4 rounded border border-dashed border-gray-300 dark:border-gray-700" />
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <NeutralStatePill state={job.state} />
          <RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-blue-700 hover:underline dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={job.repository} />
        </div>
        <div className="mt-1">
          <Link className="rounded-sm text-sm font-semibold leading-snug text-blue-600 underline focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-blue-300" to={withRoutePrefix(job.job_path, prefix)}>{job.title}</Link>
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <SlugHoverCard id={job.id} kind="job">
            <CopyableSlug slug={`JOB-${job.id}`} />
          </SlugHoverCard>
          {job.pr_number && job.pr_path ? (
            <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_path}>
              <ExternalMetadataLink href={job.pr_path}>PR #{job.pr_number}</ExternalMetadataLink>
            </PrHoverCard>
          ) : null}
          {job.pr_is_external ? <ExternalPrBadge external={job.pr_is_external} /> : null}
          {attribution ? <span>{attribution}</span> : null}
          {job.latest_workflow_id == null ? null : <WorkflowBadges state={job.latest_workflow_state ?? ""} triggerAriaPrefix="Latest workflow trigger" triggerKind={job.latest_workflow_trigger_kind} />}
          <span><RelativeTimestamp value={job.started_at || job.created_at} /></span>
        </MetadataLine>
      </div>
    </article>
  )
}

function MobileJobRow({ job, selected, onToggleOne, prefix, topSeparator = false }: { job: DashboardJobItem; selected: boolean; onToggleOne: (id: number) => void; prefix: string; topSeparator?: boolean }) {
  const { t } = useT("dashboard")
  const approvalLabel = job.approved_at ? t("approved") : t("not_approved")

  return (
    <article aria-label={job.title} className={[
      "grid grid-cols-[auto_minmax(0,1fr)] gap-3 px-4 py-3",
      topSeparator && "border-t-4 border-gray-300 dark:border-gray-600",
      job.priority === "urgent" && "bg-red-50 dark:bg-red-950/40"
    ].filter(Boolean).join(" ")}>
      <input aria-label={t("select_item", { title: job.title })} checked={selected} className="mt-1" onChange={() => onToggleOne(job.id)} type="checkbox" />
      <div className="min-w-0 text-gray-700 dark:text-gray-200">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <WorkflowBadges state={job.summary_state} triggerAriaPrefix="Active workflow trigger" triggerKind={job.active_workflow_trigger_kind} />
          <ProviderAvailabilityWarning availability={job.provider_availability} />
          {job.total_cost_usd == null ? null : <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{formatCurrency(job.total_cost_usd)}</span>}
          <RepositorySlugLink prefix={prefix} repository={job.repository} />
          <OwnerBadge badge={job.owner_badge} />
        </div>
        <div className="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <Link aria-label={job.title} className="rounded-sm text-sm font-semibold leading-snug text-blue-600 underline focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:text-blue-300" to={withRoutePrefix(job.paths.job_path, prefix)}><PendingJobTitle pending={Boolean(job.title_pending)} title={job.title} /></Link>
          {job.kind !== "issue" ? <span className="text-xs text-gray-500 dark:text-gray-400">{humanizeOption(job.kind)}</span> : null}
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <JobSlugMetadata job={job} prefix={prefix} />
          {job.manual_paused ? <ManualPauseInline job={job} /> : null}
          {job.pr_number ? (
              <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_url ?? ""}>
                <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink>
              </PrHoverCard>
            ) : null}
          {job.pr_is_external ? <ExternalPrBadge external={job.pr_is_external} /> : null}
          {job.source_chat ? <JobSourceChatLink job={job} prefix={prefix} /> : null}
          {job.claimed_by_user && !job.claimed_by_current_user ? <DashboardOwnerLabel job={job} prefix={prefix} quiet /> : null}
          <span>{approvalLabel}</span>
          {job.owner_badge ? <OwnerBadge badge={job.owner_badge} /> : null}
          <span>{job.workflows_count} {pluralize(job.workflows_count, "workflow")}</span>
          <span><RelativeTimestamp value={job.started_at || job.created_at} /></span>
          {job.state === "queued" && job.start_blocked_reason ? (
            <StartBlockedReasonPill count={job.start_blocked_count} details={job.start_blocked_details} nextCheckAt={job.start_blocked_next_check_at} reason={job.start_blocked_reason} startBlockedAt={job.start_blocked_at} />
          ) : null}
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
          <ProviderAvailabilityWarning availability={job.provider_availability} />
          <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(job.paths.job_path, prefix)}><PendingJobTitle pending={Boolean(job.title_pending)} title={job.title} /></Link>
          {job.needs_attention ? <span aria-label={t("needs_attention_aria")} className="shrink-0 rounded bg-amber-200 px-1 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-800 dark:text-amber-200">!</span> : null}
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <JobSlugMetadata job={job} prefix={prefix} />
          {job.manual_paused ? <ManualPauseInline job={job} /> : null}
          {job.pr_number ? (
              <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_url ?? ""}>
                <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink>
              </PrHoverCard>
            ) : null}
          {job.pr_is_external ? <ExternalPrBadge external={job.pr_is_external} /> : null}
          {job.source_chat ? <JobSourceChatLink job={job} prefix={prefix} /> : null}
          {job.owner_badge ? <OwnerBadge badge={job.owner_badge} /> : null}
          {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5 dark:bg-gray-800 dark:text-gray-300" key={tag.id}>{tag.name}</span>)}
          {job.retry_state && job.retry_state.state_label !== "No failure" ? <RetryStateInline job={job} /> : null}
          {job.state === "queued" && job.start_blocked_reason ? (
            <StartBlockedReasonPill count={job.start_blocked_count} details={job.start_blocked_details} nextCheckAt={job.start_blocked_next_check_at} reason={job.start_blocked_reason} startBlockedAt={job.start_blocked_at} />
          ) : null}
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
    return (
      <td className="px-4 py-3">
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="font-mono text-xs font-semibold text-gray-600 dark:text-gray-300">{job.landing_queue_position ? `#${job.landing_queue_position}` : "-"}</span>
          <CommitsBehindBadge count={job.commits_behind_base} />
        </div>
      </td>
    )
  }
  if (column === "landing_queue_blocked_reason") {
    return <LandingQueueStatusCell job={job} />
  }
  if (column === "landing_queue_wait_reason") {
    return <LandingQueueStatusCell job={job} />
  }
  if (column === "blocked_reason") {
    return <td className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{job.blocked_reason ? translateBlockedReason(job.blocked_reason, t) : "-"}</td>
  }
  if (column === "repository") {
    return <td className="px-4 py-3"><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-blue-700 hover:underline dark:text-gray-300 dark:hover:text-blue-300" prefix={prefix} repository={job.repository} /></td>
  }
  if (column === "owner") return <td className="px-4 py-3"><DashboardOwnerLabel job={job} prefix={prefix} /></td>
  if (column === "latest") return <LatestWorkflowCell job={job} />
  if (column === "deployment") return <DeploymentStageCell job={job} prefix={prefix} />
  if (column === "workflows_count") return <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{job.workflows_count}</td>
  if (column === "priority") return <PriorityPillCell priority={job.priority} />
  if (column === "commits_behind_base") return <td className="px-4 py-3"><CommitsBehindBadge count={job.commits_behind_base} /></td>

  return <TimestampCell value={jobDateValue(job, column)} />
}

function LandingQueueStatusCell({ job }: { job: DashboardJobItem }) {
  const { t } = useT("dashboard")
  if (job.landing_queue_blocked_reason) {
    return (
      <td className="px-4 py-3">
        <span className="inline-flex rounded-full bg-red-50 px-2 py-0.5 text-xs font-medium text-red-700 ring-1 ring-red-200 dark:bg-red-950/50 dark:text-red-200 dark:ring-red-800">
          {translateBlockedReason(job.landing_queue_blocked_reason, t)}
        </span>
      </td>
    )
  }

  if (job.landing_queue_wait_reason) {
    return (
      <td className="px-4 py-3">
        <span className="inline-flex rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700">
          {translateBlockedReason(job.landing_queue_wait_reason, t)}
        </span>
      </td>
    )
  }

  return <td className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">-</td>
}

export function CommitsBehindBadge({ count }: { count: number | null | undefined }) {
  if (count == null || count === 0) return null

  const tone: "red" | "amber" | "gray" = count >= 20 ? "red" : count >= 10 ? "amber" : "gray"
  return <TonePill ariaLabel={`${count} commits behind base`} tone={tone}>{count} behind</TonePill>
}

export const PRIORITY_TONE: Record<string, "red" | "amber" | "blue"> = {
  urgent: "red",
  high: "amber",
  low: "blue"
}

function PriorityPillCell({ priority }: { priority: string }) {
  const tone = PRIORITY_TONE[priority]
  if (!tone) return <td className="px-4 py-3" />
  return <td className="px-4 py-3"><TonePill tone={tone}>{priority}</TonePill></td>
}

function DeploymentStageCell({ job, prefix }: { job: DashboardJobItem; prefix: string }) {
  const stage = job.latest_deployment_stage
  if (!stage) return <td className="px-4 py-3 text-gray-400 dark:text-gray-500">—</td>

  return (
    <td className="px-4 py-3">
      <Link className="inline-flex items-center whitespace-nowrap rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-700 ring-1 ring-emerald-200 hover:bg-emerald-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:bg-emerald-950/50 dark:text-emerald-200 dark:ring-emerald-800 dark:hover:bg-emerald-900/70" title={stage.reached_at ?? undefined} to={withRoutePrefix(job.paths.job_path, prefix)}>
        {stage.label || stage.name}
      </Link>
    </td>
  )
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

function ManualPauseInline({ job }: { job: DashboardJobItem }) {
  const { t } = useT("dashboard")
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const unpauseMutation = useMutation({
    mutationFn: () => {
      if (!job.paths.app_unpause_path) throw new Error(t("manual_pause_error"))

      return unpauseDashboardJob(job.paths.app_unpause_path)
    },
    onSuccess: (payload) => {
      setNotice(payload.message ?? t("job_unpaused"))
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })

  if (!job.manual_paused) return null

  const pausedBy = job.manual_paused_by_user?.name || job.manual_paused_by_user?.email_address
  const title = pausedBy ? t("manual_paused_by", { user: pausedBy }) : t("manual_paused")
  const canUnpause = Boolean(job.paths.app_unpause_path)

  return (
    <span className="inline-flex items-center gap-1 rounded bg-amber-50 px-1.5 py-0.5 text-amber-800 ring-1 ring-amber-200 dark:bg-amber-950/50 dark:text-amber-200 dark:ring-amber-800" title={title}>
      <span>{t("manual_paused")}</span>
      <span aria-hidden="true" className="select-none">·</span>
      <button
        className="rounded border border-amber-300 bg-white px-1 py-0 text-[11px] font-semibold text-amber-900 hover:bg-amber-100 disabled:opacity-60 dark:border-amber-700 dark:bg-gray-950 dark:text-amber-100 dark:hover:bg-amber-900/50"
        disabled={!canUnpause || unpauseMutation.isPending}
        onClick={(event) => {
          event.preventDefault()
          event.stopPropagation()
          if (!job.paths.app_unpause_path) return
          unpauseMutation.mutate()
        }}
        type="button"
      >
        {t("unpause")}
      </button>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {unpauseMutation.isError ? <span className="text-red-700 dark:text-red-300" role="alert">{errorMessage(unpauseMutation.error, t("manual_pause_error"))}</span> : null}
    </span>
  )
}

function IssueMetadata({ job }: { job: DashboardJobItem }) {
  if (!job.issue_number) return <CopyableSlug slug={`JOB-${job.id}`} />

  const label = `#${job.issue_number}`

  return <ExternalMetadataLink href={job.issue_url}>{label}</ExternalMetadataLink>
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
    retry.next_auto_retry_at ? `next ${formatRelativeDate(new Date(retry.next_auto_retry_at))}` : null,
    retry.provider_circuit_open ? "provider circuit open" : null
  ].filter(Boolean).join(" · ")

  const tone = retry.auto_retry_exhausted ? "red" : retry.provider_circuit_open ? "amber" : "gray"

  return <TonePill title={details} tone={tone}>{retry.state_label}</TonePill>
}
