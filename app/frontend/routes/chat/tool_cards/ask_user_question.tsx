import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { MalformedCard, QuestionList, StatusCard, questionsFromInput, successOrError } from "../chatHelperToolCard"
import { countFromInputArray, ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "../toolFailureSummaryCard"

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
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />

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
