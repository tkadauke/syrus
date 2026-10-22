import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "../../api/chats"
import type { ToolCardContext } from "../../pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "./toolRendering"
import { parsePendingActionResult, pendingActionCollapsedSummary, pendingActionToolCard, PendingActionResultCard } from "./pendingActionToolCard"
import cancelStaleWorkCard from "./tool_cards/cancel_stale_work"
import checkJobMergeabilityCard from "./tool_cards/check_job_mergeability"
import delegateIssueCard from "./tool_cards/delegate_issue"
import forceLandingRecheckCard from "./tool_cards/force_landing_recheck"
import markCiRepairNoopCard from "./tool_cards/mark_ci_repair_noop"
import overrideLandingBlockerOnceCard from "./tool_cards/override_landing_blocker_once"
import reconcileJobStateCard from "./tool_cards/reconcile_job_state"

function context(parsedResult: unknown, livePendingAction: ChatPendingActionInline | null = null, input?: Record<string, unknown>): ToolCardContext {
  return {
    toolName: normalizedToolName("mcp__syrus-chat-sidecar__some_pending_action_tool"),
    input,
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

function renderResult(payload: unknown, livePendingAction: ChatPendingActionInline | null = null, input?: Record<string, unknown>) {
  const result = parsePendingActionResult(context(payload, livePendingAction, input))
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
    expect(parsePendingActionResult(context(standardPayload()))).toMatchObject({
      kind: "standard",
      pendingActionId: "501",
      state: "pending",
      message: "Job rebase requires operator confirmation.",
      reason: null,
      memberCount: null,
      groupId: null,
      observed: undefined
    })
  })

  it("prefers the tool message for the collapsed summary", () => {
    expect(summarize(standardPayload())).toBe("Job rebase requires operator confirmation.")
  })

  it("keeps collapsed Markdown messages compact while preserving the expanded content", () => {
    const message = `**Review first**\n\n${"Long pending-action detail. ".repeat(40)}`
    const summary = summarize(standardPayload({ message }))

    expect(summary).toHaveLength(160)
    expect(summary).toMatch(/^Review first Long pending-action detail\./)
    expect(summary).toMatch(/…$/)

    renderResult(standardPayload({ message }))
    expect(screen.getByText("Review first", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
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

    expect(screen.getByText("Pending action #501")).toBeInTheDocument()
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

describe("override_landing_blocker_once tool card", () => {
  function normalizedContext(envelope: unknown, input?: Record<string, unknown>): ToolCardContext {
    return {
      ...context(normalizedToolCardParsedResult(envelope), null, input),
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__override_landing_blocker_once")
    }
  }

  it.each([
    ["text content", { content: [{ type: "text", text: JSON.stringify(standardPayload()) }], structured_content: null }],
    ["structured content", { content: [], structured_content: standardPayload() }]
  ])("renders the linked Job, wrapping blocker key, and Markdown audit reason from a normalized %s envelope", (_label, envelope) => {
    render(
      <>
        {overrideLandingBlockerOnceCard.renderExpanded(
          normalizedContext(envelope, {
            job_id: 4222,
            blocker_key: "dependency_blocked_by_an_exceptionally_long_upstream_job_identifier",
            reason: "**Reviewed** the blocker before granting this one-time override."
          })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByText("Blocker key")).toBeInTheDocument()
    expect(screen.getByText("dependency_blocked_by_an_exceptionally_long_upstream_job_identifier")).toHaveClass("break-all")
    expect(screen.getByText("Audit reason")).toBeInTheDocument()
    expect(screen.getByText("Reviewed", { selector: "strong" })).toBeInTheDocument()
  })

  it("preserves request details in a structured error state", () => {
    render(
      <>
        {overrideLandingBlockerOnceCard.renderExpanded(
          normalizedContext(
            { error: "invalid_request", message: "The landing blocker changed before confirmation." },
            { job_id: 4222, blocker_key: "dependencies", reason: "Override approved after **manual review**." }
          )
        )}
      </>
    )

    expect(screen.getByText("invalid_request")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByText("dependencies")).toBeInTheDocument()
    expect(screen.getByText("manual review", { selector: "strong" })).toBeInTheDocument()
  })

  it("labels every unavailable request field when input is missing", () => {
    render(<>{overrideLandingBlockerOnceCard.renderExpanded(normalizedContext(standardPayload()))}</>)

    expect(screen.getAllByText("Not provided")).toHaveLength(3)
    expect(screen.getByText("Job")).toBeInTheDocument()
    expect(screen.getByText("Blocker key")).toBeInTheDocument()
    expect(screen.getByText("Audit reason")).toBeInTheDocument()
  })
})

describe("check_job_mergeability tool card", () => {
  function normalizedContext(envelope: unknown, input?: Record<string, unknown>, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
    return {
      ...context(normalizedToolCardParsedResult(envelope), livePendingAction, input),
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__check_job_mergeability")
    }
  }

  it.each([
    ["text content", { content: [{ type: "text", text: JSON.stringify(standardPayload()) }], structured_content: null }],
    ["structured content", { content: [], structured_content: standardPayload() }]
  ])("renders its linked Job from input for a normalized %s envelope", (_label, envelope) => {
    const cardContext = normalizedContext(envelope, { job_id: 4222 })

    render(<>{checkJobMergeabilityCard.renderExpanded(cardContext)}</>)

    expect(cardContext.toolName).toBe("check_job_mergeability")
    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getAllByText("JOB-4222")).toHaveLength(1)
    expect(screen.getByText("pending")).toBeInTheDocument()
  })

  it("labels the live mergeability outcome and current execution state", () => {
    const cardContext = normalizedContext(standardPayload(), { job_id: 4222 }, liveAction({ state: "confirmed", detail: "Mergeable after refreshing checks." }))

    render(<>{checkJobMergeabilityCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Mergeability outcome")).toBeInTheDocument()
    expect(screen.getByText("Mergeable after refreshing checks.")).toBeInTheDocument()
  })

  it("keeps the target visible for errors", () => {
    const cardContext = normalizedContext({ error: "job_not_found", message: "Job could not be found." }, { job_id: 4222 })

    render(<>{checkJobMergeabilityCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("job_not_found")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
  })

  it("calls out missing input instead of inferring a target from the message", () => {
    render(<>{checkJobMergeabilityCard.renderExpanded(normalizedContext(standardPayload({ message: "Check JOB-4222?" })))}</>)

    expect(screen.getByText("Not provided")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "JOB-4222" })).not.toBeInTheDocument()
  })
})

describe("reconcile_job_state tool card", () => {
  function normalizedContext(envelope: unknown, input?: Record<string, unknown>): ToolCardContext {
    return {
      ...context(normalizedToolCardParsedResult(envelope), null, input),
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__reconcile_job_state")
    }
  }

  it.each([
    ["text content", { content: [{ type: "text", text: JSON.stringify(standardPayload()) }], structured_content: null }],
    ["structured content", { content: [], structured_content: standardPayload() }]
  ])("renders mode, a linked Job, and Markdown reason from a normalized %s envelope", (_label, envelope) => {
    render(
      <>
        {reconcileJobStateCard.renderExpanded(
          normalizedContext(envelope, { job_id: 4222, mode: "mark_failed", reason: "Repair the **stale state** after review." })
        )}
      </>
    )

    expect(screen.getByText("Mode")).toBeInTheDocument()
    expect(screen.getByText("mark_failed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByText("stale state", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getAllByText("JOB-4222")).toHaveLength(1)
  })

  it("renders every bulk Job as a wrapping link with the auto mode", () => {
    render(
      <>
        {reconcileJobStateCard.renderExpanded(
          normalizedContext(
            { ...standardPayload(), pending_action_group_id: 88, member_count: 3 },
            { job_ids: [41, "42", 43], mode: "auto", reason: "The Jobs share **reconciler drift**." }
          )
        )}
      </>
    )

    for (const id of [41, 42, 43]) expect(screen.getByRole("link", { name: `JOB-${id}` })).toHaveAttribute("href", `/jobs/${id}`)
    expect(screen.getByText("auto")).toBeInTheDocument()
    expect(screen.getByText("reconciler drift", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("Jobs").parentElement).toHaveClass("min-w-0")
  })

  it("preserves request details in an error state", () => {
    render(
      <>
        {reconcileJobStateCard.renderExpanded(
          normalizedContext(
            { error: "invalid_request", message: "The requested reconciliation is not eligible." },
            { job_id: 4222, mode: "auto", reason: "Retry after **checking ownership**." }
          )
        )}
      </>
    )

    expect(screen.getByText("invalid_request")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4222" })).toBeInTheDocument()
    expect(screen.getByText("auto")).toBeInTheDocument()
    expect(screen.getByText("checking ownership", { selector: "strong" })).toBeInTheDocument()
  })

  it("labels every unavailable request field when input is missing", () => {
    render(<>{reconcileJobStateCard.renderExpanded(normalizedContext(standardPayload()))}</>)

    expect(screen.getAllByText("Not provided")).toHaveLength(3)
    expect(screen.getByText("Mode")).toBeInTheDocument()
    expect(screen.getByText("Jobs")).toBeInTheDocument()
    expect(screen.getByText("Reason")).toBeInTheDocument()
  })
})

describe("force_landing_recheck tool card", () => {
  function normalizedContext(envelope: unknown, input?: Record<string, unknown>, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
    return {
      ...context(normalizedToolCardParsedResult(envelope), livePendingAction, input),
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__force_landing_recheck")
    }
  }

  it.each([
    ["text content", { content: [{ type: "text", text: JSON.stringify(standardPayload()) }], structured_content: null }],
    ["structured content", { content: [], structured_content: standardPayload() }]
  ])("renders its linked Job and Markdown reason from a normalized %s envelope", (_label, envelope) => {
    render(<>{forceLandingRecheckCard.renderExpanded(normalizedContext(envelope, { job_id: 4222, reason: "**Checks** are stale." }))}</>)

    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByText("Checks", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("are stale.")).toBeInTheDocument()
  })

  it("renders every bulk Job with wrapping links and the live outcome", () => {
    const payload = {
      ...standardPayload({ message: "Force landing recheck for 3 Jobs?" }),
      pending_action_group_id: 88,
      member_count: 3
    }
    render(
      <>
        {forceLandingRecheckCard.renderExpanded(
          normalizedContext(
            payload,
            { job_ids: [41, 42, 43], reason: "Re-evaluate the landing blockers." },
            liveAction({
              detail:
                "- JOB-41 — observed state: approved; observed blocker: none; refreshed state: approved; refreshed blocker: none\n- JOB-42 — observed state: approved; observed blocker: dependencies; refreshed state: approved; refreshed blocker: dependencies\n- JOB-43 — observed state: landing; observed blocker: none; refreshed state: closed; refreshed blocker: none"
            })
          )
        )}
      </>
    )

    for (const id of [41, 42, 43]) expect(screen.getByRole("link", { name: `JOB-${id}` })).toHaveAttribute("href", `/jobs/${id}`)
    expect(screen.getByText("3 actions")).toBeInTheDocument()
    expect(screen.getByText("Force landing recheck for 3 Jobs?")).toBeInTheDocument()
    expect(screen.getByText("Landing recheck outcome")).toBeInTheDocument()
    expect(screen.getByText(/observed blocker: dependencies/)).toBeInTheDocument()
    expect(screen.getByText(/refreshed state: closed/)).toBeInTheDocument()
  })

  it("keeps requested Jobs visible for errors", () => {
    render(
      <>
        {forceLandingRecheckCard.renderExpanded(
          normalizedContext({ error: "invalid_request", message: "One or more Jobs could not be rechecked." }, { job_ids: [41, 404], reason: "Retry checks." })
        )}
      </>
    )

    expect(screen.getByText("invalid_request")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-41" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-404" })).toBeInTheDocument()
    expect(screen.getByText("Retry checks.")).toBeInTheDocument()
  })

  it("calls out missing input instead of inferring Jobs from the message", () => {
    render(<>{forceLandingRecheckCard.renderExpanded(normalizedContext(standardPayload({ message: "Force landing recheck for JOB-4222?" })))}</>)

    expect(screen.getByText("Not provided")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "JOB-4222" })).not.toBeInTheDocument()
  })
})

describe("mark_ci_repair_noop tool card", () => {
  function normalizedContext(envelope: unknown, input?: Record<string, unknown>): ToolCardContext {
    return {
      ...context(normalizedToolCardParsedResult(envelope), null, input),
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__mark_ci_repair_noop")
    }
  }

  it.each(["text content", "structured content"])("renders linked single targets and linkified prose from a normalized %s envelope", (label) => {
    const message = "RSpec failed: https://github.com/acme/widgets/actions/runs/123456789"
    const reason = "No progress after reviewing https://ci.example.test/builds/42."
    const payload = standardPayload({ message })
    const normalizedEnvelope =
      label === "structured content"
        ? { content: [], structured_content: payload }
        : { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }

    render(<>{markCiRepairNoopCard.renderExpanded(normalizedContext(normalizedEnvelope, { job_id: 4222, workflow_id: 8444, reason }))}</>)

    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByRole("link", { name: "WF-8444" })).toHaveAttribute("href", "/jobs/4222?tab=workflows#workflow-8444")
    expect(screen.getByRole("link", { name: "https://github.com/acme/widgets/actions/runs/123456789" })).toHaveAttribute(
      "href",
      "https://github.com/acme/widgets/actions/runs/123456789"
    )
    expect(screen.getByRole("link", { name: "https://ci.example.test/builds/42" })).toHaveAttribute("href", "https://ci.example.test/builds/42")
  })

  it("renders every bulk Workflow as a wrapping admin link", () => {
    const payload = {
      ...standardPayload({ message: "Mark 3 CI repairs as no-op?" }),
      pending_action_group_id: 88,
      member_count: 3
    }

    render(
      <>
        {markCiRepairNoopCard.renderExpanded(
          normalizedContext(payload, { workflow_ids: [101, "102", 103], reason: "The repairs made no branch or check progress." })
        )}
      </>
    )

    for (const id of [101, 102, 103]) {
      expect(screen.getByRole("link", { name: `WF-${id}` })).toHaveAttribute("href", `/admin/workflows/${id}`)
    }
    expect(screen.getByText("Workflows").parentElement).toHaveClass("min-w-0")
  })

  it("keeps input targets visible when the tool returns an error", () => {
    render(
      <>
        {markCiRepairNoopCard.renderExpanded(
          normalizedContext(
            { error: "invalid_request", message: "Workflow validation failed. See https://ci.example.test/help." },
            { job_id: 4222, workflow_id: 8444, reason: "**Investigate** the validation failure." }
          )
        )}
      </>
    )

    expect(screen.getByText("invalid_request")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByRole("link", { name: "WF-8444" })).toHaveAttribute("href", "/jobs/4222?tab=workflows#workflow-8444")
    expect(screen.getByRole("link", { name: "https://ci.example.test/help" })).toHaveAttribute("href", "https://ci.example.test/help")
    expect(screen.getByText("Investigate", { selector: "strong" })).toBeInTheDocument()
  })
})

describe("delegate_issue tool card", () => {
  function normalizedContext(envelope: unknown, input?: Record<string, unknown>, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
    return {
      ...context(normalizedToolCardParsedResult(envelope), livePendingAction, input),
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__delegate_issue")
    }
  }

  it.each([
    [
      "text content",
      {
        content: [{ type: "text", text: JSON.stringify(standardPayload({ message: "Delegate issue #73 in tkadauke/syrus to Syrus?" })) }],
        structured_content: null
      }
    ],
    ["structured content", { content: [], structured_content: standardPayload({ message: "Delegate issue #73 in tkadauke/syrus to Syrus?" }) }]
  ])("renders linked input context from a normalized %s envelope", (_label, envelope) => {
    render(<>{delegateIssueCard.renderExpanded(normalizedContext(envelope, { repository_id: 12, issue_number: 73 }))}</>)

    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/12")
    expect(screen.getByRole("link", { name: "#73" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/issues/73")
    expect(screen.getByText("Delegate issue #73 in tkadauke/syrus to Syrus?")).toBeInTheDocument()
  })

  it("shows the resulting Job after execution", () => {
    render(
      <>
        {delegateIssueCard.renderExpanded(
          normalizedContext(
            standardPayload({ message: "Delegate issue #73 in tkadauke/syrus to Syrus?" }),
            { repository_id: 12, issue_number: 73 },
            liveAction({
              state: "confirmed",
              resource_title: "Improve delegation",
              resource_url: "/jobs/7607"
            })
          )
        )}
      </>
    )

    expect(screen.getByText("Resulting Job")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7607" })).toHaveAttribute("href", "/jobs/7607")
    expect(screen.getByText("Improve delegation")).toBeInTheDocument()
    expect(screen.getByText("confirmed")).toBeInTheDocument()
  })

  it("keeps input context visible for errors", () => {
    render(
      <>
        {delegateIssueCard.renderExpanded(
          normalizedContext({ error: "issue_not_found", message: "The GitHub issue was not found." }, { repository_id: 12, issue_number: 404 })
        )}
      </>
    )

    expect(screen.getByText("issue_not_found")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository #12" })).toHaveAttribute("href", "/repositories/12")
    expect(screen.getByText("#404")).toBeInTheDocument()
  })

  it("calls out missing input instead of inferring issue identity from the message", () => {
    render(<>{delegateIssueCard.renderExpanded(normalizedContext(standardPayload({ message: "Delegate issue #73 in tkadauke/syrus to Syrus?" })))}</>)

    expect(screen.getAllByText("Not provided")).toHaveLength(2)
    expect(screen.queryByRole("link", { name: "#73" })).not.toBeInTheDocument()
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
    expect(parsePendingActionResult(context(bulkPayload))).toMatchObject({
      kind: "bulk",
      pendingActionId: "501",
      state: "pending",
      message: "Retry step 'graders' on 3 Workflows?",
      reason: null,
      memberCount: 3,
      groupId: "88",
      observed: undefined
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

    expect(screen.getByText("Pending action group #88")).toBeInTheDocument()
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
      current_pr: { number: 44, repository: "tkadauke/syrus" },
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
      destructiveConfirmation: null
    })
  })

  it("summarizes the collapsed row as a dry run for the target Job", () => {
    expect(summarize(evidencePayload)).toBe("Dry run: adopt_current_pr_head for JOB-4222")
  })

  it("renders the humanized action, linked entities, branch, and complete SHAs", () => {
    renderResult(evidencePayload)

    expect(screen.getByText("Dry run")).toBeInTheDocument()
    expect(screen.getByText("Adopt current pr head")).toBeInTheDocument()
    expect(screen.getAllByText("JOB-4222")).toHaveLength(2)
    expect(screen.getByText("syrus/direct-322")).toBeInTheDocument()
    expect(screen.getByText("abc123abc123abc123abc123")).toBeInTheDocument()
    expect(screen.getByText("def456def456def456def456")).toBeInTheDocument()
    expect(screen.getByText("111222111222111222111222")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /WF-26123/ })).toHaveAttribute("href", "/jobs/4222?tab=workflows#workflow-26123")
    expect(screen.getByRole("link", { name: "PR #44" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/44")
    expect(screen.getByRole("link", { name: "syrus/direct-322" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/syrus%2Fdirect-322")
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
  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(standardPayload()) }], structured_content: null }],
    ["structured content", { structured_content: standardPayload(), content: [] }]
  ])("parses the %s provider envelope through the shared normalizer", (_label, envelope) => {
    expect(parsePendingActionResult(context(normalizedToolCardParsedResult(envelope)))).toMatchObject({ pendingActionId: "501", state: "pending" })
  })

  it("uses input metadata when the result omits target context", () => {
    const result = renderResult(standardPayload(), null, {
      job_id: 4222,
      workflow_id: 26123,
      run_id: 99,
      reason: "**Operator** reason",
      blocker_key: "job:4222",
      instructions: "Run **carefully**"
    })
    expect(result).toMatchObject({ jobId: "4222", workflowId: "26123", runId: "99", reason: "**Operator** reason" })
    expect(screen.getByRole("link", { name: /JOB-4222/ })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByText("Operator", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("carefully", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("job:4222")).toBeInTheDocument()
  })

  it("tolerates undefined input on collapsed-summary paths", () => {
    expect(summarize(standardPayload())).toBe("Job rebase requires operator confirmation.")
  })

  it("renders structured errors and valid bases", () => {
    renderResult({ error: "invalid_base", message: "Choose another base", valid_bases: ["main", "release"] })
    expect(screen.getByText("invalid_base")).toBeInTheDocument()
    expect(screen.getByText("Choose another base")).toBeInTheDocument()
    expect(screen.getByText("main, release")).toBeInTheDocument()
  })

  it("recognizes non-evidence dry-run plan and eligibility bodies", () => {
    expect(parsePendingActionResult(context({ plan: { actions: [], branch_order: [] } }, null, { dry_run: true }))).toMatchObject({ kind: "dry_run_evidence" })
    expect(parsePendingActionResult(context({ status: "eligible", operation: "retire_terminal_work_unit" }, null, { dry_run: true }))).toMatchObject({
      kind: "dry_run_evidence",
      action: "retire_terminal_work_unit"
    })
  })

  it("renders live execution and resource details", () => {
    renderResult(
      standardPayload(),
      liveAction({
        execution_status: "failed",
        execution_step: "release locks",
        execution_error: "**Lock** failed",
        detail: "Affected two locks",
        resource_title: "Repair run",
        resource_url: "/admin/runs/99"
      })
    )
    expect(screen.getByText("release locks")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repair run" })).toHaveAttribute("href", "/admin/runs/99")
    expect(screen.getByText("Lock", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("Affected two locks")).toBeInTheDocument()
  })

  it("bounds long markdown messages with Show more", () => {
    renderResult(standardPayload({ message: `**Review**\n${"Long pending-action detail. ".repeat(80)}` }))
    expect(screen.getByText("Review", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

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

  it("uses the normalized tool name when an evidence payload omits its action name", () => {
    expect(parsePendingActionResult(context({ job_id: 4222, evidence: { remote_sha: "abc" } }))).toMatchObject({
      kind: "dry_run_evidence",
      action: "some_pending_action_tool"
    })
  })
})

describe("cancel_stale_work pending action card", () => {
  const input = {
    job_id: 4222,
    workflow_ids: [26123, 26124, 26125, 26126],
    run_ids: [99, 100, 101, 102],
    reconcile: false,
    reason: "These attempts are stale."
  }

  function cancelContext(parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
    return {
      toolName: "cancel_stale_work",
      input,
      resultBody: "",
      resultError: false,
      parsedResult,
      ...overrides
    }
  }

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(standardPayload({ reason: input.reason })) }], structured_content: null }],
    ["structured content", { structured_content: standardPayload({ reason: input.reason }), content: [] }]
  ])("renders linked input targets from a normalizer-built %s envelope", (_label, envelope) => {
    const toolContext = cancelContext(normalizedToolCardParsedResult(envelope))
    render(<>{cancelStaleWorkCard.renderExpanded(toolContext)}</>)

    expect(screen.getAllByRole("link", { name: /JOB-4222/ })).toHaveLength(1)
    expect(screen.getByRole("link", { name: /WF-26123/ })).toHaveAttribute("href", "/jobs/4222?tab=workflows#workflow-26123")
    expect(screen.getByRole("link", { name: /RUN-99/ })).toHaveAttribute("href", "/admin/runs/99")
    expect(screen.getByText("Reconcile after cancellation")).toBeInTheDocument()
    expect(screen.getByText("No")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /WF-26123/ }).closest(".flex-wrap")).not.toBeNull()
  })

  it("renders the Error: path with the attempted targets", () => {
    const envelope = { content: [{ type: "text", text: "Error: workflow is already terminal" }], structured_content: null }
    const toolContext = cancelContext(normalizedToolCardParsedResult(envelope), {
      resultBody: JSON.stringify(envelope),
      resultError: true
    })

    expect(cancelStaleWorkCard.collapsedSummary?.(toolContext)).toContain("workflow is already terminal")
    render(<>{cancelStaleWorkCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("workflow is already terminal")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /WF-26124/ })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /RUN-100/ })).toBeInTheDocument()
  })

  it("keeps a recorded pending action useful when its input is missing", () => {
    const toolContext = cancelContext(standardPayload(), { input: undefined })
    render(<>{cancelStaleWorkCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Request details are unavailable for this recorded tool call.")).toBeInTheDocument()
  })

  it("shows empty target lists and the default reconcile behavior", () => {
    const toolContext = cancelContext(standardPayload(), { input: { job_id: 4222, reason: "Nothing selected." } })
    render(<>{cancelStaleWorkCard.renderExpanded(toolContext)}</>)

    expect(screen.getAllByText("None")).toHaveLength(2)
    expect(screen.getByText("Yes (default)")).toBeInTheDocument()
  })
})

describe("pending action tool card: configured inputs and envelopes", () => {
  const card = pendingActionToolCard("admin_pause_runs", {
    inputFields: [
      { key: "workflow_ids", label: "Workflows", format: "entity_list", entityKind: "workflow", hrefPrefix: "/admin/workflows" },
      { key: "provider", format: "badge" },
      { key: "positive_evidence", format: "markdown" }
    ]
  })

  it("normalizes a namespaced raw name and structured_content result", () => {
    const normalizedContext = context(normalizedToolCardParsedResult({ structured_content: standardPayload() }))
    normalizedContext.toolName = normalizedToolName("mcp__syrus-chat-sidecar__admin_pause_runs")
    expect(normalizedContext.toolName).toBe("admin_pause_runs")
    expect(card.collapsedSummary?.(normalizedContext)).toBe("Job rebase requires operator confirmation.")
  })

  it("normalizes content text JSON and renders configured bulk targets", () => {
    const normalizedContext = context(normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(standardPayload()) }] }))
    normalizedContext.input = { workflow_ids: [41, 42], provider: "codex" }
    render(<>{card.renderExpanded(normalizedContext)}</>)
    expect(screen.getByRole("link", { name: "WF-41" })).toHaveAttribute("href", "/admin/workflows/41")
    expect(screen.getByRole("link", { name: "WF-42" })).toHaveAttribute("href", "/admin/workflows/42")
    expect(screen.getByText("codex")).toBeInTheDocument()
  })

  it("renders tool-error results without requiring a pending action id", () => {
    const errorContext = context({ content: [{ type: "text", text: "Provider unavailable" }] })
    errorContext.resultError = true
    render(<>{card.renderExpanded(errorContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Provider unavailable")).toBeInTheDocument()
  })

  it("links entity references and email addresses embedded in result prose", () => {
    renderResult(standardPayload({ message: "Pause workflow #71 for user #9 (operator@example.com) after process #4." }))
    expect(screen.getByRole("link", { name: "workflow #71" })).toHaveAttribute("href", "/admin/workflows/71")
    expect(screen.getByRole("link", { name: "user #9" })).toHaveAttribute("href", "/admin/users/9")
    expect(screen.getByRole("link", { name: "process #4" })).toHaveAttribute("href", "/admin/processes/4")
    expect(screen.getByRole("link", { name: "operator@example.com" })).toHaveAttribute("href", "mailto:operator@example.com")
  })
})

