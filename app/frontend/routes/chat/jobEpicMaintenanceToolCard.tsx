import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "../../toolCardParsing"
import { MarkdownPreview } from "./toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, SectionLabel, StatePill, WrappingRow } from "./toolCardUi"

type SubjectKind = "job" | "epic"
const SUBJECT_ENTITY_KIND: Record<SubjectKind, "job" | "epic"> = { job: "job", epic: "epic" }

type MaintenanceToolDefinition = {
  toolName: string
  subjectKind: SubjectKind
  actionLabel: string
  verb: string
  pendingVerb?: string
}

const DEFINITIONS: Record<string, MaintenanceToolDefinition> = {
  approve_job: { toolName: "approve_job", subjectKind: "job", actionLabel: "Approve Job", verb: "Approved", pendingVerb: "Approval requested" },
  cancel_job: { toolName: "cancel_job", subjectKind: "job", actionLabel: "Cancel Job", verb: "Cancel requested" },
  close_job_successfully: { toolName: "close_job_successfully", subjectKind: "job", actionLabel: "Close Job Successfully", verb: "Close requested" },
  set_job_priority: { toolName: "set_job_priority", subjectKind: "job", actionLabel: "Set Job Priority", verb: "Priority changed" },
  update_job: { toolName: "update_job", subjectKind: "job", actionLabel: "Update Job", verb: "Updated" },
  rebase_job: { toolName: "rebase_job", subjectKind: "job", actionLabel: "Rebase Job", verb: "Rebase requested" },
  reopen_job: { toolName: "reopen_job", subjectKind: "job", actionLabel: "Reopen Job", verb: "Reopen requested" },
  poll_job_feedback: { toolName: "poll_job_feedback", subjectKind: "job", actionLabel: "Poll Job Feedback", verb: "Feedback poll requested" },
  unapprove_job: { toolName: "unapprove_job", subjectKind: "job", actionLabel: "Unapprove Job", verb: "Unapproved", pendingVerb: "Unapproval requested" },
  remove_job_from_epic: { toolName: "remove_job_from_epic", subjectKind: "job", actionLabel: "Remove Job From Epic", verb: "Removed from Epic" },
  add_job_dependency: { toolName: "add_job_dependency", subjectKind: "job", actionLabel: "Add Job Dependency", verb: "Dependency added" },
  remove_job_dependency: { toolName: "remove_job_dependency", subjectKind: "job", actionLabel: "Remove Job Dependency", verb: "Dependency removed" },
  start_epic: { toolName: "start_epic", subjectKind: "epic", actionLabel: "Start Epic", verb: "Started" },
  move_epic_to_backlog: { toolName: "move_epic_to_backlog", subjectKind: "epic", actionLabel: "Move Epic To Backlog", verb: "Moved to backlog" },
  archive_epic: { toolName: "archive_epic", subjectKind: "epic", actionLabel: "Archive Epic", verb: "Archive requested" },
  update_epic: { toolName: "update_epic", subjectKind: "epic", actionLabel: "Update Epic", verb: "Updated" },
  add_epic_dependency: { toolName: "add_epic_dependency", subjectKind: "epic", actionLabel: "Add Epic Dependency", verb: "Dependency added" },
  remove_epic_dependency: { toolName: "remove_epic_dependency", subjectKind: "epic", actionLabel: "Remove Epic Dependency", verb: "Dependency removed" }
}

type DetailRow = { label: string; value: ReactNode; markdown?: string }

type MaintenanceCard = {
  definition: MaintenanceToolDefinition
  targetId: string | null
  targetIds: string[]
  pendingId: string | null
  pendingGroupId: string | null
  memberCount: number | null
  state: string
  hasNewState: boolean
  failed: boolean
  message: string | null
  rows: DetailRow[]
  dependencies: string[]
  showsDependencies: boolean
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
  if (!context.resultError && !displayValue(objectValue(context.parsedResult, "error"))) return null
  const message = firstValue(objectValue(context.parsedResult, "error"), objectValue(context.parsedResult, "message"), context.resultBody)
  if (!message) return null
  const stripped = message.replace(/^Error:\s*/i, "")
  return stripped === "not_authorized" ? "Not authorized" : stripped
}

