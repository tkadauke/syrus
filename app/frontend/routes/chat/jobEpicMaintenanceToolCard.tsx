import { isValidElement, type ReactNode } from "react"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "../../toolCardParsing"
import { MarkdownPreview } from "./toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row, SectionLabel, StatePill } from "./toolCardUi"

type SubjectKind = "job" | "epic"
const SUBJECT_ENTITY_KIND: Record<SubjectKind, "job" | "epic"> = { job: "job", epic: "epic" }

type MaintenanceToolDefinition = {
  toolName: string
  subjectKind: SubjectKind
  actionLabel: string
  verb: string
  pendingVerb?: string
  confirmedSubjectState?: string
  warningMessage?: boolean
  showsComment?: boolean
  showsTargetTitle?: boolean
  transitionStatePills?: boolean
  showsFullErrorMessage?: boolean
  showsLiveExecution?: boolean
  showsReasonMarkdown?: boolean
  recoversTargetFromMessage?: boolean
  removedDependencyLabel?: boolean
  emptyDependenciesLabel?: string
}

const DEFINITIONS: Record<string, MaintenanceToolDefinition> = {
  approve_job: { toolName: "approve_job", subjectKind: "job", actionLabel: "Approve Job", verb: "Approved", pendingVerb: "Approval requested" },
  cancel_job: {
    toolName: "cancel_job",
    subjectKind: "job",
    actionLabel: "Cancel Job",
    verb: "Cancelled",
    pendingVerb: "Cancel requested",
    confirmedSubjectState: "cancelled"
  },
  close_job_successfully: {
    toolName: "close_job_successfully",
    subjectKind: "job",
    actionLabel: "Close Job Successfully",
    verb: "Closed successfully",
    pendingVerb: "Close requested",
    confirmedSubjectState: "closed",
    showsComment: true
  },
  set_job_priority: { toolName: "set_job_priority", subjectKind: "job", actionLabel: "Set Job Priority", verb: "Priority changed" },
  update_job: { toolName: "update_job", subjectKind: "job", actionLabel: "Update Job", verb: "Updated" },
  rebase_job: {
    toolName: "rebase_job",
    subjectKind: "job",
    actionLabel: "Rebase Job",
    verb: "Rebase requested",
    showsFullErrorMessage: true,
    showsLiveExecution: true,
    showsReasonMarkdown: true
  },
  reopen_job: { toolName: "reopen_job", subjectKind: "job", actionLabel: "Reopen Job", verb: "Reopen requested" },
  poll_job_feedback: {
    toolName: "poll_job_feedback",
    subjectKind: "job",
    actionLabel: "Poll Job Feedback",
    verb: "Feedback poll queued",
    pendingVerb: "Feedback poll requested",
    showsLiveExecution: true,
    showsFullErrorMessage: true,
    recoversTargetFromMessage: true
  },
  unapprove_job: { toolName: "unapprove_job", subjectKind: "job", actionLabel: "Unapprove Job", verb: "Unapproved", pendingVerb: "Unapproval requested" },
  remove_job_from_epic: { toolName: "remove_job_from_epic", subjectKind: "job", actionLabel: "Remove Job From Epic", verb: "Removed from Epic" },
  add_job_dependency: { toolName: "add_job_dependency", subjectKind: "job", actionLabel: "Add Job Dependency", verb: "Dependency added" },
  remove_job_dependency: { toolName: "remove_job_dependency", subjectKind: "job", actionLabel: "Remove Job Dependency", verb: "Dependency removed" },
  start_epic: { toolName: "start_epic", subjectKind: "epic", actionLabel: "Start Epic", verb: "Started" },
  move_epic_to_backlog: {
    toolName: "move_epic_to_backlog",
    subjectKind: "epic",
    actionLabel: "Move Epic To Backlog",
    verb: "Moved to backlog",
    showsTargetTitle: true,
    transitionStatePills: true,
    showsFullErrorMessage: true
  },
  archive_epic: {
    toolName: "archive_epic",
    subjectKind: "epic",
    actionLabel: "Archive Epic",
    verb: "Archived",
    pendingVerb: "Archive requested",
    confirmedSubjectState: "archived",
    warningMessage: true
  },
  update_epic: { toolName: "update_epic", subjectKind: "epic", actionLabel: "Update Epic", verb: "Updated" },
  add_epic_dependency: { toolName: "add_epic_dependency", subjectKind: "epic", actionLabel: "Add Epic Dependency", verb: "Dependency added" },
  remove_epic_dependency: {
    toolName: "remove_epic_dependency",
    subjectKind: "epic",
    actionLabel: "Remove Epic Dependency",
    verb: "Dependency removed",
    removedDependencyLabel: true,
    emptyDependenciesLabel: "No dependencies"
  }
}

