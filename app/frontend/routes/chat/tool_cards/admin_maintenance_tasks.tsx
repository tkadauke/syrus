import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"

type TaskStep = { key: string; title: string; description: string | null }
type TaskEvent = {
  id: string
  level: string
  stepKey: string | null
  stepTitle: string | null
  message: string
  unitsDone: number | null
  unitsTotal: number | null
  createdAt: string | null
}
type MaintenanceTask = {
  id: string
  definitionKey: string | null
  taskKey: string | null
  state: string
  recurrence: string | null
  category: string | null
  title: string
  summary: string | null
  triggerKind: string | null
  triggerKey: string | null
  requiredRole: string | null
  currentStepKey: string | null
  currentStepTitle: string | null
  totalUnits: number | null
  completedUnits: number | null
  failedUnits: number | null
  progressPercent: number | null
  etaSeconds: number | null
  startedAt: string | null
  finishedAt: string | null
  pausedAt: string | null
  cancelledAt: string | null
  dismissedAt: string | null
  lastError: string | null
  pendingReason: string | null
  checkpoint: unknown
  documentation: string | null
  steps: TaskStep[]
  events: TaskEvent[]
  requestedBy: { id: string | null; displayName: string | null } | null
  adminPath: string | null
  apiPath: string | null
}

function parseTask(value: unknown): MaintenanceTask | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id),
    title = displayValue(value.title),
    state = displayValue(value.state)
  if (!id || !title || !state) return null
  const requestedBy = isPlainObject(value.requested_by)
    ? { id: displayValue(value.requested_by.id), displayName: displayValue(value.requested_by.display_name) }
    : null
  const paths = isPlainObject(value.paths) ? value.paths : {}
  const steps = Array.isArray(value.steps)
    ? value.steps.flatMap((step) => {
        if (!isPlainObject(step)) return []
        const key = displayValue(step.key),
          stepTitle = displayValue(step.title)
        return key && stepTitle ? [{ key, title: stepTitle, description: displayValue(step.description) }] : []
      })
    : []
  const events = Array.isArray(value.events)
    ? value.events.flatMap((event) => {
        if (!isPlainObject(event)) return []
        const eventId = displayValue(event.id),
          level = displayValue(event.level),
          message = displayValue(event.message)
        return eventId && level && message
          ? [
              {
                id: eventId,
                level,
                message,
                stepKey: displayValue(event.step_key),
                stepTitle: displayValue(event.step_title),
                unitsDone: numberValue(event.units_done),
                unitsTotal: numberValue(event.units_total),
                createdAt: displayValue(event.created_at)
              }
            ]
          : []
      })
    : []
  return {
    id,
    title,
    state,
    steps,
    events,
    requestedBy,
    definitionKey: displayValue(value.definition_key),
    taskKey: displayValue(value.task_key),
    recurrence: displayValue(value.recurrence),
    category: displayValue(value.category),
    summary: displayValue(value.summary),
    triggerKind: displayValue(value.trigger_kind),
    triggerKey: displayValue(value.trigger_key),
    requiredRole: displayValue(value.required_role),
    currentStepKey: displayValue(value.current_step_key),
    currentStepTitle: displayValue(value.current_step_title),
    totalUnits: numberValue(value.total_units),
    completedUnits: numberValue(value.completed_units),
    failedUnits: numberValue(value.failed_units),
    progressPercent: numberValue(value.progress_percent),
    etaSeconds: numberValue(value.eta_seconds),
    startedAt: displayValue(value.started_at),
    finishedAt: displayValue(value.finished_at),
    pausedAt: displayValue(value.paused_at),
    cancelledAt: displayValue(value.cancelled_at),
    dismissedAt: displayValue(value.dismissed_at),
    lastError: displayValue(value.last_error),
    pendingReason: displayValue(value.pending_reason),
    checkpoint: value.checkpoint,
    documentation: displayValue(value.documentation),
    adminPath: displayValue(paths.admin),
    apiPath: displayValue(paths.api)
  }
}

type MaintenancePayload = { kind: "list"; tasks: MaintenanceTask[] } | { kind: "single"; task: MaintenanceTask }
function parsePayload(context: ToolCardContext): MaintenancePayload | null {
  const parsed = normalizedToolCardParsedResult(context.parsedResult)
  if (!isPlainObject(parsed)) return null
  if (Array.isArray(parsed.tasks))
    return {
      kind: "list",
      tasks: parsed.tasks.flatMap((value) => {
        const task = parseTask(value)
        return task ? [task] : []
      })
    }
  const task = parseTask(parsed.task)
  return task ? { kind: "single", task } : null
}

function taskRows(task: MaintenanceTask) {
  const rows: Array<[string, string | null]> = [
    ["Task ID", task.id],
    ["Definition", task.definitionKey],
    ["Task key", task.taskKey],
    ["Trigger kind", task.triggerKind],
    ["Trigger key", task.triggerKey],
    ["Required role", task.requiredRole],
    ["Current step key", task.currentStepKey],
    ["Current step", task.currentStepTitle],
    ["Total units", task.totalUnits?.toString() ?? null],
    ["Completed units", task.completedUnits?.toString() ?? null],
    ["Failed units", task.failedUnits?.toString() ?? null],
    ["Progress", task.progressPercent == null ? null : `${task.progressPercent}%`],
    ["ETA", task.etaSeconds == null ? null : `${task.etaSeconds}s`],
    ["Started", task.startedAt],
    ["Finished", task.finishedAt],
    ["Paused", task.pausedAt],
    ["Cancelled", task.cancelledAt],
    ["Dismissed", task.dismissedAt]
  ]
  if (task.requestedBy)
    rows.push([
      "Requested by",
      task.requestedBy.displayName && task.requestedBy.id
        ? `${task.requestedBy.displayName} (#${task.requestedBy.id})`
        : task.requestedBy.displayName || task.requestedBy.id
    ])
  return rows
}

