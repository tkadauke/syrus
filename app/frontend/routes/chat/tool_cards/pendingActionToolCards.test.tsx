import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import rebaseJobCard from "./rebase_job"
import runVisualReviewCard from "./run_visual_review"
import delegateIssueCard from "./delegate_issue"
import checkJobMergeabilityCard from "./check_job_mergeability"
import pauseLandingQueueCard from "./pause_landing_queue"
import resumeLandingQueueCard from "./resume_landing_queue"
import adminCleanupWorkspaceCard from "./admin_cleanup_workspace"
import adminClearGithubCacheCard from "./admin_clear_github_cache"
import adminPausePollingCard from "./admin_pause_polling"
import adminUnpausePollingCard from "./admin_unpause_polling"
import adminPauseRunsCard from "./admin_pause_runs"
import adminUnpauseRunsCard from "./admin_unpause_runs"
import adminPauseUserSchedulingCard from "./admin_pause_user_scheduling"
import adminUnpauseUserSchedulingCard from "./admin_unpause_user_scheduling"
import adminReapStaleRunsCard from "./admin_reap_stale_runs"
import adminRefreshInstallationsCard from "./admin_refresh_installations"
import rerunCiRepairCard from "./rerun_ci_repair"
import markCiRepairNoopCard from "./mark_ci_repair_noop"
import overrideLandingBlockerOnceCard from "./override_landing_blocker_once"
import forceLandingRecheckCard from "./force_landing_recheck"
import cancelStaleWorkCard from "./cancel_stale_work"
import reenqueueWorkCard from "./reenqueue_work"
import wakeLandingQueueCard from "./wake_landing_queue"
import wakeProviderAdmissionCard from "./wake_provider_admission"
import clearProviderCircuitCard from "./clear_provider_circuit"
import repairProviderCircuitEvidenceCard from "./repair_provider_circuit_evidence"
import adminKillProcessCard from "./admin_kill_process"
import adminRetryStepCard from "./admin_retry_step"
import adoptCurrentPrHeadCard from "./adopt_current_pr_head"
import replacePrBranchWithWorkflowOutputCard from "./replace_pr_branch_with_workflow_output"
import retryFromCurrentPrBranchCard from "./retry_from_current_pr_branch"

// Parity guard for the pending-action tool card family (EPIC-292 /
// JOB-4222). Each card is a thin re-export of ../pendingActionToolCard, so
// the per-shape behavior is covered once in pendingActionToolCard.test.tsx;
// what can still silently rot here is the tool-name binding (a copy/paste
// slip registers a card the sidecar never dispatches to), plus the wiring
// from each module through to the shared parser.
//
// This file exports no ToolCardRenderer of its own; pluginToolCards.tsx
// excludes *.test.tsx from its card glob, so it is never discovered.
const CARDS: Array<[string, ToolCardRenderer]> = [
  ["rebase_job", rebaseJobCard],
  ["run_visual_review", runVisualReviewCard],
  ["delegate_issue", delegateIssueCard],
  ["check_job_mergeability", checkJobMergeabilityCard],
  ["pause_landing_queue", pauseLandingQueueCard],
  ["resume_landing_queue", resumeLandingQueueCard],
  ["admin_cleanup_workspace", adminCleanupWorkspaceCard],
  ["admin_clear_github_cache", adminClearGithubCacheCard],
  ["admin_pause_polling", adminPausePollingCard],
  ["admin_unpause_polling", adminUnpausePollingCard],
  ["admin_pause_runs", adminPauseRunsCard],
  ["admin_unpause_runs", adminUnpauseRunsCard],
  ["admin_pause_user_scheduling", adminPauseUserSchedulingCard],
  ["admin_unpause_user_scheduling", adminUnpauseUserSchedulingCard],
  ["admin_reap_stale_runs", adminReapStaleRunsCard],
  ["admin_refresh_installations", adminRefreshInstallationsCard],
  ["rerun_ci_repair", rerunCiRepairCard],
  ["mark_ci_repair_noop", markCiRepairNoopCard],
  ["override_landing_blocker_once", overrideLandingBlockerOnceCard],
  ["force_landing_recheck", forceLandingRecheckCard],
  ["cancel_stale_work", cancelStaleWorkCard],
  ["reenqueue_work", reenqueueWorkCard],
  ["wake_landing_queue", wakeLandingQueueCard],
  ["wake_provider_admission", wakeProviderAdmissionCard],
  ["clear_provider_circuit", clearProviderCircuitCard],
  ["repair_provider_circuit_evidence", repairProviderCircuitEvidenceCard],
  ["admin_kill_process", adminKillProcessCard],
  ["admin_retry_step", adminRetryStepCard],
  ["adopt_current_pr_head", adoptCurrentPrHeadCard],
  ["replace_pr_branch_with_workflow_output", replacePrBranchWithWorkflowOutputCard],
  ["retry_from_current_pr_branch", retryFromCurrentPrBranchCard],
]

