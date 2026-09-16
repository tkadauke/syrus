import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { Badge, CardShell, displayValue, EmptyState, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for admin_maintenance_tasks. Covers all six
// sub-actions (list/read/discover/start/pause/resume/cancel/dismiss) --
// list and discover return { tasks: [...] }; read and every mutation
// return { task: {...} } -- by branching on which key App::MaintenanceTasksPayload
// actually populated.
type MaintenanceTaskRow = {
  id: string
  title: string
  state: string
  category: string | null
  recurrence: string | null
  totalUnits: number | null
  completedUnits: number | null
  failedUnits: number | null
  progressPercent: number | null
  lastError: string | null
  pendingReason: string | null
  currentStepTitle: string | null
}

function parseTask(value: unknown): MaintenanceTaskRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const title = displayValue(value.title)
  const state = displayValue(value.state)
  if (!id || !title || !state) return null

  return {
    id,
    title,
    state,
    category: displayValue(value.category),
    recurrence: displayValue(value.recurrence),
    totalUnits: numberValue(value.total_units),
    completedUnits: numberValue(value.completed_units),
    failedUnits: numberValue(value.failed_units),
    progressPercent: numberValue(value.progress_percent),
    lastError: displayValue(value.last_error),
    pendingReason: displayValue(value.pending_reason),
    currentStepTitle: displayValue(value.current_step_title)
  }
}

type MaintenancePayload =
  | { kind: "list"; tasks: MaintenanceTaskRow[] }
  | { kind: "single"; task: MaintenanceTaskRow }

function parsePayload(context: ToolCardContext): MaintenancePayload | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  if (Array.isArray(parsed.tasks)) {
    return { kind: "list", tasks: parsed.tasks.flatMap((task) => { const row = parseTask(task); return row ? [row] : [] }) }
  }

  if (isPlainObject(parsed.task)) {
    const task = parseTask(parsed.task)
    return task ? { kind: "single", task } : null
  }

  return null
}

function collapsedSummary(context: ToolCardContext) {
  const payload = parsePayload(context)
  if (!payload) return null

  if (payload.kind === "list") return `${payload.tasks.length} maintenance task${payload.tasks.length === 1 ? "" : "s"}`

  return `${payload.task.title} (${payload.task.state})`
}

function followUpFor(task: MaintenanceTaskRow): string | null {
  if (task.state === "failed" && task.lastError) return "Investigate the last error, then resume or cancel."
  if (task.state === "paused" && task.pendingReason) return task.pendingReason
  if (task.state === "running" && task.failedUnits) return `${task.failedUnits} unit(s) failed so far; review before it finishes.`
  return null
}

function TaskDetail({ task }: { task: MaintenanceTaskRow }) {
  const followUp = followUpFor(task)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={task.state} />
        {task.category ? <Badge>{task.category}</Badge> : null}
        {task.recurrence ? <Badge>{task.recurrence}</Badge> : null}
      </div>
      <div className="font-medium text-gray-900 dark:text-gray-100">{task.title}</div>
      <dl className="grid gap-2 sm:grid-cols-2">
        {task.currentStepTitle ? <Row label="Current step" value={task.currentStepTitle} /> : null}
        {task.progressPercent != null ? <Row label="Progress" value={`${task.progressPercent}%`} /> : null}
        {task.completedUnits != null && task.totalUnits != null ? <Row label="Units" value={`${task.completedUnits} / ${task.totalUnits}`} /> : null}
        {task.failedUnits ? <Row label="Failed units" value={String(task.failedUnits)} /> : null}
      </dl>
      {task.lastError ? (
        <div>
          <SectionLabel>Last error</SectionLabel>
          <div className="mt-0.5 break-words font-mono text-xs text-red-700 dark:text-red-300">{task.lastError}</div>
        </div>
      ) : null}
      {followUp ? (
        <div>
          <SectionLabel>Follow-up</SectionLabel>
          <div className="mt-0.5 text-gray-700 dark:text-gray-300">{followUp}</div>
        </div>
      ) : null}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const payload = parsePayload(context)
  if (!payload) return null

  if (payload.kind === "single") return <TaskDetail task={payload.task} />
  if (payload.tasks.length === 0) return <EmptyState>No maintenance tasks found.</EmptyState>

  return (
    <CardShell>
      <Table>
        <THead columns={["Task", "State", "Category", "Progress", "Failed"]} />
        <TBody>
          {payload.tasks.map((task) => (
            <tr key={task.id}>
              <Td maxWidth title={task.title}>{task.title}</Td>
              <Td><StatePill state={task.state} /></Td>
              <Td>{task.category || "—"}</Td>
              <Td mono>{task.progressPercent != null ? `${task.progressPercent}%` : "—"}</Td>
              <Td mono>{task.failedUnits ?? "—"}</Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

const adminMaintenanceTasksToolCard: ToolCardRenderer = {
  toolName: "admin_maintenance_tasks",
  collapsedSummary,
  renderExpanded
}

export default adminMaintenanceTasksToolCard
