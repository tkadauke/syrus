import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { MalformedCard, QuestionList, StatusCard, questionsFromInput, successOrError } from "../chatHelperToolCard"
import { countFromInputArray, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type AskUserQuestionResult = { questionId: string; message: string | null }

const failureConfig: ToolFailureConfig = {
  title: "Operator question",
  attempted: (context) => {
    const count = countFromInputArray(context, "questions")
    return count == null ? "Ask operator question" : `Ask ${count} operator question${count === 1 ? "" : "s"}`
  },
  retrySafety: "caution",
  recovery: "Check whether the question card already appeared before retrying."
}

function parseAskUserQuestion(context: ToolCardContext) {
  return successOrError<AskUserQuestionResult>(context, "Question request failed.", (parsed) => {
    const questionId = displayValue(parsed.question_id)
    if (!questionId) return null
    return { questionId, message: displayValue(parsed.message) }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const parsed = parseAskUserQuestion(context)
  if (parsed.kind === "error") return "Question request failed"
  if (parsed.kind === "malformed") return "Question request returned an unexpected response"
  return `Question request #${parsed.data.questionId} recorded`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const parsed = parseAskUserQuestion(context)
  if (parsed.kind === "error") return <ToolFailureSummaryCard config={failureConfig} context={context} />
  if (parsed.kind === "malformed") return <MalformedCard title="Question request" />

  return (
    <StatusCard title="Question request" status="waiting">
      <Row label="Question set" value={`#${parsed.data.questionId}`} />
      <QuestionList questions={questionsFromInput(context.input)} />
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
    label: "Question recorded",
    input: { questions: [{ text: "Which environment should this target?", options: ["staging", "production"] }] },
    parsedResult: { question_id: "q_8f2c", message: "Waiting on the operator to answer in chat." }
  },
  {
    id: "question_request_failed",
    label: "Error: question request failed",
    description: "result_error true -- renders through the shared ToolFailureSummaryCard instead of the waiting-state card.",
    input: { questions: [{ text: "Which environment should this target?" }] },
    resultError: true,
    resultBody: "Chat session is not accepting new questions right now."
  },
  {
    id: "malformed_missing_question_id",
    label: "Malformed: missing question_id",
    description: "A plain object with no `question_id` key -- falls back to the shared MalformedCard instead of throwing.",
    input: { questions: [{ text: "Which environment should this target?" }] },
    parsedResult: { ok: true }
  }
]
