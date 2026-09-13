import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { discoverMaintenanceTasks, fetchAdminMaintenanceTask, fetchAdminMaintenanceTasks, runMaintenanceTaskAction } from "../api/maintenanceTasks"
import type { AdminMaintenanceTasksPayload, MaintenanceTask, MaintenanceTaskEvent } from "../api/maintenanceTasks"
import { AdminEventFilterBar, AdminEventLogTable, AdminEventPageShell, AdminEventPanelMessage, adminEventLinkClass, disabledPaginationClass, paginationLinkClass } from "../components/AdminEventLogPanel"
import type { AdminEventLogTableColumn } from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { CloseIcon } from "../components/CloseIcon"
import { Modal } from "../components/Modal"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { DataTable, StatusPill, TonePill } from "../components/ui"
import { useConfirm } from "../hooks/useConfirm"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { Markdown } from "../lib/Markdown"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const POLL_INTERVAL_MS = 10_000
type MaintenanceTaskActionName = "start" | "pause" | "resume" | "cancel" | "dismiss"

export function AdminMaintenanceTasks() {
  const { t } = useT("admin")
  usePageTitle(t("maintenance_tasks.page_title"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const queryClient = useQueryClient()
  const tasks = useQuery({
    queryKey: ["admin", "maintenance_tasks", location.search],
    queryFn: ({ signal }) => fetchAdminMaintenanceTasks(location.search, signal),
    refetchInterval: POLL_INTERVAL_MS
  })
  const discover = useMutation({
    mutationFn: discoverMaintenanceTasks,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["admin", "maintenance_tasks"] })
  })

  return (
    <AdminEventPageShell
      actions={<Button disabled={discover.isPending} onClick={() => discover.mutate()} variant="secondary">{discover.isPending ? t("maintenance_tasks.checking") : t("maintenance_tasks.check_now")}</Button>}
      ariaLabel={t("maintenance_tasks.aria")}
      eyebrow={t("section_label")}
      title={t("maintenance_tasks.heading")}
    >
      <p className="max-w-3xl text-sm text-text-muted">{t("maintenance_tasks.description")}</p>

      <AdminEventFilterBar
        clearLabel={t("maintenance_tasks.clear_filters")}
        fields={[
          { name: "state", label: t("maintenance_tasks.filter_state") },
          { name: "recurrence", label: t("maintenance_tasks.filter_type") },
          { name: "category", label: t("maintenance_tasks.filter_category") },
          { name: "definition_key", label: t("maintenance_tasks.filter_definition") },
          { name: "trigger_kind", label: t("maintenance_tasks.filter_trigger") },
          { name: "query", label: t("maintenance_tasks.filter_search") }
        ]}
        filter={tasks.data?.filter}
        filterSchema={tasks.data?.filter_schema as any}
        search={location.search}
        searchLabel={t("maintenance_tasks.apply_filters")}
      />

      {tasks.isPending ? <AdminEventPanelMessage>{t("maintenance_tasks.loading")}</AdminEventPanelMessage> : null}
      {tasks.isError ? <AdminEventPanelMessage tone="error">{t("maintenance_tasks.error_load")}</AdminEventPanelMessage> : null}
      {tasks.isSuccess ? <MaintenanceTasksTable payload={tasks.data} prefix={prefix} /> : null}
    </AdminEventPageShell>
  )
}

