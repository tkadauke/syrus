import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import type { ChatToolGroupItem } from "../../../api/chats"
import { ToolGroup } from "../MessageCards"
import { normalizedToolCardParsedResult, normalizedToolName, parseJsonText } from "../toolRendering"
import { setSlugReferenceRegistryForTests } from "../../../lib/slugReferenceRegistry"
import askUserQuestionToolCard from "./ask_user_question"
import markGoalBlockedToolCard from "./mark_goal_blocked"
import markGoalCompletedToolCard from "./mark_goal_completed"
import pinChatToolCard from "./pin_chat"
import renameChatToolCard from "./rename_chat"
import suggestNextStepToolCard from "./suggest_next_step"
import unpinChatToolCard from "./unpin_chat"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  const resultBody = overrides.resultBody ?? ""
  const rawParsed = overrides.parsedResult === undefined ? parseJsonText(resultBody) : overrides.parsedResult
  return {
    toolName: normalizedToolName(toolName),
    resultBody,
    resultError: false,
    ...overrides,
    parsedResult: normalizedToolCardParsedResult(rawParsed)
  }
}

beforeEach(() => {
  setSlugReferenceRegistryForTests([
    {
      prefix: "JOB",
      type: "job",
      displayLabel: "Job",
      copyable: true,
      linkable: true,
      previewAvailable: false,
      linkifiesGeneratedText: true,
      hrefTemplate: "/jobs/:id",
      mobileInteractionHints: {},
      pluginPreviewComponent: null
    },
    {
      prefix: "CHAT",
      type: "chat",
      displayLabel: "Chat",
      copyable: true,
      linkable: false,
      previewAvailable: false,
      linkifiesGeneratedText: true,
      hrefTemplate: null,
      mobileInteractionHints: {},
      pluginPreviewComponent: null
    }
  ])
})

afterEach(() => setSlugReferenceRegistryForTests(null))

