import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import restackEpicToolCard, { examples } from "./restack_epic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "restack_epic", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const plan = {
  epic_id: 91,
  slug: "stack-repair",
  strategy: "dependency_topology",
  repository_slug: "tkadauke/syrus",
  branch_order: [
    {
      job_id: 101,
      slug: "stack-root",
      branch_name: "syrus/a-very-long-stack-root-branch-name",
      current_base: "main",
      target_base: "syrus/parent",
      target_parent_job_id: 100,
      pr_number: 501,
      commits_behind: 2,
      state: "approved",
      checks_state: "success",
      mergeable_state: "clean",
      repair_reasons: ["base_ref", "behind_base"]
    }
  ],
  actions: [
    {
      job_id: 101,
      slug: "stack-root",
      branch_name: "syrus/a-very-long-stack-root-branch-name",
      pr_number: 501,
      state: "approved",
      repair_reasons: ["base_ref", "behind_base"]
    }
  ],
  skipped_nodes: [{ job_id: 102, slug: "busy-child", branch_name: "syrus/busy-child", pr_number: 502, state: "running", reason: "active_rebase_workflow" }],
  expected_landing_impact: "Updates parents and dispatches **one root**."
}

describe("restack_epic tool card", () => {
  it("registers the MCP name and normalizes prefixed names", () => {
    expect(restackEpicToolCard.toolName).toBe("restack_epic")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__restack_epic")).toBe("restack_epic")
  })

  it("renders a dry-run plan from a content text envelope", () => {
    const parsedResult = normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify({ plan }) }] })
    const cardContext = context({ input: { epic_id: 91, reason: "Repair **branch drift**.", dry_run: true }, parsedResult })
    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toBe("Restack EPIC-91 (stack-repair) · dry-run plan · 1 branches · 1 skipped")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByRole("link", { name: /EPIC-91 \(stack-repair\)/ })).toHaveAttribute("href", "/epics/91")
    expect(screen.getAllByRole("link", { name: /JOB-101 \(stack-root\)/ })[0]).toHaveAttribute("href", "/jobs/101")
    expect(screen.getAllByRole("link", { name: "PR #501" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/501")
    expect(screen.getAllByRole("link", { name: "syrus/a-very-long-stack-root-branch-name" })[0]).toHaveClass("break-all", "min-h-11")
    expect(screen.getByText("main → syrus/parent")).toBeInTheDocument()
    expect(screen.getByText("Commits behind").closest("dl")).toHaveClass("grid-cols-[repeat(auto-fit,minmax(10rem,1fr))]")
    expect(screen.getAllByText("behind_base").length).toBeGreaterThan(0)
    expect(screen.getByText("active_rebase_workflow")).toBeInTheDocument()
    expect(screen.getByText(/Repair/)).toBeInTheDocument()
    expect(screen.getByText(/Updates parents/)).toBeInTheDocument()
  })

  it("renders a structured_content no-op envelope", () => {
    const parsedResult = normalizedToolCardParsedResult({
      structured_content: { plan: { ...plan, branch_order: [], actions: [], skipped_nodes: [] }, no_op: true, message: "Nothing **needs changing**." }
    })
    const cardContext = context({ input: { epic_id: 91, dry_run: true }, parsedResult })
    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toContain("nothing to do")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getAllByText(/Nothing/).length).toBeGreaterThan(0)
    expect(screen.getByText("no branches are in the restack plan.", { exact: false })).toBeInTheDocument()
  })

  it("uses live pending-action state and reason", () => {
    const cardContext = context({
      input: { epic_id: 91, reason: "Original reason." },
      parsedResult: { pending_action_id: 77, state: "pending", plan },
      livePendingAction: {
        id: 77,
        action: "restack_epic",
        state: "confirmed",
        label: "Restack Epic",
        detail: null,
        reason: "Approved after review.",
        app_confirm_path: "/chats/1/pending_actions/77/confirm",
        app_reject_path: "/chats/1/pending_actions/77/reject"
      }
    })
    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toContain("confirmed")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Approved after review.")).toBeInTheDocument()
    expect(screen.getByText("pending #77")).toBeInTheDocument()
  })

  it("renders structured errors with recovery guidance", () => {
    const cardContext = context({
      input: { epic_id: 404 },
      resultError: true,
      resultBody: JSON.stringify({ code: "invalid_params", message: "epic not found: 404" }),
      parsedResult: { code: "invalid_params", message: "epic not found: 404" }
    })
    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toContain("Restack Epic failed")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Restack Epic failed")).toBeInTheDocument()
    expect(screen.getByText("Restack EPIC-404")).toBeInTheDocument()
    expect(screen.getByText(/preview the restack again/i)).toBeInTheDocument()
  })

  it("provides catalog examples for all required states", () => {
    expect(examples.map(({ id }) => id)).toEqual(["dry_run", "no_op", "pending", "live_confirmed", "error"])
  })
})
