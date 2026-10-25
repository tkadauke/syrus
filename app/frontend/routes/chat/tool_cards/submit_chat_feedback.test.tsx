import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import type { ChatPendingActionInline } from "../../../api/chats"
import { normalizedToolName } from "../toolRendering"
import submitChatFeedbackToolCard, { examples } from "./submit_chat_feedback"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "submit_chat_feedback",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function liveAction(overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 501,
    action: "submit_chat_feedback",
    state: "confirmed",
    label: "Submit feedback",
    detail: null,
    app_confirm_path: "/api/v1/app/chats/1/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/1/pending_actions/501/reject",
    ...overrides
  }
}

describe("submit_chat_feedback tool card", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("registers catalog fixtures for pending media, queued, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["pending_with_feedback_and_media", "queued_feedback", "feedback_error"])

    for (const example of examples) {
      const exampleContext = toolCardContextForExample(submitChatFeedbackToolCard.toolName, example)
      expect(submitChatFeedbackToolCard.renderExpanded(exampleContext), example.id).not.toBeNull()
    }

    render(<>{submitChatFeedbackToolCard.renderExpanded(toolCardContextForExample(submitChatFeedbackToolCard.toolName, examples[0]))}</>)
    expect(screen.getByRole("img", { name: "Mobile header" })).toHaveAttribute("src", expect.stringMatching(/^data:image\/svg\+xml/))
    expect(screen.getByRole("button", { name: "Open Header hierarchy" })).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
  })

  it("registers under the exact MCP tool name", () => {
    expect(submitChatFeedbackToolCard.toolName).toBe("submit_chat_feedback")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__submit_chat_feedback")).toBe(submitChatFeedbackToolCard.toolName)
  })

  it("summarizes the collapsed row with the tool's own message", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." }
    })
    expect(submitChatFeedbackToolCard.collapsedSummary?.(context_)).toBe("Chat feedback requires operator confirmation.")
  })

  it("localizes generated summaries while preserving the canonical Job id", async () => {
    await i18n.changeLanguage("de")
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "queued", status: "queued" }
    })

    expect(submitChatFeedbackToolCard.collapsedSummary?.(context_)).toBe("Chat-Feedback für JOB-4048 eingereiht")
  })

  it("renders linked targets, feedback Markdown, media refs, and a pending-confirmation note", () => {
    const feedback = `Please fix the **header**. ${"Include the compact mobile layout in the next pass. ".repeat(20)}`
    const message = `**Chat feedback** requires operator confirmation. ${"Review the requested changes before starting the follow-up workflow. ".repeat(20)}`
    const context_ = context({
      input: { job_id: 4048, feedback, media: ["snapshot:42", "chat_image:7"] },
      parsedResult: {
        pending_confirmation_id: 501,
        pending_action_id: 501,
        state: "pending",
        message
      },
      presentation: { chatId: 12 }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("link", { name: "Pending action #501" })).toHaveAttribute("href", "/chats/12#pending-action-501")
    expect(screen.getByText("header", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("Chat feedback", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
    expect(screen.getByText("snapshot:42")).toBeInTheDocument()
    expect(screen.getByRole("img", { name: "chat_image:7" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/7/file")
    expect(screen.getByText("Confirming this will start a new chat_feedback workflow.")).toBeInTheDocument()
  })

  it("resolves chat media metadata into responsive preview tiles and falls back to a wrapping badge", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Review both references.", media: ["chat_image:7", "snapshot:42", "artifact:very-long-unresolved-reference"] },
      parsedResult: { pending_action_id: 501, state: "pending", message: "Confirm feedback." },
      presentation: {
        chatId: 12,
        chatMedia: {
          snapshots: [{ id: 42, name: "Header sketch", snapshot_kind: "manual", element_count: 3, created_at: "2026-10-20T12:00:00Z" }],
          chat_images: [{ id: 7, title: "Mobile header", filename: "header.png", content_type: "image/png", image_url: "/media/header.png" }],
          typed_artifacts: [],
          whiteboard_has_unsaved_content: false
        }
      }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByRole("img", { name: "Mobile header" })).toHaveAttribute("src", "/media/header.png")
    expect(screen.getByRole("button", { name: "Open Header sketch" })).toBeInTheDocument()
    expect(screen.getByText("3 whiteboard elements")).toBeInTheDocument()
    expect(screen.getByText("artifact:very-long-unresolved-reference").parentElement).toHaveClass("break-words")
  })

  it("rejects unsafe stored media URLs and falls back to the reference badge", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Review the attachment.", media: ["chat_image:7"] },
      parsedResult: { pending_action_id: 501, state: "pending", message: "Confirm feedback." },
      presentation: {
        chatMedia: {
          snapshots: [],
          chat_images: [{ id: 7, title: "Unsafe image", filename: "unsafe.png", content_type: "image/png", image_url: "javascript:alert('unsafe')" }],
          typed_artifacts: [],
          whiteboard_has_unsaved_content: false
        }
      }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.queryByRole("img", { name: "Unsafe image" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Open image" })).not.toBeInTheDocument()
    expect(screen.getByText("chat_image:7")).toBeInTheDocument()
  })

  it("renders the queued state distinctly from the pending-confirmation state", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: {
        pending_confirmation_id: 501,
        pending_action_id: 501,
        state: "queued",
        status: "queued",
        message: "Feedback queued - will appear for your confirmation once JOB-4048 finishes its current run."
      }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText(/chat_feedback workflow starts once it is confirmed/)).toBeInTheDocument()
  })

  it("prefers the live pending action's state over the frozen tool-result state, and drops the forward-looking hint once resolved", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." },
      livePendingAction: liveAction({ state: "confirmed" })
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
    expect(screen.queryByText("Confirming this will start a new chat_feedback workflow.")).not.toBeInTheDocument()
  })

  it("ignores a live pending action for a different id", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." },
      livePendingAction: liveAction({ id: 999, state: "confirmed" })
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
  })

  it("omits the media section when no media was attached", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.queryByText("Media")).not.toBeInTheDocument()
  })

  it.each([
    ["text content", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })],
    ["structured content", (payload: unknown) => ({ content: [], structured_content: payload })]
  ])("uses the shared normalizer for a %s envelope", (_label, envelope) => {
    const payload = { pending_action_id: 501, state: "pending", message: "Confirm **feedback**." }
    const context_ = context({
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__submit_chat_feedback"),
      input: { job_id: 4048, feedback: "Fix **mobile** spacing." },
      parsedResult: normalizedToolCardParsedResult(envelope(payload))
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("mobile", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("feedback", { selector: "strong" })).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload and preserves input context for errors", () => {
    expect(submitChatFeedbackToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(submitChatFeedbackToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    render(
      <>
        {submitChatFeedbackToolCard.renderExpanded(
          context({
            input: { job_id: 4048, feedback: "Fix the **header**.", media: ["snapshot:42"] },
            resultError: true,
            parsedResult: null,
            resultBody: "Error: feedback is required"
          })
        )}
      </>
    )
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: feedback is required")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("header", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("snapshot:42")).toBeInTheDocument()
  })
})
