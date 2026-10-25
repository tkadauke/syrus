import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"

type Eligibility = {
  status: string
  operation: string
  targetState: string | null
  blockingPreconditions: string[]
  expectedMutations: { workUnits: number; locks: number }
  affectedIds: { workUnitIds: string[]; workflowIds: string[]; runIds: string[]; lockIds: string[] }
  facts: { workUnitState: string | null; workflowState: string | null; lockKeys: string[]; workIntentId: string | null }
}

function stringList(value: unknown) {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const displayed = displayValue(entry)
    return displayed ? [displayed] : []
  })
}

function parseEligibility(context: ToolCardContext): Eligibility | null {
  if (context.input?.dry_run !== true || !isPlainObject(context.parsedResult)) return null
  const value = context.parsedResult
  const status = displayValue(value.status)
  const operation = displayValue(value.operation)
  if (!status || !operation) return null

  const mutations = isPlainObject(value.expected_mutations) ? value.expected_mutations : {}
  const ids = isPlainObject(value.affected_ids) ? value.affected_ids : {}
  const facts = isPlainObject(value.facts) ? value.facts : {}
  return {
    status,
    operation,
    targetState: displayValue(value.target_state),
    blockingPreconditions: stringList(value.blocking_preconditions),
    expectedMutations: {
      workUnits: numberValue(mutations.work_units) ?? 0,
      locks: numberValue(mutations.locks) ?? 0
    },
    affectedIds: {
      workUnitIds: stringList(ids.work_unit_ids),
      workflowIds: stringList(ids.workflow_ids),
      runIds: stringList(ids.run_ids),
      lockIds: stringList(ids.lock_ids)
    },
    facts: {
      workUnitState: displayValue(facts.work_unit_state),
      workflowState: displayValue(facts.workflow_state),
      lockKeys: stringList(facts.lock_keys),
      workIntentId: displayValue(facts.work_intent_id)
    }
  }
}

function Reason({ context }: { context: ToolCardContext }) {
  const reason = displayValue(context.input?.reason)
  return reason ? (
    <MarkdownPreview
      linkifySlugs
      linkifyUrls
      maxLines={4}
      modalLabel={i18n.t("chat:retire_terminal_work_unit.reason")}
      text={reason}
      title={i18n.t("chat:retire_terminal_work_unit.reason")}
    />
  ) : null
}

function IdGroup({ ids, kind }: { ids: string[]; kind: "workflow" | "run" }) {
  if (ids.length === 0) return <span className="text-text-subtle">{i18n.t("chat:retire_terminal_work_unit.none")}</span>
  return (
    <span className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
      {ids.map((id) => (
        <EntityReference href={kind === "workflow" ? `/admin/workflows/${id}` : `/admin/runs/${id}/transcript`} id={id} key={id} kind={kind} />
      ))}
    </span>
  )
}

function BadgeGroup({ ids, prefix }: { ids: string[]; prefix: string }) {
  if (ids.length === 0) return <span className="text-text-subtle">{i18n.t("chat:retire_terminal_work_unit.none")}</span>
  return (
    <span className="flex min-w-0 flex-wrap gap-1">
      {ids.map((id) => (
        <Badge key={id}>
          {prefix}
          {id}
        </Badge>
      ))}
    </span>
  )
}

