import i18n from "@app/i18n"
import { isPlainObject, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

const spawnSyrusChatToolCard: ToolCardRenderer = {
  toolName: "spawn_syrus_chat",
  argumentSummary: (input) => displayValue(input?.title) || displayValue(input?.prompt) || "",
  collapsedSummary: (context) => displayValue(context.input?.title) || i18n.t("coworkers:tool_card.spawn_syrus_chat_title"),
  renderExpanded(context) {
    const result = isPlainObject(context.parsedResult) ? context.parsedResult : {}
    const pendingId = displayValue(result.pending_action_id)
    const live = pendingId && displayValue(context.livePendingAction?.id) === pendingId ? context.livePendingAction : null
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state={live?.state || displayValue(result.state) || (context.resultError ? "failed" : "confirmed")} />
          <span className="text-sm font-medium">{i18n.t("coworkers:tool_card.spawn_syrus_chat_title")}</span>
        </div>
        <Row label={i18n.t("coworkers:tool_card.repository")} value={displayValue(result.repository) || displayValue(context.input?.repository_id)} />
        <Row label={i18n.t("coworkers:tool_card.spawn_chat_prompt")} value={displayValue(context.input?.prompt)} />
      </CardShell>
    )
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_syrus_planner_chat",
    label: i18n.t("coworkers:tool_card.spawn_syrus_chat_pending"),
    input: { repository_id: 42, prompt: "Plan the engineering work", title: "Engineering plan" },
    parsedResult: { pending_action_id: 504, approval_policy: "queue" }
  }
]

export default spawnSyrusChatToolCard
