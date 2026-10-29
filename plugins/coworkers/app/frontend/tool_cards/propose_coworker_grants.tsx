import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

const proposeCoworkerGrantsToolCard: ToolCardRenderer = {
  toolName: "propose_coworker_grants",
  argumentSummary: () => "",
  collapsedSummary(context) {
    const payload = isPlainObject(context.parsedResult) && isPlainObject(context.parsedResult.grant_escalation) ? context.parsedResult.grant_escalation : null
    return payload ? i18n.t("coworkers:tool_card.grant_summary", { handle: displayValue(payload.handle) }) : null
  },
  renderExpanded(context) {
    if (!isPlainObject(context.parsedResult) || !isPlainObject(context.parsedResult.grant_escalation)) return null
    const payload = context.parsedResult.grant_escalation
    const id = displayValue(context.parsedResult.pending_action_id)
    const live = id && displayValue(context.livePendingAction?.id) === id ? context.livePendingAction : null
    const grants = Array.isArray(payload.grants)
      ? payload.grants
          .map((grant) => displayValue(grant))
          .filter(Boolean)
          .join(", ")
      : ""
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state={live?.state || displayValue(context.parsedResult.state) || "pending"} />
          <span className="text-sm font-medium">{i18n.t("coworkers:tool_card.grant_title")}</span>
        </div>
        <Row label={i18n.t("coworkers:fields.handle")} value={`@${displayValue(payload.handle)}`} />
        <Row label={i18n.t("coworkers:fields.grants")} value={grants} />
      </CardShell>
    )
  }
}

export default proposeCoworkerGrantsToolCard
