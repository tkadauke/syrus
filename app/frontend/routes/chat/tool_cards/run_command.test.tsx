import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import runCommandToolCard from "./run_command"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "run_command", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("run_command tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(runCommandToolCard.toolName).toBe("run_command")
  })

  it("summarizes a successful command", () => {
    const parsedResult = { stdout: "ok\n", stderr: "", exit_code: 0 }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command succeeded (exit 0)")
  })

  it("summarizes and renders command failure output (non-zero exit is a successful tool call, not a tool error)", () => {
    const parsedResult = { stdout: "", stderr: "bundle: command not found\n", exit_code: 127 }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command failed (exit 127)")

    render(<>{runCommandToolCard.renderExpanded(context({ parsedResult, input: { command: "bundle exec rspec" } }))}</>)

    expect(screen.getByText("exit 127")).toBeInTheDocument()
    expect(screen.getByText("bundle exec rspec")).toBeInTheDocument()
    expect(screen.getByText("stderr")).toBeInTheDocument()
    expect(screen.queryByText("stdout")).not.toBeInTheDocument()
  })

  it("summarizes a killed command", () => {
    const parsedResult = { stdout: "", stderr: "", exit_code: 0, killed: true }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command killed (timeout)")

    render(<>{runCommandToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("killed")).toBeInTheDocument()
    expect(screen.getByText("No output.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(runCommandToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
