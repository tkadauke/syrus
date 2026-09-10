import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { compactSummary, ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type SuggestNextStepResult = { sessionId: string; text: string }

function parseSuggestNextStep(context: ToolCardContext) {
  return successOrError<SuggestNextStepResult>(context, "Next-step suggestion failed.", (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const text = displayValue(parsed.suggested_next_step)
    if (!sessionId || !text) return null
    return { sessionId, text }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseSuggestNextStep(context)
  if (parsed.kind === "error") return "Next-step suggestion failed"
  if (parsed.kind === "malformed") return "Next-step suggestion returned an unexpected response"
  return `Suggested: ${compactSummary(parsed.data.text)}`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseSuggestNextStep(context)
  if (parsed.kind === "error") return <ErrorCard title="Next-step suggestion" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Next-step suggestion" />

  return (
    <StatusCard title="Next-step suggestion" status="stored">
      <div className="rounded border border-gray-200 bg-white px-2 py-1 font-medium text-gray-900 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-100">
        {parsed.data.text}
      </div>
      <Row label="Chat" value={`#${parsed.data.sessionId}`} />
    </StatusCard>
  )
}

const suggestNextStepToolCard: ToolCardRenderer = {
  toolName: "suggest_next_step",
  collapsedSummary,
  renderExpanded
}

export default suggestNextStepToolCard
