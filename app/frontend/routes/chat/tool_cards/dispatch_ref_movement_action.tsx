import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "../toolCardUi"
import { parseRefMovementCore, refMovementCollapsedSummary, RefMovementCoreFields } from "../refMovementToolCard"

// Core-owned tool card for dispatch_ref_movement_action (the tool-card work /
// Always renders, even when state is "blocked" -- the dispatch
// still creates a durable audit record either way (see
// dispatch_ref_movement_action_tool.rb).
function parseResult(context: ToolCardContext) {
  const parsed = context.parsedResult
  const core = parseRefMovementCore(parsed)
  if (!core || !isPlainObject(parsed)) return null

  return { core, jobId: displayValue(parsed.job_id), workflowId: displayValue(parsed.workflow_id) }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  return result ? refMovementCollapsedSummary(result.core) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <RefMovementCoreFields core={result.core} />
      {result.jobId || result.workflowId ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {result.jobId ? <Row label="Job" value={`JOB-${result.jobId}`} /> : null}
          {result.workflowId ? <Row label="Workflow" value={`WORKFLOW-${result.workflowId}`} /> : null}
        </dl>
      ) : null}
    </CardShell>
  )
}

const dispatchRefMovementActionToolCard: ToolCardRenderer = {
  toolName: "dispatch_ref_movement_action",
  collapsedSummary,
  renderExpanded
}

export default dispatchRefMovementActionToolCard
