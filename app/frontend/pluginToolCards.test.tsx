import { describe, expect, it } from "vitest"
import {
  discoveredToolCardEntries,
  pluginToolCardRendererFor,
  pluginToolCardRendererKeys,
  pluginToolCardCollapsedSummary,
  pluginToolCardExpandedBody,
  renderToolCard,
  resolveExampleResultBody,
  summarizeToolCard,
  toolCardContextForExample,
  type ToolCardContext,
  type ToolCardExample,
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
    expect(pluginToolCardRendererKeys()).toEqual(expect.arrayContaining([
      "compare_test_runtime",
      "read_job_test_results",
      "read_test_insight"
    ]))
    expect(pluginToolCardRendererFor("list_design_docs")).not.toBeNull()
  })

  it("discovers Browser plugin cards by directory convention", () => {
    expect(pluginToolCardRendererKeys()).toEqual(expect.arrayContaining([
      "browser_navigate",
      "browser_snapshot",
      "browser_screenshot",
      "browser_resize",
      "browser_wait_for",
      "browser_close"
    ]))
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

  describe("example fixtures", () => {
    function findExample(toolName: string, id: string): ToolCardExample {
      const entry = discoveredToolCardEntries.find((candidate) => candidate.renderer.toolName === toolName)
      const example = entry?.examples.find((candidate) => candidate.id === id)
      if (!example) throw new Error(`fixture not found: ${toolName}/${id}`)
      return example
    }

    it("discovers examples exported alongside a core card module", () => {
      const entry = discoveredToolCardEntries.find((candidate) => candidate.renderer.toolName === "list_jobs")
      expect(entry?.examples.length).toBeGreaterThan(0)
    })

    it("discovers examples exported alongside a plugin card module, purely by directory convention", () => {
      const entry = discoveredToolCardEntries.find((candidate) => candidate.renderer.toolName === "browser_click")
      expect(entry?.owner).toEqual({ ownerType: "plugin", ownerName: "browser" })
      expect(entry?.examples.length).toBeGreaterThan(0)
    })

    it("resolves resultBody directly when an example supplies it", () => {
      const example: ToolCardExample = { id: "x", label: "x", resultBody: "not json at all" }
      expect(resolveExampleResultBody(example)).toBe("not json at all")
    })

    it("derives resultBody by JSON-encoding parsedResult when resultBody is omitted", () => {
      const example: ToolCardExample = { id: "x", label: "x", parsedResult: { a: 1 } }
      expect(resolveExampleResultBody(example)).toBe(JSON.stringify({ a: 1 }))
    })

    it("resultBody wins over parsedResult when both are given", () => {
      const example: ToolCardExample = { id: "x", label: "x", resultBody: "literal text", parsedResult: { a: 1 } }
      expect(resolveExampleResultBody(example)).toBe("literal text")
    })

    it("builds a real ToolCardContext from a fixture, deriving parsedResult from resultBody when not given explicitly", () => {
      const example = findExample("list_jobs", "two_open_jobs")
      const context = toolCardContextForExample("list_jobs", example)

      expect(context.toolName).toBe("list_jobs")
      expect(context.resultError).toBe(false)
      expect(context.parsedResult).toEqual(example.parsedResult)
      expect(context.resultBody).toBe(JSON.stringify(example.parsedResult))
    })

    it("a malformed example's context best-effort-parses to null instead of throwing", () => {
      const example: ToolCardExample = { id: "malformed", label: "malformed", resultBody: "not valid json {" }
      const context = toolCardContextForExample("list_jobs", example)

      expect(context.parsedResult).toBeNull()
      expect(context.resultBody).toBe("not valid json {")
    })

    it("renders a card's own malformed-payload fallback cleanly for a real discovered malformed fixture, without throwing", () => {
      const example = findExample("list_jobs", "malformed_missing_jobs_key")
      const renderer = pluginToolCardRendererFor("list_jobs")
      const context = toolCardContextForExample("list_jobs", example)

      expect(() => renderToolCard(renderer, context)).not.toThrow()
      expect(renderToolCard(renderer, context)).toBeNull()
      expect(summarizeToolCard(renderer, context)).toBeNull()
    })

    it("renders every discovered example through its own card without throwing, malformed or not", () => {
      for (const entry of discoveredToolCardEntries) {
        for (const example of entry.examples) {
          const context = toolCardContextForExample(entry.renderer.toolName, example)
          expect(() => renderToolCard(entry.renderer, context)).not.toThrow()
          expect(() => summarizeToolCard(entry.renderer, context)).not.toThrow()
        }
      }
    })
  })
})
