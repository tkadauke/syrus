import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import type { ChatToolGroupItem } from "../../../api/chats"
import { ToolGroup } from "../MessageCards"
import askUserQuestionToolCard from "./ask_user_question"
import markGoalBlockedToolCard from "./mark_goal_blocked"
import markGoalCompletedToolCard from "./mark_goal_completed"
import renameChatToolCard from "./rename_chat"
import suggestNextStepToolCard from "./suggest_next_step"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("chat helper tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(askUserQuestionToolCard.toolName).toBe("ask_user_question")
    expect(suggestNextStepToolCard.toolName).toBe("suggest_next_step")
    expect(markGoalCompletedToolCard.toolName).toBe("mark_goal_completed")
    expect(markGoalBlockedToolCard.toolName).toBe("mark_goal_blocked")
    expect(renameChatToolCard.toolName).toBe("rename_chat")
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

  it("renders rename_chat old and new titles when available", () => {
    const parsedResult = { session_id: 42, previous_title: "Old title", title: "Release planning" }

    expect(renameChatToolCard.collapsedSummary?.(context("rename_chat", { parsedResult }))).toBe('Renamed "Old title" -> "Release planning"')
    render(<>{renameChatToolCard.renderExpanded(context("rename_chat", { parsedResult }))}</>)

    expect(screen.getAllByText("Old title").length).toBeGreaterThan(0)
    expect(screen.getByText("Release planning")).toBeInTheDocument()
  })

  it("renders missing payload fields as malformed cards instead of throwing", () => {
    expect(suggestNextStepToolCard.collapsedSummary?.(context("suggest_next_step", { parsedResult: { session_id: 42 } }))).toBe(
      "Next-step suggestion returned an unexpected response"
    )
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
