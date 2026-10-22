import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EntityReference, Row } from "../toolCardUi"

function requestedBulkWorkflowIds(context: ToolCardContext) {
  if (!Array.isArray(context.input?.workflow_ids)) return []
  return context.input.workflow_ids.flatMap((id) => {
    const value = displayValue(id)
    return value ? [value] : []
  })
}

function RequestDetails({ context, showReason }: { context: ToolCardContext; showReason: boolean }) {
  const workflowIds = requestedBulkWorkflowIds(context)
  const reason = displayValue(context.input?.reason)

  return (
    <>
      {workflowIds.length ? (
        <Row
          label="Workflows"
          value={
            <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
              {workflowIds.map((workflowId) => (
                <EntityReference href={`/admin/workflows/${workflowId}`} id={workflowId} key={workflowId} kind="workflow" />
              ))}
            </div>
          }
        />
      ) : null}
      {showReason && reason ? <MarkdownPreview linkifyUrls maxLines={4} modalLabel="Pending action reason" text={reason} title="Reason" /> : null}
    </>
  )
}

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? (
    <PendingActionResultCard
      details={<RequestDetails context={context} showReason={result.kind === "error"} />}
      linkifyMessageUrls
      linkifyReasonUrls
      result={result}
    />
  ) : null
}

const markCiRepairNoopToolCard: ToolCardRenderer = {
  toolName: "mark_ci_repair_noop",
  collapsedSummary,
  renderExpanded
}

export default markCiRepairNoopToolCard

const bulkWorkflowIds = [8101, 8102, 8103, 8104, 8105, 8106, 8107, 8108, 8109, 8110, 8111, 8112]

export const examples: ToolCardExample[] = [
  {
    id: "single_pending",
    label: "Single pending repair no-op",
    description: "Shows linked Job and Workflow targets plus linkified failing-check and audit-reason URLs.",
    input: {
      job_id: 4201,
      workflow_id: 8101,
      reason: "The repair produced no progress after reviewing https://ci.example.test/builds/8101."
    },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message:
        "Mark WF-8101 as CI repair no-op for JOB-4201? Current checks: failing; failing checks: RSpec (https://github.com/acme/widgets/actions/runs/123456789)."
    }
  },
  {
    id: "bulk_pending",
    label: "Bulk pending repair no-ops",
    description: "A long linked Workflow list exercises wrapping on narrow and wide layouts.",
    input: {
      workflow_ids: bulkWorkflowIds,
      reason: "These repairs made no branch or check progress. See https://ci.example.test/incidents/42 for the shared diagnosis."
    },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 502,
      state: "pending",
      member_count: bulkWorkflowIds.length,
      message: `Mark ${bulkWorkflowIds.length} CI repairs as no-op?`
    }
  },
  {
    id: "validation_error",
    label: "Validation error with requested targets",
    description: "Keeps the requested Job, Workflow, reason, and help URL visible when validation fails.",
    input: {
      job_id: 4201,
      workflow_id: 8999,
      reason: "**Investigate** the validation failure before retrying."
    },
    parsedResult: {
      error: "invalid_request",
      message: "Workflow is not a CI failure repair. See https://ci.example.test/help/repair-workflows."
    },
    resultError: true
  }
]
