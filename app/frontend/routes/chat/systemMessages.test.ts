import { describe, expect, it } from "vitest"
import type { ChatMessageItem, ChatRenderItem } from "../../api/chats"
import { isLowPrioritySystemMessage } from "./messageDisplay"
import { goalContinuationFromContent, skillInvocationFromContent, systemMessage } from "./systemMessages"

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

function systemMessageItem(overrides: Partial<ChatMessageItem> = {}): ChatMessageItem {
  return {
    type: "message",
    id: 1,
    role: "system",
    text: "",
    bookmarkable: false,
    ...overrides
  }
}

describe("skillInvocationFromContent", () => {
  it("returns null when the content carries no skill_invocation marker", () => {
    expect(skillInvocationFromContent({ text: "MCP starting: syrus-chat-sidecar" }, "MCP starting: syrus-chat-sidecar")).toBeNull()
  })

  it("returns a warning-toned message for a coding_mode_required marker", () => {
    const result = skillInvocationFromContent(
      { skill_invocation: { status: "coding_mode_required" } },
      "`/security-review` runs a skill, which executes within this chat's Coding Mode workspace."
    )

    expect(result).toMatchObject({
      tone: "warning",
      body: "`/security-review` runs a skill, which executes within this chat's Coding Mode workspace."
    })
  })

  it("returns a warning-toned message for unknown_skill and invalid_args markers", () => {
    expect(skillInvocationFromContent({ skill_invocation: { status: "unknown_skill" } }, "No skill named `/dead-code-sweep`.")).toMatchObject({ tone: "warning" })
    expect(skillInvocationFromContent({ skill_invocation: { status: "invalid_args" } }, "`/investigate` needs valid arguments.")).toMatchObject({ tone: "warning" })
  })
})

describe("goalContinuationFromContent", () => {
  it("renders goal continuation markers as compact goal system messages", () => {
    const result = goalContinuationFromContent(
      {
        text: "Goal resumed. Continuing...",
        internal_prompt: "Continue the active goal after this goal-linked work boundary.\n\nEvent:\n{...}",
        source: "goal_continuation",
        goal_continuation: true
      },
      "Goal resumed. Continuing..."
    )

    expect(result).toEqual({
      tone: "neutral",
      label: "Goal",
      body: "Goal resumed. Continuing..."
    })
  })

  it("does not leak the hidden prompt through systemMessage", () => {
    const message = systemMessageItem({
      text: "Goal continuation started.",
      content: {
        text: "Goal continuation started.",
        internal_prompt: "Continue the active goal after this goal-linked work boundary.",
        source: "goal_continuation",
        goal_continuation: true
      }
    })

    expect(systemMessage(message)).toMatchObject({
      label: "Goal",
      body: "Goal continuation started."
    })
  })
})

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

  it("renders a skill-invocation guidance message with a non-neutral tone via the structured marker", () => {
    const message = systemMessageItem({
      text: "`/security-review` runs a skill, which executes within this chat's Coding Mode workspace. Enable Coding Mode for this chat, then run the command again.",
      content: {
        text: "`/security-review` runs a skill, which executes within this chat's Coding Mode workspace. Enable Coding Mode for this chat, then run the command again.",
        skill_invocation: { status: "coding_mode_required" }
      }
    })

    const result = systemMessage(message)

    expect(result).not.toBeNull()
    expect(result?.tone).not.toBe("neutral")
    expect(result?.body).toContain("Coding Mode")
  })

  it("is not filtered by isLowPrioritySystemMessage once tagged with the skill_invocation marker", () => {
    const message = systemMessageItem({
      text: "No skill named `/dead-code-sweep` is available for acme/widgets.",
      content: {
        text: "No skill named `/dead-code-sweep` is available for acme/widgets.",
        skill_invocation: { status: "unknown_skill" }
      }
    })
    const renderItem: ChatRenderItem = { ...message, system: systemMessage(message) ?? undefined }

    expect(isLowPrioritySystemMessage(renderItem)).toBe(false)
  })

  it("still falls through to the neutral catch-all for bare skill-guidance text without the marker (pre-fix behavior)", () => {
    const message = systemMessageItem({
      text: "`/security-review` runs a skill, which executes within this chat's Coding Mode workspace.",
      content: { text: "`/security-review` runs a skill, which executes within this chat's Coding Mode workspace." }
    })

    expect(systemMessage(message)).toMatchObject({ tone: "neutral", label: "System" })
  })
})
