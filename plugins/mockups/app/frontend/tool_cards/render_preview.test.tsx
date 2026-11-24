import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import renderPreviewToolCard, { examples } from "./render_preview"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "render_preview", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("render_preview tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(renderPreviewToolCard.toolName).toBe("render_preview")
  })

  it("summarizes and renders the unpublished screenshot with metadata", () => {
    const ctx = context({ parsedResult: examples[0].parsedResult })
    expect(renderPreviewToolCard.collapsedSummary?.(ctx)).toBe("Rendered panel #42 (unpublished)")
    render(<>{renderPreviewToolCard.renderExpanded(ctx)}</>)
    expect(screen.getByText("Unpublished")).toBeInTheDocument()
    expect(screen.getByText("mobile (393×852)")).toBeInTheDocument()
    expect(screen.getByText("viewport")).toBeInTheDocument()
  })

  it("renders a styled error", () => {
    const failed = context({ resultBody: 'Error: No open preview panel "9" for this chat.', resultError: true })
    expect(renderPreviewToolCard.collapsedSummary?.(failed)).toBe('Render preview failed: No open preview panel "9" for this chat.')
  })

  it("falls back to null for malformed payloads", () => {
    expect(renderPreviewToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })
})
