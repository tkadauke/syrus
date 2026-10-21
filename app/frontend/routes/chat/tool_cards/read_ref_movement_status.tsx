import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, Row, SectionLabel, StatePill } from "../toolCardUi"
import { parseRefMovementCore, refMovementCollapsedSummary, RefMovementCoreFields } from "../refMovementToolCard"

// Core-owned tool card for read_ref_movement_status (the tool-card work).
// Adds the nested job/workflow/pr_link summaries read_ref_movement_status
// returns on top of the shared ref-movement core fields.
type JobSummary = { id: string; slug: string | null; state: string | null }
type WorkflowSummary = { id: string; state: string; triggerKind: string | null }
type PrLinkSummary = {
  prNumber: string
  prState: string | null
  sourceRef: string | null
  targetRepository: string | null
  targetRef: string | null
}

function parseJob(value: unknown): JobSummary | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const slug = displayValue(value.slug)
  const state = displayValue(value.state)
  if (!id) return null
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
  return {
    prNumber,
    prState: displayValue(value.pr_state),
    sourceRef: displayValue(value.source_ref),
    targetRepository: displayValue(value.target_repository),
    targetRef: displayValue(value.target_ref)
  }
}

function inputActionId(context: ToolCardContext) {
  return displayValue(context.input?.ref_movement_action_id)
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
  if (result)
    return context.resultError ? `Ref movement ${result.core.actionId || inputActionId(context) || "status"} failed` : refMovementCollapsedSummary(result.core)
  if (context.resultError) return `Ref movement ${inputActionId(context) || "status"} failed`
  return null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  const actionId = result?.core.actionId || inputActionId(context)
  if (!result && !context.resultError) return null

  return (
    <CardShell>
      {result ? (
        <RefMovementCoreFields core={result.core} />
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          {actionId ? <span className="font-mono font-semibold text-text-primary">Ref movement {actionId}</span> : null}
          <StatePill state="failed" />
        </div>
      )}
      {context.resultError && context.resultBody ? <MarkdownPreview modalLabel="Full error" text={context.resultBody} /> : null}
      {result?.job ? (
        <div>
          <SectionLabel>Job</SectionLabel>
          <div className="mt-0.5 flex flex-wrap items-center gap-2">
            <EntityReference id={result.job.id} kind="job" slug={result.job.slug} />
            {result.job.state ? <StatePill state={result.job.state} /> : null}
          </div>
        </div>
      ) : null}
      {result?.workflow ? (
        <div>
          <SectionLabel>Workflow</SectionLabel>
          <div className="mt-0.5 flex flex-wrap items-center gap-2">
            <EntityReference id={result.workflow.id} jobId={result.job?.id} kind="workflow" />
            <StatePill state={result.workflow.state} />
            {result.workflow.triggerKind ? <Badge>{result.workflow.triggerKind}</Badge> : null}
          </div>
        </div>
      ) : null}
      {result?.prLink ? (
        <div className="space-y-1">
          <div className="flex flex-wrap items-center gap-2">
            <EntityReference
              id={result.prLink.prNumber}
              kind="pull_request"
              prUrl={result.prLink.targetRepository ? `https://github.com/${result.prLink.targetRepository}/pull/${result.prLink.prNumber}` : null}
            />
            {result.prLink.prState ? <StatePill state={result.prLink.prState} /> : null}
          </div>
          <dl className="grid gap-1 sm:grid-cols-2">
            {result.prLink.targetRepository ? (
              <div>
                <dt className="text-2xs font-semibold uppercase text-text-muted">Target repository</dt>
                <dd>
                  <EntityReference
                    href={`https://github.com/${result.prLink.targetRepository}`}
                    kind="repository"
                    repositorySlug={result.prLink.targetRepository}
                    wrap="break"
                  />
                </dd>
              </div>
            ) : null}
            {result.prLink.sourceRef ? <Row label="Source ref" value={result.prLink.sourceRef} wrap /> : null}
            {result.prLink.targetRef ? <Row label="Target ref" value={result.prLink.targetRef} wrap /> : null}
          </dl>
        </div>
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
