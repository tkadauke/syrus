import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { discoverMaintenanceTasks, fetchAdminMaintenanceTask, fetchAdminMaintenanceTasks, runMaintenanceTaskAction } from "../api/maintenanceTasks"
import type { AdminMaintenanceTasksPayload, MaintenanceTask, MaintenanceTaskEvent } from "../api/maintenanceTasks"
import { AdminEventFilterBar, AdminEventLogTable, AdminEventPageShell, AdminEventPanelMessage, adminEventLinkClass } from "../components/AdminEventLogPanel"
import type { AdminEventLogTableColumn } from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { CloseIcon } from "../components/CloseIcon"
import { Modal } from "../components/Modal"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { DataTable, StatusPill, TonePill } from "../components/ui"
import { useConfirm } from "../hooks/useConfirm"
import { usePageTitle } from "../hooks/usePageTitle"
import { Markdown } from "../lib/Markdown"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const POLL_INTERVAL_MS = 10_000
type MaintenanceTaskActionName = "start" | "pause" | "resume" | "cancel" | "dismiss"

export function AdminMaintenanceTasks() {
  usePageTitle("Maintenance tasks")
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
      actions={<Button disabled={discover.isPending} onClick={() => discover.mutate()} variant="secondary">{discover.isPending ? "Checking..." : "Check now"}</Button>}
      ariaLabel="Maintenance tasks"
      eyebrow="Admin"
      title="Maintenance tasks"
    >
      <p className="max-w-3xl text-sm text-text-muted">Run resumable backfills, index rebuilds, and operational repairs without hiding long work inside deploys.</p>

      <AdminEventFilterBar
        clearLabel="Clear filters"
        fields={[
          { name: "state", label: "State" },
          { name: "recurrence", label: "Type" },
          { name: "category", label: "Category" },
          { name: "definition_key", label: "Definition" },
          { name: "trigger_kind", label: "Trigger" },
          { name: "query", label: "Search" }
        ]}
        filter={tasks.data?.filter}
        filterSchema={tasks.data?.filter_schema as any}
        search={location.search}
        searchLabel="Apply filters"
      />

      {tasks.isPending ? <AdminEventPanelMessage>Loading maintenance tasks...</AdminEventPanelMessage> : null}
      {tasks.isError ? <AdminEventPanelMessage tone="error">Maintenance tasks could not be loaded.</AdminEventPanelMessage> : null}
      {tasks.isSuccess ? <MaintenanceTasksTable payload={tasks.data} prefix={prefix} /> : null}
    </AdminEventPageShell>
  )
}

