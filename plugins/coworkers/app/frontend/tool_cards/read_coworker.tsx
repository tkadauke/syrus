import i18n from "@app/i18n"
import { isPlainObject, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

const readCoworkerToolCard: ToolCardRenderer = {
  toolName: "read_coworker",
  collapsedSummary(context) {
    const coworker = isPlainObject(context.parsedResult) && isPlainObject(context.parsedResult.coworker) ? context.parsedResult.coworker : null
    return coworker ? i18n.t("coworkers:tool_card.read_summary", { handle: displayValue(coworker.handle) }) : null
  },
  renderExpanded(context) {
    if (!isPlainObject(context.parsedResult) || !isPlainObject(context.parsedResult.coworker)) return null
    const coworker = context.parsedResult.coworker
    const workspace = isPlainObject(coworker.workspace) ? coworker.workspace : {}
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state={displayValue(coworker.state) || "unknown"} />
          <span className="text-sm font-medium">{displayValue(coworker.name)}</span>
        </div>
        <Row label={i18n.t("coworkers:fields.handle")} value={`@${displayValue(coworker.handle)}`} />
        <Row label={i18n.t("coworkers:fields.remote")} value={displayValue(workspace.repository)} />
        <Row label={i18n.t("coworkers:fields.branch")} value={displayValue(workspace.home_branch)} />
      </CardShell>
    )
  }
}

export default readCoworkerToolCard
