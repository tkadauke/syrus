import { SortableColumnHeader, TimestampCell, UntaggedIssuesBanner, useMediaQuery, ExternalMetadataLink, ExternalPrBadge, MetadataLine, NeutralStatePill, OwnerBadge, PendingJobTitle, RepositorySlugLink, WorkflowBadges, WorkflowTriggerPill } from "./components"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { formatRelativeDate } from "../../lib/relativeTime"
import { translateBlockedReason } from "../../lib/translateBlockedReason"
import { linkifySlugs } from "../../lib/linkifySlugs"
import { bulkButtonClass, columnAriaSort, formatCurrency, humanizeOption, jobDateValue, withRoutePrefix } from "./helpers"
import type { DashboardSortState } from "./helpers"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState, type MouseEvent, type ReactNode } from "react"
import { Link, useNavigate } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { Button, buttonClasses } from "../../components/Button"
import { CopyableSlug } from "../../components/CopyableSlug"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { Checkbox } from "../../components/Checkbox"
import { DataTable, Select } from "../../components/ui"
import { useOrderedColumns } from "./useOrderedColumns"
import { PrHoverCard } from "../../components/PrHoverCard"
import { NoticeToast } from "../../components/NoticeToast"
import { StartBlockedReasonPill } from "../../components/StartBlockedReasonPill"
import { ProviderAvailabilityWarning, ProviderMismatchPill } from "../../components/ProviderAvailabilityWarning"
import { PILL_TONE_CLASSES, StatusPill, TonePill } from "../../components/StatusPill"
import { bulkDashboardJobs, unpauseDashboardJob, type DashboardBulkJobAction, type DashboardJobItem, type DashboardLandingQueueEntry, type DashboardLandingQueueStatus, type DashboardPayload, type DashboardUntaggedIssues } from "../../api/dashboard"
import { type LandingQueueBlockerJob } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { useConfirm } from "../../hooks/useConfirm"
import { createDashboardJobNavigationContext, jobNavigationHref, storeJobNavigationContext } from "../../lib/jobNavigationContext"


// Dashboard jobs table extracted from Dashboard.tsx: JobsDashboardTable and its
// subtree — the desktop jobs table, the landing-queue grouping/topology, the
// per-job cells, and the mobile jobs list. Entry point rendered by the table
// view. Depends only on leaf modules and shared UI imports.

export function JobsDashboardTable({ items, columns, controls, landingQueueEntries, landingQueueStatus, onReorderColumns, prefix, reorderPending, sortState, t, untaggedIssues }: { items: DashboardJobItem[]; columns: string[]; controls: DashboardPayload["controls"]; landingQueueEntries: DashboardLandingQueueEntry[]; landingQueueStatus?: DashboardLandingQueueStatus | null; onReorderColumns?: (nextOrder: string[]) => void; prefix: string; reorderPending?: boolean; sortState: DashboardSortState; t: (key: string, opts?: Record<string, unknown>) => string; untaggedIssues?: DashboardUntaggedIssues }) {
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
      <BulkJobActions controls={controls} items={items} selectedIds={selectedArray} onClear={() => setSelectedIds(new Set())} />
      {landingQueueStatus ? <LandingQueueSummary status={landingQueueStatus} prefix={prefix} /> : null}
      <UntaggedIssuesBanner prefix={prefix} untaggedIssues={untaggedIssues} />
      <JobsTable
        allSelected={allSelected}
        columns={columns}
        items={items}
        landingQueueEntries={landingQueueEntries}
        onReorderColumns={onReorderColumns}
        onToggleAll={toggleAll}
        onToggleOne={toggleOne}
        prefix={prefix}
        reorderPending={reorderPending}
        requiredColumns={controls.columns.required.map((column) => column.key)}
        selectedIds={selectedIds}
        sortState={sortState}
        t={t}
      />
    </div>
  )
}

function LandingQueueSummary({ status, prefix }: { status: DashboardLandingQueueStatus; prefix: string }) {
  const toneClasses = status.tone === "danger"
    ? "border-red-200 bg-red-50 text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-100"
    : status.tone === "warning"
      ? "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-900/60 dark:bg-amber-950/40 dark:text-amber-100"
      : "border-info/30 bg-info/10 text-info"

  return (
    <section className={`rounded border px-4 py-3 text-sm ${toneClasses}`} role="status">
      <div className="font-semibold">{status.title}</div>
      <p className="mt-1">{status.summary}</p>
      {status.links && status.links.length > 0 ? (
        <div className="mt-2 flex flex-wrap gap-2">
          {status.links.map((link) => (
            <Link className="font-semibold underline decoration-current/40 underline-offset-2 hover:decoration-current" key={`${link.label}-${link.path}`} to={withRoutePrefix(link.path, prefix)}>
              {link.label}
            </Link>
          ))}
        </div>
      ) : null}
    </section>
  )
}