function context(toolName: string, parsedResult: unknown): ToolCardContext {
  return { toolName, resultBody: "", resultError: false, parsedResult }
}

describe("pending action tool card family", () => {
  it("registers exactly the expected tool names", () => {
    expect(CARDS).toHaveLength(31)
    expect(new Set(CARDS.map(([name]) => name)).size).toBe(31)
  })

  it.each(CARDS)("%s registers under its exact MCP tool name", (name, card) => {
    expect(card.toolName).toBe(name)
  })

  it.each(CARDS)("%s falls back to null for a malformed payload", (name, card) => {
    expect(card.collapsedSummary?.(context(name, { oops: true }))).toBeNull()
    expect(card.renderExpanded(context(name, { oops: true }))).toBeNull()
  })

  it.each(CARDS)("%s falls back to null for a non-object payload", (name, card) => {
    expect(card.collapsedSummary?.(context(name, "not json"))).toBeNull()
    expect(card.renderExpanded(context(name, "not json"))).toBeNull()
  })

  it("wires a standard-shape tool through to the shared card", () => {
    const parsedResult = {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: "Rebase JOB-4222 onto main?"
    }

    expect(rebaseJobCard.collapsedSummary?.(context("rebase_job", parsedResult))).toBe("Rebase JOB-4222 onto main?")
    render(<>{rebaseJobCard.renderExpanded(context("rebase_job", parsedResult))}</>)
    expect(screen.getByText("#501")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
  })

  it("wires a bulk-shape tool through to the shared card", () => {
    const parsedResult = {
      pending_action_group_id: 88,
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      member_count: 3,
      message: "Kill 3 processes?"
    }

    expect(adminKillProcessCard.collapsedSummary?.(context("admin_kill_process", parsedResult))).toBe("Kill 3 processes? · 3 actions")
    render(<>{adminKillProcessCard.renderExpanded(context("admin_kill_process", parsedResult))}</>)
    expect(screen.getByText("Group #88")).toBeInTheDocument()
    expect(screen.getByText("3 actions")).toBeInTheDocument()
  })

  it("wires a dry-run-evidence tool through to the shared card", () => {
    const parsedResult = {
      action: "adopt_current_pr_head",
      job_id: 4222,
      evidence: {
        remote_sha: "abc123abc123abc123",
        workflow_local_sha: "def456def456def456",
        base_sha: "111222111222111222",
        diff_summary: { available: true, files: ["app/models/job.rb"] }
      }
    }

    expect(adoptCurrentPrHeadCard.collapsedSummary?.(context("adopt_current_pr_head", parsedResult))).toBe(
      "Dry run: adopt_current_pr_head for JOB-4222"
    )
    render(<>{adoptCurrentPrHeadCard.renderExpanded(context("adopt_current_pr_head", parsedResult))}</>)
    expect(screen.getByText("Adopt current pr head")).toBeInTheDocument()
    expect(screen.getByText("1 changed file")).toBeInTheDocument()
  })

  it("wires the destructive dry-run tool through to the shared card", () => {
    const parsedResult = {
      action: "replace_pr_branch_with_workflow_output",
      job_id: 4222,
      evidence: { remote_sha: "abc123abc123abc123", diff_summary: { available: true, files: [] } },
      destructive_confirmation: "REPLACE PR BRANCH"
    }

    render(<>{replacePrBranchWithWorkflowOutputCard.renderExpanded(context("replace_pr_branch_with_workflow_output", parsedResult))}</>)
    expect(screen.getByText("REPLACE PR BRANCH")).toBeInTheDocument()
  })
})
