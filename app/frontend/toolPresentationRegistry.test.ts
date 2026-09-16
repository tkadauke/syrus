import { describe, expect, it } from "vitest"
import { allToolPresentationEntries, isReadOnlyToolName, toolPresentationEntryFor } from "./toolPresentationRegistry"

describe("toolPresentationRegistry", () => {
  describe("registry lookup", () => {
    it("resolves a core MCP tool card with its renderer, owner, source type, and example fixtures", () => {
      const entry = toolPresentationEntryFor("list_jobs")

      expect(entry.toolName).toBe("list_jobs")
      expect(entry.ownerType).toBe("core")
      expect(entry.ownerName).toBe("core")
      expect(entry.sourceType).toBe("mcp_tool")
      expect(entry.renderer).not.toBeNull()
      expect(entry.readOnly).toBe(true)
      expect(entry.examples.length).toBeGreaterThan(0)
      expect(entry.examples[0].label).toBe("Two open Jobs")
    })

    it("resolves a plugin-owned MCP tool card (with its own example fixtures) without any core file naming that plugin", () => {
      const entry = toolPresentationEntryFor("browser_click")

      expect(entry.ownerType).toBe("plugin")
      expect(entry.ownerName).toBe("browser")
      expect(entry.sourceType).toBe("mcp_tool")
      expect(entry.renderer).not.toBeNull()
      expect(entry.examples.length).toBeGreaterThan(0)
      expect(entry.examples[0].label).toBe("Click a submit button")
    })

    it("defaults examples to an empty array for a card that doesn't opt in", () => {
      const entry = toolPresentationEntryFor("Bash")
      expect(entry.examples).toEqual([])
    })

    it("resolves a provider built-in tool with no MCP card", () => {
      const bash = toolPresentationEntryFor("Bash")
      expect(bash.ownerType).toBe("provider")
      expect(bash.sourceType).toBe("provider_builtin")
      expect(bash.renderer).toBeNull()
      expect(bash.readOnly).toBe(false)
      expect(bash.displayLabel).toBeTruthy()
      expect(bash.progressLabel).toBeTruthy()

      const read = toolPresentationEntryFor("Read")
      expect(read.sourceType).toBe("provider_builtin")
      expect(read.readOnly).toBe(true)
    })

    it("classifies a Local Mode management tool distinctly, even with no registered card", () => {
      const complete = toolPresentationEntryFor("complete_implement_step")
      expect(complete.sourceType).toBe("local_mode_tool")
      expect(complete.renderer).toBeNull()

      const openInLocalMode = toolPresentationEntryFor("open_in_local_mode")
      expect(openInLocalMode.sourceType).toBe("local_mode_tool")
      // Local Mode classification is additive: a tool with a registered card
      // keeps rendering through it.
      expect(openInLocalMode.renderer).not.toBeNull()
    })

    it("resolves a chat surface component by its synthetic identifier", () => {
      const proposal = toolPresentationEntryFor("proposal_card")
      expect(proposal.sourceType).toBe("chat_surface_component")
      expect(proposal.ownerType).toBe("core")
    })

    it("includes every discovered/registered entry in the full listing", () => {
      const names = allToolPresentationEntries().map((entry) => entry.toolName)
      expect(names).toContain("list_jobs")
      expect(names).toContain("browser_click")
      expect(names).toContain("Bash")
      expect(names).toContain("proposal_card")
      expect(names).toContain("complete_implement_step")
      expect(new Set(names).size).toBe(names.length)
    })
  })

  describe("alias resolution", () => {
    it("resolves Agent to the canonical Task entry", () => {
      const task = toolPresentationEntryFor("Task")
      const agent = toolPresentationEntryFor("Agent")

      expect(agent.toolName).toBe("Task")
      expect(agent).toEqual(task)
    })

    it("normalizes mcp__ and sidecar-prefixed raw names to the same canonical entry", () => {
      const direct = toolPresentationEntryFor("list_jobs")
      const mcpPrefixed = toolPresentationEntryFor("mcp__syrus-chat-sidecar__list_jobs")
      const sidecarPrefixed = toolPresentationEntryFor("syrus-chat-sidecar.list_jobs")

      expect(mcpPrefixed.toolName).toBe(direct.toolName)
      expect(sidecarPrefixed.toolName).toBe(direct.toolName)
    })
  })

  describe("plugin/core discovery", () => {
    it("discovers plugin cards purely by directory convention", () => {
      const entries = allToolPresentationEntries().filter((entry) => entry.ownerType === "plugin")
      const ownerNames = new Set(entries.map((entry) => entry.ownerName))

      expect(ownerNames).toContain("browser")
      expect(ownerNames).toContain("design_docs")
      expect(entries.every((entry) => entry.renderer !== null)).toBe(true)
    })

    it("discovers core cards under routes/chat/tool_cards", () => {
      const entries = allToolPresentationEntries().filter((entry) => entry.sourceType === "mcp_tool" && entry.ownerType === "core")
      expect(entries.length).toBeGreaterThan(0)
      expect(entries.every((entry) => entry.renderer !== null)).toBe(true)
    })
  })

  describe("fallback behavior", () => {
    it("returns a usable fallback_only entry for a name nothing else registers", () => {
      const entry = toolPresentationEntryFor("totally_unknown_tool_xyz")

      expect(entry.sourceType).toBe("fallback_only")
      expect(entry.ownerType).toBe("core")
      expect(entry.renderer).toBeNull()
      expect(entry.displayLabel).toBeTruthy()
      expect(entry.progressLabel).toBeTruthy()
      expect(() => entry.argumentSummary({ foo: "bar" })).not.toThrow()
    })

    it("classifies an unrecognized list_/read_/search_/get_ prefixed tool as read-only by pattern", () => {
      expect(isReadOnlyToolName("get_something_new")).toBe(true)
      expect(isReadOnlyToolName("delete_something_new")).toBe(false)

      const entry = toolPresentationEntryFor("get_something_new")
      expect(entry.sourceType).toBe("fallback_only")
      expect(entry.readOnly).toBe(true)
    })
  })
})
