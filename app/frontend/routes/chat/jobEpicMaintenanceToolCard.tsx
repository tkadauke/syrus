import i18n from "../../i18n"
import { isValidElement, type ReactNode } from "react"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "../../toolCardParsing"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row, SectionLabel, StatePill } from "./toolCardUi"

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
  approve_job: {
    toolName: "approve_job",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_approve_job_632a56"),
    verb: i18n.t("chat:ops_approved_41b81e"),
    pendingVerb: i18n.t("chat:ops_approval_requested_91db06")
  },
  cancel_job: {
    toolName: "cancel_job",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_cancel_job_110d45"),
    verb: i18n.t("chat:ops_cancel_requested_90ce89")
  },
  close_job_successfully: {
    toolName: "close_job_successfully",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_close_job_successfully_3edf52"),
    verb: i18n.t("chat:ops_close_requested_c13147")
  },
  set_job_priority: {
    toolName: "set_job_priority",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_set_job_priority_d10c11"),
    verb: i18n.t("chat:ops_priority_changed_1f3dbd")
  },
  update_job: { toolName: "update_job", subjectKind: "job", actionLabel: i18n.t("chat:ops_update_job_b15457"), verb: i18n.t("chat:ops_updated_f2f857") },
  rebase_job: {
    toolName: "rebase_job",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_rebase_job_ed3be6"),
    verb: i18n.t("chat:ops_rebase_requested_fcbabf")
  },
  reopen_job: {
    toolName: "reopen_job",
    subjectKind: "job",
    get actionLabel() {
      return i18n.t("chat:ops_reopen_job_298406")
    },
    get verb() {
      return i18n.t("chat:ops_reopen_requested_316246")
    }
  },
  poll_job_feedback: {
    toolName: "poll_job_feedback",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_poll_job_feedback_524260"),
    verb: i18n.t("chat:ops_feedback_poll_requested_54d89d")
  },
  unapprove_job: {
    toolName: "unapprove_job",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_unapprove_job_8d9f77"),
    verb: i18n.t("chat:ops_unapproved_f0ed16"),
    pendingVerb: i18n.t("chat:ops_unapproval_requested_066bc2")
  },
  remove_job_from_epic: {
    toolName: "remove_job_from_epic",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_remove_job_from_epic_7b2760"),
    verb: i18n.t("chat:ops_removed_from_epic_d6b368")
  },
  add_job_dependency: {
    toolName: "add_job_dependency",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_add_job_dependency_d9894e"),
    verb: i18n.t("chat:ops_dependency_added_cfef73")
  },
  remove_job_dependency: {
    toolName: "remove_job_dependency",
    subjectKind: "job",
    actionLabel: i18n.t("chat:ops_remove_job_dependency_d63eef"),
    verb: i18n.t("chat:ops_dependency_removed_57fad1")
  },
  start_epic: { toolName: "start_epic", subjectKind: "epic", actionLabel: i18n.t("chat:ops_start_epic_b78ddb"), verb: i18n.t("chat:ops_started_faa9e7") },
  move_epic_to_backlog: {
    toolName: "move_epic_to_backlog",
    subjectKind: "epic",
    actionLabel: i18n.t("chat:ops_move_epic_to_backlog_7797df"),
    verb: i18n.t("chat:ops_moved_to_backlog_22dad5")
  },
  archive_epic: {
    toolName: "archive_epic",
    subjectKind: "epic",
    actionLabel: i18n.t("chat:ops_archive_epic_0948ca"),
    verb: i18n.t("chat:ops_archive_requested_6cd181")
  },
  update_epic: { toolName: "update_epic", subjectKind: "epic", actionLabel: i18n.t("chat:ops_update_epic_760f63"), verb: i18n.t("chat:ops_updated_f2f857") },
  add_epic_dependency: {
    toolName: "add_epic_dependency",
    subjectKind: "epic",
    get actionLabel() {
      return i18n.t("chat:ops_add_epic_dependency_c33b9d")
    },
    get verb() {
      return i18n.t("chat:ops_dependency_added_cfef73")
    }
  },
  remove_epic_dependency: {
    toolName: "remove_epic_dependency",
    subjectKind: "epic",
    actionLabel: i18n.t("chat:ops_remove_epic_dependency_445ad5"),
    verb: i18n.t("chat:ops_dependency_removed_57fad1")
  }
}

type DetailRow = { label: string; value: ReactNode }
type Dependency = { id: string; kind: SubjectKind; title: string | null; state: string | null; added: boolean }

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
  dependencies: Dependency[]
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
  const id = firstValue(record?.id, value)
  if (!id) return null
  const addedId = firstValue(objectValue(context.input, kind === "epic" ? "depends_on_epic_id" : "depends_on_job_id"))
  return {
    id,
    kind,
    title: firstValue(record?.title, record?.issue_title),
    state: firstValue(record?.state),
    added: context.toolName === `add_${kind}_dependency` && id === addedId
  }
}

