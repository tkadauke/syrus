import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { parseRefMovementCore, refMovementCollapsedSummary, RefMovementCoreFields } from "../refMovementToolCard"

// Core-owned tool card for read_ref_movement_status (the tool-card work).
// Adds the nested job/workflow/pr_link summaries read_ref_movement_status
// returns on top of the shared ref-movement core fields.
type JobSummary = { id: string; slug: string; state: string }
type WorkflowSummary = { id: string; state: string; triggerKind: string | null }
type PrLinkSummary = { prNumber: string; targetRepository: string | null; targetRef: string | null }

function parseJob(value: unknown): JobSummary | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const slug = displayValue(value.slug)
  const state = displayValue(value.state)
  if (!id || !slug || !state) return null
  return { id, slug, state }
}

function parseWorkflow(value: unknown): WorkflowSummary | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null
  return { id, state, triggerKind: displayValue(value.trigger_kind) }
}

function parsePrLink(value: unknown): PrLinkSummary | null {
  if (!isPlainObject(value)) return null
  const prNumber = displayValue(value.pr_number)
  if (!prNumber) return null
  return { prNumber, targetRepository: displayValue(value.target_repository), targetRef: displayValue(value.target_ref) }
}

function parseResult(context: ToolCardContext) {
  const parsed = context.parsedResult
  const core = parseRefMovementCore(parsed)
  if (!core || !isPlainObject(parsed)) return null

  return {
    core,
    job: parseJob(parsed.job),
    workflow: parseWorkflow(parsed.workflow),
    prLink: parsePrLink(parsed.pr_link)
  }
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
      {result.job ? (
        <div>
          <SectionLabel>Job</SectionLabel>
          <div className="mt-0.5 flex flex-wrap items-center gap-2">
            <span className="font-mono">{result.job.slug}</span>
            <StatePill state={result.job.state} />
          </div>
        </div>
      ) : null}
      {result.workflow ? (
        <div>
          <SectionLabel>Workflow</SectionLabel>
          <div className="mt-0.5 flex flex-wrap items-center gap-2">
            <span className="font-mono">WORKFLOW-{result.workflow.id}</span>
            <StatePill state={result.workflow.state} />
            {result.workflow.triggerKind ? <Badge>{result.workflow.triggerKind}</Badge> : null}
          </div>
        </div>
      ) : null}
      {result.prLink ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="PR" value={`#${result.prLink.prNumber}`} />
          {result.prLink.targetRepository ? <Row label="Target repository" value={result.prLink.targetRepository} /> : null}
          {result.prLink.targetRef ? <Row label="Target ref" value={result.prLink.targetRef} /> : null}
        </dl>
      ) : null}
    </CardShell>
  )
}

const readRefMovementStatusToolCard: ToolCardRenderer = {
  toolName: "read_ref_movement_status",
  collapsedSummary,
  renderExpanded
}

export default readRefMovementStatusToolCard
