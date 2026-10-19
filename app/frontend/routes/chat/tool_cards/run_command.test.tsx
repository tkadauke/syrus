import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import runCommandToolCard from "./run_command"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "run_command", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("run_command tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(runCommandToolCard.toolName).toBe("run_command")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__run_command")).toBe("run_command")
  })

  it.each([
    ["structured content", { structured_content: { stdout: "ok\n", stderr: "", exit_code: 0 } }],
    ["text content", { content: [{ type: "text", text: JSON.stringify({ stdout: "ok\n", stderr: "", exit_code: 0 }) }] }]
  ])("normalizes %s result envelopes", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command succeeded (exit 0)")
  })

  it("summarizes a successful command", () => {
    const parsedResult = { stdout: "ok\n", stderr: "", exit_code: 0 }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command succeeded (exit 0)")
  })

  it("summarizes and renders command failure output (non-zero exit is a successful tool call, not a tool error)", () => {
    const parsedResult = { stdout: "", stderr: "bundle: command not found\n", exit_code: 127 }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command failed (exit 127)")

    render(
      <>{runCommandToolCard.renderExpanded(context({ parsedResult, input: { command: "bundle exec rspec", cwd: "/tmp/project", timeout_ms: 12_000 } }))}</>
    )

    expect(screen.getByText("exit 127")).toBeInTheDocument()
    expect(screen.getByText("bundle exec rspec")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy command" })).toBeInTheDocument()
    expect(screen.getByText("/tmp/project")).toBeInTheDocument()
    expect(screen.getByText("12000")).toBeInTheDocument()
    expect(screen.getByText("stderr")).toBeInTheDocument()
    expect(screen.getByText("stderr").closest("details")).toHaveAttribute("open")
    expect(screen.queryByText("stdout")).not.toBeInTheDocument()
  })

  it("summarizes a killed command", () => {
    const parsedResult = { stdout: "", stderr: "", exit_code: 0, killed: true }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command killed")

    render(<>{runCommandToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("killed")).toBeInTheDocument()
    expect(screen.getByText("No output.")).toBeInTheDocument()
  })

  it("renders dispatch and invalid-parameter errors", () => {
    const parsedResult = { error: "invalid params: missing command" }
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Command error: invalid params: missing command")

    render(<>{runCommandToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("invalid params: missing command")).toBeInTheDocument()
  })

  it("shows the tail of long redacted output and opens the complete-output dialog", () => {
    const stdout = ["DATABASE_URL=postgres://user:password@example.test/db", ...Array.from({ length: 201 }, (_, index) => `line ${index + 1}`)].join("\n")
    const parsedResult = { stdout, stderr: "", exit_code: 0 }
    render(<>{runCommandToolCard.renderExpanded(context({ parsedResult }))}</>)

    fireEvent.click(screen.getByText("stdout"))
    const preview = screen.getByTestId("text-preview-content")
    expect(preview).toHaveTextContent("line 201")
    expect(preview).not.toHaveTextContent("postgres://user:password@")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog")).toHaveTextContent("postgres://user:[redacted]@example.test/db")
  })

  it("falls back to null for a malformed payload", () => {
    expect(runCommandToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(runCommandToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
