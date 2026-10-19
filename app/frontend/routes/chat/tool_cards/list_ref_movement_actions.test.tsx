import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listRefMovementActionsToolCard, { examples } from "./list_ref_movement_actions"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_ref_movement_actions", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_ref_movement_actions tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listRefMovementActionsToolCard.toolName).toBe("list_ref_movement_actions")
    expect(normalizedToolName("mcp__syrus-mcp-sidecar__list_ref_movement_actions")).toBe(listRefMovementActionsToolCard.toolName)
  })

  it("summarizes availability as available/total", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "auto", grade_phases: [], available: true, blocked_reason: null },
        {
          name: "submit_branch_upstream",
          enabled: false,
          mode: null,
          grade_phases: [],
          available: false,
          blocked_reason: "not enabled in delivery.ref_movement_actions"
        }
      ]
    }
    expect(listRefMovementActionsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1/2 ref movement actions available")
  })

  it("renders an empty state when none are configured", () => {
    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: { repository: "tkadauke/syrus", ref_movement_actions: [] } }))}</>)
    expect(screen.getByText("No ref movement actions configured.")).toBeInTheDocument()
  })

  it("renders a blocked reason for an unavailable action", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      repository_id: 7,
      job_id: 7551,
      ref_movement_actions: [
        {
          name: "send_job_upstream",
          enabled: false,
          mode: "auto",
          grade_phases: ["review", "landing"],
          available: false,
          blocked_reason: "**Job ID** is required"
        }
      ]
    }

    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("send_job_upstream")).toBeInTheDocument()
    expect(screen.getByText("disabled")).toBeInTheDocument()
    expect(screen.getByText("review")).toBeInTheDocument()
    expect(screen.getByText("landing")).toBeInTheDocument()
    expect(screen.getByText("Job ID").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByRole("link", { name: "JOB-7551" })).toHaveAttribute("href", "/jobs/7551")
    expect(screen.getAllByText("Action").some((element) => element.classList.contains("sm:hidden"))).toBe(true)
  })

  it("uses the shared normalizer for content text and structured content envelopes", () => {
    const payload = {
      repository: "tkadauke/syrus",
      ref_movement_actions: [
        { name: "submit_branch_upstream", enabled: true, mode: "manual_pr", grade_phases: ["landing"], available: true, blocked_reason: null }
      ]
    }
    const contentEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
    const structuredEnvelope = { content: [{ type: "text", text: "stale" }], structured_content: payload }

    expect(listRefMovementActionsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(contentEnvelope) }))).toBe(
      "1/1 ref movement action available"
    )
    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))}</>)
    expect(screen.getByText("submit_branch_upstream")).toBeInTheDocument()
  })

  it("expands a long markdown blocked reason", () => {
    const blockedReason = `**Configuration issue.** ${"More details are required. ".repeat(80)}`
    const parsedResult = {
      repository: "tkadauke/syrus",
      ref_movement_actions: [{ name: "send_job_upstream", enabled: true, mode: "auto", grade_phases: [], available: false, blocked_reason: blockedReason }]
    }
    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog", { name: "Blocked reason for send_job_upstream" })).getByText("Configuration issue.").tagName).toBe("STRONG")
  })

  it("renders an explicit error state", () => {
    const errorContext = context({ resultError: true, resultBody: "Error: no repository attached" })
    expect(listRefMovementActionsToolCard.collapsedSummary?.(errorContext)).toBe("Ref movement actions failed")
    render(<>{listRefMovementActionsToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Error: no repository attached")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listRefMovementActionsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("includes catalog examples for populated, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["mixed_availability", "no_actions", "tool_error"])
  })
})
