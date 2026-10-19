import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listRefMovementActionsToolCard, { examples } from "./list_ref_movement_actions"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_ref_movement_actions", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const RESULT = {
  repository: "tkadauke/syrus",
  job_id: 4225,
  ref_movement_actions: [
    { name: "send_job_upstream", enabled: true, mode: "auto", grade_phases: ["test", "review"], available: true, blocked_reason: null },
    { name: "submit_branch_upstream", enabled: false, mode: null, grade_phases: [], available: false, blocked_reason: "Blocked by **policy**.\n".repeat(12) }
  ]
}

describe("list_ref_movement_actions tool card", () => {
  it("registers under the provider-agnostic MCP tool name", () => {
    expect(normalizedToolName("mcp__syrus_chat__list_ref_movement_actions")).toBe(listRefMovementActionsToolCard.toolName)
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(RESULT) }] }],
    ["structured content", { structured_content: RESULT }]
  ])("renders shared-normalizer %s envelopes", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(listRefMovementActionsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1/2 ref movement actions available")
    const { container } = render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("link", { name: /tkadauke\/syrus/ })).toHaveAttribute("href", "/repositories?search=tkadauke%2Fsyrus")
    expect(screen.getByRole("link", { name: /JOB-4225/ })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByText("enabled")).toBeInTheDocument()
    expect(screen.getByText("disabled")).toBeInTheDocument()
    expect(screen.getByText("test")).toBeInTheDocument()
    expect(screen.getByText("review")).toBeInTheDocument()
    expect(container.querySelector("table")).toHaveClass("block", "sm:table")
  })

  it("renders blocked reasons as truncated Markdown with a full-content dialog", () => {
    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: RESULT }))}</>)
    expect(screen.getAllByText("policy").every((element) => element.tagName === "STRONG")).toBe(true)
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Blocked reason" })).toBeInTheDocument()
  })

  it("renders scope and an empty state when none are configured", () => {
    render(
      <>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: { repository: "tkadauke/syrus", job_id: null, ref_movement_actions: [] } }))}</>
    )
    expect(screen.getByText("all jobs")).toBeInTheDocument()
    expect(screen.getByText("No ref movement actions configured.")).toBeInTheDocument()
  })

  it("falls back to the shared error presentation for errors and malformed results", () => {
    const errorContext = context({ resultError: true, parsedResult: { error: "no repository attached" } })
    expect(listRefMovementActionsToolCard.collapsedSummary?.(errorContext)).toBeNull()
    expect(listRefMovementActionsToolCard.renderExpanded(errorContext)).toBeNull()
    expect(listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("exports populated and empty catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["job_scoped_actions", "no_actions"])
  })
})
