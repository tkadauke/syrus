import { describe, expect, it } from "vitest"
import {
  pluginToolCardRendererFor,
  pluginToolCardRendererKeys,
  pluginToolCardCollapsedSummary,
  pluginToolCardExpandedBody,
  renderToolCard,
  summarizeToolCard,
  type ToolCardContext,
  type ToolCardRenderer
} from "./pluginToolCards"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "unknown_tool",
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

describe("pluginToolCards", () => {
  it("discovers a plugin-registered card by directory convention, without any core import of that plugin", () => {
    // list_design_docs.tsx lives entirely under
    // plugins/design_docs/app/frontend/tool_cards/ — this file (and the rest
    // of core) never names "design_docs" or imports that module directly.
    expect(pluginToolCardRendererKeys()).toContain("list_design_docs")
    expect(pluginToolCardRendererFor("list_design_docs")).not.toBeNull()
  })

  it("returns null for a tool no plugin or core card claims, so it keeps using the generic renderer", () => {
    expect(pluginToolCardRendererFor("totally_unknown_tool")).toBeNull()
    expect(pluginToolCardCollapsedSummary(context({ toolName: "totally_unknown_tool" }))).toBeNull()
    expect(pluginToolCardExpandedBody(context({ toolName: "totally_unknown_tool" }))).toBeNull()
  })

  it("falls back to null when renderExpanded throws on a malformed payload", () => {
    const renderer: ToolCardRenderer = {
      toolName: "broken_tool",
      renderExpanded: () => { throw new Error("boom") }
    }

    expect(renderToolCard(renderer, context({ toolName: "broken_tool" }))).toBeNull()
  })

  it("falls back to null when collapsedSummary throws", () => {
    const renderer: ToolCardRenderer = {
      toolName: "broken_tool",
      collapsedSummary: () => { throw new Error("boom") },
      renderExpanded: () => null
    }

    expect(summarizeToolCard(renderer, context({ toolName: "broken_tool" }))).toBeNull()
  })

  it("treats a renderExpanded/collapsedSummary that returns null as a signal to fall back to the generic renderer", () => {
    const renderer: ToolCardRenderer = { toolName: "quiet_tool", renderExpanded: () => null }

    expect(renderToolCard(renderer, context({ toolName: "quiet_tool" }))).toBeNull()
    expect(summarizeToolCard(renderer, context({ toolName: "quiet_tool" }))).toBeNull()
  })

  it("renders the friendly expanded view a renderer supplies", () => {
    const renderer: ToolCardRenderer = {
      toolName: "friendly_tool",
      renderExpanded: () => "friendly body"
    }

    expect(renderToolCard(renderer, context({ toolName: "friendly_tool" }))).toBe("friendly body")
  })

  it("exposes every discovered renderer's normalized tool name", () => {
    for (const key of pluginToolCardRendererKeys()) {
      expect(typeof key).toBe("string")
      expect(key.length).toBeGreaterThan(0)
    }
  })
})
