import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import i18n from "i18next"
import type { ToolCardContext } from "@app/pluginToolCards"
import loadCanvasToolCard from "./load_canvas"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "load_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("load_canvas tool card", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("registers under the exact MCP tool name", () => {
    expect(loadCanvasToolCard.toolName).toBe("load_canvas")
  })

  it("summarizes and renders a merge load", () => {
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: null, snapshot_id: 8, mode: "merge", version: 3 }
    expect(loadCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Loaded #8 (merge)")

    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Loaded snapshot")).toBeInTheDocument()
    expect(screen.getByText("#8")).toBeInTheDocument()
    expect(screen.getAllByText("merge").length).toBeGreaterThan(0)
    expect(screen.getByText("6")).toBeInTheDocument()
  })

  it("renders the auto-saved snapshot id for a replace load", () => {
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: 4, snapshot_id: 8, mode: "replace", version: 3 }
    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("#4")).toBeInTheDocument()
  })

  it("localizes snapshot preview metadata", async () => {
    await i18n.changeLanguage("de")
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: 4, snapshot_id: 8, mode: "replace", version: 3 }

    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Snapshot #8 öffnen" }))
    expect(await screen.findByText("Snapshot-ID")).toBeInTheDocument()
    expect(screen.getByText("Modus")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "ID kopieren" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Auto-Speicherung kopieren" })).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (loaded not true)", () => {
    expect(loadCanvasToolCard.renderExpanded(context({ parsedResult: { loaded: false } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(loadCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
