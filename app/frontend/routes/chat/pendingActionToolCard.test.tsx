import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "../../api/chats"
import type { ToolCardContext } from "../../pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "./pendingActionToolCard"

function context(parsedResult: unknown, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
  return {
    toolName: "some_pending_action_tool",
    resultBody: "",
    resultError: false,
    parsedResult,
    livePendingAction
  }
}

function liveAction(overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 501,
    action: "some_pending_action_tool",
    state: "confirmed",
    label: "Some pending action",
    detail: null,
    app_confirm_path: "/api/v1/app/chats/1/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/1/pending_actions/501/reject",
    ...overrides
  }
}

function standardPayload(overrides: Record<string, unknown> = {}) {
  return {
    pending_confirmation_id: 501,
    pending_action_id: 501,
    state: "pending",
    message: "Job rebase requires operator confirmation.",
    ...overrides
  }
}

function renderResult(payload: unknown, livePendingAction: ChatPendingActionInline | null = null) {
  const result = parsePendingActionResult(context(payload, livePendingAction))
  if (!result) throw new Error("expected payload to parse")
  render(<PendingActionResultCard result={result} />)
  return result
}

function summarize(payload: unknown, livePendingAction: ChatPendingActionInline | null = null) {
  const result = parsePendingActionResult(context(payload, livePendingAction))
  return result ? pendingActionCollapsedSummary(result) : null
}

