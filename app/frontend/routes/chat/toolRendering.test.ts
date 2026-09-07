import { describe, expect, it } from "vitest"
import { fullResultBody, shortenWorkspacePaths, toolDetail, toolLabel, toolPresentation, toolResultPresentation, typedToolResult } from "./toolRendering"

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
  it("prioritizes a core-registered card's collapsed summary over the generic list heuristic", () => {
    // list_chat_media's card lives under routes/chat/tool_cards/ (JOB-4220) —
    // this proves the registered card wins over the blind generic guess.
    const result = toolResultPresentation(
      "list_chat_media",
      JSON.stringify(JSON.stringify({
        snapshots: [{ id: "snapshot:1" }],
        chat_images: [{ id: "chat_image:1" }]
      }))
    )

    expect(result).toMatchObject({ kind: "text", summary: "2 media items" })
  })

  it("summarizes empty chat media payloads through the registered card", () => {
    const result = toolResultPresentation("list_chat_media", JSON.stringify({ snapshots: [], chat_images: [] }))

    expect(result).toMatchObject({ kind: "text", summary: "0 media items" })
  })

  it("falls back to a plugin-registered card's collapsed summary for a plugin-owned tool", () => {
    // list_design_docs is registered entirely inside the design_docs plugin
    // (plugins/design_docs/app/frontend/tool_cards/list_design_docs.tsx) —
    // this proves the extension point without this file naming that plugin.
    const result = toolResultPresentation("list_design_docs", JSON.stringify({
      design_docs: [{ id: 1, doc_ref: "DOC-1", title: "A" }, { id: 2, doc_ref: "DOC-2", title: "B" }]
    }))

    expect(result).toMatchObject({ kind: "text", summary: "2 design docs" })
  })

  it("keeps the generic text kind for an unknown tool with no core or plugin card", () => {
    const result = toolResultPresentation("totally_unknown_tool", "plain text result")

    expect(result).toMatchObject({ kind: "text", summary: "" })
  })
})

describe("typedToolResult", () => {
  it("renders set_bookmark as a concise success outcome", () => {
    expect(typedToolResult("set_bookmark", JSON.stringify({ id: 12, label: "Launch notes", kind: "topic" }))).toEqual({
      type: "success_row",
      label: "Bookmark added: Launch notes"
    })
  })

  it("no longer special-cases read_job/read_epic (superseded by their tool_cards/ renderers)", () => {
    expect(typedToolResult("read_job", JSON.stringify({ job: { id: 4048, state: "running" } }))).toBeNull()
    expect(typedToolResult("read_epic", JSON.stringify({ epic: { id: 285, state: "running" } }))).toBeNull()
  })

  it("no longer special-cases proposal/pending-action tools (superseded by their tool_cards/ renderers)", () => {
    expect(typedToolResult("propose_job", JSON.stringify({ slug: "fix-output", title: "Fix output", kind: "job", state: "proposed" }))).toBeNull()
    expect(typedToolResult("propose_epic", JSON.stringify({ slug: "fix-epic", title: "Fix epic", kind: "epic", state: "proposed" }))).toBeNull()
    expect(typedToolResult("propose_epic_with_jobs", JSON.stringify({ slug: "fix-epic", state: "proposed" }))).toBeNull()
    expect(typedToolResult("check_job_mergeability", JSON.stringify({ pending_action_id: 201, state: "pending", message: "Check mergeability for JOB-2351?" }))).toBeNull()
  })

  it("returns null for unknown tools and malformed typed payloads", () => {
    expect(typedToolResult("unknown_tool", JSON.stringify({ label: "Nope" }))).toBeNull()
    expect(typedToolResult("set_bookmark", "{not json")).toBeNull()
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
