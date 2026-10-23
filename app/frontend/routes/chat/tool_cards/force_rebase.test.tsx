import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolName, normalizedToolCardParsedResult } from "../toolRendering"
import forceRebaseToolCard, { examples } from "./force_rebase"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "force_rebase",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const plan = {
  job_id: 4222,
  slug: "repair-ci",
  repository_slug: "tkadauke/syrus",
  state: "approved",
  branch_name: "syrus/direct-4222",
  current_base: "main",
  target_base: "main",
  pr_number: 314,
  commits_behind: 3,
  checks_state: "failure",
  mergeable_state: "dirty",
  landing_queue_position: 4,
  workflow_trigger_kind: "rebase",
  bypass_front_of_queue: true,
  expected_landing_impact: "successful rebase will retry landing immediately",
  warnings: ["failing_or_pending_checks", "dirty_mergeability", "behind_base", "not_front_of_queue"]
}

describe("force_rebase tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(forceRebaseToolCard.toolName).toBe("force_rebase")
  })

  it("summarizes a pending force rebase with target Job, PR, and state", () => {
    const parsedResult = {
      pending_confirmation_id: 77,
      pending_action_id: 77,
      state: "pending",
      reason: "Bypass queue position.",
      message: "Force rebase for repair-ci? Target base: main.",
      plan
    }

    expect(forceRebaseToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Force rebase pending confirmation · JOB-4222 (repair-ci) PR #314 · syrus/direct-4222"
    )
  })

  it("renders target identifiers, audit fields, downstream workflow, warnings, and retry guidance", () => {
    const parsedResult = {
      pending_confirmation_id: 77,
      pending_action_id: 77,
      state: "pending",
      reason: "Bypass queue position.",
      message: "Force rebase for repair-ci? Target base: main.",
      plan
    }

    render(<>{forceRebaseToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Force rebase")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("pending #77")).toBeInTheDocument()
    expect(screen.getByText("Bypass queue position.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /JOB-4222 \(repair-ci\)/ })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByRole("link", { name: "PR #314" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/314")
    const branch = screen.getByRole("link", { name: "syrus/direct-4222" })
    expect(branch).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/syrus/direct-4222")
    expect(branch.querySelector("span")).toHaveClass("break-all")
    expect(screen.getByText("successful rebase will retry landing immediately")).toBeInTheDocument()
    expect(screen.getByText("not_front_of_queue")).toBeInTheDocument()
    expect(screen.getByText(/Waiting for operator confirmation/i)).toBeInTheDocument()
  })

  it("renders an already-current dry-run plan as a no-op", () => {
    const parsedResult = {
      plan: {
        ...plan,
        job_id: 4223,
        slug: "already-current",
        branch_name: "syrus/direct-4223",
        pr_number: 315,
        commits_behind: 0,
        checks_state: "success",
        mergeable_state: "clean",
        landing_queue_position: 1,
        warnings: []
      }
    }

    expect(forceRebaseToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Force rebase plan reviewed · JOB-4223 (already-current) PR #315 · syrus/direct-4223 · already current"
    )
    render(<>{forceRebaseToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getAllByText("already current").length).toBeGreaterThan(0)
    expect(screen.getByText(/Review the plan before confirming/i)).toBeInTheDocument()
  })

  it("uses live pending-action state for rejected and confirmed action summaries", () => {
    const parsedResult = {
      pending_confirmation_id: 77,
      pending_action_id: 77,
      state: "pending",
      reason: "Bypass queue position.",
      message: "Force rebase for repair-ci? Target base: main.",
      plan
    }

    expect(
      forceRebaseToolCard.collapsedSummary?.(
        context({
          parsedResult,
          livePendingAction: {
            id: 77,
            action: "force_rebase",
            state: "rejected",
            label: "Force rebase repair-ci",
            detail: "job_id: 4222",
            reason: "Needs a safer reason.",
            app_confirm_path: "/confirm",
            app_reject_path: "/reject"
          }
        })
      )
    ).toBe("Force rebase request rejected · JOB-4222 (repair-ci) PR #314 · syrus/direct-4222")

    expect(
      forceRebaseToolCard.collapsedSummary?.(
        context({
          parsedResult,
          livePendingAction: {
            id: 77,
            action: "force_rebase",
            state: "confirmed",
            label: "Force rebase repair-ci",
            detail: "job_id: 4222",
            reason: "Bypass queue position.",
            app_confirm_path: "/confirm",
            app_reject_path: "/reject"
          }
        })
      )
    ).toBe("Force rebase workflow queued · JOB-4222 (repair-ci) PR #314 · syrus/direct-4222")
  })

  it("shows live confirmation, execution failure, and linked pending-action outcomes", () => {
    const parsedResult = {
      pending_action_group_id: 15,
      pending_action_id: 77,
      state: "pending",
      reason: "**Audit** reason",
      message: "Force rebase with **care**.",
      plan
    }
    const livePendingAction = {
      id: 77,
      action: "force_rebase",
      state: "failed" as const,
      label: "Force rebase repair-ci",
      detail: "job_id: 4222",
      reason: "**Updated** audit reason",
      execution_status: "failed",
      execution_error: "Branch update failed after confirmation.",
      app_confirm_path: "/api/v1/app/chats/12/pending_actions/77/confirm",
      app_reject_path: "/api/v1/app/chats/12/pending_actions/77/reject"
    }

    render(<>{forceRebaseToolCard.renderExpanded(context({ parsedResult, livePendingAction }))}</>)

    expect(screen.getByText("outcome: failed")).toBeInTheDocument()
    expect(screen.getByText("Branch update failed after confirmation.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "pending #77" })).toHaveAttribute("href", "/chats/12#pending-action-77")
    expect(screen.getByRole("link", { name: "group #15" })).toHaveAttribute("href", "/chats/12#pending-action-group-15")
    expect(screen.getByText("Updated").tagName).toBe("STRONG")
    expect(screen.getByText("care").tagName).toBe("STRONG")
  })

  it("uses shared provider normalizers for MCP names and result envelopes", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__force_rebase")).toBe("force_rebase")

    const envelopes = [
      { content: [{ type: "text", text: JSON.stringify({ plan }) }] },
      { structured_content: { plans: [plan, { ...plan, job_id: 4223, slug: "second" }] } }
    ]
    const summaries = envelopes.map((envelope) => forceRebaseToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(envelope) })))

    expect(summaries[0]).toContain("JOB-4222")
    expect(summaries[1]).toContain("JOB-4222")
  })

  it("renders long markdown fields as bounded previews with Show more controls", () => {
    const longMarkdown = `**Important** ${"downstream impact ".repeat(40)}`
    render(
      <>
        {forceRebaseToolCard.renderExpanded(
          context({
            parsedResult: {
              pending_action_id: 77,
              state: "pending",
              message: longMarkdown,
              reason: longMarkdown,
              plan: { ...plan, expected_landing_impact: longMarkdown }
            }
          })
        )}
      </>
    )

    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(3)
    expect(screen.getAllByTestId("markdown-preview-content")).toHaveLength(3)
  })

  it("uses the shared failure card for conflict or permission failures", () => {
    const failure = context({
      input: { job_id: 4224, reason: "Repair branch drift." },
      resultBody: "A rebase is already in progress - wait for it to finish.",
      resultError: true
    })

    expect(forceRebaseToolCard.collapsedSummary?.(failure)).toBe("Force rebase failed: A rebase is already in progress - wait for it to finish.")
    render(<>{forceRebaseToolCard.renderExpanded(failure)}</>)

    expect(screen.getByText("Force rebase failed")).toBeInTheDocument()
    expect(screen.getByText("Force rebase JOB-4224")).toBeInTheDocument()
    const recovery = screen.getByText(/Check whether a rebase or merge-train workflow is already active/i)
    expect(recovery).toBeInTheDocument()
    expect(recovery).toHaveClass("break-words")
    expect(recovery).not.toHaveClass("truncate")
  })

  it("renders grouped pending actions with all target plans", () => {
    const parsedResult = {
      pending_action_group_id: 15,
      pending_action_id: 81,
      pending_confirmation_id: 81,
      state: "pending",
      member_count: 2,
      message: "Force rebase for 2 Jobs?",
      reason: "Both branches drifted behind the same base rewrite.",
      plans: [
        { ...plan, job_id: 4225, slug: "first-branch", branch_name: "syrus/direct-4225", pr_number: 316 },
        { ...plan, job_id: 4226, slug: "second-branch", branch_name: "syrus/direct-4226", pr_number: 317 }
      ]
    }

    render(<>{forceRebaseToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("group #15")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
    expect(screen.getByText("Both branches drifted behind the same base rewrite.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /JOB-4225 \(first-branch\)/ })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /JOB-4226 \(second-branch\)/ })).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(forceRebaseToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(forceRebaseToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("includes catalog examples for required scenarios", () => {
    expect(examples.map((example) => example.id)).toEqual([
      "requested",
      "executed_live_action",
      "already_current_noop",
      "conflict_failure",
      "permission_pending_action"
    ])
  })
})
