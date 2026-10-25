import i18n from "../../../i18n"
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
    label: i18n.t("chat:ops_pending_re_enqueue_with_targets_50a156"),
    description: i18n.t("chat:ops_input_only_workflow_and_run_context_remains_link_6eb9b3"),
    input: {
      job_id: 42,
      workflow_id: 101,
      run_id: 201,
      reason: "**Retry** after the worker recovered."
    },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: i18n.t("chat:ops_re_enqueue_work_for_job_42_400fc0")
    }
  },
  {
    id: "invalid_request",
    label: i18n.t("chat:ops_invalid_re_enqueue_request_26abb9"),
    input: {
      job_id: 42,
      workflow_id: 101,
      run_id: 201,
      reason: i18n.t("chat:ops_retry_the_blocked_work_faf05b")
    },
    parsedResult: {
      error: "invalid_request",
      message: i18n.t("chat:ops_the_selected_run_is_no_longer_eligible_to_be_re__4bda55")
    }
  },
  {
    id: "missing_input",
    label: i18n.t("chat:ops_recorded_action_without_input_35c5e0"),
    description: i18n.t("chat:ops_older_recorded_tool_calls_remain_useful_when_the_3e7ec8"),
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: i18n.t("chat:ops_re_enqueue_work_eb70f6")
    }
  }
]
