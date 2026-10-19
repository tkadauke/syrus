import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import writeFileToolCard from "./write_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "write_file", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("write_file tool card", () => {
  it("registers and summarizes success", () => {
    expect(writeFileToolCard.toolName).toBe("write_file")
    expect(writeFileToolCard.collapsedSummary?.(context({ parsedResult: { success: true } }))).toBe("Wrote file")
  })

  it("renders the path, byte count, and plain-text input content", () => {
    render(
      <>
        {writeFileToolCard.renderExpanded(context({ parsedResult: { success: true }, input: { path: "app/models/job.rb", content: "line1\nline2\nline3" } }))}
      </>
    )
    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("17")).toBeInTheDocument()
    expect(screen.getByText(/line1/)).toBeInTheDocument()
  })

  it("renders structured and transport errors", () => {
    expect(writeFileToolCard.collapsedSummary?.(context({ parsedResult: { error: "denied" } }))).toBe("Write file failed: denied")
    render(<>{writeFileToolCard.renderExpanded(context({ resultError: true, resultBody: "Local daemon not connected", input: { path: "notes.txt" } }))}</>)
    expect(screen.getByText("Write file failed")).toBeInTheDocument()
    expect(screen.getByText("Local daemon not connected")).toBeInTheDocument()
  })

  it("renders pending confirmation with Markdown links and follows live state", () => {
    render(
      <>
        {writeFileToolCard.renderExpanded(
          context({
            parsedResult: { pending_confirmation_id: 44, pending_action_id: 44, state: "pending", message: "Confirmation required" },
            input: { path: "README.md", content: "See JOB-42 and https://example.com" },
            livePendingAction: {
              id: 44,
              state: "rejected",
              reason: "No thanks",
              action: "write_file",
              label: "Write file",
              detail: "README.md",
              app_confirm_path: "/confirm",
              app_reject_path: "/reject"
            }
          })
        )}
      </>
    )
    expect(screen.getAllByText("README.md")).toHaveLength(2)
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("JOB-42")
    expect(screen.getByRole("link", { name: "https://example.com" })).toHaveAttribute("href", "https://example.com")
  })

  it("renders empty content and a full-content popup for truncated text", () => {
    const { rerender } = render(
      <>{writeFileToolCard.renderExpanded(context({ parsedResult: { success: true }, input: { path: "empty.txt", content: "" } }))}</>
    )
    expect(screen.getByText("The file is empty.")).toBeInTheDocument()
    rerender(<>{writeFileToolCard.renderExpanded(context({ parsedResult: { success: true }, input: { path: "large.txt", content: "x".repeat(1_100) } }))}</>)
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Written content: large.txt" })).toBeInTheDocument()
  })

  it("falls back for unavailable input and malformed results", () => {
    render(<>{writeFileToolCard.renderExpanded(context({ parsedResult: { success: true } }))}</>)
    expect(screen.queryByText("Written content")).not.toBeInTheDocument()
    expect(writeFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("uses normalized names and provider envelopes", () => {
    const pending = { pending_confirmation_id: 9, state: "pending", message: "Confirm write" }
    const claudeEnvelope = { content: [{ type: "text", text: JSON.stringify(pending) }] }
    const codexEnvelope = { content: [{ type: "text", text: JSON.stringify(pending) }], structuredContent: null }
    expect(normalizedToolName("mcp__local__write_file")).toBe("write_file")
    expect(writeFileToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(claudeEnvelope) }))).toContain("Confirm write")
    expect(writeFileToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(codexEnvelope) }))).toContain("Confirm write")
  })
})
