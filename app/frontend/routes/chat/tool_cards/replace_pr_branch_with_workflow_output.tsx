import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"

const DESTRUCTIVE_CONFIRMATION = "REPLACE PR BRANCH"

function DestructiveWarning() {
  return (
    <div className="rounded-[var(--radius-control)] bg-warning/10 px-2 py-1 text-warning-text">
      <div className="text-2xs font-semibold uppercase">Destructive action</div>
      <div>This will force-push the workflow output over the current pull request branch.</div>
      <div className="mt-1 text-2xs font-semibold uppercase">Confirmation phrase</div>
      <div className="break-all font-mono">{DESTRUCTIVE_CONFIRMATION}</div>
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
  return result ? <PendingActionResultCard details={result.kind === "standard" ? <DestructiveWarning /> : undefined} result={result} /> : null
}

const replacePrBranchWithWorkflowOutputToolCard: ToolCardRenderer = {
  toolName: "replace_pr_branch_with_workflow_output",
  collapsedSummary,
  renderExpanded
}

export default replacePrBranchWithWorkflowOutputToolCard

export const examples: ToolCardExample[] = [
  {
    id: "dry_run_evidence",
    label: "Destructive dry run",
    input: { job_id: 4222, workflow_id: 26123, dry_run: true },
    parsedResult: {
      action: "replace_pr_branch_with_workflow_output",
      job_id: 4222,
      destructive_confirmation: DESTRUCTIVE_CONFIRMATION,
      evidence: {
        workflow_id: 26123,
        branch: "syrus/direct-322",
        remote_sha: "abc123abc123abc123abc123abc123abc123abcd",
        workflow_local_sha: "def456def456def456def456def456def456def4",
        base_sha: "1112221112221112221112221112221112221112",
        current_pr: { number: 44, repository: "acme/widgets" },
        diff_summary: { available: true, files: ["app/models/job.rb"] }
      }
    }
  },
  {
    id: "pending_replacement",
    label: "Pending destructive replacement",
    input: {
      job_id: 4222,
      workflow_id: 26123,
      reason: "The workflow output is the intended branch state.",
      destructive_confirmation: DESTRUCTIVE_CONFIRMATION,
      dry_run: false
    },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: "Replace the pull request branch with workflow output?"
    }
  },
  {
    id: "structured_error",
    label: "Incorrect confirmation phrase",
    input: { job_id: 4222, workflow_id: 26123, destructive_confirmation: "replace", dry_run: false },
    parsedResult: {
      error: "missing_destructive_confirmation",
      message: "destructive_confirmation must be exactly REPLACE PR BRANCH",
      evidence: {
        job_id: 4222,
        workflow_id: 26123,
        branch: "syrus/direct-322",
        remote_sha: "abc123abc123abc123abc123abc123abc123abcd",
        workflow_local_sha: "def456def456def456def456def456def456def4",
        current_pr: { number: 44, repository: "acme/widgets" },
        diff_summary: { available: true, files: ["app/models/job.rb"] }
      }
    },
    resultError: true
  }
]
