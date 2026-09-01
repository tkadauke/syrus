import { describe, expect, it } from "vitest"
import { fullResultBody, shortenWorkspacePaths, toolDetail, toolLabel, toolPresentation, toolResultPresentation } from "./toolRendering"

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
})

describe("toolDetail", () => {
  it("shows the invoked skill's name for the synthetic resolve_skill provenance call", () => {
    expect(toolDetail("resolve_skill", { name: "investigate" })).toBe("investigate")
  })

  it("renders empty arguments as a concise label", () => {
    expect(toolDetail("syrus-chat-sidecar.list_chat_media", {})).toBe("No arguments")
  })
})

describe("toolLabel", () => {
  it("hides chat sidecar prefixes and humanizes snake-case tool names", () => {
    expect(toolLabel("syrus-chat-sidecar.list_chat_media")).toBe("List chat media")
    expect(toolLabel("syrus-chat-deferred-sidecar.list_chat_media")).toBe("List chat media")
  })

  it("hides mcp transport prefixes for chat sidecar tools", () => {
    expect(toolLabel("mcp__syrus-chat-sidecar__list_chat_media")).toBe("List chat media")
  })
})

describe("toolPresentation", () => {
  it("keeps raw unknown-tool arguments available while showing a compact fallback", () => {
    const input = { foo: "bar", count: 2 }
    const presentation = toolPresentation("mcp__custom-server__unknown_tool", input)

    expect(presentation.display_label).toBe("Unknown tool")
    expect(presentation.argument_summary).toBe("bar")
    expect(presentation.raw_payload).toBe(input)
  })
})

describe("toolResultPresentation", () => {
  it("summarizes escaped JSON-in-text MCP list results", () => {
    const result = toolResultPresentation(
      "list_chat_media",
      JSON.stringify(JSON.stringify({ chat_media: [{ id: "img_1" }, { id: "img_2" }] }))
    )

    expect(result).toMatchObject({
      kind: "list",
      summary: "2 media items",
      metadata: { count: 2, noun: "media item" }
    })
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
