import i18n from "../../../i18n"
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
  { key: "task_id", label: () => i18n.t("chat:ops_task_id_0491c6") },
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
    [i18n.t("chat:ops_task_id_0491c6"), task.id],
    [i18n.t("chat:admin_maintenance_definition"), task.definitionKey],
    [i18n.t("chat:admin_maintenance_task_key"), task.taskKey],
    [i18n.t("chat:admin_maintenance_trigger_kind"), task.triggerKind],
    [i18n.t("chat:admin_maintenance_trigger_key"), task.triggerKey],
    [i18n.t("chat:admin_maintenance_required_role"), task.requiredRole],
    [i18n.t("chat:admin_maintenance_current_step_key"), task.currentStepKey],
    [i18n.t("chat:admin_maintenance_current_step"), task.currentStepTitle],
    [i18n.t("chat:admin_maintenance_total_units"), task.totalUnits?.toString() ?? null],
    [i18n.t("chat:admin_maintenance_completed_units"), task.completedUnits?.toString() ?? null],
    [i18n.t("chat:admin_maintenance_failed_units"), task.failedUnits?.toString() ?? null],
    [i18n.t("chat:admin_maintenance_progress"), task.progressPercent == null ? null : `${task.progressPercent}%`],
    [i18n.t("chat:admin_maintenance_eta"), task.etaSeconds == null ? null : `${task.etaSeconds}s`],
    [i18n.t("chat:admin_column_started"), task.startedAt],
    [i18n.t("chat:admin_column_finished"), task.finishedAt],
    [i18n.t("chat:admin_maintenance_paused"), task.pausedAt],
    [i18n.t("chat:admin_maintenance_cancelled"), task.cancelledAt],
    [i18n.t("chat:admin_maintenance_dismissed"), task.dismissedAt]
  ]
  if (task.requestedBy)
    rows.push([
      i18n.t("chat:admin_maintenance_requested_by"),
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
        {task.adminPath ? <InternalLink href={task.adminPath}>{i18n.t("chat:ops_open_task_a1f175")}</InternalLink> : null}
      </div>
      <div className="whitespace-normal break-words font-medium text-text-primary [overflow-wrap:anywhere]">{task.title}</div>
      {task.summary ? (
        <MarkdownPreview maxChars={compact ? 400 : undefined} maxLines={compact ? 4 : 8} text={task.summary} title={i18n.t("chat:ops_summary_12b71c")} />
      ) : null}
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {taskRows(task).map(([label, value]) => (value != null ? <Row key={label} label={label} value={value} /> : null))}
      </dl>
      {task.apiPath ? <Row label={i18n.t("chat:ops_api_path_58046d")} value={task.apiPath} /> : null}
      {task.pendingReason ? <MarkdownPreview maxLines={4} text={task.pendingReason} title={i18n.t("chat:ops_pending_reason_a4ccfe")} /> : null}
      {task.lastError ? <TextPreview maxLines={8} text={task.lastError} title={i18n.t("chat:ops_last_error_5e4df8")} wrap /> : null}
      {task.steps.length > 0 ? (
        <div>
          <SectionLabel>{i18n.t("chat:ops_steps_cdde4f")}</SectionLabel>
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
          title={i18n.t("chat:ops_checkpoint_5cb9af")}
          wrap
        />
      ) : null}
      {!compact && task.documentation ? <MarkdownPreview maxLines={12} text={task.documentation} title={i18n.t("chat:ops_documentation_9e9cf3")} /> : null}
      {!compact && task.events.length > 0 ? (
        <div>
          <SectionLabel>{i18n.t("chat:ops_events_c5497b")}</SectionLabel>
          <div className="mt-1 space-y-3">
            {task.events.map((event) => (
              <div className="rounded-[var(--radius-panel)] border border-border p-2" key={event.id}>
                <div className="mb-1 flex flex-wrap gap-2">
                  <StatePill state={event.level} />
                  <Badge>Event #{event.id}</Badge>
                  {event.stepTitle ? <Badge>{event.stepTitle}</Badge> : null}
                </div>
                <dl className="mb-2 grid gap-2 sm:grid-cols-2">
                  {event.stepKey ? <Row label={i18n.t("chat:ops_step_key_0ae8d5")} value={event.stepKey} /> : null}
                  {event.unitsDone != null ? (
                    <Row
                      label={i18n.t("chat:ops_units_127482")}
                      value={event.unitsTotal == null ? String(event.unitsDone) : `${event.unitsDone} / ${event.unitsTotal}`}
                    />
                  ) : null}
                  {event.createdAt ? <Row label={i18n.t("chat:ops_created_accf40")} value={event.createdAt} /> : null}
                </dl>
                <TextPreview maxLines={8} text={event.message} title={i18n.t("chat:ops_message_68f414")} wrap />
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
    ? i18n.t("chat:admin_maintenance_task_count", { count: payload.tasks.length })
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
        <EmptyState>{i18n.t("chat:ops_no_maintenance_tasks_found_77c53e")}</EmptyState>
      </CardShell>
    )
  return (
    <CardShell>
      <InputDetails fields={INPUT_FIELDS} input={context.input} />
      <Table responsive>
        <THead columns={[i18n.t("chat:admin_column_task"), i18n.t("chat:admin_column_details")]} />
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
  title: i18n.t("chat:ops_rebuild_the_repository_search_index_while_preserving_vis_6509ef"),
  summary: i18n.t("chat:admin_maintenance_catalog_summary"),
  trigger_kind: "manual",
  trigger_key: "catalog_preview",
  required_role: "admin",
  current_step_key: "index_records",
  current_step_title: i18n.t("chat:ops_index_repository_records_0bf341"),
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
  steps: [
    {
      key: "index_records",
      title: i18n.t("chat:ops_index_repository_records_0bf341"),
      description: i18n.t("chat:ops_writes_searchable_records_in_small_batches_606373")
    }
  ],
  requested_by: { id: 12, display_name: "Preview Operator" },
  paths: { admin: "/admin/maintenance_tasks/47", api: "/api/v1/app/admin/maintenance_tasks/47" }
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_pause",
    label: i18n.t("chat:ops_pending_pause_36b0dc"),
    description: i18n.t("chat:ops_mutation_result_using_the_shared_pending_action_presenta_6aa208"),
    input: { action: "pause", task_id: 47 },
    parsedResult: {
      pending_action_id: 801,
      pending_confirmation_id: 801,
      state: "pending",
      message: i18n.t("chat:admin_pause_maintenance_task_confirmation", { count: 1, taskId: 47 })
    }
  },
  {
    id: "populated_list",
    label: i18n.t("chat:ops_populated_task_list_046a86"),
    description: i18n.t("chat:ops_responsive_list_layout_with_complete_task_metadata_markd_b46b66"),
    input: { action: "list", state: "running", limit: 20 },
    parsedResult: { tasks: [catalogTask] }
  },
  {
    id: "rich_detail",
    label: i18n.t("chat:ops_rich_task_detail_4bda73"),
    description: i18n.t("chat:ops_read_result_with_documentation_checkpoint_events_and_alr_d00961"),
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
    label: i18n.t("chat:ops_empty_filtered_list_508127"),
    description: i18n.t("chat:ops_empty_state_that_preserves_the_action_state_filter_and_l_8fdc91"),
    input: { action: "list", state: "paused", limit: 20 },
    parsedResult: { tasks: [] }
  },
  {
    id: "tool_error",
    label: i18n.t("chat:ops_task_lookup_error_654993"),
    description: i18n.t("chat:ops_error_result_with_the_attempted_read_target_and_redacted_4f3576"),
    input: { action: "read", task_id: 999 },
    resultBody: "authorization=[redacted]: maintenance task not found",
    resultError: true
  }
]

export default adminMaintenanceTasksToolCard