function BulkJobActions({ controls, items, selectedIds, onClear }: { controls: DashboardPayload["controls"]; items: DashboardJobItem[]; selectedIds: number[]; onClear: () => void }) {
  const { t } = useT("dashboard")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const [ownerUserId, setOwnerUserId] = useState("")
  const [priority, setPriority] = useState("medium")
  const action = useMutation({
    mutationFn: (bulkAction: DashboardBulkJobAction) => bulkDashboardJobs({
      job_ids: selectedIds,
      bulk_action: bulkAction,
      owner_user_id: bulkAction === "assign_owner" && ownerUserId ? Number(ownerUserId) : undefined,
      priority: bulkAction === "set_priority" ? priority : undefined
    }),
    onSuccess: (payload) => {
      setNotice(payload.message)
      onClear()
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const disabled = selectedIds.length === 0 || action.isPending
  const selectedJobs = useMemo(() => {
    const ids = new Set(selectedIds)
    return items.filter((item) => ids.has(item.id))
  }, [items, selectedIds])
  const canRun = useMemo(() => {
    const selected = selectedJobs.length > 0 ? selectedJobs : []
    const allSelectedCan = (bulkAction: DashboardBulkJobAction) => selected.length > 0 && selected.every((job) => dashboardJobBulkActionApplies(job, bulkAction))

    return {
      retry: allSelectedCan("retry"),
      release_from_backlog: allSelectedCan("release_from_backlog"),
      move_to_backlog: allSelectedCan("move_to_backlog"),
      pause: allSelectedCan("pause"),
      unpause: allSelectedCan("unpause"),
      claim: allSelectedCan("claim"),
      release_claim: allSelectedCan("release_claim"),
      assign_owner: allSelectedCan("assign_owner"),
      set_priority: allSelectedCan("set_priority"),
      approve: allSelectedCan("approve"),
      close: allSelectedCan("close")
    }
  }, [selectedJobs])

  async function run(bulkAction: DashboardBulkJobAction) {
    setNotice(null)
    if (bulkAction === "close" && !await confirm({ message: t(selectedIds.length === 1 ? "close_confirm_one" : "close_confirm_other", { count: selectedIds.length }), destructive: true })) return
    if (bulkAction === "move_to_backlog" && !await confirm({ message: t("move_to_backlog_confirm", { count: selectedIds.length }), destructive: false })) return
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
        {canRun.retry ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("retry")} type="button">{t("retry")}</button> : null}
        {canRun.release_from_backlog ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("release_from_backlog")} type="button">{t("release_from_backlog")}</button> : null}
        {canRun.move_to_backlog ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("move_to_backlog")} type="button">{t("move_to_backlog")}</button> : null}
        {canRun.pause ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("pause")} type="button">{t("pause")}</button> : null}
        {canRun.unpause ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("unpause")} type="button">{t("unpause")}</button> : null}
        {canRun.claim ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("claim")} type="button">{t("claim")}</button> : null}
        {canRun.release_claim ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("release_claim")} type="button">{t("release")}</button> : null}
        {canRun.assign_owner ? (
          <>
            <Select aria-label={t("assign_owner")} className="px-2 py-1 text-xs" disabled={disabled} fullWidth={false} onChange={(event) => setOwnerUserId(event.target.value)} value={ownerUserId}>
              <option value="">{t("assign_owner")}</option>
              {controls.owners.map((owner) => <option key={owner.id} value={owner.id}>{owner.label}</option>)}
            </Select>
            <button className={bulkButtonClass(disabled || !ownerUserId)} disabled={disabled || !ownerUserId} onClick={() => run("assign_owner")} type="button">{t("assign")}</button>
          </>
        ) : null}
        {canRun.set_priority ? (
          <>
            <Select aria-label={t("priority")} className="px-2 py-1 text-xs" disabled={disabled} fullWidth={false} onChange={(event) => setPriority(event.target.value)} value={priority}>
              {(controls.priorities ?? [{ value: "urgent", label: "Urgent" }, { value: "high", label: "High" }, { value: "medium", label: "Medium" }, { value: "low", label: "Low" }]).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </Select>
            <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("set_priority")} type="button">{t("set_priority")}</button>
          </>
        ) : null}
        {canRun.approve ? <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("approve")} type="button">{t("approve")}</button> : null}
        {canRun.close ? <button className={bulkButtonClass(disabled, "danger")} disabled={disabled} onClick={() => run("close")} type="button">{t("close_action")}</button> : null}
      </div>
      {dialog}
    </div>
  )
}

