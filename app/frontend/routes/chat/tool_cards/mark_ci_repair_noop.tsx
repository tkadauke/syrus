import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
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
