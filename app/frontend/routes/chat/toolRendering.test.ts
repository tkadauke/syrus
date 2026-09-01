import { describe, expect, it } from "vitest"
import { fullResultBody, shortenWorkspacePaths, toolDetail, toolLabel, toolPresentation, toolResultPresentation } from "./toolRendering"

describe("toolLabel", () => {
  it("hides Codex MCP and chat sidecar prefixes and humanizes snake-case tool names", () => {
    expect(toolLabel("mcp__syrus-chat-sidecar__list_chat_media")).toBe("List chat media")
    expect(toolLabel("syrus-chat-deferred-sidecar.list_proposals")).toBe("List proposals")
  })

  it("humanizes unknown snake-case names without changing built-in tool labels", () => {
    expect(toolLabel("unknown_tool_name")).toBe("Unknown tool name")
    expect(toolLabel("Read")).toBe("Read")
  })
})

describe("toolPresentation", () => {
  it("keeps raw input while presenting empty arguments cleanly", () => {
    const presentation = toolPresentation("syrus-chat-sidecar.list_chat_media", {})

    expect(presentation).toEqual({
      display_label: "List chat media",
      argument_summary: "No arguments",
      raw_payload: {}
    })
  })

  it("uses a concise stable JSON fallback for unknown non-empty tool arguments", () => {
    const presentation = toolPresentation("mcp__custom-server__unknown_lookup", { z: "last", a: "first" })

    expect(presentation.display_label).toBe("Unknown lookup")
    expect(presentation.argument_summary).toBe('{"a":"first","z":"last"}')
    expect(presentation.raw_payload).toEqual({ z: "last", a: "first" })
  })
})

describe("tool result rendering", () => {
  it("caps large tool result previews before the browser renders them", () => {
    const body = fullResultBody("x".repeat(25_000))

    expect(body.length).toBeLessThan(21_000)
    expect(body).toContain("Tool result preview truncated")
    expect(body).toContain("Full content remains in the chat transcript")
  })

  it("caps very tall tool result previews", () => {
    const body = fullResultBody(Array.from({ length: 500 }, (_, index) => `line ${index}`).join("\n"))

    expect(body).toContain("line 399")
    expect(body).not.toContain("line 450")
    expect(body).toContain("100 lines")
  })

  it("caps pathological single-line tool results before markdown or highlighting can render them", () => {
    const body = fullResultBody("a".repeat(45_000))

    expect(body).toContain("Tool result preview truncated")
    expect(body).toContain("Full content remains in the chat transcript")
    expect(body.split("\n")[0].length).toBeLessThanOrEqual(2_000)
    expect(body.length).toBeLessThan(3_000)
  })

  it("summarizes escaped JSON-in-text MCP list results", () => {
    const escapedJson = JSON.stringify(JSON.stringify({
      snapshots: [{ id: "snapshot:1" }],
      chat_images: [{ id: "chat_image:2" }],
      whiteboard_element_count: 3
    }))

    expect(toolResultPresentation("syrus-chat-sidecar.list_chat_media", escapedJson).summary).toBe("1 snapshot · 1 image · 3 whiteboard elements")
  })

  it("summarizes common proposal and bookmark list results by count", () => {
    const proposals = JSON.stringify({ proposals: [{ id: 1 }, { id: 2 }] })
    const bookmarks = JSON.stringify({ bookmarks: [{ id: 1 }] })

    expect(toolResultPresentation("mcp__syrus-chat-sidecar__list_proposals", proposals)).toMatchObject({
      kind: "count",
      summary: "2 proposals",
      metadata: { count: 2, collection: "proposals" }
    })
    expect(toolResultPresentation("syrus-chat-sidecar.list_bookmarks", bookmarks)).toMatchObject({
      kind: "count",
      summary: "1 bookmark"
    })
  })
})

describe("toolDetail", () => {
  it("shows the invoked skill's name for the synthetic resolve_skill provenance call", () => {
    expect(toolDetail("resolve_skill", { name: "investigate" })).toBe("investigate")
  })

  it("does not show raw braces for empty arguments", () => {
    expect(toolDetail("syrus-chat-sidecar.list_chat_media", {})).toBe("No arguments")
  })
})

describe("shortenWorkspacePaths", () => {
  it("leaves long non-workspace lines unchanged without running path replacement", () => {
    const line = `[mcp_tools_init] tools=${Array.from({ length: 500 }, (_, index) => `tool_${index}`).join(",")}`

    expect(shortenWorkspacePaths(line)).toBe(line)
  })

  it("shortens chat workspace repository roots", () => {
    expect(
      shortenWorkspacePaths("/syrus-home/.syrus/chat-workspaces/161/repositories/tkadauke/syrus/app/models/job.rb")
    ).toBe("app/models/job.rb")
  })

  it("shortens workflow workspace roots", () => {
    expect(
      shortenWorkspacePaths("changed /syrus-home/.syrus/workflows/123/app/models/job.rb")
    ).toBe("changed app/models/job.rb")
  })

  it("keeps exact workspace references readable", () => {
    expect(shortenWorkspacePaths("/syrus-home/.syrus/workflows/123")).toBe(".")
  })
})