function dashboardJobBulkActionApplies(job: DashboardJobItem, bulkAction: DashboardBulkJobAction) {
  if (job.bulk_actions) {
    return Boolean(job.bulk_actions[bulkAction])
  }

  const open = job.state !== "closed" && job.state !== "no_change_needed"
  if (bulkAction === "retry") return open && (job.state === "failed" || job.state === "implemented" || Boolean(job.retry_state?.retryable))
  if (bulkAction === "release_from_backlog") return Boolean(job.can_release_from_backlog)
  if (bulkAction === "move_to_backlog") return Boolean(job.can_move_to_backlog)
  if (bulkAction === "pause") return open && !job.manual_paused
  if (bulkAction === "unpause") return open && Boolean(job.manual_paused)
  if (bulkAction === "claim") return !job.claimed_by_user || job.claimed_by_current_user
  if (bulkAction === "release_claim") return Boolean(job.claimed_by_current_user)
  if (bulkAction === "assign_owner") return open
  if (bulkAction === "set_priority") return open
  if (bulkAction === "approve") return Boolean(job.can_approve)
  if (bulkAction === "close") return job.state !== "closed"

  return false
}

// Group key for the landing-queue delineation: one key per *landing unit*.
// An Epic lands atomically (a merge-train), so all its jobs share a key; a
// bundled epicless job lands atomically too (a job-bundle merge-train), so
// its members share a key; an unbundled epicless job lands on its own, so it
// gets its own key (a "single-job epic"). Sorted by queue position, the
// separators then trace the relative order of lands within a repository.
export function epicGroupKey(job: DashboardJobItem) {
  if (job.epic) return `epic-${job.epic.id}`
  const bundleId = job.landing_queue_entry_key?.match(/^job_bundle:(.+)$/)?.[1]
  if (bundleId) return `bundle-${bundleId}`
  return `job-${job.id}`
}

function isMultiJobGroupKey(key: string) {
  return key.startsWith("epic-") || key.startsWith("bundle-")
}

// Same idea as isMultiJobGroupKey, but for `landing_queue_entry_key`-shaped
// keys (colon-separated, e.g. "epic:5" / "job_bundle:5") as used by
// DashboardLandingQueueEntry.key rather than the dash-separated keys above.
function isMultiJobLandingUnitKey(key: string) {
  return key.startsWith("epic:") || key.startsWith("job_bundle:")
}

// True when this row begins a new landing unit relative to the previous row,
// but only at multi-job group boundaries (Epics and job bundles) —
// consecutive standalone (epicless, unbundled) jobs are the same kind of
// landing unit and do not get a separator between them. Only meaningful when
// the list is ordered by queue position.
export function startsNewEpicGroup(items: DashboardJobItem[], index: number, enabled: boolean) {
  if (!enabled || index === 0) return false
  const currentKey = epicGroupKey(items[index])
  const prevKey = epicGroupKey(items[index - 1])
  if (currentKey === prevKey) return false
  return isMultiJobGroupKey(currentKey) || isMultiJobGroupKey(prevKey)
}

