import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readRunTranscriptToolCard from "./read_run_transcript"

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
      agent_diff: "diff --git a/foo.rb b/foo.rb\n+added line\n-removed line",
      total_chunks: 5,
      page: 2,
      per: 2,
      total_pages: 3,
      chunks: [{ sequence: 2, kind: "system", chunk: "hello world" }]
    }

    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("RUN-9")).toBeInTheDocument()
    expect(screen.getByText("succeeded")).toBeInTheDocument()
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByText("changed the code")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText("2 of 3")).toBeInTheDocument()
    expect(screen.getByText("#2")).toBeInTheDocument()
    expect(screen.getByText("system")).toBeInTheDocument()
    expect(screen.getByText("hello world")).toBeInTheDocument()
    expect(screen.getByText("1 file")).toBeInTheDocument()
    expect(screen.getByText("+1")).toBeInTheDocument()
    expect(screen.getByText("-1")).toBeInTheDocument()
  })

  it("highlights a failed Run", () => {
    const parsedResult = { run_id: 9, run_state: "failed" }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("This Run did not finish successfully.")).toBeInTheDocument()
  })

  it("truncates an overly long chunk preview", () => {
    const parsedResult = { run_id: 9, run_state: "succeeded", chunks: [{ sequence: 1, chunk: "x".repeat(500) }] }
    render(<>{readRunTranscriptToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText(`${"x".repeat(400)}…`)).toBeInTheDocument()
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
