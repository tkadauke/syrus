import { describe, expect, it } from "vitest"
import type { ChatMessageItem } from "../../api/chats"
import { systemMessage } from "./systemMessages"

function systemText(text: string): ChatMessageItem {
  return {
    id: 1,
    type: "message",
    role: "system",
    text,
    content: { text },
    created_at: "2026-08-20T12:00:00Z",
    attachments: [],
    bookmarkable: false,
    pinnable: false
  }
}

describe("systemMessage", () => {
  it("summarizes MCP tool initialization instead of rendering the full registry", () => {
    const tools = Array.from({ length: 151 }, (_, index) => `mcp__server__tool_${index}`).join(",")
    const message = systemMessage(systemText(`[mcp_tools_init] count=151 required=submit_summary,submit_test_plan tools=${tools}`))

    expect(message).toEqual({
      tone: "success",
      label: "MCP tools",
      body: "151 MCP tools available · required: submit_summary, submit_test_plan"
    })
  })
})
