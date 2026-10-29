import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

function values(context: ToolCardContext) {
  if (!isPlainObject(context.parsedResult) || !isPlainObject(context.input)) return null
  const id = displayValue(context.parsedResult.pending_action_id)
  if (!id) return null
  const live = context.livePendingAction && displayValue(context.livePendingAction.id) === id ? context.livePendingAction : null
  return { id, state: live?.state || displayValue(context.parsedResult.state) || "pending", input: context.input }
}

const proposeCoworkerToolCard: ToolCardRenderer = {
  toolName: "propose_coworker",
  collapsedSummary(context) {
    const card = values(context)
    return card ? i18n.t("coworkers:tool_card.summary", { handle: displayValue(card.input.handle) }) : null
  },
  renderExpanded(context) {
    const card = values(context)
    if (!card) return null
    const grants = Array.isArray(card.input.grants) ? card.input.grants.map((grant) => displayValue(grant)).filter(Boolean).join(", ") : ""
    return <CardShell>
      <div className="flex items-center gap-2"><StatePill state={card.state} /><span className="text-sm font-medium">{i18n.t("coworkers:tool_card.title")}</span></div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={i18n.t("coworkers:fields.name")} value={displayValue(card.input.name)} />
        <Row label={i18n.t("coworkers:fields.handle")} value={`@${displayValue(card.input.handle)}`} />
        <Row label={i18n.t("coworkers:fields.remote")} value={displayValue(card.input.workspace_repo)} />
        <Row label={i18n.t("coworkers:fields.grants")} value={grants} />
      </dl>
      {displayValue(card.input.about) ? <Row label={i18n.t("coworkers:fields.about")} value={displayValue(card.input.about)} /> : null}
    </CardShell>
  }
}

export const examples: ToolCardExample[] = [{ id: "pending", label: "Pending coworker", input: { name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/coworkers.git", about: "Research lead", grants: ["workspace.files"] }, parsedResult: { pending_action_id: 501, state: "pending" } }]
export default proposeCoworkerToolCard
