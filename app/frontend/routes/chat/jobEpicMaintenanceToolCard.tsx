import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, numberValue, Row, SectionLabel, StatePill } from "./toolCardUi"

type SubjectKind = "job" | "epic"

type MaintenanceToolDefinition = {
  toolName: string
  subjectKind: SubjectKind
  actionLabel: string
  verb: string
}

const DEFINITIONS: Record<string, MaintenanceToolDefinition> = {
  approve_job: { toolName: "approve_job", subjectKind: "job", actionLabel: "Approve Job", verb: "Approved" },
  cancel_job: { toolName: "cancel_job", subjectKind: "job", actionLabel: "Cancel Job", verb: "Cancel requested" },
  close_job_successfully: { toolName: "close_job_successfully", subjectKind: "job", actionLabel: "Close Job Successfully", verb: "Close requested" },
  set_job_priority: { toolName: "set_job_priority", subjectKind: "job", actionLabel: "Set Job Priority", verb: "Priority changed" },
  update_job: { toolName: "update_job", subjectKind: "job", actionLabel: "Update Job", verb: "Updated" },
  rebase_job: { toolName: "rebase_job", subjectKind: "job", actionLabel: "Rebase Job", verb: "Rebase requested" },
  reopen_job: { toolName: "reopen_job", subjectKind: "job", actionLabel: "Reopen Job", verb: "Reopen requested" },
  poll_job_feedback: { toolName: "poll_job_feedback", subjectKind: "job", actionLabel: "Poll Job Feedback", verb: "Feedback poll requested" },
  unapprove_job: { toolName: "unapprove_job", subjectKind: "job", actionLabel: "Unapprove Job", verb: "Unapproved" },
  remove_job_from_epic: { toolName: "remove_job_from_epic", subjectKind: "job", actionLabel: "Remove Job From Epic", verb: "Removed from Epic" },
  add_job_dependency: { toolName: "add_job_dependency", subjectKind: "job", actionLabel: "Add Job Dependency", verb: "Dependency added" },
  remove_job_dependency: { toolName: "remove_job_dependency", subjectKind: "job", actionLabel: "Remove Job Dependency", verb: "Dependency removed" },
  start_epic: { toolName: "start_epic", subjectKind: "epic", actionLabel: "Start Epic", verb: "Started" },
  move_epic_to_backlog: { toolName: "move_epic_to_backlog", subjectKind: "epic", actionLabel: "Move Epic To Backlog", verb: "Moved to backlog" },
  archive_epic: { toolName: "archive_epic", subjectKind: "epic", actionLabel: "Archive Epic", verb: "Archived" },
  update_epic: { toolName: "update_epic", subjectKind: "epic", actionLabel: "Update Epic", verb: "Updated" },
  add_epic_dependency: { toolName: "add_epic_dependency", subjectKind: "epic", actionLabel: "Add Epic Dependency", verb: "Dependency added" },
  remove_epic_dependency: { toolName: "remove_epic_dependency", subjectKind: "epic", actionLabel: "Remove Epic Dependency", verb: "Dependency removed" }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

type DetailRow = { label: string; value: string }

type MaintenanceCard = {
  definition: MaintenanceToolDefinition
  targetId: string | null
  targetIds: string[]
  pendingId: string | null
  pendingGroupId: string | null
  memberCount: number | null
  state: string
  failed: boolean
  message: string | null
  rows: DetailRow[]
  dependencies: string[]
}

function subjectPrefix(kind: SubjectKind) {
  return kind === "epic" ? "EPIC" : "JOB"
}

function prefixedId(kind: SubjectKind, id: string) {
  return `${subjectPrefix(kind)}-${id}`
}

function objectValue(value: unknown, key: string) {
  return isPlainObject(value) ? value[key] : undefined
}

function compactList(values: unknown): string[] {
  if (!Array.isArray(values)) return []
  return values.flatMap((value) => {
    const label = displayValue(value)
    return label ? [label] : []
  })
}

function inputIds(context: ToolCardContext, key: string) {
  return compactList(objectValue(context.input, key))
}

function firstValue(...values: unknown[]) {
  for (const value of values) {
    const label = displayValue(value)
    if (label) return label
  }
  return null
}

function targetIdFor(context: ToolCardContext, definition: MaintenanceToolDefinition) {
  const result = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const key = definition.subjectKind === "epic" ? "epic_id" : "job_id"
  return firstValue(result[key], objectValue(context.input, key))
}

function targetIdsFor(context: ToolCardContext, definition: MaintenanceToolDefinition) {
  const key = definition.subjectKind === "epic" ? "epic_ids" : "job_ids"
  return inputIds(context, key)
}

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  return firstValue(objectValue(context.parsedResult, "error"), objectValue(context.parsedResult, "message"), context.resultBody)
}

function pushRow(rows: DetailRow[], label: string, value: unknown) {
  const displayed = displayValue(value)
  if (displayed) rows.push({ label, value: displayed })
}

function dependencyLabel(context: ToolCardContext, result: Record<string, unknown>) {
  const dependsOnJobId = firstValue(objectValue(context.input, "depends_on_job_id"))
  if (dependsOnJobId) return `JOB-${dependsOnJobId}`
  const dependsOnEpicId = firstValue(objectValue(context.input, "depends_on_epic_id"))
  if (dependsOnEpicId) return `EPIC-${dependsOnEpicId}`
  const removedFromEpicId = firstValue(result.removed_from_epic_id)
  if (removedFromEpicId) return `EPIC-${removedFromEpicId}`
  return null
}