function JobsTable({
  items,
  columns,
  landingQueueEntries,
  onReorderColumns,
  reorderPending,
  requiredColumns,
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
  onReorderColumns?: (nextOrder: string[]) => void
  reorderPending?: boolean
  requiredColumns: string[]
  selectedIds: Set<number>
  allSelected: boolean
  onToggleAll: () => void
  onToggleOne: (id: number) => void
  prefix: string
  sortState: DashboardSortState
  t: (key: string, opts?: Record<string, unknown>) => string
}) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const tableColumns = useMemo(() => columns.filter((column) => column !== "landing_queue_wait_reason"), [columns])
  const { dragOverKey, dragProps, draggable, orderedColumns } = useOrderedColumns({
    columns: tableColumns,
    onReorderColumns,
    reorderPending,
    requiredColumns
  })
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
    <DataTable.Root>
      <DataTable.Header>
          <DataTable.Row>
            {orderedColumns.map((column) => (
              <DataTable.HeadCell
                aria-sort={columnAriaSort("job", column, sortState)}
                checkbox={column === "checkbox"}
                className={dragOverKey === column ? "outline outline-2 -outline-offset-2 outline-brand" : undefined}
                key={column}
                title={column === "commits_behind_base" ? t("column_label.commits_behind_base_tooltip") : undefined}
                {...(draggable(column) ? dragProps(column) : {})}
              >
                {column === "checkbox" ? <Checkbox aria-label={t("select_all_jobs")} checked={allSelected} onChange={onToggleAll} /> : <SortableColumnHeader column={column} sortState={sortState} subject="job" />}
              </DataTable.HeadCell>
            ))}
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {groupByEpic ? (
            landingQueueGroups.map((group, index) => (
              <LandingQueueJobGroup
                columns={orderedColumns}
                expanded={expandedBlockerGroups.has(group.key)}
                group={group}
                key={group.key}
                onToggleBlockers={toggleBlockerGroup}
                onToggleOne={onToggleOne}
                prefix={prefix}
                selectedIds={selectedIds}
                topSeparator={index > 0 && (isMultiJobLandingUnitKey(group.key) || isMultiJobLandingUnitKey(landingQueueGroups[index - 1].key))}
              />
            ))
          ) : (
            items.map((job, index) => {
              const separatorClass = startsNewEpicGroup(items, index, groupByEpic) ? "border-t-4 border-gray-300 dark:border-gray-600" : ""
              const urgentClass = job.priority === "urgent" ? "bg-red-50 dark:bg-red-950/40" : ""
              return (
                <DataTable.Row className={[separatorClass, urgentClass].filter(Boolean).join(" ") || undefined} key={job.id}>
                  {orderedColumns.map((column) => <JobCell column={column} job={job} key={column} navigationItems={items} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} />)}
                </DataTable.Row>
              )
            })
          )}
        </DataTable.Body>
      </DataTable.Root>
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
        <DataTable.Row className={topSeparator ? "border-t-4 border-gray-300 dark:border-gray-600" : undefined} groupHeader>
          <DataTable.Cell className="bg-gray-50 px-4 py-2 dark:bg-gray-950/40" colSpan={columns.length}>
            <button
              aria-expanded={expanded}
              className="inline-flex items-center gap-2 rounded px-1 py-0.5 text-xs font-semibold text-gray-600 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:text-gray-300 dark:hover:text-gray-100"
              onClick={() => onToggleBlockers(group.key)}
              type="button"
            >
              <span aria-hidden="true">{expanded ? "▼" : "▶"}</span>
              <span>{t(blockerCount === 1 ? "blocker_one" : "blocker_other", { count: blockerCount })}</span>
            </button>
          </DataTable.Cell>
        </DataTable.Row>
      ) : null}
      {rows.map((row, index) => {
        const separatorClass = blockerCount === 0 && topSeparator && index === 0 ? "border-t-4 border-gray-300 dark:border-gray-600" : undefined
        if (row.kind === "blocker") {
          return (
            <DataTable.Row className={`bg-gray-50/70 text-gray-500 dark:bg-gray-950/30 dark:text-gray-400${separatorClass ? ` ${separatorClass}` : ""}`} key={`blocker-${group.key}-${row.id}`}>
              {columns.map((column) => <LandingQueueBlockerCell column={column} job={row.job} attribution={row.attribution} key={column} prefix={prefix} />)}
            </DataTable.Row>
          )
        }

        const urgentClass = row.job.priority === "urgent" ? "bg-red-50 dark:bg-red-950/40" : ""
        return (
          <DataTable.Row className={[separatorClass, urgentClass].filter(Boolean).join(" ") || undefined} key={row.job.id}>
            {columns.map((column) => <JobCell column={column} job={row.job} key={column} navigationItems={group.jobs} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(row.job.id)} />)}
          </DataTable.Row>
        )
      })}
    </>
  )
}

function LandingQueueBlockerCell({ job, column, attribution, prefix }: { job: LandingQueueBlockerJob; column: string; attribution: string | null; prefix: string }) {
  if (column === "checkbox") return <DataTable.Cell className="align-top" />
  if (column === "landing_queue_position") return <DataTable.Cell />
  if (column === "landing_queue_blocked_reason") return <DataTable.Cell />
  if (column === "landing_queue_wait_reason") return <DataTable.Cell />
  if (column === "issue" || column === "title") {
    return (
      <DataTable.Cell className="max-w-md">
        <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(job.job_path, prefix)}>{job.title}</Link>
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
          {attribution ? <span className="rounded border border-gray-200 px-1.5 py-0.5 text-2xs text-gray-500 dark:border-gray-700 dark:text-gray-400">{attribution}</span> : null}
        </div>
      </DataTable.Cell>
    )
  }
  if (column === "state") {
    return (
      <DataTable.Cell>
        <NeutralStatePill state={job.state} />
      </DataTable.Cell>
    )
  }
  if (column === "repository") {
    return <DataTable.Cell><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-brand hover:underline dark:text-gray-300" prefix={prefix} repository={job.repository} /></DataTable.Cell>
  }
  if (column === "latest") {
    if (job.latest_workflow_id == null) return <DataTable.Cell />
    return (
      <DataTable.Cell aria-label={`Latest workflow: ${job.latest_workflow_trigger_kind ?? ""} ${job.latest_workflow_state ?? ""}`}>
        <WorkflowBadges state={job.latest_workflow_state ?? ""} triggerAriaPrefix="Latest workflow trigger" triggerKind={job.latest_workflow_trigger_kind} />
      </DataTable.Cell>
    )
  }
  if (column === "started" || column === "started_at") return <TimestampCell value={job.started_at} />
  if (column === "created_at") return <TimestampCell value={job.created_at} />
  if (column === "commits_behind_base") return <DataTable.Cell />

  return <DataTable.Cell className="text-gray-400 dark:text-gray-500">-</DataTable.Cell>
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
  if (job.bundle_other_job_count != null) {
    return t(job.bundle_other_job_count === 1 ? "bundle_attribution_one" : "bundle_attribution_other", { count: job.bundle_other_job_count })
  }
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
              topSeparator={index > 0 && (isMultiJobLandingUnitKey(group.key) || isMultiJobLandingUnitKey(landingQueueGroups[index - 1].key))}
            />
          ))
        ) : (
          items.map((job, index) => <MobileJobRow job={job} key={job.id} navigationItems={items} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} topSeparator={startsNewEpicGroup(items, index, groupByEpic)} />)
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
            className="inline-flex min-h-8 items-center gap-2 rounded px-1 py-0.5 text-xs font-semibold text-gray-600 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:text-gray-300 dark:hover:text-gray-100"
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
        <MobileJobRow job={row.job} key={row.job.id} navigationItems={group.jobs} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(row.job.id)} />
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
          <RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-brand hover:underline dark:text-gray-300" prefix={prefix} repository={job.repository} />
        </div>
        <div className="mt-1 min-w-0">
          <Link className="block max-w-full truncate rounded-sm text-sm font-semibold leading-snug text-brand underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" title={job.title} to={withRoutePrefix(job.job_path, prefix)}>{job.title}</Link>
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