function TaskDetails({ task, compact = false }: { task: MaintenanceTask; compact?: boolean }) {
  return (
    <div className="min-w-0 space-y-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={task.state} />
        {task.category ? <Badge>{task.category}</Badge> : null}
        {task.recurrence ? <Badge>{task.recurrence}</Badge> : null}
        {task.adminPath ? <InternalLink href={task.adminPath}>Open task</InternalLink> : null}
      </div>
      <div className="whitespace-normal break-words font-medium text-text-primary [overflow-wrap:anywhere]">{task.title}</div>
      {task.summary ? <MarkdownPreview maxChars={compact ? 400 : undefined} maxLines={compact ? 4 : 8} text={task.summary} title="Summary" /> : null}
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {taskRows(task).map(([label, value]) => (value != null ? <Row key={label} label={label} value={value} /> : null))}
      </dl>
      {task.apiPath ? <Row label="API path" value={task.apiPath} /> : null}
      {task.pendingReason ? <MarkdownPreview maxLines={4} text={task.pendingReason} title="Pending reason" /> : null}
      {task.lastError ? <TextPreview maxLines={8} text={task.lastError} title="Last error" wrap /> : null}
      {task.steps.length > 0 ? (
        <div>
          <SectionLabel>Steps</SectionLabel>
          <div className="mt-1 space-y-2">
            {task.steps.map((step) => (
              <div className="min-w-0" key={step.key}>
                <div className="break-words font-medium text-text-primary">
                  {step.title} <span className="font-mono text-2xs text-text-muted">{step.key}</span>
                </div>
                {step.description ? <MarkdownPreview maxLines={3} text={step.description} /> : null}
              </div>
            ))}
          </div>
        </div>
      ) : null}
      {!compact && task.checkpoint != null ? (
        <TextPreview
          maxLines={10}
          text={typeof task.checkpoint === "string" ? task.checkpoint : JSON.stringify(task.checkpoint, null, 2)}
          title="Checkpoint"
          wrap
        />
      ) : null}
      {!compact && task.documentation ? <MarkdownPreview maxLines={12} text={task.documentation} title="Documentation" /> : null}
      {!compact && task.events.length > 0 ? (
        <div>
          <SectionLabel>Events</SectionLabel>
          <div className="mt-1 space-y-3">
            {task.events.map((event) => (
              <div className="rounded-[var(--radius-panel)] border border-border p-2" key={event.id}>
                <div className="mb-1 flex flex-wrap gap-2">
                  <StatePill state={event.level} />
                  <Badge>Event #{event.id}</Badge>
                  {event.stepTitle ? <Badge>{event.stepTitle}</Badge> : null}
                </div>
                <dl className="mb-2 grid gap-2 sm:grid-cols-2">
                  {event.stepKey ? <Row label="Step key" value={event.stepKey} /> : null}
                  {event.unitsDone != null ? (
                    <Row label="Units" value={event.unitsTotal == null ? String(event.unitsDone) : `${event.unitsDone} / ${event.unitsTotal}`} />
                  ) : null}
                  {event.createdAt ? <Row label="Created" value={event.createdAt} /> : null}
                </dl>
                <TextPreview maxLines={8} text={event.message} title="Message" wrap />
              </div>
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

function pendingResult(context: ToolCardContext) {
  return parsePendingActionResult(context, true)
}
function collapsedSummary(context: ToolCardContext) {
  const pending = pendingResult(context)
  if (pending) return pendingActionCollapsedSummary(pending)
  const payload = parsePayload(context)
  if (!payload) return null
  return payload.kind === "list"
    ? `${payload.tasks.length} maintenance task${payload.tasks.length === 1 ? "" : "s"}`
    : `${payload.task.title} (${payload.task.state})`
}
function renderExpanded(context: ToolCardContext) {
  const pending = pendingResult(context)
  if (pending)
    return (
      <PendingActionResultCard
        input={context.input}
        inputFields={[{ key: "action", format: "badge" }, { key: "task_id", label: "Task ID" }, { key: "state", format: "badge" }, { key: "limit" }]}
        result={pending}
      />
    )
  const payload = parsePayload(context)
  if (!payload) return null
  if (payload.kind === "single")
    return (
      <CardShell>
        <TaskDetails task={payload.task} />
      </CardShell>
    )
  if (payload.tasks.length === 0) return <EmptyState>No maintenance tasks found.</EmptyState>
  return (
    <CardShell>
      <Table responsive>
        <THead columns={["Task", "Details"]} />
        <TBody>
          {payload.tasks.map((task) => (
            <tr key={task.id}>
              <Td primary wrap>
                {task.title}
              </Td>
              <Td wrap>
                <TaskDetails compact task={task} />
              </Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

const adminMaintenanceTasksToolCard: ToolCardRenderer = { toolName: "admin_maintenance_tasks", argumentSummary: () => "", collapsedSummary, renderExpanded }
export default adminMaintenanceTasksToolCard
