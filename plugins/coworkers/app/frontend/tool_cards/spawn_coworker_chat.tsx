import i18n from "@app/i18n"
import { isPlainObject, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

const spawnCoworkerChatToolCard: ToolCardRenderer = {
  toolName: "spawn_coworker_chat",
  argumentSummary: (input) => displayValue(input?.title) || displayValue(input?.prompt) || "",
  collapsedSummary: (context) => displayValue(context.input?.title) || i18n.t("coworkers:tool_card.spawn_chat_title"),
  renderExpanded(context) {
    const result = isPlainObject(context.parsedResult) ? context.parsedResult : {}
    const pendingId = displayValue(result.pending_action_id)
    const live = pendingId && displayValue(context.livePendingAction?.id) === pendingId ? context.livePendingAction : null
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state={live?.state || displayValue(result.state) || (context.resultError ? "failed" : "confirmed")} />
          <span className="text-sm font-medium">{i18n.t("coworkers:tool_card.spawn_chat_title")}</span>
        </div>
        <Row label={i18n.t("coworkers:fields.handle")} value={`@${displayValue(context.input?.handle)}`} />
        <Row label={i18n.t("coworkers:tool_card.spawn_chat_prompt")} value={displayValue(context.input?.prompt)} />
      </CardShell>
    )
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_coworker_side_chat",
    label: i18n.t("coworkers:tool_card.spawn_chat_pending"),
    input: { handle: "maya", prompt: "Investigate the flaky release check", title: "Release check" },
    parsedResult: { pending_action_id: 503, approval_policy: "confirm" }
  }
]

export default spawnCoworkerChatToolCard