function pushRow(rows: DetailRow[], label: string, value: unknown, markdown = false) {
  const displayed = displayValue(value)
  if (displayed) rows.push({ label, value: displayed, markdown: markdown ? displayed : undefined })
}

function pushNodeRow(rows: DetailRow[], label: string, value: ReactNode | null) {
  if (value != null) rows.push({ label, value })
}

function entityValue(kind: SubjectKind, id: string): ReactNode {
  return <EntityReference id={id} kind={SUBJECT_ENTITY_KIND[kind]} />
}

function dependencyLabel(context: ToolCardContext, result: Record<string, unknown>): ReactNode | null {
  const dependsOnJobId = firstValue(objectValue(context.input, "depends_on_job_id"))
  if (dependsOnJobId) return entityValue("job", dependsOnJobId)
  const dependsOnEpicId = firstValue(objectValue(context.input, "depends_on_epic_id"))
  if (dependsOnEpicId) return entityValue("epic", dependsOnEpicId)
  const removedFromEpicId = firstValue(result.removed_from_epic_id)
  if (removedFromEpicId) return entityValue("epic", removedFromEpicId)
  return null
}

function dependencyList(definition: MaintenanceToolDefinition, result: Record<string, unknown>) {
  if (definition.subjectKind === "epic") return compactList(result.depends_on).map((id) => `EPIC-${id}`)
  return [
    ...compactList(result.depends_on_job_ids).map((id) => `JOB-${id}`),
    ...compactList(result.depends_on_epic_ids).map((id) => `EPIC-${id}`)
  ]
}

function buildRows(context: ToolCardContext, result: Record<string, unknown>, showNewState: boolean) {
  const rows: DetailRow[] = []
  pushRow(rows, "Before", result.previous_state)
  if (showNewState) pushRow(rows, "After", result.new_state)
  pushRow(rows, "Previous priority", result.previous_priority)
  pushRow(rows, "New priority", result.new_priority || objectValue(context.input, "new_priority") || objectValue(context.input, "priority"))
  pushRow(rows, "Title", result.title || objectValue(context.input, "title"))
  pushRow(rows, "Description", result.description || objectValue(context.input, "description"), true)
  pushRow(rows, "Closure reason", result.closure_reason || objectValue(context.input, "closure_reason"))
  pushNodeRow(rows, "Dependency", dependencyLabel(context, result))
  pushRow(rows, "Satisfaction", objectValue(context.input, "satisfaction_mode"))
  pushRow(rows, "Required stage", objectValue(context.input, "required_deployment_stage_name") || result.required_deployment_stage_name)
  const removedId = firstValue(result.removed_from_epic_id)
  if (displayValue(result.removed_from_epic_title)) pushRow(rows, "Removed from", result.removed_from_epic_title)
  else pushNodeRow(rows, "Removed from", removedId ? entityValue("epic", removedId) : null)
  pushRow(rows, "Reason", result.reason || objectValue(context.input, "reason"), true)
  pushRow(rows, "Comment", result.comment || objectValue(context.input, "comment"), true)
  return rows
}

function linkifiedText(text: string): ReactNode {
  const parts = text.split(/\b((?:JOB|EPIC)-\d+)\b/g)
  return parts.map((part, index) => {
    const match = part.match(/^(JOB|EPIC)-(\d+)$/)
    return match ? <EntityReference key={`${part}-${index}`} id={match[2]} kind={match[1] === "JOB" ? "job" : "epic"} /> : part
  })
}

