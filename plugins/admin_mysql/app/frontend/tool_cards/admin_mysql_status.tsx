import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseStatusPayload, StatusCard, statusSummary } from "../adminMysqlToolCard"

function collapsedSummary(context: ToolCardContext) {
  return statusSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  if (!context.resultError && !parseStatusPayload(context)) return null
  return <StatusCard context={context} />
}

const adminMysqlStatusToolCard: ToolCardRenderer = {
  toolName: "admin_mysql_status",
  collapsedSummary,
  renderExpanded
}

export default adminMysqlStatusToolCard
