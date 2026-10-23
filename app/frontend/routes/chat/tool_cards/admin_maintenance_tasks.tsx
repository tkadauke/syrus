import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { Table, TBody, Td, THead } from "../adminToolCard"
import {
  InputDetails,
  parsePendingActionResult,
  pendingActionCollapsedSummary,
  PendingActionResultCard,
  type PendingActionInputField
} from "../pendingActionToolCard"
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
const INPUT_FIELDS: PendingActionInputField[] = [
  { key: "action", format: "badge" },
  { key: "task_id", label: "Task ID" },
  { key: "state", format: "badge" },
  { key: "limit" }
]

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
  if (pending) return <PendingActionResultCard input={context.input} inputFields={INPUT_FIELDS} result={pending} />
  const payload = parsePayload(context)
  if (!payload) return null
  if (payload.kind === "single")
    return (
      <CardShell>
        <InputDetails fields={INPUT_FIELDS} input={context.input} />
        <TaskDetails task={payload.task} />
      </CardShell>
    )
  if (payload.tasks.length === 0)
    return (
      <CardShell>
        <InputDetails fields={INPUT_FIELDS} input={context.input} />
        <EmptyState>No maintenance tasks found.</EmptyState>
      </CardShell>
    )
  return (
    <CardShell>
      <InputDetails fields={INPUT_FIELDS} input={context.input} />
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

const catalogTask = {
  id: 47,
  definition_key: "rebuild_search_index",
  task_key: "rebuild_search_index:catalog",
  state: "running",
  recurrence: "one_off",
  category: "search",
  title: "Rebuild the repository search index while preserving visibility across a deliberately long maintenance-task title",
  summary: "Rebuilds the **repository search index** in bounded batches.",
  trigger_kind: "manual",
  trigger_key: "catalog_preview",
  required_role: "admin",
  current_step_key: "index_records",
  current_step_title: "Index repository records",
  total_units: 1200,
  completed_units: 450,
  failed_units: 0,
  progress_percent: 37.5,
  eta_seconds: 180,
  started_at: "2026-10-22T10:00:00Z",
  finished_at: null,
  paused_at: null,
  cancelled_at: null,
  dismissed_at: null,
  last_error: null,
  pending_reason: null,
  steps: [{ key: "index_records", title: "Index repository records", description: "Writes searchable records in **small batches**." }],
  requested_by: { id: 12, display_name: "Preview Operator" },
  paths: { admin: "/admin/maintenance_tasks/47", api: "/api/v1/app/admin/maintenance_tasks/47" }
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_pause",
    label: "Pending pause",
    description: "Mutation result using the shared pending-action presentation with its task target and action.",
    input: { action: "pause", task_id: 47 },
    parsedResult: { pending_action_id: 801, pending_confirmation_id: 801, state: "pending", message: "Pause maintenance task #47?" }
  },
  {
    id: "populated_list",
    label: "Populated task list",
    description: "Responsive list layout with complete task metadata, Markdown summary, long-title wrapping, and links.",
    input: { action: "list", state: "running", limit: 20 },
    parsedResult: { tasks: [catalogTask] }
  },
  {
    id: "rich_detail",
    label: "Rich task detail",
    description: "Read result with documentation, checkpoint, events, and already-redacted log previews.",
    input: { action: "read", task_id: 47 },
    parsedResult: {
      task: {
        ...catalogTask,
        state: "failed",
        last_error: "authorization=[redacted] while updating the index",
        pending_reason: "Waiting for **operator review** before resuming.",
        checkpoint: { last_repository_id: 450, cursor: "page-9" },
        documentation: "# Search-index rebuild\n\nReview failed batches, then resume from the saved checkpoint.",
        events: [
          {
            id: 902,
            level: "error",
            step_key: "index_records",
            step_title: "Index repository records",
            message: "token=[redacted] was rejected by the search service",
            units_done: 450,
            units_total: 1200,
            created_at: "2026-10-22T10:08:00Z"
          }
        ]
      }
    }
  },
  {
    id: "empty_filtered_list",
    label: "Empty filtered list",
    description: "Empty state that preserves the action, state filter, and limit that produced it.",
    input: { action: "list", state: "paused", limit: 20 },
    parsedResult: { tasks: [] }
  },
  {
    id: "tool_error",
    label: "Task lookup error",
    description: "Error result with the attempted read target and redacted diagnostic text.",
    input: { action: "read", task_id: 999 },
    resultBody: "authorization=[redacted]: maintenance task not found",
    resultError: true
  }
]

export default adminMaintenanceTasksToolCard
