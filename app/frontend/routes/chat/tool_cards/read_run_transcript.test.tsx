import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import readRunTranscriptToolCard, { examples } from "./read_run_transcript"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_run_transcript",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_run_transcript tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readRunTranscriptToolCard.toolName).toBe("read_run_transcript")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__read_run_transcript")).toBe("read_run_transcript")
    expect(examples.map(({ id }) => id)).toEqual(["completed_with_markdown_and_diff", "empty_page", "failed_run", "long_chunk"])
  })

  it.each([
    ["structured content", { structured_content: { run_id: 9, run_state: "succeeded" } }],
    ["text content", { content: [{ type: "text", text: JSON.stringify({ run_id: 9, run_state: "succeeded" }) }] }],
    ["string parsedResult", JSON.stringify({ run_id: 9, run_state: "succeeded" })]
  ])("normalizes %s", (_label, envelope) => {
    const parsedResult = typeof envelope === "string" ? envelope : normalizedToolCardParsedResult(envelope)
    expect(readRunTranscriptToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("RUN-9 (succeeded)")
  })

  it("summarizes the collapsed row with the canonical RUN id and state", () => {
    const parsedResult = { run_id: 9, run_state: "succeeded" }
    expect(readRunTranscriptToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("RUN-9 (succeeded)")
  })

  it("renders pagination metadata, chunk count, transcript preview, and diff section", () => {
    const parsedResult = {
      run_id: 9,
      run_state: "succeeded",
      agent_outcome: "success",
      agent_summary: "changed the code",
      agent_diff: "diff --git a/foo.rb b/foo.rb\n@@ -1 +1 @@\n+added line\n-removed line",
      total_chunks: 5,
      page: 2,
      per: 2,
      total_pages: 3,
      chunks: [{ sequence: 2, kind: "system", chunk: "hello world" }]
    }

    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "RUN-9" })).toHaveAttribute("href", "/admin/runs/9/transcript")
    expect(screen.getByRole("button", { name: "Copy RUN-9 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("succeeded")).toBeInTheDocument()
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("changed the code")
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText("2 of 3")).toBeInTheDocument()
    expect(screen.getByText("2", { selector: "div[title='2']" })).toBeInTheDocument()
    expect(screen.getByText("#2")).toBeInTheDocument()
    expect(screen.getByText("system")).toBeInTheDocument()
    expect(screen.getByText("hello world")).toBeInTheDocument()
    expect(screen.getByText("1 file")).toBeInTheDocument()
    expect(screen.getByText("+1")).toBeInTheDocument()
    expect(screen.getByText("-1")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous page" })).toHaveAttribute("href", "/admin/runs/9/transcript?page=1&per=2")
    expect(screen.getByRole("link", { name: "Next page" })).toHaveAttribute("href", "/admin/runs/9/transcript?page=3&per=2")
  })

  it("highlights a failed Run", () => {
    const parsedResult = { run_id: 9, run_state: "failed" }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("This Run did not finish successfully.")).toBeInTheDocument()
  })

  it("opens the complete text of an overly long chunk", () => {
    const parsedResult = { run_id: 9, run_state: "succeeded", chunks: [{ sequence: 1, chunk: "x".repeat(500) }] }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("x".repeat(400))
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog")).toHaveTextContent("x".repeat(500))
  })

  it("renders markdown summary and empty-page context", () => {
    const parsedResult = {
      run_id: 9,
      run_state: "running",
      agent_summary: "## Progress\n\nFinished **setup**.",
      total_chunks: 8,
      page: 3,
      per: 4,
      total_pages: 2,
      chunks: []
    }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("Progress")
    expect(screen.getByText("3", { selector: "div[title='3']" })).toBeInTheDocument()
    expect(screen.queryByText("3 of 2")).not.toBeInTheDocument()
    expect(screen.getByText("No transcript chunks were returned for this page.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous page" })).toHaveAttribute("href", "/admin/runs/9/transcript?page=2&per=4")
  })

  it("shows a redacted error and a genuinely empty transcript", () => {
    const parsedResult = { run_id: 9, run_state: "failed", error: "token=super-secret-value", total_chunks: 0, page: 1, per: 50, total_pages: 0, chunks: [] }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult, resultError: true }))}</>)
    expect(screen.getByText("This Run has no transcript chunks.")).toBeInTheDocument()
    expect(screen.getByText("1", { selector: "div[title='1']" })).toBeInTheDocument()
    expect(screen.queryByText("1 of 0")).not.toBeInTheDocument()
    expect(screen.queryByText(/super-secret-value/)).not.toBeInTheDocument()
  })

  it("includes a catalog example that can open the long-chunk modal", () => {
    const example = examples.find(({ id }) => id === "long_chunk")
    expect(example).toBeDefined()

    render(<>{readRunTranscriptToolCard.renderExpanded(context({ input: example?.input, parsedResult: example?.parsedResult }))}</>)
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { run_id: 9, run_state: "queued" }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("RUN-9")).toBeInTheDocument()
    expect(screen.queryByText("Transcript preview")).not.toBeInTheDocument()
    expect(screen.queryByText("Diff")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readRunTranscriptToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readRunTranscriptToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readRunTranscriptToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
