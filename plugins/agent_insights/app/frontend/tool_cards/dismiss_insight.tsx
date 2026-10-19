import i18n from "i18next"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/pluginToolCards"
import { Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { CardShell, SectionLabel } from "@app/routes/chat/toolCardUi"

function summary(context: ToolCardContext) {
  const result = context.parsedResult
  if (!isPlainObject(result)) return i18n.t("agent_insights:tool_dismiss_one")
  const ids = Array.isArray(result.insight_ids) ? result.insight_ids : []
  return ids.length ? i18n.t("agent_insights:tool_dismiss_count", { count: ids.length }) : i18n.t("agent_insights:tool_dismiss_many")
}

function Expanded({ context }: { context: ToolCardContext }) {
  const { t } = useT("agent_insights")

  return (
    <CardShell>
      <SectionLabel>{t("dismiss")}</SectionLabel>
      <Text>{summary(context)}</Text>
    </CardShell>
  )
}

const card: ToolCardRenderer = {
  toolName: "dismiss_insight",
  collapsedSummary: summary,
  renderExpanded: (context) => <Expanded context={context} />
}
export default card