type DetailRow = { label: string; value: ReactNode }
type Dependency = {
  id: string
  kind: SubjectKind
  title: string | null
  state: string | null
  added: boolean
  satisfactionMode: string | null
  requiredStage: string | null
}

type MaintenanceCard = {
  definition: MaintenanceToolDefinition
  targetId: string | null
  targetIds: string[]
  pendingId: string | null
  pendingGroupId: string | null
  memberCount: number | null
  state: string
  subjectState: string | null
  hasNewState: boolean
  failed: boolean
  message: string | null
  reason: string | null
  comment: string | null
  targetHref: string | null
  workflowId: string | null
  prNumber: string | null
  prUrl: string | null
  rows: DetailRow[]
  dependencies: Dependency[]
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
  const explicitTarget = firstValue(result[key], objectValue(context.input, key))
  if (explicitTarget || (definition.toolName !== "cancel_job" && !definition.recoversTargetFromMessage)) return explicitTarget

  return displayValue(result.message)?.match(/\bJOB-(\d+)\b/i)?.[1] || null
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
  if (isValidElement(value)) {
    rows.push({ label, value })
    return
  }
  const displayed = displayValue(value)
  if (displayed) rows.push({ label, value: displayed })
}

function dependencyReference(context: ToolCardContext, result: Record<string, unknown>) {
  const dependsOnJobId = firstValue(objectValue(context.input, "depends_on_job_id"))
  if (dependsOnJobId) return <EntityReference id={dependsOnJobId} kind="job" />
  const dependsOnEpicId = firstValue(objectValue(context.input, "depends_on_epic_id"))
  if (dependsOnEpicId) return <EntityReference id={dependsOnEpicId} kind="epic" />
  const removedFromEpicId = firstValue(result.removed_from_epic_id)
  if (removedFromEpicId) return <EntityReference id={removedFromEpicId} kind="epic" />
  return null
}

function dependency(context: ToolCardContext, value: unknown, kind: SubjectKind): Dependency | null {
  const record = isPlainObject(value) ? value : null
  const id = firstValue(record?.[kind === "epic" ? "depends_on_epic_id" : "depends_on_job_id"], record?.id, value)
  if (!id) return null
  const addedId = firstValue(objectValue(context.input, kind === "epic" ? "depends_on_epic_id" : "depends_on_job_id"))
  return {
    id,
    kind,
    title: firstValue(record?.title, record?.issue_title),
    state: firstValue(record?.state),
    added: context.toolName.startsWith("add_") && context.toolName.endsWith("_dependency") && id === addedId,
    satisfactionMode: firstValue(record?.satisfaction_mode),
    requiredStage: firstValue(record?.required_deployment_stage_name)
  }
}

function dependencyList(context: ToolCardContext, definition: MaintenanceToolDefinition, result: Record<string, unknown>) {
  const dependencyRecords = Array.isArray(result.dependencies) ? result.dependencies.filter(isPlainObject) : []
  const recordFor = (value: unknown, kind: SubjectKind) => {
    const id = firstValue(value)
    const key = kind === "epic" ? "depends_on_epic_id" : "depends_on_job_id"
    return dependencyRecords.find((record) => firstValue(record[key]) === id) || value
  }
  const entries: Array<[unknown, SubjectKind]> =
    definition.subjectKind === "epic"
      ? (Array.isArray(result.depends_on) ? result.depends_on : []).map((value) => [value, "epic"])
      : [
          ...(Array.isArray(result.depends_on_job_ids) ? result.depends_on_job_ids : []).map((value): [unknown, SubjectKind] => [
            recordFor(value, "job"),
            "job"
          ]),
          ...(Array.isArray(result.depends_on_epic_ids) ? result.depends_on_epic_ids : []).map((value): [unknown, SubjectKind] => [
            recordFor(value, "epic"),
            "epic"
          ]),
          ...dependencyRecords
            .filter((record) => {
              const kind = record.depends_on_job_id !== undefined ? "job" : "epic"
              const ids = kind === "job" ? result.depends_on_job_ids : result.depends_on_epic_ids
              return (
                !Array.isArray(ids) || !ids.some((id) => firstValue(id) === firstValue(record[kind === "job" ? "depends_on_job_id" : "depends_on_epic_id"]))
              )
            })
            .map((record): [unknown, SubjectKind] => [record, record.depends_on_job_id !== undefined ? "job" : "epic"])
        ]
  return entries.flatMap(([value, kind]) => {
    const item = dependency(context, value, kind)
    return item ? [item] : []
  })
}

