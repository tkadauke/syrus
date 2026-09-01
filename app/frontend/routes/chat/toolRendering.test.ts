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

describe("typedToolResult", () => {
  it("detects list_chat_media galleries from escaped MCP JSON text", () => {
    const result = typedToolResult("syrus-chat-sidecar.list_chat_media", JSON.stringify(JSON.stringify({
      snapshots: [{ id: "snapshot:9", kind: "snapshot", name: "Checkout flow", element_count: 4, created_at: "2026-09-01T12:00:00Z" }],
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png" }],
      whiteboard_element_count: 7
    })))

    expect(result).toMatchObject({
      type: "chat_media_gallery",
      whiteboard_element_count: 7,
      snapshots: [{ id: "snapshot:9", name: "Checkout flow", element_count: 4 }],
      images: [{ id: "chat_image:3", filename: "desktop.png", content_type: "image/png" }]
    })
  })

  it("renders set_bookmark as a concise success outcome", () => {
    expect(typedToolResult("set_bookmark", JSON.stringify({ id: 12, label: "Launch notes", kind: "topic" }))).toEqual({
      type: "success_row",
      label: "Bookmark added: Launch notes"
    })
  })

  it("renders proposal tools as proposal outcomes", () => {
    expect(typedToolResult("propose_job", JSON.stringify({
      id: 1800,
      slug: "fix-output",
      title: "Fix output",
      kind: "job",
      state: "pending",
      repository: "tkadauke/syrus"
    }))).toEqual({
      type: "proposal_outcome",
      label: "Job proposal ready",
      title: "Fix output",
      detail: "fix-output · pending · tkadauke/syrus"
    })
  })

  it("summarizes predictable live job state payloads", () => {
    expect(typedToolResult("read_job", JSON.stringify({
      job: { id: 4048, issue_title: "Typed renderers", state: "running", repository: "tkadauke/syrus", pr_number: 12, branch_name: "syrus/direct-4048" },
      latest_workflow: { state: "running" }
    }))).toEqual({
      type: "state_summary",
      label: "Typed renderers",
      rows: [
        { label: "State", value: "running" },
        { label: "Repository", value: "tkadauke/syrus" },
        { label: "PR", value: "12" },
        { label: "Branch", value: "syrus/direct-4048" },
        { label: "Latest workflow", value: "running" }
      ]
    })
  })

  it("summarizes predictable live epic state payloads", () => {
    expect(typedToolResult("read_epic", JSON.stringify({
      epic: { id: 285, display_number: "EPIC-285", title: "Polished Chat Tool Output", state: "running", repository: "tkadauke/syrus", depends_on_epics: [] },
      child_jobs: [{ id: 4046 }, { id: 4048 }]
    }))).toEqual({
      type: "state_summary",
      label: "Polished Chat Tool Output",
      rows: [
        { label: "State", value: "running" },
        { label: "Repository", value: "tkadauke/syrus" },
        { label: "Children", value: "2" },
        { label: "Depends on", value: "0" }
      ]
    })
  })

  it("summarizes predictable mergeability pending-action payloads", () => {
    expect(typedToolResult("check_job_mergeability", JSON.stringify({
      pending_action_id: 201,
      state: "pending",
      message: "Check mergeability for JOB-2351?"
    }))).toEqual({
      type: "state_summary",
      label: "Check mergeability for JOB-2351?",
      rows: [
        { label: "Pending action", value: "201" },
        { label: "State", value: "pending" }
      ]
    })
  })

  it("returns null for unknown tools and malformed typed payloads", () => {
    expect(typedToolResult("unknown_tool", JSON.stringify({ label: "Nope" }))).toBeNull()
    expect(typedToolResult("set_bookmark", "{not json")).toBeNull()
    expect(typedToolResult("list_chat_media", JSON.stringify({ snapshots: [{ id: "" }], chat_images: "bad" }))).toBeNull()
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