export function AdminMaintenanceTaskDetail() {
  const { id } = useParams()
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const queryClient = useQueryClient()
  const [documentationOpen, setDocumentationOpen] = useState(false)
  const detail = useQuery({
    queryKey: ["admin", "maintenance_tasks", id],
    queryFn: ({ signal }) => fetchAdminMaintenanceTask(id || "", signal),
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
    return <AdminEventPageShell ariaLabel="Maintenance task" eyebrow="Admin" title="Maintenance task"><AdminEventPanelMessage>Loading maintenance task...</AdminEventPanelMessage></AdminEventPageShell>
  }
  if (detail.isError) {
    return <AdminEventPageShell ariaLabel="Maintenance task" eyebrow="Admin" title="Maintenance task"><AdminEventPanelMessage tone="error">Maintenance task could not be loaded.</AdminEventPanelMessage></AdminEventPageShell>
  }

  const task = detail.data
  return (
    <AdminEventPageShell
      actions={<TaskActions task={task} busy={action.isPending} onAction={(name) => action.mutate(name)} onDocs={() => setDocumentationOpen(true)} />}
      ariaLabel={`Maintenance task ${task.id}`}
      eyebrow="Admin"
      title={task.title}
    >
      <Link className={adminEventLinkClass()} to={withRoutePrefix("/admin/maintenance_tasks", prefix)}>Maintenance tasks</Link>
      <p className="max-w-3xl text-sm text-text-muted">{task.summary}</p>
      <TaskProgress task={task} large />

      <section className="space-y-3">
        <h2 className="text-lg font-semibold text-text-primary">Task log</h2>
        <TaskEventLog events={task.events} />
      </section>

      {documentationOpen ? <TaskDocumentationModal task={task} onClose={() => setDocumentationOpen(false)} /> : null}
    </AdminEventPageShell>
  )
}

function MaintenanceTasksTable({ payload, prefix }: { payload: AdminMaintenanceTasksPayload; prefix: string }) {
  if (payload.tasks.length === 0) return <AdminEventPanelMessage>No matching maintenance tasks.</AdminEventPanelMessage>

  const columns: Array<AdminEventLogTableColumn<MaintenanceTask>> = [
    {
      className: "w-[42%] px-4 py-3 align-top",
      headerClassName: "px-4 py-2",
      header: "Task",
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
      header: "Status",
      key: "status",
      render: (task) => (
        <div className="space-y-2">
          <div className="flex items-center justify-between gap-3">
            <TaskStatusPill task={task} />
            <span className="text-xs text-text-muted">{task.progress_percent}%{task.eta_seconds == null ? "" : ` · ${formatEta(task.eta_seconds)}`}</span>
          </div>
          <TaskProgress task={task} showMeta={false} />
          <p className="line-clamp-2 text-xs text-text-muted">{task.current_step_title || "No active step"}</p>
        </div>
      )
    },
    {
      className: "w-[14%] px-4 py-3 align-top font-mono text-xs text-text-muted",
      headerClassName: "px-4 py-2",
      header: "Trigger",
      key: "trigger",
      render: (task) => `${task.trigger_kind}:${task.trigger_key}`
    },
    {
      className: "w-[6%] whitespace-nowrap px-4 py-3 align-top text-xs text-text-muted",
      headerClassName: "px-4 py-2",
      header: "Started",
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

export function TaskActions({ task, busy, onAction, onDocs }: { task: MaintenanceTask; busy?: boolean; onAction: (action: "start" | "pause" | "resume" | "cancel" | "dismiss") => void; onDocs: () => void }) {
  const { confirm, dialog } = useConfirm()

  async function cancel() {
    const confirmed = await confirm({
      cancelLabel: "Keep task",
      confirmLabel: "Cancel task",
      destructive: true,
      message: `Cancel ${task.title}?`
    })
    if (confirmed) onAction("cancel")
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-1.5">
        {task.state === "running" ? <TaskActionButton action="pause" busy={busy} onClick={() => onAction("pause")} /> : null}
        {["pending", "failed", "dismissed"].includes(task.state) ? <TaskActionButton action="start" busy={busy} onClick={() => onAction("start")} /> : null}
        {task.state === "paused" ? <TaskActionButton action="resume" busy={busy} onClick={() => onAction("resume")} /> : null}
        {["pending", "failed", "paused"].includes(task.state) ? <TaskActionButton action="dismiss" busy={busy} onClick={() => onAction("dismiss")} /> : null}
        {!["succeeded", "cancelled", "not_needed"].includes(task.state) ? <TaskActionButton action="cancel" busy={busy} onClick={() => void cancel()} /> : null}
        <TaskActionButton action="docs" busy={busy} onClick={onDocs} />
      </div>
      {dialog}
    </>
  )
}

function TaskStatusPill({ task }: { task: MaintenanceTask }) {
  return <StatusPill state={task.state} />
}

function TaskActionButton({ action, busy = false, onClick }: { action: MaintenanceTaskActionName | "docs"; busy?: boolean; onClick: () => void }) {
  const labels: Record<MaintenanceTaskActionName | "docs", string> = {
    cancel: "Cancel task",
    dismiss: "Dismiss task",
    docs: "Open documentation",
    pause: "Pause task",
    resume: "Resume task",
    start: "Start task"
  }
  const variant = action === "cancel" ? "danger" : action === "start" || action === "resume" ? "primary" : "secondary"

  return (
    <Button
      aria-label={labels[action]}
      className="h-7 w-7 font-mono text-xs"
      disabled={busy}
      onClick={onClick}
      size="icon"
      title={labels[action]}
      variant={variant}
    >
      <TaskActionIcon action={action} />
    </Button>
  )
}

function TaskActionIcon({ action }: { action: MaintenanceTaskActionName | "docs" }) {
  if (action === "cancel") return <CloseIcon className="h-3.5 w-3.5" />
  if (action === "dismiss") return <MinusIcon />
  if (action === "docs") return <QuestionIcon />
  if (action === "pause") return <PauseIcon />
  return <PlayIcon />
}

function PlayIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="currentColor" viewBox="0 0 20 20">
      <path d="M6.25 4.5v11l8.25-5.5-8.25-5.5Z" />
    </svg>
  )
}

function PauseIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="2" viewBox="0 0 20 20">
      <path d="M7 5v10M13 5v10" />
    </svg>
  )
}

function MinusIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="2" viewBox="0 0 20 20">
      <path d="M5 10h10" />
    </svg>
  )
}

function QuestionIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" viewBox="0 0 20 20">
      <path d="M7.75 7.35a2.4 2.4 0 1 1 3.52 2.12c-.76.43-1.27.84-1.27 1.78" />
      <path d="M10 14.75h.01" />
    </svg>
  )
}

export function TaskProgress({ task, large = false, showMeta = true }: { task: MaintenanceTask; large?: boolean; showMeta?: boolean }) {
  const eta = task.eta_seconds == null ? null : formatEta(task.eta_seconds)
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

function TaskEventLog({ events }: { events: MaintenanceTaskEvent[] }) {
  if (events.length === 0) return <AdminEventPanelMessage>No events yet.</AdminEventPanelMessage>

  return (
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>Time</DataTable.HeadCell>
          <DataTable.HeadCell>Level</DataTable.HeadCell>
          <DataTable.HeadCell>Step</DataTable.HeadCell>
          <DataTable.HeadCell>Message</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {events.map((event) => (
          <DataTable.Row key={event.id}>
            <DataTable.Cell className="whitespace-nowrap text-text-muted">{event.created_at ? <RelativeTimestamp value={event.created_at} /> : "-"}</DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap"><TonePill tone={event.level === "error" ? "red" : event.level === "warn" ? "amber" : "blue"}>{event.level}</TonePill></DataTable.Cell>
            <DataTable.Cell className="text-text-muted">{event.step_title || "-"}</DataTable.Cell>
            <DataTable.Cell>{event.message}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

export function TaskDocumentationModal({ task, onClose }: { task: MaintenanceTask; onClose: () => void }) {
  return (
    <Modal
      backdropClassName="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-gray-950/40 p-0 sm:items-center sm:p-4"
      className="flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-white shadow-2xl sm:h-auto sm:max-h-[min(82dvh,46rem)] sm:w-[min(92dvw,52rem)] sm:rounded-lg dark:bg-gray-950"
      label={`${task.title} documentation`}
      onClose={onClose}
      open
    >
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3">
        <h2 className="truncate text-sm font-semibold text-text-primary">{task.title}</h2>
        <Button aria-label="Close documentation" className="h-7 w-7" onClick={onClose} size="icon" title="Close documentation" variant="secondary">
          <CloseIcon className="h-3.5 w-3.5" />
        </Button>
      </header>
      <div className="min-h-0 overflow-auto px-5 py-4 sm:max-h-[calc(min(82dvh,46rem)-3.5rem)]">
        <Markdown className="text-text-primary" text={task.documentation || task.summary} />
      </div>
    </Modal>
  )
}

function formatEta(seconds: number) {
  if (seconds < 60) return `${seconds}s left`
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m left`
  return `${Math.round(minutes / 60)}h left`
}