export function parseJobEpicMaintenanceResult(context: ToolCardContext): MaintenanceCard | null {
  const definition = DEFINITIONS[context.toolName]
  if (!definition) return null

  const frozenResult = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const pendingIdFromResult = firstValue(frozenResult.pending_action_id, frozenResult.pending_confirmation_id)
  const live = context.livePendingAction
  const liveMatch = live && pendingIdFromResult && displayValue(live.id) === pendingIdFromResult ? live : null
  const afterSnapshot = liveMatch && isPlainObject(liveMatch.after_snapshot) ? liveMatch.after_snapshot : {}
  const result = { ...frozenResult, ...afterSnapshot }
  const targetId = targetIdFor(context, definition)
  const targetIds = targetIdsFor(context, definition)
  const pendingId = pendingIdFromResult
  const pendingGroupId = firstValue(result.pending_action_group_id)
  const memberCount = numberValue(result.member_count)
  const reportedFailure = context.resultError || displayValue(frozenResult.error) != null
  const message = errorMessage(context) || firstValue(liveMatch?.execution_error, liveMatch?.reason, result.message)
  const state = firstValue(liveMatch?.state, reportedFailure ? "failed" : null, result.state, result.new_state, pendingId ? "pending" : "success") || "success"
  const failed = reportedFailure || state === "failed"
  const transitionSucceeded = !pendingId || ["confirmed", "executed", "succeeded", "success"].includes(state)
  const hasNewState = transitionSucceeded && displayValue(result.new_state) != null
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
    hasNewState,
    failed,
    message,
    rows: buildRows(context, result, hasNewState),
    dependencies: dependencyList(definition, result),
    showsDependencies: definition.toolName.includes("dependency") || result.depends_on !== undefined || result.depends_on_job_ids !== undefined || result.depends_on_epic_ids !== undefined
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
  const awaitingConfirmation = ["queued", "pending", "confirming"].includes(card.state)
  const action = card.failed
    ? `${card.definition.actionLabel} failed`
    : awaitingConfirmation && card.definition.pendingVerb
      ? card.definition.pendingVerb
      : ["rejected", "cancelled", "canceled"].includes(card.state)
        ? `${card.definition.actionLabel} ${card.state}`
        : card.definition.verb
  const pending = awaitingConfirmation
    ? card.pendingGroupId
      ? `pending group #${card.pendingGroupId}`
      : card.pendingId
        ? `pending #${card.pendingId}`
        : null
    : null
  return [action, target, pending].filter(Boolean).join(" · ")
}

export function JobEpicMaintenanceCard({ card }: { card: MaintenanceCard }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.state} tone={card.failed ? "failure" : undefined} />
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{card.definition.actionLabel}</span>
        {card.targetId ? <Badge><EntityReference id={card.targetId} kind={SUBJECT_ENTITY_KIND[card.definition.subjectKind]} /></Badge> : null}
        {card.targetIds.map((id) => <Badge key={id}><EntityReference id={id} kind={SUBJECT_ENTITY_KIND[card.definition.subjectKind]} /></Badge>)}
        {card.pendingId ? <Badge>pending #{card.pendingId}</Badge> : null}
        {card.pendingGroupId ? <Badge>group #{card.pendingGroupId}</Badge> : null}
        {card.memberCount != null ? <Badge>{card.memberCount} {card.memberCount === 1 ? "action" : "actions"}</Badge> : null}
      </div>
      {card.message ? (card.failed ? <div className="break-words text-xs text-danger-text [overflow-wrap:anywhere]">{linkifiedText(card.message)}</div> : <MarkdownPreview text={card.message} />) : null}
      {card.rows.length > 0 ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {card.rows.map((row, index) => (
            <WrappingRow key={`${row.label}-${index}`} label={row.label} value={row.markdown ? <MarkdownPreview text={row.markdown} /> : row.value} />
          ))}
        </dl>
      ) : null}
      {card.dependencies.length > 0 ? (
        <div>
          <SectionLabel>Current dependencies</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.dependencies.map((dependency) => {
              const job = dependency.match(/^JOB-(\d+)$/)
              const epic = dependency.match(/^EPIC-(\d+)$/)
              return (
                <Badge key={dependency}>
                  {job ? <EntityReference id={job[1]} kind="job" /> : epic ? <EntityReference id={epic[1]} kind="epic" /> : dependency}
                </Badge>
              )
            })}
          </div>
        </div>
      ) : card.showsDependencies ? <EmptyState>No dependencies</EmptyState> : null}
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