export function AdminMaintenanceTaskDetail() {
  const { t } = useT("admin")
  const { id } = useParams()
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const queryClient = useQueryClient()
  const [documentationOpen, setDocumentationOpen] = useState(false)
  const detail = useQuery({
    queryKey: ["admin", "maintenance_tasks", id, location.search],
    queryFn: ({ signal }) => fetchAdminMaintenanceTask(id || "", location.search, signal),
    enabled: Boolean(id),
    refetchInterval: POLL_INTERVAL_MS
  })
  const action = useMutation({
    mutationFn: (name: "start" | "pause" | "resume" | "cancel" | "dismiss") => runMaintenanceTaskAction(id || "", name),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["admin", "maintenance_tasks"] })
    }
  })

  if (detail.isPending) {
    return <AdminEventPageShell ariaLabel={t("maintenance_tasks.detail_aria")} eyebrow={t("section_label")} title={t("maintenance_tasks.detail_title")}><AdminEventPanelMessage>{t("maintenance_tasks.detail_loading")}</AdminEventPanelMessage></AdminEventPageShell>
  }
  if (detail.isError) {
    return <AdminEventPageShell ariaLabel={t("maintenance_tasks.detail_aria")} eyebrow={t("section_label")} title={t("maintenance_tasks.detail_title")}><AdminEventPanelMessage tone="error">{t("maintenance_tasks.detail_error_load")}</AdminEventPanelMessage></AdminEventPageShell>
  }

  const task = detail.data
  return (
    <AdminEventPageShell
      actions={<TaskActions task={task} busy={action.isPending} onAction={(name) => action.mutate(name)} onDocs={() => setDocumentationOpen(true)} />}
      ariaLabel={t("maintenance_tasks.detail_aria_with_id", { id: task.id })}
      eyebrow={t("section_label")}
      title={task.title}
    >
      <Link className={adminEventLinkClass()} to={withRoutePrefix("/admin/maintenance_tasks", prefix)}>{t("maintenance_tasks.back_link")}</Link>
      <p className="max-w-3xl text-sm text-text-muted">{task.summary}</p>
      <TaskProgress task={task} large />

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-text-primary">{t("maintenance_tasks.task_log")}</h2>
        <TaskEventLog task={task} prefix={prefix} />
      </section>

      {documentationOpen ? <TaskDocumentationModal task={task} onClose={() => setDocumentationOpen(false)} /> : null}
    </AdminEventPageShell>
  )
}

function MaintenanceTasksTable({ payload, prefix }: { payload: AdminMaintenanceTasksPayload; prefix: string }) {
  const { t } = useT("admin")
  if (payload.tasks.length === 0) return <AdminEventPanelMessage>{t("maintenance_tasks.empty")}</AdminEventPanelMessage>

  const columns: Array<AdminEventLogTableColumn<MaintenanceTask>> = [
    {
      className: "w-[42%] px-4 py-3 align-top",
      headerClassName: "px-4 py-2",
      header: t("maintenance_tasks.col_task"),
      key: "task",
      render: (task) => (
        <div className="space-y-2">
          <Link className={adminEventLinkClass()} to={withRoutePrefix(`/admin/maintenance_tasks/${task.id}`, prefix)}>{task.title}</Link>
          <p className="max-w-lg text-xs text-text-muted">{task.summary}</p>
          <TaskType task={task} />
        </div>
      )
    },
    {
      className: "w-[38%] px-4 py-3 align-top",
      headerClassName: "px-4 py-2",
      header: t("maintenance_tasks.col_status"),
      key: "status",
      render: (task) => (
        <div className="space-y-2">
          <div className="flex items-center justify-between gap-3">
            <TaskStatusPill task={task} />
            <span className="text-xs text-text-muted">{task.progress_percent}%{task.eta_seconds == null ? "" : ` · ${formatEta(task.eta_seconds, t)}`}</span>
          </div>
          <TaskProgress task={task} showMeta={false} />
          <p className="line-clamp-2 text-xs text-text-muted">{task.current_step_title || t("maintenance_tasks.no_active_step")}</p>
        </div>
      )
    },
    {
      className: "w-[14%] px-4 py-3 align-top font-mono text-xs text-text-muted",
      headerClassName: "px-4 py-2",
      header: t("maintenance_tasks.col_trigger"),
      key: "trigger",
      render: (task) => `${task.trigger_kind}:${task.trigger_key}`
    },
    {
      className: "w-[6%] whitespace-nowrap px-4 py-3 align-top text-xs text-text-muted",
      headerClassName: "px-4 py-2",
      header: t("maintenance_tasks.col_started"),
      key: "started",
      render: (task) => task.started_at ? <RelativeTimestamp value={task.started_at} /> : "-"
    }
  ]

  return <AdminEventLogTable columns={columns} getRowKey={(task) => task.id} rows={payload.tasks} tableClassName="min-w-full divide-y divide-border text-sm" />
}

function TaskType({ task }: { task: MaintenanceTask }) {
  return (
    <div className="flex flex-wrap gap-1">
      <TonePill tone={task.recurrence === "one_off" ? "amber" : "blue"}>{task.recurrence.replace("_", " ")}</TonePill>
      <TonePill tone="gray">{task.category}</TonePill>
    </div>
  )
}

