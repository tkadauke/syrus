import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/pluginToolCards"
import { Text } from "@app/components/ui"
import { CardShell, SectionLabel } from "@app/routes/chat/toolCardUi"

function summary(context: ToolCardContext) {
  const result = context.parsedResult
  if (!isPlainObject(result)) return "Accept insight"
  const ids = Array.isArray(result.insight_ids) ? result.insight_ids : []
  return ids.length ? `Accept ${ids.length} insight${ids.length === 1 ? "" : "s"}` : "Accept insights"
}

const card: ToolCardRenderer = {
  toolName: "accept_insight",
  collapsedSummary: summary,
  renderExpanded: (context) => (
    <CardShell>
      <SectionLabel>Acceptance</SectionLabel>
      <Text>{summary(context)}</Text>
    </CardShell>
  )
}
export default card