function EligibilityCard({ context, result }: { context: ToolCardContext; result: Eligibility }) {
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge>{i18n.t("chat:retire_terminal_work_unit.dry_run")}</Badge>
        <StatePill state={result.status} />
        <span className="min-w-0 break-words font-mono font-semibold text-text-primary">{result.operation}</span>
      </div>

      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label={i18n.t("chat:retire_terminal_work_unit.target_state")} value={result.targetState || i18n.t("chat:retire_terminal_work_unit.none")} />
        <Row
          label={i18n.t("chat:retire_terminal_work_unit.work_unit_state")}
          value={result.facts.workUnitState || i18n.t("chat:retire_terminal_work_unit.none")}
        />
        <Row
          label={i18n.t("chat:retire_terminal_work_unit.workflow_state")}
          value={result.facts.workflowState || i18n.t("chat:retire_terminal_work_unit.none")}
        />
        <Row
          label={i18n.t("chat:retire_terminal_work_unit.work_intent")}
          value={result.facts.workIntentId ? `#${result.facts.workIntentId}` : i18n.t("chat:retire_terminal_work_unit.none")}
        />
      </dl>

      <div>
        <SectionLabel>{i18n.t("chat:retire_terminal_work_unit.blocking_preconditions")}</SectionLabel>
        {result.blockingPreconditions.length > 0 ? (
          <ul className="mt-1 list-disc space-y-1 pl-5 text-sm text-text-secondary">
            {result.blockingPreconditions.map((blocker) => (
              <li className="break-words" key={blocker}>
                {blocker}
              </li>
            ))}
          </ul>
        ) : (
          <div className="mt-1 text-sm text-text-subtle">{i18n.t("chat:retire_terminal_work_unit.no_blockers")}</div>
        )}
      </div>

      <div>
        <SectionLabel>{i18n.t("chat:retire_terminal_work_unit.expected_mutations")}</SectionLabel>
        <div className="mt-1 flex flex-wrap gap-1">
          <Badge>{i18n.t("chat:retire_terminal_work_unit.work_units_count", { count: result.expectedMutations.workUnits })}</Badge>
          <Badge>{i18n.t("chat:retire_terminal_work_unit.locks_count", { count: result.expectedMutations.locks })}</Badge>
        </div>
      </div>

      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label={i18n.t("chat:retire_terminal_work_unit.work_units")} value={<BadgeGroup ids={result.affectedIds.workUnitIds} prefix="#" />} />
        <Row label={i18n.t("chat:retire_terminal_work_unit.workflows")} value={<IdGroup ids={result.affectedIds.workflowIds} kind="workflow" />} />
        <Row label={i18n.t("chat:retire_terminal_work_unit.runs")} value={<IdGroup ids={result.affectedIds.runIds} kind="run" />} />
        <Row label={i18n.t("chat:retire_terminal_work_unit.locks")} value={<BadgeGroup ids={result.affectedIds.lockIds} prefix="#" />} />
      </dl>

      <div>
        <SectionLabel>{i18n.t("chat:retire_terminal_work_unit.lock_keys")}</SectionLabel>
        <div className="mt-1 flex min-w-0 flex-wrap gap-1">
          {result.facts.lockKeys.length > 0 ? (
            result.facts.lockKeys.map((key) => (
              <Badge key={key} wrap>
                {key}
              </Badge>
            ))
          ) : (
            <span className="text-text-subtle">{i18n.t("chat:retire_terminal_work_unit.none")}</span>
          )}
        </div>
      </div>
      <Reason context={context} />
    </CardShell>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const eligibility = parseEligibility(context)
  if (eligibility) return i18n.t("chat:retire_terminal_work_unit.eligibility_summary", { status: eligibility.status })
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const eligibility = parseEligibility(context)
  if (eligibility) return <EligibilityCard context={context} result={eligibility} />

  const result = parsePendingActionResult(context, true)
  return result ? <PendingActionResultCard details={<Reason context={context} />} omitReason result={result} /> : null
}

const retireTerminalWorkUnitToolCard: ToolCardRenderer = {
  toolName: "retire_terminal_work_unit",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default retireTerminalWorkUnitToolCard

const ELIGIBILITY = {
  status: "eligible",
  operation: "retire_terminal_work_unit",
  target_state: "cancelled",
  blocking_preconditions: [],
  expected_mutations: { work_units: 1, locks: 2 },
  affected_ids: { work_unit_ids: [73], workflow_ids: [612], run_ids: [], lock_ids: [91, 92] },
  facts: { work_unit_state: "running", workflow_state: "failed", lock_keys: ["job:42", "repository:7"], work_intent_id: 38 }
}

export const examples: ToolCardExample[] = [
  {
    id: "eligible_dry_run",
    label: i18n.t("chat:retire_terminal_work_unit.example_dry_run"),
    input: { work_unit_id: 73, reason: "Release the **stale ownership** after verifying the terminal workflow.", dry_run: true },
    parsedResult: ELIGIBILITY
  },
  {
    id: "pending_retirement",
    label: i18n.t("chat:retire_terminal_work_unit.example_pending"),
    input: { work_unit_id: 73, reason: "Release the **stale ownership** after verifying the terminal workflow.", dry_run: false },
    parsedResult: { pending_action_id: 504, state: "pending", message: "Retire WU-73 and release 2 stale locks?" }
  },
  {
    id: "ineligible",
    label: i18n.t("chat:retire_terminal_work_unit.example_error"),
    input: { work_unit_id: 73, reason: "Retire stale ownership.", dry_run: false },
    resultBody: "Error: Workflow #612 is running, not terminal",
    resultError: true
  }
]
