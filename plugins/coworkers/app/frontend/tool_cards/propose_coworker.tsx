import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

function values(context: ToolCardContext) {
  if (!isPlainObject(context.parsedResult) || !isPlainObject(context.parsedResult.coworker)) return null
  const id = displayValue(context.parsedResult.pending_action_id)
  if (!id) return null
  const live = context.livePendingAction && displayValue(context.livePendingAction.id) === id ? context.livePendingAction : null
  return { id, state: live?.state || displayValue(context.parsedResult.state) || "pending", coworker: context.parsedResult.coworker }
}

function optional(value: unknown) {
  return displayValue(value) || i18n.t("coworkers:tool_card.account_default")
}

const proposeCoworkerToolCard: ToolCardRenderer = {
  toolName: "propose_coworker",
  argumentSummary: () => "",
  collapsedSummary(context) {
    const card = values(context)
    return card ? i18n.t("coworkers:tool_card.summary", { handle: displayValue(card.coworker.handle) }) : null
  },
  renderExpanded(context) {
    const card = values(context)
    if (!card) return null
    const grants = Array.isArray(card.coworker.grants)
      ? card.coworker.grants
          .map((grant) => displayValue(grant))
          .filter(Boolean)
          .join(", ")
      : ""
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state={card.state} />
          <span className="text-sm font-medium">{i18n.t("coworkers:tool_card.title")}</span>
        </div>
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label={i18n.t("coworkers:fields.name")} value={displayValue(card.coworker.name)} />
          <Row label={i18n.t("coworkers:fields.handle")} value={`@${displayValue(card.coworker.handle)}`} />
          <Row label={i18n.t("coworkers:fields.remote")} value={displayValue(card.coworker.workspace_repo)} />
          <Row label={i18n.t("coworkers:fields.color")} value={optional(card.coworker.color_key)} />
          <Row label={i18n.t("coworkers:fields.avatar")} value={optional(card.coworker.avatar_key)} />
          <Row label={i18n.t("coworkers:fields.provider")} value={optional(card.coworker.chat_provider)} />
          <Row label={i18n.t("coworkers:fields.model")} value={optional(card.coworker.chat_model)} />
          <Row label={i18n.t("coworkers:fields.effort")} value={optional(card.coworker.chat_effort)} />
          <Row label={i18n.t("coworkers:fields.grants")} value={grants} />
        </dl>
        <Row label={i18n.t("coworkers:fields.about")} value={displayValue(card.coworker.about) || i18n.t("coworkers:tool_card.not_provided")} />
      </CardShell>
    )
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "pending",
    label: i18n.t("coworkers:tool_card.example_pending"),
    input: { name: " Maya ", handle: "@Maya", workspace_repo: " https://github.com/acme/coworkers.git ", grants: ["workspace.files", "workspace.files"] },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      coworker: {
        name: "Maya",
        handle: "maya",
        workspace_repo: "https://github.com/acme/coworkers.git",
        about: "Research lead",
        color_key: "coral-deep",
        avatar_key: "comet",
        chat_provider: "codex",
        chat_model: "gpt-5.6-sol",
        chat_effort: "high",
        grants: ["workspace.files"]
      }
    }
  }
]
export default proposeCoworkerToolCard
