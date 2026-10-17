import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/pluginToolCards"
import { Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { CardShell, SectionLabel } from "@app/routes/chat/toolCardUi"

function summary(context: ToolCardContext) {
  const result = context.parsedResult
  if (!isPlainObject(result)) return "Accept insight"
  const ids = Array.isArray(result.insight_ids) ? result.insight_ids : []
  return ids.length ? `Accept ${ids.length} insight${ids.length === 1 ? "" : "s"}` : "Accept insights"
}

function Expanded({ context }: { context: ToolCardContext }) {
  const { t } = useT("agent_insights")

  return (
    <CardShell>
      <SectionLabel>{t("accept")}</SectionLabel>
      <Text>{summary(context)}</Text>
    </CardShell>
  )
}

const card: ToolCardRenderer = {
  toolName: "accept_insight",
  collapsedSummary: summary,
  renderExpanded: (context) => <Expanded context={context} />
}
export default card
