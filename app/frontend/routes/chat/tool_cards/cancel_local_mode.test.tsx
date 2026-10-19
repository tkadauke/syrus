import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import cancelLocalModeToolCard, { examples } from "./cancel_local_mode"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "cancel_local_mode", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

function normalizedContext(rawName: string, parsedResult: unknown, overrides: Partial<ToolCardContext> = {}) {
  return context({
    toolName: normalizedToolName(rawName),
    parsedResult: normalizedToolCardParsedResult(parsedResult),
    ...overrides
  })
}

describe("cancel_local_mode tool card", () => {
  it("registers examples for implemented, closed, failure, and empty outcomes", () => {
    expect(examples.map((example) => example.id)).toEqual([
      "returned_to_implemented",
      "returned_to_closed",
      "failure",
      "empty"
    ])
  })

  it("renders a content[0].text envelope from an mcp-prefixed tool name", () => {
    const payload = { job_id: 51, job_state: "implemented", message: "Returned `JOB-51` to implemented." }
    const toolContext = normalizedContext("mcp__syrus-chat-sidecar__cancel_local_mode", {
      content: [{ type: "text", text: JSON.stringify(payload) }],
      structured_content: null
    }, { input: { job_id: 51 } })

    expect(toolContext.toolName).toBe("cancel_local_mode")
    render(<>{cancelLocalModeToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getAllByRole("link", { name: "JOB-51" })[0]).toHaveAttribute("href", "/jobs/51")
    expect(screen.getByText("implemented", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("JOB-51", { selector: "code" })).toBeInTheDocument()
  })

  it("renders a structured_content envelope and closed outcome", () => {
    const toolContext = normalizedContext("mcp__custom__cancel_local_mode", {
      content: [{ type: "text", text: "ignored" }],
      structured_content: { job_id: 52, job_state: "closed", message: "Cancellation complete." }
    }, { input: { job_id: "52" } })

    render(<>{cancelLocalModeToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("closed", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("Requested Job")).toBeInTheDocument()
  })

  it("owns error and empty results while retaining input-derived Job context", () => {
    const failure = normalizedContext("mcp__syrus-chat-sidecar__cancel_local_mode", null, {
      input: { job_id: 53 },
      resultBody: "Error: JOB-53 is not in Local Mode.",
      resultError: true
    })

    render(<>{cancelLocalModeToolCard.renderExpanded(failure)}</>)
    expect(screen.getByText("Cancel Local Mode failed")).toBeInTheDocument()
    expect(screen.getByText("Cancel Local Mode for JOB-53")).toBeInTheDocument()

    const empty = context({ input: { job_id: 54 } })
    expect(cancelLocalModeToolCard.collapsedSummary?.(empty)).toBe("No outcome returned for JOB-54")
    render(<>{cancelLocalModeToolCard.renderExpanded(empty)}</>)
    expect(screen.getByText(/No job outcome was returned/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-54" })).toHaveAttribute("href", "/jobs/54")
  })
})