function DashboardJobNavigationLink({ ariaLabel, children, className, currentJob, items, prefix, title }: { ariaLabel?: string; children: ReactNode; className: string; currentJob: DashboardJobItem; items: DashboardJobItem[]; prefix: string; title?: string }) {
  const { t } = useT("dashboard")
  const navigate = useNavigate()
  const fallbackHref = withRoutePrefix(currentJob.paths.job_path, prefix)

  function onClick(event: MouseEvent<HTMLAnchorElement>) {
    if (event.defaultPrevented || event.button !== 0 || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return

    const context = createDashboardJobNavigationContext({
      currentJobId: currentJob.id,
      items,
      label: t("job_navigation_context_dashboard"),
      sourcePath: `${window.location.pathname}${window.location.search}`
    })
    const token = storeJobNavigationContext(context)
    if (!token) return

    event.preventDefault()
    navigate(jobNavigationHref(currentJob.paths.job_path, prefix, token))
  }

  return (
    <Link aria-label={ariaLabel} className={className} onClick={onClick} title={title} to={fallbackHref}>
      {children}
    </Link>
  )
}

function MobileJobRow({ job, navigationItems, selected, onToggleOne, prefix, topSeparator = false }: { job: DashboardJobItem; navigationItems: DashboardJobItem[]; selected: boolean; onToggleOne: (id: number) => void; prefix: string; topSeparator?: boolean }) {
  const { t } = useT("dashboard")

  return (
    <article aria-label={job.title} className={[
      "grid grid-cols-[auto_minmax(0,1fr)] gap-3 px-4 py-3",
      topSeparator && "border-t-4 border-gray-300 dark:border-gray-600",
      job.priority === "urgent" && "bg-red-50 dark:bg-red-950/40"
    ].filter(Boolean).join(" ")}>
      <Checkbox aria-label={t("select_item", { title: job.title })} checked={selected} className="mt-1" onChange={() => onToggleOne(job.id)} />
      <div className="min-w-0 text-gray-700 dark:text-gray-200">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <WorkflowBadges state={job.summary_state} triggerAriaPrefix="Active workflow trigger" triggerKind={job.active_workflow_trigger_kind} />
          <ProviderAvailabilityWarning availability={job.provider_availability} />
          {job.total_cost_usd == null ? null : <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{formatCurrency(job.total_cost_usd)}</span>}
          <RepositorySlugLink prefix={prefix} repository={job.repository} />
          <OwnerBadge badge={job.owner_badge} />
        </div>
        <div className="mt-1 flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
          <DashboardJobNavigationLink ariaLabel={job.title} className="block min-w-0 max-w-full truncate rounded-sm text-sm font-semibold leading-snug text-brand underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" currentJob={job} items={navigationItems} prefix={prefix} title={job.title}><PendingJobTitle pending={Boolean(job.title_pending)} title={job.title} /></DashboardJobNavigationLink>
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          {job.kind !== "issue" ? <span>{humanizeOption(job.kind)}</span> : null}
          <JobSlugMetadata job={job} prefix={prefix} />
          {job.issue_number ? <IssueMetadata job={job} /> : null}
          {job.pr_number ? (
              <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_url ?? ""}>
                <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink>
              </PrHoverCard>
            ) : null}
          {job.pr_is_external ? <ExternalPrBadge external={job.pr_is_external} /> : null}
          {job.source_chat ? <JobSourceChatLink job={job} prefix={prefix} /> : null}
          {job.claimed_by_user && !job.claimed_by_current_user ? <DashboardOwnerLabel job={job} prefix={prefix} quiet /> : null}
          {job.owner_badge ? <OwnerBadge badge={job.owner_badge} /> : null}
          <span><RelativeTimestamp value={job.latest_workflow_started_at || job.started_at || job.created_at} /></span>
          <MobileJobQueueStatus job={job} />
        </MetadataLine>
        <JobAttentionLine includeBlockedReason job={job} />
        {job.tags.length > 0 ? (
          <div className="mt-1 flex flex-wrap gap-1">
            {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-500 dark:bg-gray-800 dark:text-gray-300" key={tag.id}>{tag.name}</span>)}
          </div>
        ) : null}
      </div>
    </article>
  )
}

function JobCell({ job, column, navigationItems, selected, onToggleOne, prefix }: { job: DashboardJobItem; column: string; navigationItems: DashboardJobItem[]; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  const { t } = useT("dashboard")
  if (column === "checkbox") {
    return <DataTable.Cell className="align-top"><Checkbox aria-label={t("select_item", { title: job.title })} checked={selected} onChange={() => onToggleOne(job.id)} /></DataTable.Cell>
  }
  if (column === "issue" || column === "title") {
    return (
      <DataTable.Cell className="max-w-md">
        <div className="flex min-w-0 items-center gap-1.5">
          <ProviderAvailabilityWarning availability={job.provider_availability} />
          <DashboardJobNavigationLink className="block min-w-0 max-w-full truncate font-medium text-brand hover:underline" currentJob={job} items={navigationItems} prefix={prefix} title={job.title}><PendingJobTitle pending={Boolean(job.title_pending)} title={job.title} /></DashboardJobNavigationLink>
          {job.needs_attention ? <span aria-label={t("needs_attention_aria")} className="shrink-0 rounded bg-amber-200 px-1 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-800 dark:text-amber-200">!</span> : null}
        </div>
        <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          <JobSlugMetadata job={job} prefix={prefix} />
          {job.issue_number ? <IssueMetadata job={job} /> : null}
          {job.pr_number ? (
              <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_url ?? ""}>
                <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink>
              </PrHoverCard>
            ) : null}
          {job.pr_is_external ? <ExternalPrBadge external={job.pr_is_external} /> : null}
          {job.source_chat ? <JobSourceChatLink job={job} prefix={prefix} /> : null}
          {job.owner_badge ? <OwnerBadge badge={job.owner_badge} /> : null}
          {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5 dark:bg-gray-800 dark:text-gray-300" key={tag.id}>{tag.name}</span>)}
        </MetadataLine>
        <JobAttentionLine job={job} />
      </DataTable.Cell>
    )
  }
  if (column === "state") {
    return (
      <DataTable.Cell>
        <NeutralStatePill state={job.state} />
      </DataTable.Cell>
    )
  }
  if (column === "landing_queue_position") {
    return (
      <DataTable.Cell>
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="font-mono text-xs font-semibold text-gray-600 dark:text-gray-300">{job.landing_queue_position ? `#${job.landing_queue_position}` : "-"}</span>
          <LandingQueueStatusBadges job={job} showEmpty={false} />
        </div>
      </DataTable.Cell>
    )
  }
  if (column === "landing_queue_blocked_reason") {
    return <LandingQueueStatusCell job={job} />
  }
  if (column === "landing_queue_wait_reason") {
    return <LandingQueueStatusCell job={job} />
  }
  if (column === "blocked_reason") {
    return <DataTable.Cell className="text-xs text-gray-500 dark:text-gray-400">{job.blocked_reason ? <CopyableBlockedReason reason={translateBlockedReason(job.blocked_reason, t)} /> : "-"}</DataTable.Cell>
  }
  if (column === "repository") {
    return <DataTable.Cell><RepositorySlugLink className="font-mono text-xs text-gray-600 hover:text-brand hover:underline dark:text-gray-300" prefix={prefix} repository={job.repository} /></DataTable.Cell>
  }
  if (column === "owner") return <DataTable.Cell><DashboardOwnerLabel job={job} prefix={prefix} /></DataTable.Cell>
  if (column === "latest") return <LatestWorkflowCell job={job} />
  if (column === "deployment") return <DeploymentStageCell job={job} prefix={prefix} />
  if (column === "workflows_count") return <DataTable.Cell className="text-gray-700 dark:text-gray-200">{job.workflows_count}</DataTable.Cell>
  if (column === "priority") return <PriorityPillCell priority={job.priority} />
  if (column === "commits_behind_base") return <DataTable.Cell><CommitsBehindBadge count={job.commits_behind_base} /></DataTable.Cell>

  return <TimestampCell value={jobDateValue(job, column)} />
}

// Second, exceptional line under a job's issue/title metadata: only the
// pills/badges that flag something needs attention. Renders null when none
// apply so a normal job's subtitle stays a single line. `includeBlockedReason`
// is mobile-only -- desktop already exposes blocked_reason as its own
// optional column, so repeating it here would duplicate that column.
function JobAttentionLine({ job, includeBlockedReason = false }: { job: DashboardJobItem; includeBlockedReason?: boolean }) {
  const { t } = useT("dashboard")
  const hasAttention = Boolean(job.provider_mismatch)
    || isNotableDeliveryStatus(job.delivery_status)
    || Boolean(job.retry_state && job.retry_state.state_label !== "No failure")
    || (job.state === "queued" && Boolean(job.start_blocked_reason))
    || Boolean(job.manual_paused)
    || (includeBlockedReason && Boolean(job.blocked_reason))

  if (!hasAttention) return null

  return (
    <MetadataLine className="mt-1 flex flex-wrap gap-x-1.5 gap-y-1 text-xs text-text-secondary">
      {job.provider_mismatch ? <ProviderMismatchPill mismatch={job.provider_mismatch} /> : null}
      {isNotableDeliveryStatus(job.delivery_status) ? <DeliveryStatusBadge status={job.delivery_status} /> : null}
      {job.retry_state && job.retry_state.state_label !== "No failure" ? <RetryStateInline job={job} /> : null}
      {job.state === "queued" && job.start_blocked_reason ? (
        <StartBlockedReasonPill count={job.start_blocked_count} details={job.start_blocked_details} nextCheckAt={job.start_blocked_next_check_at} reason={job.start_blocked_reason} startBlockedAt={job.start_blocked_at} />
      ) : null}
      {job.manual_paused ? <ManualPauseInline job={job} /> : null}
      {includeBlockedReason && job.blocked_reason ? <span><CopyableBlockedReason reason={translateBlockedReason(job.blocked_reason, t)} /></span> : null}
    </MetadataLine>
  )
}

function LandingQueueStatusCell({ job }: { job: DashboardJobItem }) {
  return (
    <DataTable.Cell>
      <div className="flex flex-wrap items-center gap-1.5">
        <LandingQueueStatusBadges job={job} />
      </div>
    </DataTable.Cell>
  )
}

function MobileJobQueueStatus({ job }: { job: DashboardJobItem }) {
  if (!job.landing_queue_blocked_reason && !job.landing_queue_wait_reason && !job.landing_blocker_override_requested_at) return null

  return <LandingQueueStatusBadges job={job} wrapPill />
}

function LandingQueueStatusBadges({ job, showEmpty = true, wrapPill = false }: { job: DashboardJobItem; showEmpty?: boolean; wrapPill?: boolean }) {
  const { t } = useT("dashboard")

  if (job.landing_queue_blocked_reason) {
    return (
      <>
        <TonePill tone={landingQueueBlockedReasonTone(job.landing_queue_blocked_reason)} wrap={wrapPill}><CopyableBlockedReason reason={translateBlockedReason(job.landing_queue_blocked_reason, t)} /></TonePill>
        <LandingBlockerOverrideBadge job={job} />
      </>
    )
  }

  if (job.landing_queue_wait_reason) {
    return (
      <>
        <TonePill tone="gray" wrap={wrapPill}><CopyableBlockedReason reason={translateBlockedReason(job.landing_queue_wait_reason, t)} /></TonePill>
        <LandingBlockerOverrideBadge job={job} />
      </>
    )
  }

  const overrideBadge = <LandingBlockerOverrideBadge job={job} />
  if (job.landing_blocker_override_requested_at) return overrideBadge
  if (!showEmpty) return null

  return <span className="text-xs text-gray-500 dark:text-gray-400">-</span>
}

function landingQueueBlockedReasonTone(reason: DashboardJobItem["landing_queue_blocked_reason"]) {
  if (typeof reason === "object" && reason?.key === "queued_in_bundle") return "blue"
  return "red"
}

function CopyableBlockedReason({ reason }: { reason: string }) {
  return <>{linkifySlugs(reason, { hoverCards: false, slugStyle: "copyable" })}</>
}

function LandingBlockerOverrideBadge({ job }: { job: DashboardJobItem }) {
  const { t } = useT("dashboard")
  if (!job.landing_blocker_override_requested_at) return null

  const requestedBy = job.landing_blocker_override_requested_by?.name || job.landing_blocker_override_requested_by?.email_address
  const used = Boolean(job.landing_blocker_override_used_at)
  const title = requestedBy
    ? t("landing_blocker_override_granted_by", { time: job.landing_blocker_override_requested_at, user: requestedBy })
    : undefined

  return (
    <TonePill title={title} tone={used ? "gray" : "amber"}>
      {used ? t("landing_blocker_override_used") : t("landing_blocker_override_pending")}
    </TonePill>
  )
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
  if (!tone) return <DataTable.Cell />
  return <DataTable.Cell><TonePill tone={tone}>{priority}</TonePill></DataTable.Cell>
}

function DeploymentStageCell({ job, prefix }: { job: DashboardJobItem; prefix: string }) {
  const stage = job.latest_deployment_stage
  if (!stage) return <DataTable.Cell className="text-gray-400 dark:text-gray-500">—</DataTable.Cell>

  return (
    <DataTable.Cell>
      <Link className={`inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ring-1 hover:bg-emerald-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:hover:bg-emerald-900/70 ${PILL_TONE_CLASSES.green}`} title={stage.reached_at ?? undefined} to={withRoutePrefix(job.paths.job_path, prefix)}>
        {stage.label || stage.name}
      </Link>
    </DataTable.Cell>
  )
}

function DashboardOwnerLabel({ job, prefix, quiet = false }: { job: DashboardJobItem; prefix: string; quiet?: boolean }) {
  const { t } = useT("dashboard")
  const owner = job.owner_user
  if (!owner) return quiet ? null : <span className="text-xs text-gray-400 dark:text-gray-500">{t("unclaimed")}</span>

  return (
    <Link className="text-xs font-medium text-brand hover:underline dark:text-brand-emphasis" to={withRoutePrefix(`/profiles/${owner.id}`, prefix)}>
      {owner.name || owner.email_address}
    </Link>
  )
}

function LatestWorkflowCell({ job }: { job: DashboardJobItem }) {
  if (job.latest_workflow_id == null) {
    return <DataTable.Cell />
  }

  if (!job.latest_workflow_trigger_kind) {
    return <DataTable.Cell><StatusPill state={job.latest_workflow_state} /></DataTable.Cell>
  }

  return (
    <DataTable.Cell aria-label={`Latest workflow: ${job.latest_workflow_trigger_kind} ${job.latest_workflow_state}`}>
      <div className="flex flex-col items-start gap-1.5">
        <WorkflowTriggerPill ariaPrefix="Latest workflow trigger" triggerKind={job.latest_workflow_trigger_kind} />
        <StatusPill state={job.latest_workflow_state} />
      </div>
    </DataTable.Cell>
  )
}

function JobSlugMetadata({ job, prefix }: { job: DashboardJobItem; prefix: string }) {
  if (job.epic) {
    return (
      <span className="inline-flex items-center">
        <SlugHoverCard id={job.epic.id} kind="epic">
          <Link className="text-gray-500 hover:text-brand hover:underline dark:text-gray-400" to={withRoutePrefix(job.epic.path, prefix)}>{job.epic.display_number}</Link>
        </SlugHoverCard>
        <span>/</span>
        <SlugHoverCard id={job.id} kind="job">
          <CopyableSlug slug={`JOB-${job.id}`} />
        </SlugHoverCard>
      </span>
    )
  }

  return (
    <SlugHoverCard id={job.id} kind="job">
      <CopyableSlug slug={`JOB-${job.id}`} />
    </SlugHoverCard>
  )
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
    <span className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 ring-1 ${PILL_TONE_CLASSES.amber}`} title={title}>
      <span>{t("manual_paused")}</span>
      <span aria-hidden="true" className="select-none">·</span>
      <button
        className="rounded border border-amber-300 bg-white px-1 py-0 text-2xs font-semibold text-amber-900 hover:bg-amber-100 disabled:opacity-60 dark:border-amber-700 dark:bg-gray-950 dark:text-amber-100 dark:hover:bg-amber-900/50"
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

// Only the delivery statuses an the relevant change track/promotion/upstream-export
// flow actually produces are worth a badge here — the two default states
// (waiting_for_local_approval, approved_for_local_landing) match virtually
// every job on a repository with no delivery config and would just be noise.
const NOTABLE_DELIVERY_STATUSES = new Set([
  "waiting_for_upstream_approval",
  "waiting_for_promotion",
  "syncing_hotfix",
  "upstream_merged",
  "upstream_closed_without_merge",
  "delivery_needs_attention"
])

function isNotableDeliveryStatus(status: DashboardJobItem["delivery_status"]): status is NonNullable<DashboardJobItem["delivery_status"]> {
  return Boolean(status) && NOTABLE_DELIVERY_STATUSES.has(status as string)
}

function DeliveryStatusBadge({ status }: { status: NonNullable<DashboardJobItem["delivery_status"]> }) {
  const { t } = useT("dashboard")
  const tone = status === "delivery_needs_attention" ? "red" : status === "upstream_closed_without_merge" ? "amber" : "blue"
  return <TonePill tone={tone}>{t(`delivery_status.${status}`)}</TonePill>
}

function IssueMetadata({ job }: { job: DashboardJobItem }) {
  if (!job.issue_number) return null

  const label = `#${job.issue_number}`

  return <ExternalMetadataLink href={job.issue_url}>{label}</ExternalMetadataLink>
}

function JobSourceChatLink({ job, prefix }: { job: DashboardJobItem; prefix: string }) {
  if (!job.source_chat) return null

  return (
    <Link className="text-gray-500 hover:text-brand hover:underline dark:text-gray-400" to={withRoutePrefix(job.source_chat.path, prefix)}>
      <SlugHoverCard id={job.source_chat.chat_id} kind="chat">
        {/* Copy is a button nested inside this Link; preventDefault stops
            the anchor's native navigation (stopPropagation alone only
            blocks the Link's own onClick, which is what calls
            preventDefault — skip it and the native <a> still navigates). */}
        <span
          onClick={(event) => {
            event.preventDefault()
            event.stopPropagation()
          }}
        >
          <CopyableSlug slug={`CHAT-${job.source_chat.chat_id}`} />
        </span>
      </SlugHoverCard>
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
