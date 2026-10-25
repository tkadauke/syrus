import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import manualAgenticRunToolCard, { examples } from "./manual_agentic_run"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "manual_agentic_run",
    input: {
      job_id: 4222,
      base: "failed_workflow_workspace",
      failed_workflow_id: 61270,
      instructions: `**Repair** the partial implementation. ${"Keep the public API stable. ".repeat(30)}`,
      reason: `The failed workflow contains useful work. ${"Review it carefully. ".repeat(30)}`,
      push: false
    },
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const pending = {
  pending_confirmation_id: 501,
  pending_action_id: 501,
  state: "pending",
  message: "Start a manual agentic run for repair-ci from failed workflow workspace; push=false?"
}

describe("manual_agentic_run tool card", () => {
  it("registers under the normalized MCP tool name and supplies catalog examples", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__manual_agentic_run")).toBe("manual_agentic_run")
    expect(manualAgenticRunToolCard.toolName).toBe("manual_agentic_run")
    expect(examples.map((example) => example.id)).toEqual([
      "pending_confirmation",
      "missing_reason",
      "fresh_checkout_push_not_supported",
      "missing_pr_branch",
      "missing_pr"
    ])
  })

  it.each([
    ["text content", { content: [{ type: "text", text: JSON.stringify(pending) }] }],
    ["structured content", { structured_content: pending }]
  ])("renders pending input details from a normalizer-built %s envelope", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(manualAgenticRunToolCard.collapsedSummary?.(context({ parsedResult }))).toContain("Start a manual agentic run")

    render(<>{manualAgenticRunToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByRole("link", { name: "WF-61270" })).toHaveAttribute("href", "/jobs/4222?tab=workflows#workflow-61270")
    expect(screen.getByText("failed_workflow_workspace")).toBeInTheDocument()
    expect(screen.getByText("false")).toBeInTheDocument()
    expect(screen.getByText(/temporary workspace is deleted/i)).toHaveTextContent("get_job_diff")
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
  })

  it.each([
    ["missing_reason", "reason is required", undefined],
    [
      "fresh_checkout_push_not_supported",
      "fresh_checkout cannot push to the existing PR branch; use current_pr_branch or set push=false.",
      ["current_pr_branch", "fresh_checkout", "failed_workflow_workspace"]
    ],
    ["missing_pr_branch", "push requires an existing PR branch.", undefined],
    ["missing_pr", "push requires an existing PR.", undefined]
  ])("renders the %s structured error", (error, message, validBases) => {
    const envelope = { content: [{ type: "text", text: JSON.stringify({ error, message, valid_bases: validBases }) }] }
    const parsedResult = normalizedToolCardParsedResult(envelope)
    const errorContext = context({ parsedResult, resultError: true })

    expect(manualAgenticRunToolCard.collapsedSummary?.(errorContext)).toBe(`Manual agentic run failed: ${message}`)
    render(<>{manualAgenticRunToolCard.renderExpanded(errorContext)}</>)

    expect(screen.getByText(error)).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
    for (const base of validBases || []) expect(screen.getAllByText(base).length).toBeGreaterThan(0)
  })
})
