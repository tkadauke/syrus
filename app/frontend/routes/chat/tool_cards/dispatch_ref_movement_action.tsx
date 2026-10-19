import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EntityReference, Row, StatePill } from "../toolCardUi"
import { parseRefMovementCore, refMovementCollapsedSummary, RefMovementCoreFields } from "../refMovementToolCard"

// Core-owned tool card for dispatch_ref_movement_action (the tool-card work /
// Always renders, even when state is "blocked" -- the dispatch
// still creates a durable audit record either way (see
// dispatch_ref_movement_action_tool.rb).
function parseResult(context: ToolCardContext) {
  const parsed = context.parsedResult
  const core = parseRefMovementCore(parsed)
  if (!core || !isPlainObject(parsed)) return null

  const input = inputDetails(context)

  return {
    core: {
      ...core,
      actionName: core.actionName || input.action,
      state: context.resultError ? "failed" : core.state,
      sourceRef: core.sourceRef || input.sourceBranch,
      targetRef: core.targetRef || input.targetBranch
    },
    jobId: displayValue(parsed.job_id) || input.jobId,
    workflowId: displayValue(parsed.workflow_id)
  }
}

function inputDetails(context: ToolCardContext) {
  const input = context.input || {}
  return {
    action: displayValue(input.action),
    jobId: displayValue(input.job_id),
    sourceBranch: displayValue(input.source_branch),
    targetBranch: displayValue(input.target_branch)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (result) return refMovementCollapsedSummary(result.core)
  const input = inputDetails(context)
  if (context.resultError) return `${input.action?.replace(/_/g, " ") || "Ref movement"} failed`
  return input.action ? `${input.action.replace(/_/g, " ")} (pending)` : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  const input = inputDetails(context)
  if (!result && !input.action && !context.resultError) return null

  const jobId = result?.jobId || input.jobId
  const workflowId = result?.workflowId

  return (
    <CardShell>
      {result ? (
        <RefMovementCoreFields core={result.core} />
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          {input.action ? <span className="font-mono font-semibold text-text-primary">{input.action}</span> : null}
          <StatePill state={context.resultError ? "failed" : "pending"} />
        </div>
      )}
      {context.resultError && context.resultBody ? <MarkdownPreview modalLabel="Full error" text={context.resultBody} /> : null}
      {jobId || workflowId ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {jobId ? (
            <div>
              <dt className="text-2xs font-semibold uppercase text-text-muted">Job</dt>
              <dd>
                <EntityReference id={jobId} kind="job" />
              </dd>
            </div>
          ) : null}
          {workflowId ? (
            <div>
              <dt className="text-2xs font-semibold uppercase text-text-muted">Workflow</dt>
              <dd>
                <EntityReference id={workflowId} jobId={jobId} kind="workflow" />
              </dd>
            </div>
          ) : null}
        </dl>
      ) : null}
      {!result?.core.sourceRef && input.sourceBranch ? <Row label="Source branch" value={input.sourceBranch} wrap /> : null}
      {!result?.core.targetRef && input.targetBranch ? <Row label="Target branch" value={input.targetBranch} wrap /> : null}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "dispatched",
    label: "Dispatched ref movement",
    input: { action: "send_job_upstream", job_id: 4225 },
    parsedResult: {
      ref_movement_action_id: 7,
      action_name: "send_job_upstream",
      state: "dispatched",
      target_repository: "upstream/syrus",
      job_id: 4225,
      workflow_id: 900
    }
  },
  {
    id: "blocked",
    label: "Blocked with operator guidance",
    input: { action: "submit_branch_upstream", source_branch: "release/very-long-source-branch", target_branch: "main" },
    parsedResult: {
      ref_movement_action_id: 8,
      action_name: "submit_branch_upstream",
      state: "blocked",
      blocked_reason: "Enable **submit_branch_upstream** in `.syrus.yml` before retrying."
    }
  },
  {
    id: "provider_error",
    label: "Provider error with original input",
    input: { action: "send_job_upstream", job_id: 4225 },
    resultBody: "The ref-movement dispatcher is unavailable.",
    resultError: true
  }
]

const dispatchRefMovementActionToolCard: ToolCardRenderer = {
  toolName: "dispatch_ref_movement_action",
  collapsedSummary,
  renderExpanded
}

export default dispatchRefMovementActionToolCard
