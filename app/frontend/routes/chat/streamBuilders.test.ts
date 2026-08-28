import { describe, expect, it } from "vitest"
import type { ChatMessageItem, ChatPendingAction, ChatRenderItem, ChatToolGroupItem } from "../../api/chats"
import { pendingActionCardData, renderChatMessages } from "./streamBuilders"

function toolUse(id: number, overrides: Partial<ChatMessageItem> & { toolUseId: string; toolName: string; input?: Record<string, unknown> }): ChatMessageItem {
  const { toolUseId, toolName, input, ...rest } = overrides
  return {
    type: "message",
    id,
    role: "tool_use",
    tool_name: toolName,
    content: { type: "tool_use", id: toolUseId, name: toolName, input: input || {} },
    text: "",
    bookmarkable: false,
    ...rest
  }
}

function toolResult(id: number, overrides: Partial<ChatMessageItem> & { toolUseId: string; content?: unknown; isError?: boolean }): ChatMessageItem {
  const { toolUseId, content, isError, ...rest } = overrides
  return {
    type: "message",
    id,
    role: "tool_result",
    content: { type: "tool_result", tool_use_id: toolUseId, content: content ?? "ok", is_error: isError === true },
    text: "",
    bookmarkable: false,
    ...rest
  }
}

function group(item: ChatRenderItem | undefined): ChatToolGroupItem {
  if (!item || item.type !== "tool_group") throw new Error("expected a tool_group render item")
  return item
}

describe("pendingActionCardData", () => {
  it("carries the resource title and url through to the inline card", () => {
    const action: ChatPendingAction = {
      id: 501,
      label: "Add dark mode toggle",
      detail: "**Branch:** syrus/chat-42-handoff-7",
      state: "pending",
      action: "submit_coding_changes",
      action_type: null,
      resource_title: "acme/widgets",
      resource_url: "/repositories/9",
      app_confirm_path: "/api/v1/app/chats/122/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/122/pending_actions/501/reject",
      app_cancel_path: "/api/v1/app/chats/122/pending_actions/501"
    }

    expect(pendingActionCardData(action)).toMatchObject({
      label: "Add dark mode toggle",
      detail: "**Branch:** syrus/chat-42-handoff-7",
      resource_title: "acme/widgets",
      resource_url: "/repositories/9",
      app_cancel_path: "/api/v1/app/chats/122/pending_actions/501"
    })
  })
})

describe("renderChatMessages tool grouping", () => {
  it("groups consecutive same-tool calls into one tool_group and pairs each result by adjacency", () => {
    const items = renderChatMessages([
      toolUse(1, { toolUseId: "tu_1", toolName: "Read", input: { file_path: "a.rb" } }),
      toolResult(2, { toolUseId: "tu_1", content: "class A" }),
      toolUse(3, { toolUseId: "tu_2", toolName: "Read", input: { file_path: "b.rb" } }),
      toolResult(4, { toolUseId: "tu_2", content: "class B" })
    ])

    expect(items).toHaveLength(1)
    const toolGroup = group(items[0])
    expect(toolGroup.tool).toBe("Read")
    expect(toolGroup.calls).toHaveLength(2)
    expect(toolGroup.calls[0].result_body).toBe("class A")
    expect(toolGroup.calls[1].result_body).toBe("class B")
  })

  it("nests a subagent's tool_use/tool_result pair that interleaves inside a still-open parent Agent call", () => {
    const items = renderChatMessages([
      toolUse(1, { toolUseId: "tu_agent", toolName: "Task", input: { prompt: "investigate" } }),
      toolUse(2, { toolUseId: "tu_read", toolName: "Read", input: { file_path: "app/models/job.rb" }, sidechain: true, parent_tool_use_id: "tu_agent" }),
      toolResult(3, { toolUseId: "tu_read", content: "class Job < ApplicationRecord", sidechain: true, parent_tool_use_id: "tu_agent" }),
      toolUse(4, { toolUseId: "tu_bash", toolName: "Bash", input: { command: "bin/rspec spec/models/job_spec.rb" }, sidechain: true, parent_tool_use_id: "tu_agent" }),
      toolResult(5, { toolUseId: "tu_bash", content: "1 example, 0 failures", sidechain: true, parent_tool_use_id: "tu_agent" }),
      toolResult(6, { toolUseId: "tu_agent", content: "Job model looks correct" })
    ])

    // The outer Agent/Task call is not orphaned by the interleaved nested
    // calls -- it still renders as a single top-level tool_group with its
    // own result attached.
    expect(items).toHaveLength(1)
    const outer = group(items[0])
    expect(outer.tool).toBe("Task")
    expect(outer.calls).toHaveLength(1)
    expect(outer.calls[0].result_body).toBe("Job model looks correct")

    // The nested Read/Bash calls render as their own syntax-highlighted
    // groups nested under the parent call, not as raw unmatched fallbacks.
    const nested = outer.calls[0].nested || []
    expect(nested).toHaveLength(2)
    expect(nested[0].tool).toBe("Read")
    expect(nested[0].calls[0].result_body).toBe("class Job < ApplicationRecord")
    expect(nested[1].tool).toBe("Bash")
    expect(nested[1].calls[0].result_body).toBe("1 example, 0 failures")
  })

  it("supports multiple nesting levels (a subagent whose own tool call spawns another subagent)", () => {
    const items = renderChatMessages([
      toolUse(1, { toolUseId: "tu_outer", toolName: "Task", input: {} }),
      toolUse(2, { toolUseId: "tu_inner", toolName: "Task", input: {}, sidechain: true, parent_tool_use_id: "tu_outer" }),
      toolUse(3, { toolUseId: "tu_grep", toolName: "Grep", input: { pattern: "foo" }, sidechain: true, parent_tool_use_id: "tu_inner" }),
      toolResult(4, { toolUseId: "tu_grep", content: "app/models/foo.rb:1", sidechain: true, parent_tool_use_id: "tu_inner" }),
      toolResult(5, { toolUseId: "tu_inner", content: "inner done", sidechain: true, parent_tool_use_id: "tu_outer" }),
      toolResult(6, { toolUseId: "tu_outer", content: "outer done" })
    ])

    expect(items).toHaveLength(1)
    const outer = group(items[0])
    expect(outer.calls[0].result_body).toBe("outer done")

    const inner = outer.calls[0].nested?.[0]
    expect(inner?.tool).toBe("Task")
    expect(inner?.calls[0].result_body).toBe("inner done")

    const grep = inner?.calls[0].nested?.[0]
    expect(grep?.tool).toBe("Grep")
    expect(grep?.calls[0].result_body).toBe("app/models/foo.rb:1")
  })
})
