import i18n from "@app/i18n"
import { isPlainObject, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "@app/routes/chat/toolCardUi"

const listCoworkerGrantsToolCard: ToolCardRenderer = {
  toolName: "list_coworker_grants",
  argumentSummary: () => "",
  collapsedSummary(context) {
    const coworkers = isPlainObject(context.parsedResult) && Array.isArray(context.parsedResult.coworkers) ? context.parsedResult.coworkers : []
    return i18n.t("coworkers:tool_card.grant_list_summary", { count: coworkers.length })
  },
  renderExpanded(context) {
    if (!isPlainObject(context.parsedResult) || !Array.isArray(context.parsedResult.coworkers)) return null
    return (
      <CardShell>
        {context.parsedResult.coworkers.map((raw, index) => {
          if (!isPlainObject(raw)) return null
          const grants = Array.isArray(raw.grants)
            ? raw.grants
                .filter(isPlainObject)
                .map((grant) => `${displayValue(grant.capability)}: ${displayValue(grant.approval_policy)}`)
                .join(", ")
            : ""
          return <Row key={displayValue(raw.id) || index} label={`@${displayValue(raw.handle)}`} value={grants} />
        })}
      </CardShell>
    )
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "coworker_grants",
    label: i18n.t("coworkers:tool_card.example_grant_list"),
    input: {},
    parsedResult: { coworkers: [{ id: 7, handle: "maya", grants: [{ capability: "workspace.files", approval_policy: "auto" }] }] }
  }
]

export default listCoworkerGrantsToolCard
