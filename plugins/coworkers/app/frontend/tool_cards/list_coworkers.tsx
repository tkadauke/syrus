import i18n from "@app/i18n"
import { isPlainObject, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "@app/routes/chat/toolCardUi"

const listCoworkersToolCard: ToolCardRenderer = {
  toolName: "list_coworkers",
  collapsedSummary(context) {
    const coworkers = isPlainObject(context.parsedResult) && Array.isArray(context.parsedResult.coworkers) ? context.parsedResult.coworkers : null
    return coworkers ? i18n.t("coworkers:tool_card.list_summary", { count: coworkers.length }) : null
  },
  renderExpanded(context) {
    if (!isPlainObject(context.parsedResult) || !Array.isArray(context.parsedResult.coworkers)) return null
    return (
      <CardShell>
        {context.parsedResult.coworkers.map((entry, index) => {
          if (!isPlainObject(entry)) return null
          return <Row key={displayValue(entry.id) || index} label={displayValue(entry.name)} value={`@${displayValue(entry.handle)}`} />
        })}
      </CardShell>
    )
  }
}

export default listCoworkersToolCard
