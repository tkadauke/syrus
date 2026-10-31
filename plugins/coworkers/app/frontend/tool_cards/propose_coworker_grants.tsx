import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
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
          .map((grant) => (isPlainObject(grant) ? `${displayValue(grant.capability)}: ${displayValue(grant.policy)}` : displayValue(grant)))
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

export const examples: ToolCardExample[] = [
  {
    id: "pending_grant_escalation",
    label: i18n.t("coworkers:tool_card.example_grant_pending"),
    input: {
      coworker_id: 7,
      grants: [
        { capability: "workspace.shell", policy: "confirm" },
        { capability: "syrus.propose_job", policy: "off" }
      ]
    },
    parsedResult: {
      pending_confirmation_id: 502,
      pending_action_id: 502,
      state: "pending",
      message: "Grant additional capabilities to @maya?",
      grant_escalation: {
        coworker_id: 7,
        handle: "maya",
        grants: [
          { capability: "workspace.shell", policy: "confirm" },
          { capability: "syrus.propose_job", policy: "off" }
        ]
      }
    }
  }
]

export default proposeCoworkerGrantsToolCard