function dependencyList(context: ToolCardContext, definition: MaintenanceToolDefinition, result: Record<string, unknown>) {
  const entries: Array<[unknown, SubjectKind]> =
    definition.subjectKind === "epic"
      ? (Array.isArray(result.depends_on) ? result.depends_on : []).map((value) => [value, "epic"])
      : [
          ...(Array.isArray(result.depends_on_job_ids) ? result.depends_on_job_ids : []).map((value): [unknown, SubjectKind] => [value, "job"]),
          ...(Array.isArray(result.depends_on_epic_ids) ? result.depends_on_epic_ids : []).map((value): [unknown, SubjectKind] => [value, "epic"])
        ]
  return entries.flatMap(([value, kind]) => {
    const item = dependency(context, value, kind)
    return item ? [item] : []
  })
}

function buildRows(context: ToolCardContext, result: Record<string, unknown>, transitionExecuted = true) {
  const rows: DetailRow[] = []
  pushRow(rows, i18n.t("chat:ops_before_74f396"), result.previous_state)
  if (transitionExecuted) pushRow(rows, i18n.t("chat:ops_after_79ba5e"), result.new_state)
  pushRow(rows, i18n.t("chat:ops_previous_priority_439762"), result.previous_priority)
  pushRow(rows, i18n.t("chat:ops_new_priority_43fd16"), result.new_priority)
  pushRow(rows, i18n.t("chat:ops_title_768e0c"), result.title)
  pushRow(rows, i18n.t("chat:ops_description_55f8eb"), result.description)
  pushRow(rows, i18n.t("chat:ops_closure_reason_d72807"), result.closure_reason || objectValue(context.input, "closure_reason"))
  pushRow(rows, i18n.t("chat:ops_dependency_ce311a"), dependencyReference(context, result))
  pushRow(rows, i18n.t("chat:ops_satisfaction_6b04c5"), objectValue(context.input, "satisfaction_mode"))
  pushRow(rows, i18n.t("chat:ops_required_stage_3fc3c8"), objectValue(context.input, "required_deployment_stage_name") || result.required_deployment_stage_name)
  pushRow(
    rows,
    i18n.t("chat:ops_removed_from_77b2d7"),
    result.removed_from_epic_title || (displayValue(result.removed_from_epic_id) ? `EPIC-${result.removed_from_epic_id}` : null)
  )
  pushRow(rows, i18n.t("chat:ops_reason_f219cc"), result.reason)
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
  const livePendingAction = context.livePendingAction
  const liveMatch = livePendingAction && displayValue(livePendingAction.id) === pendingId ? livePendingAction : null
  const state =
    firstValue(liveMatch?.state, result.state, result.new_state, context.resultError ? "failed" : null, pendingId ? "pending" : "success") || "success"
  const failed = context.resultError || state === "failed"
  const message = errorMessage(context) || displayValue(result.message)
  const transitionExecuted = (!pendingId && !pendingGroupId) || state === "confirmed"
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
    hasNewState: transitionExecuted && displayValue(result.new_state) != null,
    failed,
    message,
    rows: buildRows(context, result, transitionExecuted),
    dependencies: dependencyList(context, definition, result)
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
            <EntityReference id={card.targetId} kind={SUBJECT_ENTITY_KIND[card.definition.subjectKind]} />
          </Badge>
        ) : target ? (
          <Badge>{target}</Badge>
        ) : null}
        {awaitingConfirmation && card.pendingId ? <Badge>{i18n.t("chat:pending_number", { id: card.pendingId })}</Badge> : null}
        {awaitingConfirmation && card.pendingGroupId ? <Badge>{i18n.t("chat:group_number", { id: card.pendingGroupId })}</Badge> : null}
        {card.memberCount != null ? <Badge>{i18n.t("chat:action_count", { count: card.memberCount })}</Badge> : null}
      </div>
      {card.message ? <div className="text-gray-700 dark:text-gray-300">{card.message}</div> : null}
      {card.rows.length > 0 ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {card.rows.map((row, index) => (
            <Row key={`${row.label}-${index}`} label={row.label} value={row.value} />
          ))}
        </dl>
      ) : null}
      {card.dependencies.length > 0 ? (
        <div>
          <SectionLabel>{i18n.t("chat:ops_current_dependencies_a4b8fa")}</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.dependencies.map((dependency) => (
              <Badge key={`${dependency.kind}-${dependency.id}`}>
                <span className="inline-flex min-w-0 flex-wrap items-center gap-1">
                  <EntityReference id={dependency.id} kind={SUBJECT_ENTITY_KIND[dependency.kind]} />
                  {dependency.title ? <span className="max-w-full break-words">{dependency.title}</span> : null}
                  {dependency.state ? <StatePill state={dependency.state} /> : null}
                  {dependency.added ? <StatePill state="added" tone="success" /> : null}
                </span>
              </Badge>
            ))}
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
