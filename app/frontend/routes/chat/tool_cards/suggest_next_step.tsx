import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { displayValue, Row } from "../toolCardUi"
import { compactSummary, ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type SuggestNextStepResult = { sessionId: string; text: string }

function parseSuggestNextStep(context: ToolCardContext) {
  return successOrError<SuggestNextStepResult>(context, i18n.t("chat:tool_card_next_step_failed_period"), (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const text = displayValue(parsed.suggested_next_step)
    if (!sessionId || !text) return null
    return { sessionId, text }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseSuggestNextStep(context)
  if (parsed.kind === "error") return i18n.t("chat:tool_card_next_step_failed")
  if (parsed.kind === "malformed") return i18n.t("chat:tool_card_next_step_unexpected")
  return i18n.t("chat:tool_card_next_step_suggested", { text: compactSummary(parsed.data.text) })
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseSuggestNextStep(context)
  if (parsed.kind === "error") return <ErrorCard title={i18n.t("chat:tool_card_next_step")} message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title={i18n.t("chat:tool_card_next_step")} />

  return (
    <StatusCard title={i18n.t("chat:tool_card_next_step")} status="stored">
      <div className="rounded border border-gray-200 bg-white px-2 py-1 font-medium text-gray-900 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-100">
        {parsed.data.text}
      </div>
      <Row label={i18n.t("chat:tool_card_chat")} value={`#${parsed.data.sessionId}`} />
    </StatusCard>
  )
}

const suggestNextStepToolCard: ToolCardRenderer = {
  toolName: "suggest_next_step",
  // The result summary owns the collapsed suggestion. Repeating the input
  // beside it adds no information, while the expanded card and raw details
  // retain the complete text.
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default suggestNextStepToolCard
