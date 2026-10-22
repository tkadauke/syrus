import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard result={result} /> : null
}

const reenqueueWorkToolCard: ToolCardRenderer = {
  toolName: "reenqueue_work",
  collapsedSummary,
  renderExpanded
}

export default reenqueueWorkToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_with_targets",
    label: "Pending re-enqueue with targets",
    description: "Input-only workflow and run context remains linked while a Markdown reason explains the request.",
    input: {
      job_id: 42,
      workflow_id: 101,
      run_id: 201,
      reason: "**Retry** after the worker recovered."
    },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: "Re-enqueue work for JOB-42?"
    }
  },
  {
    id: "invalid_request",
    label: "Invalid re-enqueue request",
    input: {
      job_id: 42,
      workflow_id: 101,
      run_id: 201,
      reason: "Retry the **blocked** work."
    },
    parsedResult: {
      error: "invalid_request",
      message: "The selected run is no longer eligible to be re-enqueued."
    }
  },
  {
    id: "missing_input",
    label: "Recorded action without input",
    description: "Older recorded tool calls remain useful when their original input was not retained.",
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: "Re-enqueue work?"
    }
  }
]