function buildRows(context: ToolCardContext, definition: MaintenanceToolDefinition, result: Record<string, unknown>, transitionExecuted = true) {
  const rows: DetailRow[] = []
  const previousState = firstValue(result.previous_state)
  const newState = firstValue(result.new_state)
  pushRow(rows, "Before", definition.transitionStatePills && previousState ? <StatePill state={previousState} /> : previousState)
  if (transitionExecuted) pushRow(rows, "After", definition.transitionStatePills && newState ? <StatePill state={newState} /> : newState)
  pushRow(rows, "Previous priority", result.previous_priority)
  pushRow(rows, "New priority", result.new_priority)
  pushRow(
    rows,
    "Title",
    definition.showsTargetTitle
      ? firstValue(result.title, result.epic_title, objectValue(context.input, "title"), objectValue(context.input, "epic_title"))
      : result.title
  )
  pushRow(rows, "Description", result.description)
  pushRow(rows, "Closure reason", result.closure_reason || objectValue(context.input, "closure_reason"))
  pushRow(rows, definition.removedDependencyLabel ? "Removed" : "Dependency", dependencyReference(context, result))
  pushRow(rows, "Satisfaction", objectValue(context.input, "satisfaction_mode"))
  pushRow(rows, "Required stage", objectValue(context.input, "required_deployment_stage_name") || result.required_deployment_stage_name)
  pushRow(rows, "Removed from", result.removed_from_epic_title || (displayValue(result.removed_from_epic_id) ? `EPIC-${result.removed_from_epic_id}` : null))
  if (!definition.showsReasonMarkdown) pushRow(rows, "Reason", result.reason)
  return rows
}

