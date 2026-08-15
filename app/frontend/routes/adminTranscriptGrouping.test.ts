import { describe, expect, it } from "vitest"
import { groupTranscriptEvents } from "./adminTranscriptGrouping"
import type { TranscriptEvent } from "../api/adminTranscript"

function event(kind: string, data: Record<string, unknown>): TranscriptEvent {
  return { kind, timestamp: null, data }
}

describe("groupTranscriptEvents", () => {
  it("groups consecutive same-tool calls and pairs results by id", () => {
    const items = groupTranscriptEvents([
      event("tool_use", { name: "Read", input: { file_path: "a.rb" }, id: "1" }),
      event("tool_use", { name: "Read", input: { file_path: "b.rb" }, id: "2" }),
      event("tool_result", { tool_use_id: "1", content: "class A; end" }),
      event("tool_result", { tool_use_id: "2", content: "class B; end" })
    ])

    expect(items).toHaveLength(1)
    const group = items[0]
    if (group.type !== "tool_group") throw new Error("expected a tool_group item")
    expect(group.tool).toBe("Read")
    expect(group.calls).toHaveLength(2)
    expect(group.calls[0].detail).toBe("a.rb")
    expect(group.calls[0].result_body).toBe("class A; end")
    expect(group.calls[1].result_body).toBe("class B; end")
  })

  it("starts a new group when the tool name changes, even with interleaved results", () => {
    const items = groupTranscriptEvents([
      event("tool_use", { name: "Read", input: { file_path: "a.rb" }, id: "1" }),
      event("tool_use", { name: "Bash", input: { command: "ls" }, id: "2" }),
      event("tool_result", { tool_use_id: "1", content: "ok" }),
      event("tool_result", { tool_use_id: "2", content: "ok" })
    ])

    expect(items.map((item) => item.type)).toEqual(["tool_group", "tool_group"])
  })

  it("marks failed tool results", () => {
    const items = groupTranscriptEvents([
      event("tool_use", { name: "Bash", input: { command: "false" }, id: "1" }),
      event("tool_result", { tool_use_id: "1", content: "boom", error: true })
    ])

    const group = items[0]
    if (group.type !== "tool_group") throw new Error("expected a tool_group item")
    expect(group.calls[0].result_error).toBe(true)
  })

  it("renders an unmatched tool_result as a fallback item instead of dropping it", () => {
    const items = groupTranscriptEvents([
      event("tool_result", { tool_use_id: "missing", content: "orphaned" })
    ])

    expect(items).toEqual([
      expect.objectContaining({ type: "fallback", badge: "tool ok", title: "orphaned" })
    ])
  })

  it("passes through text and system events untouched", () => {
    const items = groupTranscriptEvents([
      event("user_prompt", { text: "do the thing" }),
      event("assistant_text", { text: "done" }),
      event("system_init", { model: "claude", cwd: "/work" }),
      event("result", { turns: 3 })
    ])

    expect(items.map((item) => item.type)).toEqual(["text", "text", "system_init", "result"])
  })

  it("breaks grouping between two calls of the same tool separated by other events", () => {
    const items = groupTranscriptEvents([
      event("tool_use", { name: "Read", input: { file_path: "a.rb" }, id: "1" }),
      event("assistant_text", { text: "let me check something else" }),
      event("tool_use", { name: "Read", input: { file_path: "b.rb" }, id: "2" })
    ])

    expect(items.map((item) => item.type)).toEqual(["tool_group", "text", "tool_group"])
  })
})
