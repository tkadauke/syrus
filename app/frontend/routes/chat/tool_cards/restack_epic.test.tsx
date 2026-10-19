import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { pluginToolCardRendererFor } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import restackEpicToolCard, { examples } from "./restack_epic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "restack_epic", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const plan = {
  epic_id: 91,
  slug: "stacked-delivery",
  strategy: "dependency_topology",
  branch_order: [
    {
      job_id: 501,
      slug: "root-change",
      state: "approved",
      branch_name: "syrus/root-with-an-extremely-long-branch-name-that-must-wrap",
      current_base: "main",
      target_base: "main",
      target_parent_job_id: null,
      pr_number: 71,
      commits_behind: 0,
      checks_state: "success",
      mergeable_state: "clean",
      current_parent_job_id: null,
      repair_reasons: []
    },
    {
      job_id: 502,
      slug: "child-change",
      state: "approved",
      branch_name: "syrus/child",
      current_base: "main",
      target_base: "syrus/root-with-an-extremely-long-branch-name-that-must-wrap",
      target_parent_job_id: 501,
      pr_number: 72,
      commits_behind: 3,
      checks_state: "pending",
      mergeable_state: "clean",
      current_parent_job_id: null,
      repair_reasons: ["parent_metadata", "base_ref", "behind_base"]
    }
  ],
  actions: [
    {
      job_id: 502,
      slug: "child-change",
      state: "approved",
      branch_name: "syrus/child",
      pr_number: 72,
      repair_reasons: ["parent_metadata", "base_ref", "behind_base"]
    }
  ],
  skipped_nodes: [{ job_id: 503, slug: "closed-change", state: "closed", branch_name: "syrus/closed", pr_number: 73, reason: "closed" }],
  expected_landing_impact: "Updates stack parents and dispatches **one rebase root**."
}

describe("restack_epic tool card", () => {
  it("registers for the normalized mcp-prefixed tool name", () => {
    const normalized = normalizedToolName("mcp__syrus-chat-sidecar__restack_epic")

    expect(normalized).toBe("restack_epic")
    expect(pluginToolCardRendererFor(normalized)).toBe(restackEpicToolCard)
  })

  it("renders a content[0].text dry-run envelope with ordered branches, actions, skipped nodes, and links", () => {
    const envelope = { content: [{ type: "text", text: JSON.stringify({ plan }) }], structured_content: null }
    const parsedResult = normalizedToolCardParsedResult(envelope)
    const cardContext = context({
      input: { epic_id: 91, dry_run: true, reason: "Repair **stack topology**.", repository_slug: "tkadauke/syrus" },
      parsedResult
    })

    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toBe("Restack EPIC-91 · dry run · 1 action")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("link", { name: /EPIC-91/ })).toHaveAttribute("href", "/epics/91")
    expect(screen.getByText("dependency topology")).toBeInTheDocument()
    expect(screen.getByText("stack topology")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: /JOB-502/ }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: /PR #72/ })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/72")
    expect(screen.getByText(/main → syrus\/root/)).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("parent metadata")).toBeInTheDocument()
    expect(screen.getAllByText("closed").length).toBeGreaterThan(0)
    expect(screen.getByText("one rebase root")).toBeInTheDocument()
    expect(screen.getByText(plan.branch_order[0].branch_name)).toHaveClass("break-all")
  })

  it("prefers a structured_content no-op envelope and renders its message", () => {
    const payload = {
      plan: { ...plan, actions: [], expected_landing_impact: "No **landing work** is expected." },
      no_op: true,
      message: "No open child PR branches need **restacking**."
    }
    const parsedResult = normalizedToolCardParsedResult({
      content: [{ type: "text", text: JSON.stringify({ plan }) }],
      structured_content: payload
    })
    const cardContext = context({ input: { epic_id: 91 }, parsedResult })

    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toBe("Restack EPIC-91 · nothing to do")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("no op")).toBeInTheDocument()
    expect(screen.getByText("restacking")).toBeInTheDocument()
    expect(screen.getByText("landing work")).toBeInTheDocument()
  })

  it("uses live pending-action state and reason when the result contains no plan", () => {
    const parsedResult = { pending_action_id: 812, pending_confirmation_id: 812, state: "pending", message: "Restack stacked-delivery?" }
    const cardContext = context({
      input: { epic_id: 91, reason: "Original reason" },
      parsedResult,
      livePendingAction: {
        id: 812,
        action: "restack_epic",
        state: "confirmed",
        label: "Restack stacked-delivery",
        detail: "epic_id: 91",
        reason: "Approved **after review**.",
        app_confirm_path: "/confirm",
        app_reject_path: "/reject"
      }
    })

    expect(restackEpicToolCard.collapsedSummary?.(cardContext)).toBe("Restack EPIC-91 · confirmed")
    render(<>{restackEpicToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("pending #812")).toBeInTheDocument()
    expect(screen.getByText("after review")).toBeInTheDocument()
    expect(screen.getByText(/full plan is stored with the pending action/i)).toBeInTheDocument()
  })

  it("renders structured JSON errors through the shared failure card", () => {
    const failed = context({ input: { epic_id: 999 }, parsedResult: { error: "epic not found: 999", code: "invalid_request" }, resultError: true })

    expect(restackEpicToolCard.collapsedSummary?.(failed)).toBe("Restack epic failed: epic not found: 999")
    render(<>{restackEpicToolCard.renderExpanded(failed)}</>)

    expect(screen.getByText("Restack epic failed")).toBeInTheDocument()
    expect(screen.getByText("Restack EPIC-999")).toBeInTheDocument()
    expect(screen.getByText("invalid_request")).toBeInTheDocument()
  })

  it("returns null for malformed results and exposes catalog examples", () => {
    expect(restackEpicToolCard.renderExpanded(context({ parsedResult: { unexpected: true } }))).toBeNull()
    expect(examples.map((example) => example.id)).toEqual(["dry_run", "nothing_to_do", "pending", "error"])
  })
})
