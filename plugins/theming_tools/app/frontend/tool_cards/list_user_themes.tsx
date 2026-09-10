import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, renderError, themeListSummary, themeRows, ThemeListBody } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  return errorSummary("Theme list", context) ?? themeListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError("Theme list", context)
  if (error) return error

  const rows = themeRows(context)
  if (!rows) return null

  return <ThemeListBody rows={rows} />
}

const listUserThemesToolCard: ToolCardRenderer = {
  toolName: "list_user_themes",
  collapsedSummary,
  renderExpanded
}

export default listUserThemesToolCard
