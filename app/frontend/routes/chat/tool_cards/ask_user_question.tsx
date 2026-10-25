import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { displayValue, EmptyState, Row } from "../toolCardUi"
import { MarkdownPreview } from "../toolCardMarkdown"
import { MalformedCard, QuestionList, StatusCard, questionsFromInput, successOrError } from "../chatHelperToolCard"
import {
  countFromInputArray,
  ToolFailureSummaryCard,
  toolFailureCollapsedSummary,
  toolFailureDetected,
  type ToolFailureConfig
} from "../toolFailureSummaryCard"

type AskUserQuestionResult = { questionId: string; message: string | null }

const failureConfig: ToolFailureConfig = {
  title: i18n.t("chat:tool_card_operator_question"),
  attempted: (context) => {
    const count = countFromInputArray(context, "questions")
    return count == null ? i18n.t("chat:tool_card_ask_operator_question") : i18n.t("chat:tool_card_ask_operator_questions", { count })
  },
  retrySafety: "caution",
  recovery: i18n.t("chat:tool_card_question_recovery")
}

function parseAskUserQuestion(context: ToolCardContext) {
  return successOrError<AskUserQuestionResult>(context, i18n.t("chat:tool_card_question_failed_period"), (parsed) => {
    const questionId = displayValue(parsed.question_id)
    if (!questionId) return null
    return { questionId, message: displayValue(parsed.message) }
  })
}

function requestIsPending(context: ToolCardContext) {
  return context.parsedResult == null && !context.resultBody.trim()
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const parsed = parseAskUserQuestion(context)
  if (parsed.kind === "error") return i18n.t("chat:tool_card_question_failed")
  if (parsed.kind === "malformed") return requestIsPending(context) ? i18n.t("chat:tool_card_question_pending") : i18n.t("chat:tool_card_question_unexpected")
  return i18n.t("chat:tool_card_question_recorded", { id: parsed.data.questionId })
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const parsed = parseAskUserQuestion(context)
  if (parsed.kind === "error") return <ToolFailureSummaryCard config={failureConfig} context={context} />
  if (parsed.kind === "malformed") {
    if (requestIsPending(context)) {
      return (
        <StatusCard title={i18n.t("chat:tool_card_question_request")} status="pending">
          <QuestionList questions={questionsFromInput(context.input)} />
          <EmptyState>{i18n.t("chat:tool_card_question_waiting")}</EmptyState>
        </StatusCard>
      )
    }
    return <MalformedCard title={i18n.t("chat:tool_card_question_request")} />
  }

  return (
    <StatusCard title={i18n.t("chat:tool_card_question_request")} status="waiting">
      <Row label={i18n.t("chat:tool_card_question_set")} value={`#${parsed.data.questionId}`} />
      <QuestionList questions={questionsFromInput(context.input)} />
      <MarkdownPreview
        emptyState={<EmptyState>{i18n.t("chat:tool_card_no_result_message")}</EmptyState>}
        linkifySlugs
        linkifyUrls
        maxChars={500}
        maxLines={4}
        text={parsed.data.message || ""}
        title={i18n.t("chat:tool_card_result")}
      />
    </StatusCard>
  )
}

const askUserQuestionToolCard: ToolCardRenderer = {
  toolName: "ask_user_question",
  collapsedSummary,
  renderExpanded
}

export default askUserQuestionToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "question_recorded",
    label: i18n.t("chat:tool_card_question_example_recorded"),
    input: { questions: [{ question: "Which environment should this target?", options: ["staging", "production"] }] },
    parsedResult: { question_id: "q_8f2c", message: "Waiting on the operator to answer in chat." }
  },
  {
    id: "question_request_failed",
    label: i18n.t("chat:tool_card_question_example_failed"),
    description: "result_error true -- renders through the shared ToolFailureSummaryCard instead of the waiting-state card.",
    input: { questions: [{ question: "Which environment should this target?" }] },
    resultError: true,
    resultBody: "Chat session is not accepting new questions right now."
  },
  {
    id: "malformed_missing_question_id",
    label: i18n.t("chat:tool_card_question_example_malformed"),
    description: i18n.t("chat:tool_card_question_example_malformed_description"),
    input: { questions: [{ question: "Which environment should this target?" }] },
    parsedResult: { ok: true }
  }
]
