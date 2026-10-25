import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import i18n from "@app/i18n"

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

const adoptCurrentPrHeadToolCard: ToolCardRenderer = {
  toolName: "adopt_current_pr_head",
  collapsedSummary,
  renderExpanded
}

export default adoptCurrentPrHeadToolCard

export const examples: ToolCardExample[] = [
  {
    id: "dry_run_evidence",
    label: i18n.t("chat:adopt_current_pr_head.example_dry_run"),
    description: i18n.t("chat:adopt_current_pr_head.example_dry_run_description"),
    parsedResult: {
      action: "adopt_current_pr_head",
      job_id: 4222,
      evidence: {
        workflow_id: 26123,
        branch: "syrus/direct-322",
        remote_sha: "abc123abc123abc123abc123abc123abc123abcd",
        workflow_local_sha: "def456def456def456def456def456def456def4",
        base_ref: "origin/main",
        base_sha: "1112221112221112221112221112221112221112",
        current_pr: { number: 44, repository: "acme/widgets" },
        diff_summary: {
          available: true,
          stat: " app/models/job.rb      | 12 ++++++++----\n spec/models/job_spec.rb | 18 ++++++++++++++++++",
          files: ["app/models/job.rb", "spec/models/job_spec.rb"]
        }
      }
    }
  },
  {
    id: "pending_input_fallback",
    label: i18n.t("chat:adopt_current_pr_head.example_pending"),
    description: i18n.t("chat:adopt_current_pr_head.example_pending_description"),
    input: {
      job_id: 4222,
      workflow_id: 26123,
      reason: "The current PR already contains the intended fix.\n\n**Audit note:** preserve the remote branch as the source of truth.",
      dry_run: false
    },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: `Adopt the current PR head?\n\n${"Review the divergence evidence before confirming. ".repeat(28)}`
    }
  },
  {
    id: "structured_error",
    label: i18n.t("chat:adopt_current_pr_head.example_error"),
    input: { job_id: 4222, workflow_id: 26123, reason: "Adopt the current PR head.", dry_run: false },
    parsedResult: {
      error: "invalid_base",
      message: "The requested workflow does not use an eligible base.",
      valid_bases: ["main", "release"]
    },
    resultError: true
  },
  {
    id: "empty_result",
    label: i18n.t("chat:adopt_current_pr_head.example_empty"),
    description: i18n.t("chat:adopt_current_pr_head.example_empty_description"),
    input: { job_id: 4222, workflow_id: 26123, reason: "Adopt the current PR head.", dry_run: false },
    resultBody: "",
    resultSettled: true
  }
]
