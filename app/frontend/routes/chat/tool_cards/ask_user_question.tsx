import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { ErrorCard, MalformedCard, QuestionList, StatusCard, questionsFromInput, successOrError } from "../chatHelperToolCard"

type AskUserQuestionResult = { questionId: string; message: string | null }

function parseAskUserQuestion(context: ToolCardContext) {
  return successOrError<AskUserQuestionResult>(context, "Question request failed.", (parsed) => {
    const questionId = displayValue(parsed.question_id)
    if (!questionId) return null
    return { questionId, message: displayValue(parsed.message) }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseAskUserQuestion(context)
  if (parsed.kind === "error") return "Question request failed"
  if (parsed.kind === "malformed") return "Question request returned an unexpected response"
  return `Question request #${parsed.data.questionId} recorded`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseAskUserQuestion(context)
  if (parsed.kind === "error") return <ErrorCard title="Question request" message={parsed.message} />
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
