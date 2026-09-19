import { describe, expect, it } from "vitest"
import type { ChatCrossChatBridge, ChatMessageItem, ChatRenderItem } from "../../api/chats"
import { isLowPrioritySystemMessage } from "./messageDisplay"
import { crossChatBridgeSystemMessage, goalContinuationFromContent, skillInvocationFromContent, systemMessage } from "./systemMessages"

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
    expect(skillInvocationFromContent({ skill_invocation: { status: "unknown_skill" } }, "No skill named `/dead-code-sweep`.")).toMatchObject({
      tone: "warning"
    })
    expect(skillInvocationFromContent({ skill_invocation: { status: "invalid_args" } }, "`/investigate` needs valid arguments.")).toMatchObject({
      tone: "warning"
    })
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

  it("renders batched goal continuation notices without leaking the nested prompt", () => {
    const message = systemMessageItem({
      text: "Goal continuation started.\n\nProposal confirmed. JOB-716 was created.",
      content: {
        text: "Goal continuation started.\n\nProposal confirmed. JOB-716 was created.",
        source: "queued_internal_notice_batch",
        notices: [
          {
            text: "Goal continuation started.",
            source: "goal_continuation",
            content: {
              text: "Goal continuation started.",
              internal_prompt: "Continue the active goal after this goal-linked work boundary.",
              source: "goal_continuation",
              goal_continuation: true
            }
          },
          {
            text: "Proposal confirmed. JOB-716 was created.",
            source: "proposal_notification",
            content: {
              text: "Proposal confirmed. JOB-716 was created.",
              source: "proposal_notification",
              outcome: "confirmed"
            }
          }
        ]
      }
    })

    expect(systemMessage(message)).toMatchObject({
      label: "Goal",
      body: "Goal continuation started."
    })
  })
})

describe("crossChatBridgeSystemMessage", () => {
  function bridge(overrides: Partial<ChatCrossChatBridge> = {}): ChatCrossChatBridge {
    return {
      thread_id: 7,
      direction: "outbound",
      counterpart_chat_session_id: 42,
      counterpart_chat_title: "Debugging session",
      ...overrides
    }
  }

  it("renders the outbound message with a linking cta to the target chat", () => {
    const result = crossChatBridgeSystemMessage({ ...systemMessageItem(), cross_chat_bridge: bridge() }, "Sent to chat #42: check on JOB-1")

    expect(result).toEqual({
      tone: "neutral",
      label: "Cross-chat",
      body: "Sent to chat #42: check on JOB-1",
      cta: { label: "via Chat #42: Debugging session", path: "/chats/42" }
    })
  })

  it("falls back to the new-chat label when the counterpart has no title, matching the inbound badge's fallback", () => {
    const result = crossChatBridgeSystemMessage(
      { ...systemMessageItem(), cross_chat_bridge: bridge({ counterpart_chat_title: null }) },
      "Sent to chat #42: check on JOB-1"
    )

    expect(result?.cta).toEqual({ label: "via Chat #42: New chat", path: "/chats/42" })
  })

  it("renders the hop-limit closure notice with a warning tone and no cta", () => {
    const result = crossChatBridgeSystemMessage(
      { ...systemMessageItem(), cross_chat_bridge: bridge({ direction: "closed" }) },
      "Cross-chat thread #7 reached its hop limit (6) and has been closed."
    )

    expect(result).toEqual({
      tone: "warning",
      label: "Cross-chat",
      body: "Cross-chat thread #7 reached its hop limit (6) and has been closed."
    })
  })

  it("returns null for the inbound direction, which renders as a normal user bubble instead", () => {
    const result = crossChatBridgeSystemMessage({ ...systemMessageItem(), cross_chat_bridge: bridge({ direction: "inbound" }) }, "check on JOB-1")

    expect(result).toBeNull()
  })

  it("returns null when the message carries no cross_chat_bridge data", () => {
    expect(crossChatBridgeSystemMessage(systemMessageItem(), "hello")).toBeNull()
  })

  it("is not filtered by isLowPrioritySystemMessage despite its neutral tone", () => {
    const message = { ...systemMessageItem(), cross_chat_bridge: bridge() }
    const renderItem: ChatRenderItem = { ...message, system: systemMessage(message) ?? undefined }

    expect(isLowPrioritySystemMessage(renderItem)).toBe(false)
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
