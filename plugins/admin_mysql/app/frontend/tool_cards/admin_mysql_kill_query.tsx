import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { KillQueryCard, killQuerySummary, parseKillQueryPayload } from "../adminMysqlToolCard"

function collapsedSummary(context: ToolCardContext) {
  return killQuerySummary(context)
}

function renderExpanded(context: ToolCardContext) {
  if (!context.resultError && !parseKillQueryPayload(context)) return null
  return <KillQueryCard context={context} />
}

const adminMysqlKillQueryToolCard: ToolCardRenderer = {
  toolName: "admin_mysql_kill_query",
  collapsedSummary,
  renderExpanded
}

export default adminMysqlKillQueryToolCard
