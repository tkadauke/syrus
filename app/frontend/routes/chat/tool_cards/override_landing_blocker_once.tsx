import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EntityReference, Row } from "../toolCardUi"

function RequestDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const blockerKey = displayValue(context.input?.blocker_key)
  const reason = displayValue(context.input?.reason)

  return (
    <div className="space-y-2">
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label="Job" value={jobId ? <EntityReference id={jobId} kind="job" /> : "Not provided"} />
        <Row label="Blocker key" value={blockerKey ? <span className="break-all font-mono">{blockerKey}</span> : "Not provided"} />
      </dl>
      {reason ? (
        <MarkdownPreview maxLines={4} modalLabel="Audit reason" text={reason} title="Audit reason" />
      ) : (
        <Row label="Audit reason" value="Not provided" />
      )}
    </div>
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
  return result ? <PendingActionResultCard details={<RequestDetails context={context} />} omitBlocker omitJob omitReason result={result} /> : null
}

const overrideLandingBlockerOnceToolCard: ToolCardRenderer = {
  toolName: "override_landing_blocker_once",
  collapsedSummary,
  renderExpanded
}

export default overrideLandingBlockerOnceToolCard
