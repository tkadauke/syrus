import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard, type PendingActionInputField } from "../pendingActionToolCard"
import { displayValue, Row, StatePill } from "../toolCardUi"
import i18n from "@app/i18n"

// Core-owned tool card for force_state_transition. Reuses the shared
// pending-action parsing/rendering (which already surfaces the admin audit
// reason and target context) and adds the requested AASM event read back
// from the tool call's own input arguments.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

const inputFields: PendingActionInputField[] = [
  { key: "event", label: () => i18n.t("chat:mutation_requested_event"), format: "badge" },
  { key: "reason", label: "Reason", format: "markdown" }
]

function snapshotJobState(snapshot: unknown, jobId: unknown) {
  if (!isPlainObject(snapshot) || !Array.isArray(snapshot.jobs)) return null
  const expectedId = displayValue(jobId)
  const job = snapshot.jobs.find((entry) => isPlainObject(entry) && (!expectedId || displayValue(entry.id) === expectedId))
  return isPlainObject(job) ? displayValue(job.state) : null
}

function TransitionDetails({ context }: { context: ToolCardContext }) {
  const input = isPlainObject(context.input) ? context.input : {}
  const live = context.livePendingAction
  const fromState = snapshotJobState(live?.before_snapshot, input.job_id)
  const toState = snapshotJobState(live?.after_snapshot, input.job_id)

  if (fromState && toState) {
    return (
      <Row
        label="Transition"
        value={
          <span className="inline-flex flex-wrap items-center gap-1.5">
            <StatePill state={fromState} />
            <span aria-hidden="true" className="text-text-muted">
              →
            </span>
            <StatePill state={toState} />
          </span>
        }
      />
    )
  }

  return null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  return <PendingActionResultCard details={<TransitionDetails context={context} />} input={input} inputFields={inputFields} result={result} />
}

const forceStateTransitionToolCard: ToolCardRenderer = {
  toolName: "force_state_transition",
  collapsedSummary,
  renderExpanded
}

export default forceStateTransitionToolCard