export function TaskActions({ task, busy, compact = false, onAction, onDocs }: { task: MaintenanceTask; busy?: boolean; compact?: boolean; onAction: (action: "start" | "pause" | "resume" | "cancel" | "dismiss") => void; onDocs: () => void }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()

  async function cancel() {
    const confirmed = await confirm({
      cancelLabel: t("maintenance_tasks.keep_task"),
      confirmLabel: t("maintenance_tasks.cancel_task"),
      destructive: true,
      message: t("maintenance_tasks.cancel_confirm", { title: task.title })
    })
    if (confirmed) onAction("cancel")
  }

  return (
    <>
      <div className={`flex flex-wrap items-center gap-1.5 ${compact ? "justify-end" : ""}`}>
        {task.state === "running" ? <TaskActionButton action="pause" busy={busy} compact={compact} onClick={() => onAction("pause")} /> : null}
        {["pending", "failed", "dismissed"].includes(task.state) ? <TaskActionButton action="start" busy={busy} compact={compact} onClick={() => onAction("start")} /> : null}
        {task.state === "paused" ? <TaskActionButton action="resume" busy={busy} compact={compact} onClick={() => onAction("resume")} /> : null}
        {["pending", "failed", "dismissed"].includes(task.state) ? <TaskActionButton action="dismiss" busy={busy} compact={compact} onClick={() => onAction("dismiss")} /> : null}
        {["running", "paused"].includes(task.state) ? <TaskActionButton action="cancel" busy={busy} compact={compact} onClick={() => void cancel()} /> : null}
        <TaskActionButton action="docs" busy={busy} compact={compact} onClick={onDocs} />
      </div>
      {dialog}
    </>
  )
}

function TaskStatusPill({ task }: { task: MaintenanceTask }) {
  return <StatusPill state={task.state} />
}

function TaskActionButton({ action, busy = false, compact = false, onClick }: { action: MaintenanceTaskActionName | "docs"; busy?: boolean; compact?: boolean; onClick: () => void }) {
  const { t } = useT("admin")
  const labels: Record<MaintenanceTaskActionName | "docs", string> = {
    cancel: t("maintenance_tasks.cancel_task"),
    dismiss: t("maintenance_tasks.dismiss_task"),
    docs: t("maintenance_tasks.open_documentation"),
    pause: t("maintenance_tasks.pause_task"),
    resume: t("maintenance_tasks.resume_task"),
    start: t("maintenance_tasks.start_task")
  }
  const variant = action === "cancel" ? "danger" : action === "start" || action === "resume" ? "primary" : "secondary"

  return (
    <Button
      aria-label={labels[action]}
      className={`${compact ? "h-5 w-5" : "h-7 w-7"} font-mono text-xs`}
      disabled={busy}
      onClick={onClick}
      size="icon"
      title={labels[action]}
      variant={variant}
    >
      <TaskActionIcon action={action} compact={compact} />
    </Button>
  )
}

function TaskActionIcon({ action, compact = false }: { action: MaintenanceTaskActionName | "docs"; compact?: boolean }) {
  const className = compact ? "h-3 w-3" : "h-3.5 w-3.5"
  if (action === "cancel") return <CloseIcon className={className} />
  if (action === "dismiss") return <MinusIcon className={className} />
  if (action === "docs") return <QuestionIcon className={className} />
  if (action === "pause") return <PauseIcon className={className} />
  return <PlayIcon className={className} />
}

function PlayIcon({ className = "h-3.5 w-3.5" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="currentColor" viewBox="0 0 20 20">
      <path d="M6.25 4.5v11l8.25-5.5-8.25-5.5Z" />
    </svg>
  )
}

function PauseIcon({ className = "h-3.5 w-3.5" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="2" viewBox="0 0 20 20">
      <path d="M7 5v10M13 5v10" />
    </svg>
  )
}

function MinusIcon({ className = "h-3.5 w-3.5" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="2" viewBox="0 0 20 20">
      <path d="M5 10h10" />
    </svg>
  )
}

function QuestionIcon({ className = "h-3.5 w-3.5" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" viewBox="0 0 20 20">
      <path d="M7.75 7.35a2.4 2.4 0 1 1 3.52 2.12c-.76.43-1.27.84-1.27 1.78" />
      <path d="M10 14.75h.01" />
    </svg>
  )
}

export function TaskProgress({ task, large = false, showMeta = true }: { task: MaintenanceTask; large?: boolean; showMeta?: boolean }) {
  const { t } = useT("admin")
  const eta = task.eta_seconds == null ? null : formatEta(task.eta_seconds, t)
  return (
    <div className={large ? "rounded border border-border bg-surface p-4" : ""}>
      {showMeta ? (
        <div className="flex items-center justify-between gap-3 text-xs text-text-muted">
          <span>{task.completed_units}/{task.total_units}</span>
          <span>{task.progress_percent}%{eta ? ` · ${eta}` : ""}</span>
        </div>
      ) : null}
      <div className="mt-1 h-2 overflow-hidden rounded-full bg-surface-raised">
        <div className="h-full rounded-full bg-brand" style={{ width: `${task.progress_percent}%` }} />
      </div>
      {large && task.current_step_title ? <p className="mt-2 text-sm text-text-primary">{task.current_step_title}</p> : null}
      {large && task.last_error ? <p className="mt-2 text-sm text-danger-text">{task.last_error}</p> : null}
    </div>
  )
}