function snapshotWorkflowId(snapshot: Record<string, unknown>) {
  const jobs = Array.isArray(snapshot.jobs) ? snapshot.jobs : []
  for (const job of jobs) {
    const workflowId = firstValue(objectValue(objectValue(job, "workflow"), "id"))
    if (workflowId) return workflowId
  }
  return null
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
  const livePendingAction = context.livePendingAction
  const liveMatch = livePendingAction && displayValue(livePendingAction.id) === pendingId ? livePendingAction : null
  const state =
    firstValue(liveMatch?.state, result.state, result.new_state, context.resultError ? "failed" : null, pendingId ? "pending" : "success") || "success"
  const failed = context.resultError || state === "failed"
  const message = errorMessage(context) || displayValue(result.message)
  const transitionExecuted = (!pendingId && !pendingGroupId) || state === "confirmed"
  const liveOutcome = isPlainObject(liveMatch?.outcome) ? liveMatch.outcome : {}
  const beforeSnapshot = isPlainObject(liveMatch?.before_snapshot) ? liveMatch.before_snapshot : {}
  const afterSnapshot = isPlainObject(liveMatch?.after_snapshot) ? liveMatch.after_snapshot : {}
  const liveExecutionError = definition.showsLiveExecution ? firstValue(liveMatch?.execution_error) : null
  const prUrl = definition.showsLiveExecution ? firstValue(result.pr_url, liveOutcome.pr_url, afterSnapshot.pr_url, beforeSnapshot.pr_url) : null
  const prNumber = definition.showsLiveExecution
    ? firstValue(result.pr_number, liveOutcome.pr_number, afterSnapshot.pr_number, beforeSnapshot.pr_number, prUrl?.match(/\/pull\/(\d+)/)?.[1])
    : null
  const workflowId = definition.showsLiveExecution ? firstValue(result.workflow_id, liveOutcome.workflow_id, snapshotWorkflowId(afterSnapshot)) : null
  const subjectState = definition.confirmedSubjectState
    ? firstValue(
        liveOutcome.state,
        objectValue(liveMatch?.after_snapshot, "state"),
        transitionExecuted ? result.new_state : null,
        state === "confirmed" ? definition.confirmedSubjectState : null
      )
    : null
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
    "epic_title",
    "description",
    "closure_reason",
    "reason",
    "depends_on",
    "depends_on_job_ids",
    "depends_on_epic_ids",
    "dependencies",
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
    subjectState,
    hasNewState: transitionExecuted && displayValue(result.new_state) != null,
    failed,
    message: liveExecutionError || message,
    reason: definition.showsReasonMarkdown ? firstValue(result.reason, objectValue(context.input, "reason"), liveMatch?.reason) : null,
    comment: definition.showsComment ? firstValue(objectValue(context.input, "comment")) : null,
    targetHref: definition.showsLiveExecution ? firstValue(liveMatch?.resource_url) : null,
    workflowId,
    prNumber,
    prUrl,
    rows: [
      ...buildRows(context, definition, result, transitionExecuted),
      ...(definition.showsLiveExecution && liveMatch?.execution_status
        ? [{ label: "Execution", value: <StatePill state={liveMatch.execution_status} /> }]
        : []),
      ...(definition.showsLiveExecution && liveMatch?.execution_step ? [{ label: "Step", value: liveMatch.execution_step }] : []),
      ...(definition.showsLiveExecution && liveMatch?.resource_title ? [{ label: "Job", value: liveMatch.resource_title }] : [])
    ],
    dependencies: dependencyList(context, definition, result),
    showsDependencies: [result.depends_on, result.depends_on_job_ids, result.depends_on_epic_ids, result.dependencies].some(Array.isArray)
  }
}

function targetSummary(card: MaintenanceCard) {
  if (card.targetId) return prefixedId(card.definition.subjectKind, card.targetId)
  if (card.targetIds.length > 0) return `${card.targetIds.length} ${subjectPrefix(card.definition.subjectKind)}s`
  return null
}

function isAwaitingState(state: string) {
  return state === "pending" || state === "confirming" || state === "queued"
}

function messageWithLinkedTarget(card: MaintenanceCard) {
  if (!card.message || !card.targetId) return card.message
  const label = prefixedId(card.definition.subjectKind, card.targetId)
  const href = card.definition.subjectKind === "epic" ? `/epics/${card.targetId}` : `/jobs/${card.targetId}`
  return card.message.replaceAll(label, `[${label}](${href})`)
}

export function jobEpicMaintenanceCollapsedSummary(context: ToolCardContext) {
  const card = parseJobEpicMaintenanceResult(context)
  if (!card) return null

  const target = targetSummary(card)
  const awaitingConfirmation = isAwaitingState(card.state)
  const terminalWithoutExecution = ["rejected", "cancelled", "canceled"].includes(card.state)
  const action = card.failed
    ? `${card.definition.actionLabel} failed`
    : terminalWithoutExecution
      ? `${card.definition.actionLabel} ${card.state}`
      : awaitingConfirmation && card.definition.pendingVerb
        ? card.definition.pendingVerb
        : card.definition.verb
  const pending = !awaitingConfirmation
    ? null
    : card.pendingGroupId
      ? `pending group #${card.pendingGroupId}`
      : card.pendingId
        ? `pending #${card.pendingId}`
        : null
  return [action, target, pending].filter(Boolean).join(" · ")
}