describe("pending action tool card: standard shape", () => {
  it("parses the single-target create_pending_action! payload", () => {
    expect(parsePendingActionResult(context(standardPayload()))).toEqual({
      kind: "standard",
      pendingActionId: "501",
      state: "pending",
      message: "Job rebase requires operator confirmation.",
      reason: null,
      memberCount: null,
      groupId: null
    })
  })

  it("prefers the tool message for the collapsed summary", () => {
    expect(summarize(standardPayload())).toBe("Job rebase requires operator confirmation.")
  })

  it("synthesizes a collapsed summary when the payload carries no message", () => {
    expect(summarize(standardPayload({ message: null }))).toBe("Pending action #501 (pending)")
  })

  it("falls back to pending_confirmation_id when pending_action_id is absent", () => {
    const result = parsePendingActionResult(context({ pending_confirmation_id: 77, state: "pending" }))
    expect(result).toMatchObject({ kind: "standard", pendingActionId: "77" })
  })

  // A transcript is re-rendered long after the tool call, by which time the
  // pending action may have moved anywhere in ChatPendingAction::STATES, so
  // the card must trust whatever `state` the payload carries when there is
  // no live state to prefer instead.
  it.each([
    ["queued", "queued"],
    ["pending", "pending"],
    ["confirming", "confirming"],
    ["confirmed", "confirmed"],
    ["rejected", "rejected"],
    ["cancelled", "cancelled"],
    ["failed", "failed"]
  ])("renders the %s lifecycle state", (state, expected) => {
    renderResult(standardPayload({ state }))
    expect(screen.getByText(expected)).toBeInTheDocument()
  })

  it("renders the pending action id and message", () => {
    renderResult(standardPayload())

    expect(screen.getByText("#501")).toBeInTheDocument()
    expect(screen.getByText("Job rebase requires operator confirmation.")).toBeInTheDocument()
  })

  it("renders the operator-facing reason when the admin shape supplies one", () => {
    renderResult(standardPayload({ reason: "Landing has been blocked for six hours." }))

    expect(screen.getByText("Reason")).toBeInTheDocument()
    expect(screen.getByText("Landing has been blocked for six hours.")).toBeInTheDocument()
  })

  it("omits the reason section when the tool never sets one", () => {
    renderResult(standardPayload())

    expect(screen.queryByText("Reason")).not.toBeInTheDocument()
  })

  // The bug this covers: the tool result is a snapshot frozen at call time
  // ("pending"), but the chat card kept showing that snapshot forever even
  // after the operator confirmed/rejected the action out of band. The live
  // pending action (re-read from the owning message on every fetch) must
  // win once it exists and matches the same id.
  it("prefers the live pending action's state over the frozen tool-result state", () => {
    const result = parsePendingActionResult(context(standardPayload({ state: "pending" }), liveAction({ id: 501, state: "confirmed" })))

    expect(result).toMatchObject({ pendingActionId: "501", state: "confirmed" })
  })

  it("renders the live confirmed state instead of the stale pending pill", () => {
    renderResult(standardPayload({ state: "pending" }), liveAction({ id: 501, state: "rejected" }))

    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("prefers the live pending action's reason once it has one", () => {
    renderResult(standardPayload({ state: "pending" }), liveAction({ id: 501, state: "failed", reason: "GitHub rejected the merge." }))

    expect(screen.getByText("GitHub rejected the merge.")).toBeInTheDocument()
  })

  it("ignores a live pending action for a different id", () => {
    const result = parsePendingActionResult(context(standardPayload({ state: "pending" }), liveAction({ id: 999, state: "confirmed" })))

    expect(result).toMatchObject({ pendingActionId: "501", state: "pending" })
  })

  it("ignores a null live pending action", () => {
    const result = parsePendingActionResult(context(standardPayload({ state: "pending" }), null))

    expect(result).toMatchObject({ pendingActionId: "501", state: "pending" })
  })
})

describe("pending action tool card: bulk shape", () => {
  const bulkPayload = {
    pending_action_group_id: 88,
    pending_action_id: 501,
    pending_confirmation_id: 501,
    state: "pending",
    member_count: 3,
    message: "Retry step 'graders' on 3 Workflows?"
  }

  it("distinguishes the bulk shape by its group id and member count", () => {
    expect(parsePendingActionResult(context(bulkPayload))).toEqual({
      kind: "bulk",
      pendingActionId: "501",
      state: "pending",
      message: "Retry step 'graders' on 3 Workflows?",
      reason: null,
      memberCount: 3,
      groupId: "88"
    })
  })

  it("mentions the member count in the collapsed summary", () => {
    expect(summarize(bulkPayload)).toBe("Retry step 'graders' on 3 Workflows? · 3 actions")
  })

  it("singularizes a one-member group", () => {
    expect(summarize({ ...bulkPayload, member_count: 1, message: null })).toBe("Pending action group #88 (pending) · 1 action")
  })

  it("renders the group id and member count badge", () => {
    renderResult(bulkPayload)

    expect(screen.getByText("Group #88")).toBeInTheDocument()
    expect(screen.getByText("3 actions")).toBeInTheDocument()
  })
})

describe("pending action tool card: dry-run evidence shape", () => {
  const evidencePayload = {
    action: "adopt_current_pr_head",
    job_id: 4222,
    evidence: {
      job_id: 4222,
      workflow_id: 26123,
      branch: "syrus/direct-322",
      remote_sha: "abc123abc123abc123abc123",
      workflow_local_sha: "def456def456def456def456",
      base_sha: "111222111222111222111222",
      base_ref: "origin/main",
      diff_summary: {
        available: true,
        stat: " app/models/job.rb | 2 +-",
        files: ["app/models/job.rb", "spec/models/job_spec.rb"]
      }
    }
  }

  it("parses the evidence preview instead of a pending action", () => {
    const result = parsePendingActionResult(context(evidencePayload))

    expect(result).toMatchObject({
      kind: "dry_run_evidence",
      action: "adopt_current_pr_head",
      jobId: "4222",
      destructiveConfirmation: null
    })
  })

  it("summarizes the collapsed row as a dry run for the target Job", () => {
    expect(summarize(evidencePayload)).toBe("Dry run: adopt_current_pr_head for JOB-4222")
  })

  it("renders the humanized action, job, branch, and truncated SHAs", () => {
    renderResult(evidencePayload)

    expect(screen.getByText("Dry run")).toBeInTheDocument()
    expect(screen.getByText("Adopt current pr head")).toBeInTheDocument()
    expect(screen.getByText("JOB-4222")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-322")).toBeInTheDocument()
    expect(screen.getByText("abc123abc123")).toBeInTheDocument()
    expect(screen.getByText("def456def456")).toBeInTheDocument()
    expect(screen.getByText("111222111222")).toBeInTheDocument()
    // The full SHA stays reachable through the title tooltip.
    expect(screen.getByTitle("abc123abc123abc123abc123")).toBeInTheDocument()
  })

  it("renders the changed files behind a disclosure", () => {
    renderResult(evidencePayload)

    expect(screen.getByText("2 changed files")).toBeInTheDocument()
    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("spec/models/job_spec.rb")).toBeInTheDocument()
  })

  it("calls out the destructive confirmation phrase when present", () => {
    renderResult({
      ...evidencePayload,
      action: "replace_pr_branch_with_workflow_output",
      destructive_confirmation: "REPLACE PR BRANCH"
    })

    expect(screen.getByText("Destructive · confirmation phrase")).toBeInTheDocument()
    expect(screen.getByText("REPLACE PR BRANCH")).toBeInTheDocument()
  })

  it("omits the destructive callout for a non-destructive dry run", () => {
    renderResult(evidencePayload)

    expect(screen.queryByText("Destructive · confirmation phrase")).not.toBeInTheDocument()
  })

  it("reports an unavailable diff summary instead of an empty file list", () => {
    renderResult({
      ...evidencePayload,
      evidence: {
        ...evidencePayload.evidence,
        diff_summary: { available: false, reason: "workflow workspace is unavailable" }
      }
    })

    expect(screen.getByText("Diff unavailable: workflow workspace is unavailable")).toBeInTheDocument()
    expect(screen.queryByText("2 changed files")).not.toBeInTheDocument()
  })
})

describe("pending action tool card: fallbacks", () => {
  it("returns null for a payload with no recognizable shape", () => {
    expect(parsePendingActionResult(context({ oops: true }))).toBeNull()
  })

  it("returns null for a non-object payload", () => {
    expect(parsePendingActionResult(context("not json"))).toBeNull()
    expect(parsePendingActionResult(context(null))).toBeNull()
    expect(parsePendingActionResult(context([{ pending_action_id: 1, state: "pending" }]))).toBeNull()
  })

  it("returns null when a pending action payload is missing its state", () => {
    expect(parsePendingActionResult(context({ pending_action_id: 501 }))).toBeNull()
  })

  it("returns null when an evidence payload is missing its action name", () => {
    expect(parsePendingActionResult(context({ job_id: 4222, evidence: { remote_sha: "abc" } }))).toBeNull()
  })
})