function dependencyList(definition: MaintenanceToolDefinition, result: Record<string, unknown>) {
  if (definition.subjectKind === "epic") return compactList(result.depends_on).map((id) => `EPIC-${id}`)
  return [
    ...compactList(result.depends_on_job_ids).map((id) => `JOB-${id}`),
    ...compactList(result.depends_on_epic_ids).map((id) => `EPIC-${id}`)
  ]
}

function buildRows(context: ToolCardContext, result: Record<string, unknown>) {
  const rows: DetailRow[] = []
  pushRow(rows, "Before", result.previous_state)
  pushRow(rows, "After", result.new_state)
  pushRow(rows, "Previous priority", result.previous_priority)
  pushRow(rows, "New priority", result.new_priority)
  pushRow(rows, "Title", result.title)
  pushRow(rows, "Description", result.description)
  pushRow(rows, "Closure reason", result.closure_reason || objectValue(context.input, "closure_reason"))
  pushRow(rows, "Dependency", dependencyLabel(context, result))
  pushRow(rows, "Satisfaction", objectValue(context.input, "satisfaction_mode"))
  pushRow(rows, "Removed from", result.removed_from_epic_title || (displayValue(result.removed_from_epic_id) ? `EPIC-${result.removed_from_epic_id}` : null))
  pushRow(rows, "Reason", result.reason)
  return rows
}

export function parseJobEpicMaintenanceResult(context: ToolCardContext): MaintenanceCard | null {
  const definition = DEFINITIONS[context.toolName]
  if (!definition) return null

  const result = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const targetId = targetIdFor(context, definition)
  const targetIds = targetIdsFor(context, definition)
  const pendingId = firstValue(result.pending_action_id, result.pending_confirmation_id)
  const pendingGroupId = firstValue(result.pending_action_group_id)
  const memberCount = numberValue(result.member_count)
  const failed = context.resultError
  const message = errorMessage(context) || displayValue(result.message)
  const state = firstValue(result.state, result.new_state, failed ? "failed" : null, pendingId ? "pending" : "success") || "success"
  const hasRecognizedResult = [
    "job_id",
    "epic_id",
    "pending_action_id",
    "pending_confirmation_id",
    "pending_action_group_id",
    "state",
    "message",
    "previous_state",
    "new_state",
    "previous_priority",
    "new_priority",
    "title",
    "description",
    "closure_reason",
    "reason",
    "depends_on",
    "depends_on_job_ids",
    "depends_on_epic_ids",
    "removed_from_epic_id",
    "removed_from_epic_title",
    "error"
  ].some((key) => result[key] !== undefined)

  if (!targetId && targetIds.length === 0 && !pendingId && !pendingGroupId && !message && !hasRecognizedResult) return null

  return {
    definition,
    targetId,
    targetIds,
    pendingId,
    pendingGroupId,
    memberCount,
    state,
    failed,
    message,
    rows: buildRows(context, result),
    dependencies: dependencyList(definition, result)
  }
}

function targetSummary(card: MaintenanceCard) {
  if (card.targetId) return prefixedId(card.definition.subjectKind, card.targetId)
  if (card.targetIds.length > 0) return `${card.targetIds.length} ${subjectPrefix(card.definition.subjectKind)}s`
  return null
}

export function jobEpicMaintenanceCollapsedSummary(context: ToolCardContext) {
  const card = parseJobEpicMaintenanceResult(context)
  if (!card) return null

  const target = targetSummary(card)
  const action = card.failed ? `${card.definition.actionLabel} failed` : card.definition.verb
  const pending = card.pendingGroupId
    ? `pending group #${card.pendingGroupId}`
    : card.pendingId
      ? `pending #${card.pendingId}`
      : null
  return [action, target, pending].filter(Boolean).join(" · ")
}

export function JobEpicMaintenanceCard({ card }: { card: MaintenanceCard }) {
  const target = targetSummary(card)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.state} tone={card.failed ? "failure" : undefined} />
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{card.definition.actionLabel}</span>
        {target ? <Badge>{target}</Badge> : null}
        {card.pendingId ? <Badge>pending #{card.pendingId}</Badge> : null}
        {card.pendingGroupId ? <Badge>group #{card.pendingGroupId}</Badge> : null}
        {card.memberCount != null ? <Badge>{card.memberCount} {card.memberCount === 1 ? "action" : "actions"}</Badge> : null}
      </div>
      {card.message ? <div className="text-gray-700 dark:text-gray-300">{card.message}</div> : null}
      {card.rows.length > 0 ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {card.rows.map((row) => <Row key={`${row.label}-${row.value}`} label={row.label} value={row.value} />)}
        </dl>
      ) : null}
      {card.dependencies.length > 0 ? (
        <div>
          <SectionLabel>Current dependencies</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.dependencies.map((dependency) => <Badge key={dependency}>{dependency}</Badge>)}
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

export function jobEpicMaintenanceExpandedBody(context: ToolCardContext) {
  const card = parseJobEpicMaintenanceResult(context)
  return card ? <JobEpicMaintenanceCard card={card} /> : null
}

export function maintenanceToolCard(toolName: string): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary: jobEpicMaintenanceCollapsedSummary,
    renderExpanded: jobEpicMaintenanceExpandedBody
  }
}
