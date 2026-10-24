import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EntityReference, Row } from "../toolCardUi"

function RequestDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const runId = displayValue(context.input?.run_id)
  const reason = displayValue(context.input?.reason)

  return (
    <div className="space-y-2">
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label="Job" value={jobId ? <EntityReference id={jobId} kind="job" /> : "Not provided"} />
        <Row label="Run" value={runId ? <EntityReference href={`/admin/runs/${runId}/transcript`} id={runId} kind="run" /> : "Not provided"} />
      </dl>
      {reason ? <MarkdownPreview maxLines={4} modalLabel="Repair reason" text={reason} title="Reason" /> : <Row label="Reason" value="Not provided" />}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard details={<RequestDetails context={context} />} omitJob omitReason omitRun result={result} /> : null
}

const repairQueueAffinityToolCard: ToolCardRenderer = {
  toolName: "repair_queue_affinity",
  collapsedSummary,
  renderExpanded
}

export default repairQueueAffinityToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_repair",
    label: "Pending queue affinity repair",
    description: "Shows linked Job and Run targets with the Markdown repair reason before confirmation.",
    input: {
      job_id: 4222,
      run_id: 9876,
      reason: "The assigned worker is **offline**, so this Run cannot start."
    },
    parsedResult: {
      pending_confirmation_id: 504,
      pending_action_id: 504,
      state: "pending",
      message: "Repair queue affinity for RUN-9876?"
    }
  },
  {
    id: "validation_error",
    label: "Queue affinity validation error",
    description: "Keeps the requested Job, Run, and reason visible when the repair fails validation.",
    input: {
      job_id: 4222,
      run_id: 9876,
      reason: "The assigned worker is **offline**."
    },
    parsedResult: {
      error: "invalid_request",
      message: "The Run is no longer queued."
    },
    resultError: true
  },
  {
    id: "missing_input",
    label: "Missing repair input",
    description: "Exercises unavailable labels for every repair request field.",
    parsedResult: {
      pending_confirmation_id: 505,
      pending_action_id: 505,
      state: "pending",
      message: "Repair queue affinity?"
    }
  }
]
