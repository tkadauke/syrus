import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import removePinnedContextToolCard from "./remove_pinned_context"
import updatePinnedContextToolCard from "./update_pinned_context"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("pinned context tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(updatePinnedContextToolCard.toolName).toBe("update_pinned_context")
    expect(removePinnedContextToolCard.toolName).toBe("remove_pinned_context")
  })

  it("renders updated pinned context as linked markdown with a concise preview", () => {
    const longContext = Array.from({ length: 30 }, (_, index) => `Line ${index + 1}: remember the OAuth migration detail.`).join("\n")
    const parsedResult = {
      pinned_context: `${longContext}\n**JOB-42** https://example.test/runbook`,
      message: "Pinned context updated.",
      chat_session_id: 9,
      pinned_context_id: 12
    }

    expect(updatePinnedContextToolCard.collapsedSummary?.(context("update_pinned_context", { parsedResult }))).toBe("Pinned context updated.")
    render(<>{updatePinnedContextToolCard.renderExpanded(context("update_pinned_context", { parsedResult }))}</>)

    expect(screen.getByText("updated")).toBeInTheDocument()
    expect(screen.getByText("31")).toBeInTheDocument()
    expect(screen.getByText(String(parsedResult.pinned_context.length))).toBeInTheDocument()
    expect(screen.getByText("9")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("Context preview")).toBeInTheDocument()
    expect(screen.getByText(/Line 1: remember/)).toBeInTheDocument()
    expect(screen.queryByText(/Line 30/)).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("renders the requested content when it differs from the saved result", () => {
    const parsedResult = { pinned_context: "Normalized content", message: "Pinned context updated." }
    render(
      <>{updatePinnedContextToolCard.renderExpanded(context("mcp__syrus__update_pinned_context", { input: { content: "Requested content" }, parsedResult }))}</>
    )

    expect(screen.getByText("Requested context")).toBeInTheDocument()
    expect(screen.getByText("Requested content")).toBeInTheDocument()
    expect(screen.getByText("Normalized content")).toBeInTheDocument()
  })

  it("renders provider error envelopes without requiring success fields", () => {
    const errorContext = context("update_pinned_context", {
      resultBody: "content is required",
      resultError: true,
      parsedResult: { error: "content is required" }
    })

    expect(updatePinnedContextToolCard.collapsedSummary?.(errorContext)).toBe("Pinned context update failed")
    render(<>{updatePinnedContextToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("content is required")).toBeInTheDocument()
  })

  it("renders pending and empty states", () => {
    const pending = context("update_pinned_context", { input: { content: "Incoming" } })
    expect(updatePinnedContextToolCard.collapsedSummary?.(pending)).toBe("Updating pinned context")
    render(<>{updatePinnedContextToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()

    render(<>{updatePinnedContextToolCard.renderExpanded(context("update_pinned_context", { parsedResult: { pinned_context: "", message: "Cleared." } }))}</>)
    expect(screen.getByText("Pinned context is empty.")).toBeInTheDocument()
  })

  it("renders removed pinned context state", () => {
    const parsedResult = { pinned_context: null, message: "Pinned context removed." }

    expect(removePinnedContextToolCard.collapsedSummary?.(context("remove_pinned_context", { parsedResult }))).toBe("Pinned context removed.")
    render(<>{removePinnedContextToolCard.renderExpanded(context("remove_pinned_context", { parsedResult }))}</>)

    expect(screen.getByText("removed")).toBeInTheDocument()
    expect(screen.getByText("Pinned context removed.")).toBeInTheDocument()
    expect(screen.queryByText("Context preview")).not.toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(updatePinnedContextToolCard.collapsedSummary?.(context("update_pinned_context", { parsedResult: { oops: true }, resultBody: "{}" }))).toBe(
      "Pinned context update returned an unexpected response"
    )
    expect(updatePinnedContextToolCard.renderExpanded(context("update_pinned_context", { parsedResult: "not json", resultBody: "not json" }))).not.toBeNull()
    expect(removePinnedContextToolCard.renderExpanded(context("remove_pinned_context", { parsedResult: { pinned_context: 7 } }))).toBeNull()
  })
})