describe("chat helper tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(askUserQuestionToolCard.toolName).toBe("ask_user_question")
    expect(suggestNextStepToolCard.toolName).toBe("suggest_next_step")
    expect(markGoalCompletedToolCard.toolName).toBe("mark_goal_completed")
    expect(markGoalBlockedToolCard.toolName).toBe("mark_goal_blocked")
    expect(renameChatToolCard.toolName).toBe("rename_chat")
    expect(pinChatToolCard.toolName).toBe("pin_chat")
    expect(unpinChatToolCard.toolName).toBe("unpin_chat")
  })

  it("renders ask_user_question as an interaction summary with safe question labels and options", () => {
    const parsedResult = { question_id: 17, message: "Question(s) recorded." }
    const input = {
      questions: [
        { question: "Which path?", options: ["Fast", "Careful"] },
        { question: "Which environments?", options: ["Staging", "Production"], multiple: true },
        { question: "Anything else?" }
      ]
    }

    expect(askUserQuestionToolCard.collapsedSummary?.(context("ask_user_question", { parsedResult }))).toBe("Question request #17 recorded")
    render(<>{askUserQuestionToolCard.renderExpanded(context("ask_user_question", { input, parsedResult }))}</>)

    expect(screen.getByText("Question request")).toBeInTheDocument()
    expect(screen.getByText("waiting")).toBeInTheDocument()
    expect(screen.getByText("Which path?")).toBeInTheDocument()
    expect(screen.getByText("Fast")).toBeInTheDocument()
    expect(screen.getByText("Careful")).toBeInTheDocument()
    expect(screen.getByText("multi-select")).toBeInTheDocument()
    expect(screen.getByText("free text")).toBeInTheDocument()
    expect(screen.getByText("Question(s) recorded.")).toBeInTheDocument()
  })

  it("renders markdown, linked references, URLs, and touch-sized wrapping options", () => {
    const input = {
      questions: [
        {
          question: "Review **JOB-42** and DOC-7 at https://example.test/details?",
          options: ["Discuss CHAT-9 at https://example.test/option/with/a/very/long/path/that/must/wrap/instead/of/overflowing"]
        }
      ]
    }
    render(
      <MemoryRouter>
        {askUserQuestionToolCard.renderExpanded(
          context("ask_user_question", { input, parsedResult: { question_id: 17, message: "Waiting for **the operator**." } })
        )}
      </MemoryRouter>
    )

    expect(screen.getByText("JOB-42").closest("a")).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "DOC-7" })).toHaveAttribute("href", "/design_docs/7")
    expect(screen.getByRole("link", { name: "https://example.test/details" })).toHaveAttribute("href", "https://example.test/details")
    expect(screen.getByText("the operator").tagName).toBe("STRONG")
    expect(screen.getByRole("button", { name: "Copy CHAT-9 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /https:\/\/example\.test\/option/ })).toHaveAttribute(
      "href",
      "https://example.test/option/with/a/very/long/path/that/must/wrap/instead/of/overflowing"
    )
    expect(screen.getByTestId("question-option")).toHaveClass("min-h-11", "w-full", "min-w-0", "max-w-full", "sm:w-auto")
    expect(within(screen.getByTestId("question-option")).getByTestId("markdown-preview-content")).toHaveClass("break-words", "[overflow-wrap:anywhere]")
  })

  it("normalizes direct, result-body-only, and Codex-wrapped result envelopes", () => {
    const payload = { question_id: 17, message: "Question(s) recorded." }
    const contexts = [
      context("ask_user_question", { parsedResult: payload }),
      context("ask_user_question", { resultBody: JSON.stringify(payload) }),
      context("mcp__syrus-chat-sidecar__ask_user_question", {
        parsedResult: { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
      })
    ]

    for (const toolContext of contexts) {
      expect(toolContext.toolName).toBe("ask_user_question")
      expect(askUserQuestionToolCard.collapsedSummary?.(toolContext)).toBe("Question request #17 recorded")
    }
  })

  it("renders pending, error, and empty-result states", () => {
    const input = { questions: [{ question: "Which path?" }] }
    const pending = context("ask_user_question", { input })
    expect(askUserQuestionToolCard.collapsedSummary?.(pending)).toBe("Question request pending")
    const { rerender } = render(<>{askUserQuestionToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Waiting for the question request to finish.")).toBeInTheDocument()

    rerender(<>{askUserQuestionToolCard.renderExpanded(context("ask_user_question", { input, parsedResult: { question_id: 18, message: null } }))}</>)
    expect(screen.getByText("No result message was included.")).toBeInTheDocument()

    rerender(
      <>{askUserQuestionToolCard.renderExpanded(context("ask_user_question", { input, resultBody: "Question service unavailable.", resultError: true }))}</>
    )
    expect(screen.getByText("Question service unavailable.")).toBeInTheDocument()
  })

  it("treats a present but malformed parsed result as malformed rather than pending", () => {
    const malformed = context("ask_user_question", {
      input: { questions: [{ question: "Which path?" }] },
      parsedResult: { ok: true }
    })

    expect(askUserQuestionToolCard.collapsedSummary?.(malformed)).toBe("Question request returned an unexpected response")
    render(<>{askUserQuestionToolCard.renderExpanded(malformed)}</>)
    expect(screen.getByText("unknown")).toBeInTheDocument()
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
    expect(screen.queryByText("Waiting for the question request to finish.")).not.toBeInTheDocument()
  })

  it("renders suggest_next_step composer text and stored status", () => {
    const parsedResult = { session_id: 42, suggested_next_step: "Create an Epic from these findings" }

    expect(suggestNextStepToolCard.collapsedSummary?.(context("suggest_next_step", { parsedResult }))).toBe("Suggested: Create an Epic from these findings")
    render(<>{suggestNextStepToolCard.renderExpanded(context("suggest_next_step", { parsedResult }))}</>)

    expect(screen.getByText("Next-step suggestion")).toBeInTheDocument()
    expect(screen.getByText("stored")).toBeInTheDocument()
    expect(screen.getByText("Create an Epic from these findings")).toBeInTheDocument()
  })

  it("renders goal status transitions and rejected transition errors clearly", () => {
    const completed = { goal_id: 9, status: "completed", reason: "done" }
    expect(markGoalCompletedToolCard.collapsedSummary?.(context("mark_goal_completed", { parsedResult: completed }))).toBe("Goal #9 -> completed")
    render(<>{markGoalCompletedToolCard.renderExpanded(context("mark_goal_completed", { parsedResult: completed }))}</>)
    expect(screen.getByText("active -> completed")).toBeInTheDocument()
    expect(screen.getByText("done")).toBeInTheDocument()

    const blockedError = context("mark_goal_blocked", { resultBody: "goal is not active", resultError: true })
    expect(markGoalBlockedToolCard.collapsedSummary?.(blockedError)).toBe("Goal blocked transition failed")
    render(<>{markGoalBlockedToolCard.renderExpanded(blockedError)}</>)
    expect(screen.getByText("goal is not active")).toBeInTheDocument()
  })

  it("renders blocked goal metadata, structured details, linked markdown, and the returned previous status", () => {
    const longReason = `Waiting for **repository access** from JOB-42 at https://example.test/access. ${"Additional context. ".repeat(40)}`
    const input = {
      reason: longReason,
      details: { provider: "github", permission: "contents:write", nested: { repository: "acme/widgets" } }
    }
    const parsedResult = {
      goal_id: 17,
      status: "blocked",
      previous_status: "paused",
      reason: longReason,
      details: input.details,
      chat_session_id: 8,
      chat_title: "Release planning",
      chat_path: "/chats/8"
    }

    render(
      <MemoryRouter>{markGoalBlockedToolCard.renderExpanded(context("mcp__syrus-chat-sidecar__mark_goal_blocked", { input, parsedResult }))}</MemoryRouter>
    )

    expect(screen.getByRole("link", { name: /Goal #17 · Release planning/ })).toHaveAttribute("href", "/chats/8")
    expect(screen.getByText("paused -> blocked")).toBeInTheDocument()
    expect(screen.getByText("repository access").tagName).toBe("STRONG")
    expect(screen.getByText("JOB-42").closest("a")).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.test/access" })).toHaveAttribute("href", "https://example.test/access")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByText("Blocked details")).toBeInTheDocument()
    expect(screen.getByText("contents:write")).toBeInTheDocument()
    expect(screen.getByText('{"repository":"acme/widgets"}')).toHaveClass("break-words", "[overflow-wrap:anywhere]")
  })

  it("normalizes blocked goal result envelopes and preserves older responses", () => {
    const payload = { goal_id: 17, status: "blocked", reason: "Waiting for input" }
    const contexts = [
      context("mark_goal_blocked", { parsedResult: payload }),
      context("mark_goal_blocked", { resultBody: JSON.stringify(payload) }),
      context("mcp__syrus-chat-sidecar__mark_goal_blocked", {
        parsedResult: { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
      })
    ]

    for (const toolContext of contexts) {
      expect(toolContext.toolName).toBe("mark_goal_blocked")
      expect(markGoalBlockedToolCard.collapsedSummary?.(toolContext)).toBe("Goal #17 -> blocked")
    }

    render(<>{markGoalBlockedToolCard.renderExpanded(contexts[0])}</>)
    expect(screen.getByText("unknown -> blocked")).toBeInTheDocument()
  })

  it("renders blocked goal pending, empty-detail, and no-active-goal error states", () => {
    const pending = context("mark_goal_blocked", { input: { reason: "Waiting for **approval**", details: {} } })
    expect(markGoalBlockedToolCard.collapsedSummary?.(pending)).toBe("Goal blocked transition pending")
    const { rerender } = render(<>{markGoalBlockedToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("approval").tagName).toBe("STRONG")
    expect(screen.getByText("No structured blocked details were provided.")).toBeInTheDocument()
    expect(screen.getByText("Waiting for the goal transition to finish.")).toBeInTheDocument()

    rerender(<>{markGoalBlockedToolCard.renderExpanded(context("mark_goal_blocked", { resultBody: "active goal not found", resultError: true }))}</>)
    expect(screen.getByText("active goal not found")).toBeInTheDocument()
  })

  it("renders rename_chat old and new titles when available", () => {
    const parsedResult = { session_id: 42, previous_title: "Old title", title: "Release planning" }

    expect(renameChatToolCard.collapsedSummary?.(context("rename_chat", { parsedResult }))).toBe('Renamed "Old title" -> "Release planning"')
    render(<>{renameChatToolCard.renderExpanded(context("rename_chat", { parsedResult }))}</>)

    expect(screen.getAllByText("Old title").length).toBeGreaterThan(0)
    expect(screen.getByText("Release planning")).toBeInTheDocument()
  })

  it("renders chat pinning state changes", () => {
    const pinned = { session_id: 42, title: "Release planning", pinned: true, message: "Chat pinned." }
    expect(pinChatToolCard.collapsedSummary?.(context("pin_chat", { parsedResult: pinned }))).toBe("Chat pinned.")
    render(<>{pinChatToolCard.renderExpanded(context("pin_chat", { parsedResult: pinned }))}</>)
    expect(screen.getByText("Chat pin")).toBeInTheDocument()
    expect(screen.getByText("pinned")).toBeInTheDocument()
    expect(screen.getByText("Release planning")).toBeInTheDocument()

    const unpinned = { session_id: 42, title: "Release planning", pinned: false, message: "Chat unpinned." }
    expect(unpinChatToolCard.collapsedSummary?.(context("unpin_chat", { parsedResult: unpinned }))).toBe("Chat unpinned.")
    render(<>{unpinChatToolCard.renderExpanded(context("unpin_chat", { parsedResult: unpinned }))}</>)
    expect(screen.getByText("Chat unpin")).toBeInTheDocument()
    expect(screen.getByText("unpinned")).toBeInTheDocument()
  })

  it("renders missing payload fields as malformed cards instead of throwing", () => {
    expect(suggestNextStepToolCard.collapsedSummary?.(context("suggest_next_step", { parsedResult: { session_id: 42 } }))).toBe(
      "Next-step suggestion returned an unexpected response"
    )
    expect(pinChatToolCard.collapsedSummary?.(context("pin_chat", { parsedResult: { session_id: 42 } }))).toBe("Chat pin returned an unexpected response")
    render(<>{renameChatToolCard.renderExpanded(context("rename_chat", { parsedResult: { session_id: 42 } }))}</>)
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
  })
})

describe("chat helper tool rendering integration", () => {
  it("keeps helper cards collapsed by default and preserves raw details when expanded", () => {
    const resultBody = JSON.stringify({ goal_id: 9, status: "completed", reason: "done" })
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "mark_goal_completed",
      summary_label: "Goal #9 -> completed",
      outcome_label: "Done",
      collapsed_by_default: true,
      calls: [
        {
          message_id: 1,
          tool_name: "mark_goal_completed",
          raw_name: "mark_goal_completed",
          detail: "done",
          display_label: "Mark goal completed",
          progress_label: "Thinking",
          raw_payload: { reason: "done" },
          result_body: resultBody,
          result_json: { goal_id: 9, status: "completed", reason: "done" },
          result_error: false,
          result_kind: "record",
          result_summary: "Goal #9 -> completed"
        }
      ]
    }

    render(<ToolGroup item={item} />)

    expect(screen.getAllByText("Goal #9 -> completed").length).toBeGreaterThan(0)
    expect(screen.queryByText("active -> completed")).not.toBeInTheDocument()
    expect(screen.queryByText("Raw details")).not.toBeInTheDocument()

    const summary = screen.getAllByText("Goal #9 -> completed")[0].closest("summary")
    expect(summary).not.toBeNull()
    if (!summary) return
    fireEvent.click(summary)

    expect(screen.getByText("active -> completed")).toBeInTheDocument()
    expect(screen.getByText("Raw details")).toBeInTheDocument()
  })
})