export function JobEpicMaintenanceCard({ card }: { card: MaintenanceCard }) {
  const target = targetSummary(card)
  const awaitingConfirmation = isAwaitingState(card.state)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.state} tone={card.failed ? "failure" : undefined} />
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{card.definition.actionLabel}</span>
        {card.targetId ? (
          <Badge>
            <EntityReference href={card.targetHref || undefined} id={card.targetId} kind={SUBJECT_ENTITY_KIND[card.definition.subjectKind]} />
          </Badge>
        ) : target ? (
          <Badge>{target}</Badge>
        ) : null}
        {awaitingConfirmation && card.pendingId ? <Badge>pending #{card.pendingId}</Badge> : null}
        {awaitingConfirmation && card.pendingGroupId ? <Badge>group #{card.pendingGroupId}</Badge> : null}
        {card.memberCount != null ? (
          <Badge>
            {card.memberCount} {card.memberCount === 1 ? "action" : "actions"}
          </Badge>
        ) : null}
      </div>
      {card.subjectState ? (
        <div className="flex flex-wrap items-center gap-2 text-xs text-text-muted">
          <span>{card.definition.subjectKind === "epic" ? "Epic" : "Job"} state</span>
          <StatePill state={card.subjectState} tone={card.subjectState === "archived" ? "success" : undefined} />
        </div>
      ) : null}
      {card.prNumber ? (
        <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs text-text-muted">
          <span>Pull request</span>
          <EntityReference href={card.prUrl || undefined} id={card.prNumber} kind="pull_request" />
        </div>
      ) : null}
      {card.message ? (
        <div
          className={card.definition.warningMessage && awaitingConfirmation ? "rounded border border-warning-border bg-warning-surface p-2" : undefined}
          role={card.definition.warningMessage && awaitingConfirmation ? "alert" : undefined}
        >
          <MarkdownPreview
            className={card.definition.warningMessage && awaitingConfirmation ? "font-medium text-warning-text" : undefined}
            clamp={!(card.failed && card.definition.showsFullErrorMessage)}
            linkifySlugs
            maxChars={360}
            maxLines={3}
            modalLabel={`${card.definition.actionLabel} message`}
            text={messageWithLinkedTarget(card)}
          />
        </div>
      ) : null}
      {card.comment ? (
        <MarkdownPreview
          linkifySlugs
          linkifyUrls
          maxChars={360}
          maxLines={3}
          modalLabel={`${card.definition.actionLabel} comment`}
          text={card.comment}
          title="PR comment"
        />
      ) : null}
      {card.reason ? (
        <MarkdownPreview
          linkifySlugs
          linkifyUrls
          maxChars={360}
          maxLines={3}
          modalLabel={`${card.definition.actionLabel} reason`}
          text={card.reason}
          title="Reason"
        />
      ) : null}
      {card.workflowId && card.targetId ? (
        <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs text-text-muted">
          <span>Workflow</span>
          <EntityReference id={card.workflowId} jobId={card.targetId} kind="workflow" />
        </div>
      ) : null}
      {card.rows.length > 0 ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {card.rows.map((row, index) => (
            <Row key={`${row.label}-${index}`} label={row.label} value={row.value} />
          ))}
        </dl>
      ) : null}
      {card.targetIds.length > 0 ? (
        <div>
          <SectionLabel>{card.definition.subjectKind === "epic" ? "Epics" : "Jobs"}</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.targetIds.map((id) => (
              <Badge key={id}>
                <EntityReference id={id} kind={SUBJECT_ENTITY_KIND[card.definition.subjectKind]} />
              </Badge>
            ))}
          </div>
        </div>
      ) : null}
      {card.showsDependencies ? (
        <div>
          <SectionLabel>Current dependencies</SectionLabel>
          {card.dependencies.length > 0 ? (
            <div className="mt-1 flex flex-wrap gap-1">
              {card.dependencies.map((dependency) => (
                <Badge key={`${dependency.kind}-${dependency.id}`}>
                  <span className="inline-flex min-w-0 flex-wrap items-center gap-1">
                    <EntityReference id={dependency.id} kind={SUBJECT_ENTITY_KIND[dependency.kind]} />
                    {dependency.title ? <span className="max-w-full break-words">{dependency.title}</span> : null}
                    {dependency.state ? <StatePill state={dependency.state} /> : null}
                    {dependency.added ? <StatePill state="added" tone="success" /> : null}
                    {dependency.satisfactionMode ? <span>· {dependency.satisfactionMode}</span> : null}
                    {dependency.requiredStage ? <span>· stage {dependency.requiredStage}</span> : null}
                  </span>
                </Badge>
              ))}
            </div>
          ) : (
            <div className="mt-1 text-xs text-text-secondary">{card.definition.emptyDependenciesLabel || "No current dependencies"}</div>
          )}
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
