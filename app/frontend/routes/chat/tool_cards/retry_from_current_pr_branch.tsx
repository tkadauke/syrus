import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard, type PendingActionInputField } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

const inputFields: PendingActionInputField[] = [
  { key: "instructions", format: "markdown" },
  { key: "reason", format: "markdown" }
]

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? <PendingActionResultCard input={context.input} inputFields={inputFields} omitInstructions result={result} /> : null
}

const retryFromCurrentPrBranchToolCard: ToolCardRenderer = {
  toolName: "retry_from_current_pr_branch",
  collapsedSummary,
  renderExpanded
}

export default retryFromCurrentPrBranchToolCard

const longInstructions = [
  "## Repair instructions",
  "",
  "Preserve the current PR branch as the source of truth.",
  "",
  "- Re-run the focused regression spec.",
  "- Keep the existing public API intact.",
  "- Explain any unexpected branch divergence in the PR summary."
].join("\n")

export const examples: ToolCardExample[] = [
  {
    id: "pending_retry",
    label: "Pending retry with instructions",
    input: {
      job_id: 4222,
      workflow_id: 26123,
      instructions: longInstructions,
      reason: "The remote PR branch contains the reviewed fix; retry from that head.",
      dry_run: false
    },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: "Retry JOB-4222 from the current PR branch?"
    }
  },
  {
    id: "dry_run_evidence",
    label: "Dry run with branch evidence",
    input: { job_id: 4222, workflow_id: 26123, instructions: longInstructions, reason: "Inspect the branch before retrying.", dry_run: true },
    parsedResult: {
      action: "retry_from_current_pr_branch",
      job_id: 4222,
      evidence: {
        workflow_id: 26123,
        branch: "syrus/direct-322",
        current_pr: { number: 44, repository: "acme/widgets" },
        remote_sha: "abc123abc123abc123abc123abc123abc123abcd",
        workflow_local_sha: "def456def456def456def456def456def456def4",
        diff_summary: { available: true, files: ["app/models/job.rb"] }
      }
    }
  },
  {
    id: "missing_input",
    label: "Missing required input",
    input: { workflow_id: 26123, instructions: longInstructions, reason: "Retry the reviewed repair.", dry_run: false },
    parsedResult: { error: "job_not_found", message: "Job could not be found." },
    resultError: true
  }
]