function TaskEventLog({ prefix, task }: { prefix: string; task: { events: MaintenanceTaskEvent[]; events_pagination: { page: number; total: number; total_pages: number; first_item: number; last_item: number; previous_path: string | null; next_path: string | null } } }) {
  const { t } = useT("admin")
  const { events, events_pagination: pagination } = task
  if (events.length === 0) return <AdminEventPanelMessage>{t("maintenance_tasks.no_events")}</AdminEventPanelMessage>

  return (
    <div className="rounded border border-border bg-surface">
      <div className="border-b border-border px-4 py-3 text-sm text-text-muted">
        {t("maintenance_tasks.log_showing", { first: pagination.first_item, last: pagination.last_item, total: pagination.total })}
      </div>
      <DataTable.Root density="compact">
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>{t("maintenance_tasks.col_time")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("maintenance_tasks.col_level")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("maintenance_tasks.col_step")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("maintenance_tasks.col_message")}</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {events.map((event) => (
            <DataTable.Row key={event.id}>
              <DataTable.Cell className="whitespace-nowrap text-text-muted">{event.created_at ? <RelativeTimestamp value={event.created_at} /> : "-"}</DataTable.Cell>
              <DataTable.Cell className="whitespace-nowrap"><TonePill tone={event.level === "error" ? "red" : event.level === "warning" ? "amber" : "blue"}>{event.level}</TonePill></DataTable.Cell>
              <DataTable.Cell className="text-text-muted">{event.step_title || "-"}</DataTable.Cell>
              <DataTable.Cell>{event.message}</DataTable.Cell>
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
      <TaskEventPagination pagination={pagination} prefix={prefix} />
    </div>
  )
}

function TaskEventPagination({ pagination, prefix }: { pagination: { page: number; total_pages: number; previous_path: string | null; next_path: string | null }; prefix: string }) {
  const { t } = useT("admin")
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label={t("maintenance_tasks.log_pagination")} className="flex items-center justify-between border-t border-border px-4 py-3 text-sm text-text-muted">
      <span>{t("maintenance_tasks.page_of", { page: pagination.page, total: pagination.total_pages })}</span>
      <div className="flex items-center gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("maintenance_tasks.previous")}</Link> : <span className={disabledPaginationClass()}>{t("maintenance_tasks.previous")}</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("maintenance_tasks.next")}</Link> : <span className={disabledPaginationClass()}>{t("maintenance_tasks.next")}</span>}
      </div>
    </nav>
  )
}

export function TaskDocumentationModal({ task, onClose }: { task: MaintenanceTask; onClose: () => void }) {
  const { t } = useT("admin")
  return (
    <Modal
      backdropClassName="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-gray-950/40 p-0 sm:items-center sm:p-4"
      className="flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-white shadow-2xl sm:h-auto sm:max-h-[min(82dvh,46rem)] sm:w-[min(92dvw,52rem)] sm:rounded-lg dark:bg-gray-950"
      label={t("maintenance_tasks.documentation_label", { title: task.title })}
      onClose={onClose}
      open
    >
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3">
        <h2 className="truncate text-sm font-semibold text-text-primary">{task.title}</h2>
        <Button aria-label={t("maintenance_tasks.close_documentation")} className="h-7 w-7" onClick={onClose} size="icon" title={t("maintenance_tasks.close_documentation")} variant="secondary">
          <CloseIcon className="h-3.5 w-3.5" />
        </Button>
      </header>
      <div className="min-h-0 overflow-auto px-5 py-4 sm:max-h-[calc(min(82dvh,46rem)-3.5rem)]">
        <Markdown className="text-text-primary" text={task.documentation || task.summary} />
      </div>
    </Modal>
  )
}

function formatEta(seconds: number, t: (key: string, options?: Record<string, unknown>) => string) {
  if (seconds < 60) return t("maintenance_tasks.eta_seconds", { seconds })
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return t("maintenance_tasks.eta_minutes", { minutes })
  return t("maintenance_tasks.eta_hours", { hours: Math.round(minutes / 60) })
}
